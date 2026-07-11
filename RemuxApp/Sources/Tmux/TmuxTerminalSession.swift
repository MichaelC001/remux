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

    /// One reducer owns the release/confirmation/create handoff. Native work
    /// remains performed by this session, but no independent flags can form an
    /// impossible transition state.
    private var panePresentation = TmuxPanePresentationStateMachine()

    /// Remux phone policy presents the active pane at full viewport
    /// size. When tmux reports an unzoomed split window, request zoom
    /// and wait for the confirming topology before binding/capturing.
    private enum PaneZoomState: Equatable {
        case idle
        case awaiting(TmuxPaneID)
        case suppressed(TmuxPaneID)
    }

    /// If tmux rejects zoom, suppression prevents a request loop until the
    /// active pane changes or a later topology confirms zoom.
    private var paneZoomState = PaneZoomState.idle

    /// Set once teardown has begun. Gates new connects and new pane
    /// presentation, and makes any late create completion discard its
    /// surface instead of binding it to a dying session.
    private var isShutDown = false

    /// Resumed when the last in-flight create completes during shutdown.
    private var shutdownDrainContinuation: CheckedContinuation<Void, Never>?

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
        handlePresentationEffect(panePresentation.reduce(.stop))

        // Drain in-flight creation before freeing the controller: a late
        // completion closes its surface (`ghostty_surface_free` +
        // `unbind`), which is only safe while the session is alive.
        if panePresentation.hasNativeWorkInFlight {
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
        guard !panePresentation.hasNativeWorkInFlight,
              let continuation = shutdownDrainContinuation
        else {
            return
        }
        shutdownDrainContinuation = nil
        continuation.resume()
    }

    // MARK: Event handling (main actor)

    private func handleState(_ newState: TmuxSessionController.SessionState) {
        state = newState
        if case .detached = newState {
            paneZoomState = .idle
            handlePresentationEffect(panePresentation.reduce(.detached))
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
                  panePresentation.state == .idle,
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
        presentActivePane(from: snapshot)
    }

    private func handleRequestFailed(_ request: TmuxSessionController.Request) {
        lastFailedRequest = request
        if request == .selectPane {
            handlePresentationEffect(panePresentation.reduce(
                .selectionRequestFailed(
                    confirmedPane: topology.flatMap(Self.activePaneID(in:))
                )
            ))
            return
        }
        guard request == .zoomPane else { return }
        guard case .awaiting(let paneID) = paneZoomState else { return }
        paneZoomState = .suppressed(paneID)
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

        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "presentation.selection.prepared",
            fields: ["pane": "\(paneID)"]
        )

        handlePresentationEffect(panePresentation.reduce(
            .requestSelection(
                target: paneID,
                outgoing: paneSurface?.paneID
            )
        ))
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

        switch paneZoomState {
        case .awaiting(let zoomPaneID), .suppressed(let zoomPaneID):
            if zoomPaneID != paneID {
                paneZoomState = .idle
            }
        case .idle:
            break
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
        let zoomSuppressed = paneZoomState == .suppressed(paneID)
        if !window.zoomed, hasSiblingPane, !zoomSuppressed {
            if paneZoomState == .awaiting(paneID) {
                GhosttyRuntimeTrace.flowEventOnce(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "presentation.zoom.waiting",
                    fields: ["pane": "\(paneID)"]
                )
                return
            }
            paneZoomState = .awaiting(paneID)
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
        if window.zoomed {
            paneZoomState = .idle
        }

        if case .awaitingTopology = panePresentation.state {
            handlePresentationEffect(panePresentation.reduce(
                .reconcile(confirmedPane: paneID)
            ))
            return
        }

        guard panePresentation.state == .idle
                || isFailedPresentationState
        else { return }
        if paneSurface?.paneID == paneID { return }

        handlePresentationEffect(panePresentation.reduce(
            .requirePresentation(
                target: paneID,
                outgoing: paneSurface?.paneID
            )
        ))
    }

    private var isFailedPresentationState: Bool {
        if case .failed = panePresentation.state { return true }
        return false
    }

    private func releasePresentedPane(outgoingPaneID: TmuxPaneID?) {
        let incomingPaneID = panePresentation.targetPaneID
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "presentation.transition.begin",
            fields: [
                "incoming": incomingPaneID.map(String.init) ?? "none",
                "outgoing": outgoingPaneID.map(String.init) ?? "none",
            ]
        )

        let previous = paneSurface
        paneSurface = nil

        guard let previous else {
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.release.skipped",
                fields: ["incoming": incomingPaneID.map(String.init) ?? "none"]
            )
            handlePresentationEffect(panePresentation.reduce(
                .releaseCompleted(
                    succeeded: true,
                    confirmedPane: topology.flatMap(Self.activePaneID(in:))
                )
            ))
            return
        }
        assert(outgoingPaneID == previous.paneID)

        let releaseStartedAt = GhosttyRuntimeTrace.flowTraceEnabled
            ? GhosttyRuntimeTrace.nowNanos() : 0
        let releasedPaneID = previous.paneID
        GhosttyRuntimeTrace.perf(
            "tmuxPane.transition release.begin outgoing=\(releasedPaneID) incoming=\(incomingPaneID.map(String.init) ?? "none")"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "presentation.release.begin",
            fields: [
                "incoming": incomingPaneID.map(String.init) ?? "none",
                "outgoing": "\(releasedPaneID)",
            ],
            at: releaseStartedAt == 0 ? nil : releaseStartedAt
        )
        previous.close { [weak self] releaseResult in
            guard let self else { return }
            GhosttyRuntimeTrace.perf(
                "tmuxPane.transition release.end outgoing=\(releasedPaneID) incoming=\(incomingPaneID.map(String.init) ?? "none") elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: releaseStartedAt))"
            )
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.release.end",
                fields: [
                    "incoming": incomingPaneID.map(String.init) ?? "none",
                    "outgoing": "\(releasedPaneID)",
                    "result": String(describing: releaseResult),
                ]
            )
            let succeeded: Bool
            if case .success = releaseResult {
                succeeded = true
            } else {
                succeeded = false
                GhosttyRuntimeTrace.flowEndIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "presentation.release.failed",
                    fields: [
                        "incoming": incomingPaneID.map(String.init) ?? "none",
                        "outgoing": "\(releasedPaneID)",
                    ]
                )
            }
            self.handlePresentationEffect(self.panePresentation.reduce(
                .releaseCompleted(
                    succeeded: succeeded,
                    confirmedPane: self.topology.flatMap(Self.activePaneID(in:))
                )
            ))
        }
    }

    private func createPaneSurfaceAfterRelease(paneID: TmuxPaneID) {
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
            let confirmedPaneID = self.topology.flatMap(Self.activePaneID(in:))
            let stillDesired = self.panePresentation.isCreateStillDesired(
                pane: paneID,
                confirmedPane: confirmedPaneID
            )
            if createdSurface == nil {
                GhosttyRuntimeTrace.perf(
                    "tmuxPane.transition create.failed pane=\(paneID) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: createStartedAt))"
                )
                GhosttyRuntimeTrace.flowEndIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "presentation.create.failed",
                    fields: ["pane": "\(paneID)"]
                )
            }
            let effect = self.panePresentation.reduce(
                .createCompleted(
                    pane: paneID,
                    succeeded: createdSurface != nil,
                    stillDesired: stillDesired,
                    confirmedPane: confirmedPaneID
                )
            )
            self.handlePresentationEffect(
                effect,
                createdSurface: createdSurface,
                createStartedAt: createStartedAt
            )
        }
    }

    private func handlePresentationEffect(
        _ effect: TmuxPanePresentationStateMachine.Effect,
        createdSurface: TmuxPaneSurface? = nil,
        createStartedAt: UInt64 = 0
    ) {
        switch effect {
        case .none:
            break

        case .release(let outgoingPaneID):
            releasePresentedPane(outgoingPaneID: outgoingPaneID)

        case .evaluateTopology:
            guard let topology else { return }
            presentActivePane(from: topology)

        case .create(let paneID):
            createPaneSurfaceAfterRelease(paneID: paneID)

        case .present(let paneID):
            guard let createdSurface else {
                assertionFailure("presentation reducer requested a missing created surface")
                return
            }
            assert(createdSurface.paneID == paneID)
            assert(paneSurface == nil)
            paneSurface = createdSurface
            GhosttyRuntimeTrace.perf(
                "tmuxPane.transition create.ready pane=\(paneID) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: createStartedAt))"
            )
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.create.ready",
                fields: [
                    "pane": "\(paneID)",
                    "surface": String(describing: createdSurface.rawSurface),
                ]
            )
            resumeShutdownDrainIfQuiescent()

        case .discard:
            guard let createdSurface else {
                assertionFailure("presentation reducer requested a missing discard surface")
                return
            }
            let paneID = createdSurface.paneID
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.create.discarding",
                fields: ["pane": "\(paneID)"]
            )
            createdSurface.close { [weak self] releaseResult in
                guard let self else { return }
                let succeeded: Bool
                if case .success = releaseResult {
                    succeeded = true
                    GhosttyRuntimeTrace.flowEndIfActive(
                        GhosttyRuntimeTrace.paneSwitchFlow,
                        event: "presentation.discard.ready",
                        fields: ["pane": "\(paneID)"]
                    )
                } else {
                    succeeded = false
                    GhosttyRuntimeTrace.flowEndIfActive(
                        GhosttyRuntimeTrace.paneSwitchFlow,
                        event: "presentation.discard.failed",
                        fields: ["pane": "\(paneID)"]
                    )
                }
                self.handlePresentationEffect(self.panePresentation.reduce(
                    .discardCompleted(
                        succeeded: succeeded,
                        confirmedPane: self.topology.flatMap(Self.activePaneID(in:))
                    )
                ))
            }

        case .finished(let shouldRedrive):
            resumeShutdownDrainIfQuiescent()
            guard shouldRedrive, !isShutDown, let topology else { return }
            presentActivePane(from: topology)
        }
    }

    private static func activePaneID(
        in snapshot: TmuxSessionController.TopologySnapshot
    ) -> TmuxPaneID? {
        snapshot.activeWindowID.flatMap { windowID in
            snapshot.windows.first(where: { $0.id == windowID })?.activePaneID
        }
    }

}
