import Combine
import Foundation
import GhosttyKit

/// The production screen model for tmux workspaces: owns one
/// GhosttyKitRuntime (per session, as before) and one
/// TmuxTerminalSession, connects through the app's prepared-transport
/// pooling, and reports the domain `TerminalRuntimeState` vocabulary
/// the root model already reduces (badges, auto-reconnect).
@MainActor
final class TmuxScreenModel: ObservableObject {
    typealias TransportFactory = @MainActor (TmuxConnectionTarget) -> any TmuxControlTransport

    let target: TmuxConnectionTarget
    let sessionInstanceID: UUID

    /// The screen-facing facet: presents this session through the
    /// GhosttyTerminalScreenModeling boundary for GhosttySurfaceScreen.
    /// Created before the runtime because it is the runtime's surface
    /// delegate (scroll state delivery).
    let terminalScreenAdapter = TmuxTerminalScreenAdapter()

    @Published private(set) var session: TmuxTerminalSession?
    @Published private(set) var startupFailure: String?

    /// The reducer's expectations: the target this session connects to.
    var runtimeConnectionTarget: TmuxConnectionTarget { target }

    /// The viewport the root carries into the replacement model on
    /// reconnect for a sized attach. Prefers the last size reported
    /// with the viewport in its settled shape, so disconnecting while
    /// the keyboard is up does not make the next attach first-paint
    /// at the keyboard-shrunken size.
    var carriedClientSize: TmuxSessionController.ClientSize? {
        session?.controller.carriedClientSize
    }

    /// True when no connection exists or is in progress, so the root
    /// model may replace this model (e.g. after a server edit) without
    /// dropping a session the user is still attached to.
    var isDisconnected: Bool {
        guard let session else { return true }
        switch session.state {
        case .detached, .closed: return true
        case .attaching, .syncing, .ready: return false
        }
    }

    private let transportFactory: TransportFactory
    private let onRuntimeStateChange: (TerminalRuntimeStateUpdate) -> Void
    private var runtime: GhosttyKitRuntime?
    private var currentTerminalSettings: TerminalSettings
    private var reportTracker = TerminalRuntimeStateReportTracker()
    private var pendingReconnectSource: TerminalReconnectSource?
    private var pendingForegroundInactiveReason: TerminalDisconnectReason?
    private var stateObservation: AnyCancellable?
    private var transportFailureObservation: AnyCancellable?
    private var stopped = false

    private let initialClientSize: TmuxSessionController.ClientSize?

    init(
        target: TmuxConnectionTarget,
        sessionInstanceID: UUID,
        transportFactory: @escaping TransportFactory,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void,
        initialClientSize: TmuxSessionController.ClientSize? = nil
    ) {
        self.target = target
        self.sessionInstanceID = sessionInstanceID
        self.transportFactory = transportFactory
        self.onRuntimeStateChange = onRuntimeStateChange
        self.currentTerminalSettings = target.terminalSettings
        self.initialClientSize = initialClientSize
        start()
    }

    private func start() {
        let flow = "session.open.\(target.workspace.id.uuidString)"
        let runtimeInitStart = GhosttyRuntimeTrace.nowNanos()
        let runtime: GhosttyKitRuntime
        do {
            runtime = try GhosttyKitRuntime(
                surfaceDelegate: terminalScreenAdapter,
                terminalSettings: target.terminalSettings
            )
        } catch {
            startupFailure = String(describing: error)
            report(.disconnected(Self.runtimeStartFailureReason))
            return
        }
        self.runtime = runtime
        GhosttyRuntimeTrace.flowEventIfActive(
            flow,
            event: "model.runtime.init",
            fields: ["elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: runtimeInitStart)]
        )

        let session = TmuxTerminalSession(
            app: runtime.appHandle,
            makeTransport: { [transportFactory, target] in
                transportFactory(target)
            },
            baseSurfaceConfig: { [runtime] in
                runtime.makeTmuxBaseSurfaceConfig()
            },
            paneViewTheme: { [weak self, target] in
                self?.currentTerminalSettings.theme ?? target.terminalSettings.theme
            }
        )
        self.session = session
        terminalScreenAdapter.activate(session: session)

        // Sized attach: a viewport carried from the previous runtime
        // attempt is reported before connect, so the engine pipelines
        // refresh-client -C ahead of the baseline and every capture
        // lands at this client's width (no relayout churn, physical
        // rows byte-exact).
        if let size = initialClientSize {
            session.controller.setClientSize(cols: size.cols, rows: size.rows)
        }

        stateObservation = session.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.handleSessionState(state)
            }

        // A failed connect can leave the state unchanged (.detached(nil)
        // before and after), which the deduplicated state stream drops;
        // the failure itself is the report-worthy signal.
        transportFailureObservation = session.$transportFailure
            .compactMap { $0 }
            .sink { [weak self] failure in
                self?.report(.disconnected(failure))
            }

        GhosttyRuntimeTrace.flowEventIfActive(flow, event: "model.session.created")
        connect()
    }

