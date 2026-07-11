import Foundation
import GhosttyKit

/// Orchestrates one tmux session end to end for the UI: owns the
/// controller for the session's whole life, builds a link per
/// connection (the controller's state survives detaches), and presents
/// the active window's active pane as a surface.
///
/// STATE DISCIPLINE: the session model inside libghostty is the single
/// source of truth. This object holds no derived topology — it
/// re-publishes immutable snapshots and reacts to them; the displayed
/// pane is always recomputed from the latest snapshot, so UI state
/// cannot drift from the server.
@MainActor
final class TmuxTerminalSession: ObservableObject {
    @Published private(set) var state: TmuxSessionController.SessionState = .detached(nil)
    @Published private(set) var topology: TmuxSessionController.TopologySnapshot?
    @Published private(set) var paneSurface: TmuxPaneSurface?
    @Published private(set) var lastFailedRequest: TmuxSessionController.Request?

    /// Set when a connection attempt fails before the session ever
    /// attaches (SSH dial, auth, host key, control-channel open). The
    /// controller has no event for host-side failures, so this carries
    /// the classified reason alongside the `.detached(nil)` state.
    @Published private(set) var transportFailure: TerminalDisconnectReason?

    private let app: ghostty_app_t
    private(set) var controller: TmuxSessionController!
    private var link: TmuxSessionLink?
    private let makeTransport: () -> any TmuxControlTransport
    private let baseSurfaceConfig: () -> ghostty_surface_config_s
    private let paneViewTheme: () -> TerminalTheme

    /// The asynchronous pane-surface creator. Injectable so the
    /// in-flight-create vs `shutdown()` drain ordering can be tested
    /// deterministically without a live pane binding; defaults to the
    /// real creator.
    typealias PaneSurfaceCreator = @MainActor (
        ghostty_app_t,
        TmuxSessionController,
        TmuxPaneID,
        ghostty_surface_config_s,
        TerminalTheme,
        @escaping @MainActor (Result<TmuxPaneSurface, TmuxPaneSurface.CreateError>) -> Void
    ) -> Void
    private let createPaneSurface: PaneSurfaceCreator

    /// Serialized pane transition in flight. A transition releases and
    /// dematerializes the outgoing pane before binding the incoming pane, so
    /// Remux never owns two live pane engines at once.
    private var presentingPaneID: TmuxPaneID?

    private enum PaneTransitionPhase {
        case releasing
        case awaitingTopology
        case creating
    }

    /// Release may start from the picker tap, before tmux confirms the new
    /// active pane. The phase keeps that overlap explicit and prevents an
    /// incoming bind until both release and topology confirmation complete.
    private var paneTransitionPhase: PaneTransitionPhase?

    /// Latest picker intent that tmux has not confirmed yet. This is separate
    /// from topology: the latter remains the only source of truth for what may
    /// actually be presented.
    private var pendingSelectionPaneID: TmuxPaneID?

    /// Detach and shutdown can arrive while release is still asynchronous.
    /// The completion must drain the transition without attempting a bind.
    private var stopPaneTransitionAfterRelease = false

    /// Remux phone policy presents the active pane at full viewport
    /// size. When tmux reports an unzoomed split window, request zoom
    /// and wait for the confirming topology before binding/capturing.
    private var awaitingZoomPaneID: TmuxPaneID?

    /// If tmux rejects the zoom request, do not spin forever. Present
    /// the pane at the server's current geometry until the active pane
    /// changes or a later topology reports it zoomed.
    private var zoomFailedPaneID: TmuxPaneID?

    /// Number of pane transitions whose completion has not yet run. The
    /// release and create halves both touch the controller's writer queue, so
    /// `shutdown()` drains these to zero before freeing the controller.
    private var inFlightCreateCount = 0

    /// Set once teardown has begun. Gates new connects and new pane
    /// presentation, and makes any late create completion discard its
    /// surface instead of binding it to a dying session.
    private var isShutDown = false

    /// Resumed when the last in-flight create completes during shutdown.
    private var shutdownDrainContinuation: CheckedContinuation<Void, Never>?

