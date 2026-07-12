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
    private var pendingForegroundInactiveReason: TerminalDisconnectReason?
    private var stateObservation: AnyCancellable?
    private var transportFailureObservation: AnyCancellable?
    private var stopped = false
    private var initialViewport: TmuxControlViewport?
    private var lastSubmittedClientSize: TmuxSessionController.ClientSize?

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
        terminalScreenAdapter.activate(
            session: session,
            initialViewportHandler: { [weak self] size, scale in
                self?.prepareInitialViewport(size: size, scale: scale)
            },
            clientSizeHandler: { [weak self] size in
                self?.submitClientSizeIfChanged(size)
            }
        )

        if let size = initialClientSize {
            initialViewport = TmuxControlViewport(clientSize: size)
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
        if let initialViewport {
            connect(viewport: initialViewport)
        }
    }

    private func connect(viewport: TmuxControlViewport) {
        initialViewport = viewport
        submitClientSizeIfChanged(TmuxSessionController.ClientSize(
            cols: UInt32(viewport.columns),
            rows: UInt32(viewport.rows)
        ))
        report(currentRuntimeState(for: session?.state ?? .attaching, connecting: true))
        session?.connect(viewport: viewport)
    }

    private func prepareInitialViewport(size: CGSize, scale: CGFloat) {
        guard !stopped else { return }
        guard initialViewport == nil else { return }
        guard let runtime else { return }

        do {
            guard let viewport = try runtime.measureTmuxViewport(size: size, scale: scale) else {
                return
            }
            connect(viewport: viewport)
        } catch {
            startupFailure = String(describing: error)
            report(.disconnected(Self.initialViewportFailureReason))
        }
    }

    /// The single host authority for this control connection's client grid.
    /// Record before queueing so repeated pane layouts cannot enqueue duplicate
    /// controller work while the first submission is still pending.
    @discardableResult
    func submitClientSizeIfChanged(
        _ size: TmuxSessionController.ClientSize
    ) -> Bool {
        guard !stopped, let controller = session?.controller else { return false }
        guard size != lastSubmittedClientSize else { return false }
        lastSubmittedClientSize = size
        controller.setClientSize(cols: size.cols, rows: size.rows)
        return true
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
           let reason = await session.invalidateInactiveTransportOnForeground(
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
        if let state = foregroundDisconnectedState() {
            report(state, source: .foreground)
        }
    }

    private func foregroundDisconnectedState() -> TerminalRuntimeState? {
        guard let session else {
            return .disconnected(Self.runtimeStartFailureReason)
        }

        switch session.state {
        case .attaching, .syncing, .ready:
            return nil
        case .detached(let reason):
            if let reason {
                return .disconnected(reason.terminalDisconnectReason)
            }
            guard let failure = session.transportFailure else {
                return nil
            }
            return .disconnected(failure)
        case .closed(let reason):
            return .disconnected(reason.terminalDisconnectReason)
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
            return .connecting
        case .ready:
            return .connected
        case .detached(let reason):
            if connecting {
                // A connection is being initiated from the session's
                // initial detached state: report progress, not the stale
                // detach.
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

    private static let initialViewportFailureReason = TerminalDisconnectReason(
        kind: .runtime,
        message: "terminal viewport failed to initialize"
    )
}