    /// Connect or reconnect; the session keeps its state across
    /// detaches, so this is the single (re)entry point.
    func connect() {
        report(currentRuntimeState(for: session?.state ?? .attaching, connecting: true))
        session?.connect(viewport: nil)
    }

    func reconnect(source: TerminalReconnectSource) {
        pendingReconnectSource = source
        connect()
    }

    func handleAppLifecyclePhase(_ phase: GhosttyAppLifecyclePhase) {
        // Presentation discontinuity handling lives in the renderer
        // (visibility-resume full damage); here we gate drawing.
        session?.paneSurface?.setVisible(phase == .active)

        guard phase == .active else { return }
        guard let session, case .ready = session.state else {
            reportForegroundDisconnectedStateIfNeeded()
            return
        }

        Task { [weak self] in
            await self?.handleForegroundActivation()
        }
    }

    private func handleForegroundActivation() async {
        guard !stopped else { return }
        if let session,
           case .ready = session.state,
           let reason = await session.invalidateInactiveSSHTransportOnForeground(
               willInvalidate: { reason in
                   pendingForegroundInactiveReason = reason
               }
           ) {
            if pendingForegroundInactiveReason != nil {
                pendingForegroundInactiveReason = nil
                report(.disconnected(reason), source: .foreground)
            }
            return
        }

        reportForegroundDisconnectedStateIfNeeded()
    }

    private func reportForegroundDisconnectedStateIfNeeded() {
        // Foreground is a reconnect opportunity: re-surface a
        // disconnected state with the foreground source so the root's
        // auto-reconnect policy can act on it (the report tracker
        // re-reports foreground disconnects even when unchanged).
        let state: TerminalRuntimeState = if let session {
            currentRuntimeState(for: session.state, connecting: false)
        } else {
            .disconnected(Self.runtimeStartFailureReason)
        }
        if state.disconnectedReason != nil {
            report(state, source: .foreground)
        }
    }

    /// Live settings application: updates the runtime's config (which
    /// libghostty propagates to existing surfaces), the base config used
    /// for surfaces bound to panes in the future, and the bound pane
    /// view's theme.
    func applyTerminalSettings(_ settings: TerminalSettings) throws {
        currentTerminalSettings = settings
        try runtime?.applyTerminalSettings(settings)
        session?.paneSurface?.view.applyTerminalTheme(settings.theme)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        stateObservation = nil
        transportFailureObservation = nil
        terminalScreenAdapter.invalidate()
        if let session {
            await session.shutdown()
        }
        session = nil
        runtime = nil
    }

    // MARK: Domain state reporting

    private func handleSessionState(_ state: TmuxSessionController.SessionState) {
        if case .ready = state {
            pendingReconnectSource = nil
            pendingForegroundInactiveReason = nil
        }
        if case .detached = state,
           let reason = pendingForegroundInactiveReason {
            pendingForegroundInactiveReason = nil
            report(.disconnected(reason), source: .foreground)
            return
        }
        report(currentRuntimeState(for: state, connecting: false))
    }

    private func currentRuntimeState(
        for state: TmuxSessionController.SessionState,
        connecting: Bool
    ) -> TerminalRuntimeState {
        switch state {
        case .attaching, .syncing:
            if let source = pendingReconnectSource {
                return .reconnecting(source)
            }
            return .connecting
        case .ready:
            return .connected
        case .detached(let reason):
            if connecting {
                // A (re)connect is being initiated from a detached
                // session: report progress, not the stale detach.
                if let source = pendingReconnectSource {
                    return .reconnecting(source)
                }
                return .connecting
            }
            if let reason {
                return .disconnected(reason.terminalDisconnectReason)
            }
            return .disconnected(
                session?.transportFailure ?? TerminalDisconnectReason(
                    kind: .unknown,
                    message: "disconnected"
                )
            )
        case .closed(let reason):
            return .disconnected(reason.terminalDisconnectReason)
        }
    }

    private func report(
        _ state: TerminalRuntimeState,
        source: TerminalRuntimeStateUpdateSource = .runtime
    ) {
        guard reportTracker.shouldReport(state: state, source: source) else {
            return
        }
        onRuntimeStateChange(TerminalRuntimeStateUpdate(
            workspaceID: target.workspace.id,
            instanceID: sessionInstanceID,
            state: state,
            source: source
        ))
    }

    private static let runtimeStartFailureReason = TerminalDisconnectReason(
        kind: .runtime,
        message: "terminal runtime failed to initialize"
    )
}