    /// What to do with the result of an in-flight pane-surface creation.
    /// Pure so the shutdown-race rule (a surface created after teardown
    /// begins must be closed, never presented) is unit-testable without
    /// a live tmux binding.
    enum CreatedSurfaceDisposition: Equatable {
        /// Bind it as the live surface.
        case present
        /// Close it: the session shut down, or the desired pane moved on.
        case discard
        /// Creation failed; nothing was allocated.
        case ignoreFailure
    }

    static func createdSurfaceDisposition(
        isShutDown: Bool,
        creationSucceeded: Bool,
        stillDesired: Bool
    ) -> CreatedSurfaceDisposition {
        guard creationSucceeded else { return .ignoreFailure }
        guard !isShutDown else { return .discard }
        return stillDesired ? .present : .discard
    }

    /// Breaks the init cycle: controller callbacks are built before
    /// `self` is fully initialized.
    private final class Relay: @unchecked Sendable {
        /// Main-actor confined: written once after init, read inside
        /// MainActor.assumeIsolated blocks only.
        weak var target: TmuxTerminalSession?
    }

    init(
        app: ghostty_app_t,
        makeTransport: @escaping () -> any TmuxControlTransport,
        baseSurfaceConfig: @escaping () -> ghostty_surface_config_s,
        paneViewTheme: @escaping () -> TerminalTheme,
        createPaneSurface: @escaping PaneSurfaceCreator = TmuxPaneSurface.create
    ) {
        self.app = app
        self.makeTransport = makeTransport
        self.baseSurfaceConfig = baseSurfaceConfig
        self.paneViewTheme = paneViewTheme
        self.createPaneSurface = createPaneSurface

        let relay = Relay()
        self.controller = TmuxSessionController(
            app: app,
            callbacks: TmuxSessionController.Callbacks(
                // The controller invokes these on the main queue.
                onState: { state in
                    MainActor.assumeIsolated { relay.target?.handleState(state) }
                },
                onTopology: { snapshot in
                    MainActor.assumeIsolated { relay.target?.handleTopology(snapshot) }
                },
                onPaneRemoved: { _ in
                    // The next topology snapshot names the successor;
                    // until then the bound surface shows the frozen
                    // final frame (zombie semantics).
                },
                onPaneLive: { _ in },
                onPaneDegraded: { _ in },
                onRequestFailed: { request in
                    MainActor.assumeIsolated { relay.target?.handleRequestFailed(request) }
                }
            )
        )
        relay.target = self
    }

    // MARK: Connection lifecycle

    /// Connect (or reconnect — the session state, engines, and any
    /// bound surface survive detaches).
    func connect(viewport: TmuxControlViewport?) {
        guard !isShutDown else { return }
        guard link == nil else { return }
        transportFailure = nil
        let link = TmuxSessionLink(controller: controller, transport: makeTransport())
        self.link = link
        // Detached so transport startup is not serialized behind the
        // main actor: a Task inheriting this @MainActor context could
        // not begin until the main actor drains, and on session open the
        // main actor is busy with the SwiftUI navigation push for tens
        // of milliseconds while an already authenticated SSH root sits
        // idle (device trace 2026-06-12: root ready at ~5ms, transport
        // start at 81ms with the inherited task). Late teardown is safe:
        // shutdown() fences and drains in-flight work.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await link.start(viewport: viewport)
            } catch {
                await self?.connectFailed(link: link, error: error)
            }
        }
    }

    private func connectFailed(link failed: TmuxSessionLink, error: any Error) async {
        await failed.stop()
        if link === failed { link = nil }
        // The model never attached (transport-level failure); classify
        // the error so the UI can offer the right repair action.
        GhosttyRuntimeTrace.diagnostics(
            "tmuxSession.connectFailed error=\(String(describing: error))"
        )
        transportFailure = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(error)
        state = .detached(nil)
    }

    func disconnect() async {
        guard let link else { return }
        self.link = nil
        await link.stop()
    }

    func invalidateInactiveTransportOnForeground(
        willInvalidate: (TerminalDisconnectReason) -> Void
    ) async -> TerminalDisconnectReason? {
        guard let link else { return nil }
        guard let isActive = await link.controlChannelIsActive() else {
            return nil
        }
        guard !isActive else { return nil }
        guard self.link === link else { return nil }

        let reason = GhosttyTerminalDisconnectReasonClassifier.foregroundMissingHost()
        willInvalidate(reason)
        await link.invalidateTransport()
        return reason
    }

    /// Full teardown, in contract order: fence new work, drain any
    /// in-flight pane-surface creation, then pane surface (surface free →
    /// unbind), then the link, then the controller. Idempotent.
    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        pendingSelectionPaneID = nil

        switch paneTransitionPhase {
        case .awaitingTopology:
            finishPaneTransition(redriveLatestTopology: false)
        case .releasing:
            stopPaneTransitionAfterRelease = true
        case .creating, nil:
            break
        }

        // Drain in-flight creation before freeing the controller: a late
        // completion closes its surface (`ghostty_surface_free` +
        // `unbind`), which is only safe while the session is alive.
        if inFlightCreateCount > 0 {
            await withCheckedContinuation { continuation in
                shutdownDrainContinuation = continuation
            }
        }

        let surface = paneSurface
        paneSurface = nil
        await withCheckedContinuation { continuation in
            if let surface {
                surface.close { _ in continuation.resume() }
            } else {
                continuation.resume()
            }
        }
        await disconnect()
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
    }

    private func resumeShutdownDrainIfQuiescent() {
        guard inFlightCreateCount == 0, let continuation = shutdownDrainContinuation else {
            return
        }
        shutdownDrainContinuation = nil
        continuation.resume()
    }

    // MARK: Event handling (main actor)

    private func handleState(_ newState: TmuxSessionController.SessionState) {
        state = newState
        if case .detached = newState {
            awaitingZoomPaneID = nil
            zoomFailedPaneID = nil
            pendingSelectionPaneID = nil
            switch paneTransitionPhase {
            case .awaitingTopology:
                finishPaneTransition(redriveLatestTopology: false)
            case .releasing:
                stopPaneTransitionAfterRelease = true
            case .creating, nil:
                break
            }
            // Transport links don't outlive the connection; drop ours
            // so a reconnect builds a fresh one. The pane surface
            // stays: its binding (and frozen content) survive the
            // detach and re-bootstrap refreshes it on reconnect.
            if let link {
                self.link = nil
                Task { await link.stop() }
            }
        } else if newState == .ready,
                  paneSurface == nil,
                  paneTransitionPhase == nil,
                  let topology {
            // A detach during an eager release intentionally leaves no
            // surface. Re-drive the retained canonical snapshot on reconnect
            // even if tmux does not emit a structurally different topology.
            presentActivePane(from: topology)
        }
    }

    #if DEBUG
    private(set) var requestedZoomPaneIDsForTesting: [TmuxPaneID] = []

    func handleStateForTesting(_ newState: TmuxSessionController.SessionState) {
        handleState(newState)
    }

    func handleRequestFailedForTesting(_ request: TmuxSessionController.Request) {
        handleRequestFailed(request)
    }
    #endif

    /// Internal (not private) so a test can drive pane presentation —
    /// and therefore an in-flight create — without a live tmux session.
    func handleTopology(_ snapshot: TmuxSessionController.TopologySnapshot) {
        topology = snapshot
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "presentation.topology.received",
            fields: [
                "active_pane": Self.activePaneID(in: snapshot).map(String.init) ?? "none",
            ]
        )
        if paneTransitionPhase == .awaitingTopology {
            advanceReleasedPaneTransition()
        } else {
            presentActivePane(from: snapshot)
        }
    }

    private func handleRequestFailed(_ request: TmuxSessionController.Request) {
        lastFailedRequest = request
        if request == .selectPane {
            pendingSelectionPaneID = nil
            if paneTransitionPhase == .awaitingTopology {
                advanceReleasedPaneTransition()
            }
            return
        }
        guard request == .zoomPane else { return }
        guard let paneID = awaitingZoomPaneID else { return }
        awaitingZoomPaneID = nil
        zoomFailedPaneID = paneID
        if let topology {
            presentActivePane(from: topology)
        }
    }

    /// Begin releasing the outgoing pane as soon as a validated picker intent
    /// is queued. Topology still authorizes the incoming bind; this only moves
    /// teardown under the SSH/tmux round trip.
    func prepareForPaneSelection(paneID: TmuxPaneID) {
        guard !isShutDown else { return }
        guard topology?.panes.contains(where: { $0.id == paneID }) == true else { return }
        guard paneSurface?.paneID != paneID else { return }

        pendingSelectionPaneID = paneID
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "presentation.selection.prepared",
            fields: ["pane": "\(paneID)"]
        )

        switch paneTransitionPhase {
        case .releasing:
            presentingPaneID = paneID
        case .awaitingTopology:
            presentingPaneID = paneID
            advanceReleasedPaneTransition()
        case .creating:
            // Creation already owns a native pane binding. Its completion
            // will discard if the confirmed target moves on, then re-drive.
            break
        case nil:
            beginPaneTransition(to: paneID)
        }
    }

    /// The presentation rule, recomputed from every snapshot: show the
    /// active window's active pane.
    private func presentActivePane(from snapshot: TmuxSessionController.TopologySnapshot) {
        guard !isShutDown else { return }
        guard
            let windowID = snapshot.activeWindowID,
            let window = snapshot.windows.first(where: { $0.id == windowID }),
            let paneID = window.activePaneID
        else { return }

        if awaitingZoomPaneID != paneID {
            awaitingZoomPaneID = nil
        }
        if zoomFailedPaneID != paneID {
            zoomFailedPaneID = nil
        }

        // Phone presentation policy (matches the legacy pipeline): the
        // presented pane is zoomed so it owns the full client size.
        // Run this before the same-pane early return: another tmux
        // client can split/unzoom the currently presented window without
        // changing the active pane, and Remux still must restore the
        // full-screen mobile presentation.
        let hasSiblingPane = snapshot.panes.contains {
            $0.windowID == windowID && $0.id != paneID
        }
        if !window.zoomed, hasSiblingPane, zoomFailedPaneID != paneID {
            if awaitingZoomPaneID == paneID {
                GhosttyRuntimeTrace.flowEventOnce(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "presentation.zoom.waiting",
                    fields: ["pane": "\(paneID)"]
                )
                return
            }
            awaitingZoomPaneID = paneID
            #if DEBUG
            requestedZoomPaneIDsForTesting.append(paneID)
            #endif
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.zoom.requested",
                fields: ["pane": "\(paneID)"]
            )
            controller.requestZoomPane(paneID: paneID)
            return
        }
        awaitingZoomPaneID = nil
        if window.zoomed {
            zoomFailedPaneID = nil
        }

        if paneSurface?.paneID == paneID { return }

        if presentingPaneID == paneID {
            guard paneTransitionPhase == .awaitingTopology else { return }
            if pendingSelectionPaneID == paneID {
                pendingSelectionPaneID = nil
            }
            paneTransitionPhase = .creating
            createPaneSurfaceAfterRelease(paneID: paneID)
            return
        }

        // One transition at a time. If topology moves again while release or
        // creation is in flight, its completion re-drives the latest snapshot.
        guard presentingPaneID == nil else { return }

        beginPaneTransition(to: paneID)
    }

    private func beginPaneTransition(to paneID: TmuxPaneID) {
        presentingPaneID = paneID
        paneTransitionPhase = .releasing
        stopPaneTransitionAfterRelease = false
        inFlightCreateCount += 1

        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "presentation.transition.begin",
            fields: [
                "incoming": "\(paneID)",
                "outgoing": paneSurface.map { "\($0.paneID)" } ?? "none",
            ]
        )

        let previous = paneSurface
        paneSurface = nil

        guard let previous else {
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.release.skipped",
                fields: ["incoming": "\(paneID)"]
            )
            paneReleaseCompleted()
            return
        }

        let releaseStartedAt = GhosttyRuntimeTrace.flowTraceEnabled
            ? GhosttyRuntimeTrace.nowNanos() : 0
        let outgoingPaneID = previous.paneID
        GhosttyRuntimeTrace.perf(
            "tmuxPane.transition release.begin outgoing=\(outgoingPaneID) incoming=\(paneID)"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "presentation.release.begin",
            fields: [
                "incoming": "\(paneID)",
                "outgoing": "\(outgoingPaneID)",
            ],
            at: releaseStartedAt == 0 ? nil : releaseStartedAt
        )
        previous.close { [weak self] releaseResult in
            guard let self else { return }
            GhosttyRuntimeTrace.perf(
                "tmuxPane.transition release.end outgoing=\(outgoingPaneID) incoming=\(paneID) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: releaseStartedAt))"
            )
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.release.end",
                fields: [
                    "incoming": "\(paneID)",
                    "outgoing": "\(outgoingPaneID)",
                    "result": String(describing: releaseResult),
                ]
            )
            guard case .success = releaseResult else {
                GhosttyRuntimeTrace.flowEndIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "presentation.release.failed",
                    fields: [
                        "incoming": "\(paneID)",
                        "outgoing": "\(outgoingPaneID)",
                    ]
                )
                self.finishPaneTransition(redriveLatestTopology: false)
                return
            }
            self.paneReleaseCompleted()
        }
    }

    private func paneReleaseCompleted() {
        guard paneTransitionPhase == .releasing else {
            assertionFailure("pane release completed outside the releasing phase")
            return
        }
        guard !isShutDown, !stopPaneTransitionAfterRelease else {
            finishPaneTransition(redriveLatestTopology: false)
            return
        }

        paneTransitionPhase = .awaitingTopology
        advanceReleasedPaneTransition()
    }

    private func advanceReleasedPaneTransition() {
        guard paneTransitionPhase == .awaitingTopology else { return }
        guard !isShutDown else {
            finishPaneTransition(redriveLatestTopology: false)
            return
        }
        guard let topology else { return }

        if let pendingSelectionPaneID,
           pendingSelectionPaneID != presentingPaneID {
            presentingPaneID = pendingSelectionPaneID
        }
        guard let presentingPaneID else {
            assertionFailure("awaiting topology without a pane target")
            finishPaneTransition(redriveLatestTopology: false)
            return
        }

        let confirmedPaneID = Self.activePaneID(in: topology)
        if let pendingSelectionPaneID {
            guard confirmedPaneID == pendingSelectionPaneID else {
                GhosttyRuntimeTrace.flowEventOnce(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "presentation.selection.waiting",
                    fields: [
                        "confirmed": confirmedPaneID.map(String.init) ?? "none",
                        "pane": "\(pendingSelectionPaneID)",
                    ]
                )
                return
            }
        } else if confirmedPaneID != presentingPaneID {
            finishPaneTransition(redriveLatestTopology: true)
            return
        }

        presentActivePane(from: topology)
    }

    private func createPaneSurfaceAfterRelease(paneID: TmuxPaneID) {
        guard !isShutDown else {
            GhosttyRuntimeTrace.flowEndIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.create.cancelled",
                fields: ["reason": "shutdown"]
            )
            finishPaneTransition(redriveLatestTopology: false)
            return
        }

        let desiredPaneID = topology.flatMap(Self.activePaneID(in:))
        guard desiredPaneID == paneID else {
            GhosttyRuntimeTrace.flowEndIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.create.cancelled",
                fields: [
                    "desired": desiredPaneID.map(String.init) ?? "none",
                    "pane": "\(paneID)",
                    "reason": "target_changed",
                ]
            )
            finishPaneTransition(redriveLatestTopology: true)
            return
        }

        let createStartedAt = GhosttyRuntimeTrace.flowTraceEnabled
            ? GhosttyRuntimeTrace.nowNanos() : 0
        GhosttyRuntimeTrace.perf("tmuxPane.transition create.begin pane=\(paneID)")
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "presentation.create.begin",
            fields: ["pane": "\(paneID)"],
            at: createStartedAt == 0 ? nil : createStartedAt
        )
        createPaneSurface(
            app,
            controller,
            paneID,
            baseSurfaceConfig(),
            paneViewTheme()
        ) { [weak self] result in
            let createdSurface: TmuxPaneSurface?
            switch result {
            case .success(let surface): createdSurface = surface
            case .failure: createdSurface = nil
            }

            guard let self else {
                // The session was deallocated while this create was in
                // flight: close any surface so it is not released without
                // close() (the borrowed-handle contract).
                createdSurface?.close()
                return
            }
            // The desired pane may have moved on while binding; re-check
            // against the LATEST snapshot before showing.
            let stillDesired = self.topology.flatMap(Self.activePaneID(in:)) == paneID
                && (self.pendingSelectionPaneID == nil || self.pendingSelectionPaneID == paneID)

            switch Self.createdSurfaceDisposition(
                isShutDown: self.isShutDown,
                creationSucceeded: createdSurface != nil,
                stillDesired: stillDesired
            ) {
            case .ignoreFailure:
                // AlreadyBound/unknown: a newer snapshot will retry;
                // nothing to roll back.
                GhosttyRuntimeTrace.perf(
                    "tmuxPane.transition create.failed pane=\(paneID) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: createStartedAt))"
                )
                GhosttyRuntimeTrace.flowEndIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "presentation.create.failed",
                    fields: ["pane": "\(paneID)"]
                )
                let shouldRedrive = !self.isShutDown
                    && (self.topology.flatMap(Self.activePaneID(in:)) != paneID
                        || self.pendingSelectionPaneID != nil)
                self.finishPaneTransition(redriveLatestTopology: shouldRedrive)
            case .discard:
                // Shut down mid-flight, or the desired pane moved on:
                // close the orphan instead of binding it. The transition
                // stays in flight until unbind + dematerialize completes;
                // otherwise a re-drive could bind the successor while this
                // orphan engine still exists.
                guard let createdSurface else {
                    self.finishPaneTransition(redriveLatestTopology: !self.isShutDown)
                    return
                }
                let shouldRedrive = !self.isShutDown
                GhosttyRuntimeTrace.flowEventIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "presentation.create.discarding",
                    fields: ["pane": "\(paneID)"]
                )
                createdSurface.close { [weak self] releaseResult in
                    guard let self else { return }
                    guard case .success = releaseResult else {
                        GhosttyRuntimeTrace.flowEndIfActive(
                            GhosttyRuntimeTrace.paneSwitchFlow,
                            event: "presentation.discard.failed",
                            fields: ["pane": "\(paneID)"]
                        )
                        self.finishPaneTransition(redriveLatestTopology: false)
                        return
                    }
                    GhosttyRuntimeTrace.flowEndIfActive(
                        GhosttyRuntimeTrace.paneSwitchFlow,
                        event: "presentation.discard.ready",
                        fields: ["pane": "\(paneID)"]
                    )
                    self.finishPaneTransition(
                        redriveLatestTopology: shouldRedrive
                    )
                }
            case .present:
                assert(self.paneSurface == nil)
                self.paneSurface = createdSurface
                GhosttyRuntimeTrace.perf(
                    "tmuxPane.transition create.ready pane=\(paneID) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: createStartedAt))"
                )
                GhosttyRuntimeTrace.flowEventIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "presentation.create.ready",
                    fields: [
                        "pane": "\(paneID)",
                        "surface": createdSurface.map { String(describing: $0.rawSurface) } ?? "missing",
                    ]
                )
                self.finishPaneTransition(redriveLatestTopology: false)
            }
        }
    }

    private static func activePaneID(
        in snapshot: TmuxSessionController.TopologySnapshot
    ) -> TmuxPaneID? {
        snapshot.activeWindowID.flatMap { windowID in
            snapshot.windows.first(where: { $0.id == windowID })?.activePaneID
        }
    }

    private func finishPaneTransition(redriveLatestTopology: Bool) {
        presentingPaneID = nil
        paneTransitionPhase = nil
        stopPaneTransitionAfterRelease = false
        inFlightCreateCount -= 1
        assert(inFlightCreateCount >= 0)
        resumeShutdownDrainIfQuiescent()

        guard redriveLatestTopology, !isShutDown, let topology else { return }
        presentActivePane(from: topology)
    }
}
