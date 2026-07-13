import Foundation
import GhosttyKit

/// Owns one tmux control session and the real surfaces retained for panes the
/// user has visited. Libghostty remains the topology/engine source of truth;
/// this object owns only presentation lifetime and publishes one surface for
/// the phone viewport.
@MainActor
final class TmuxTerminalSession: ObservableObject {
    @Published private(set) var state: TmuxSessionController.SessionState = .detached(nil)
    @Published private(set) var topology: TmuxSessionController.TopologySnapshot?
    @Published private(set) var paneSurface: TmuxPaneSurface?
    @Published private(set) var lastFailedRequest: TmuxSessionController.Request?
    @Published private(set) var transportFailure: TerminalDisconnectReason?

    private let app: ghostty_app_t
    private(set) var controller: TmuxSessionController!
    private var link: TmuxSessionLink?
    private let makeTransport: () -> any TmuxControlTransport
    private let baseSurfaceConfig: () -> ghostty_surface_config_s
    private let paneViewTheme: () -> TerminalTheme

    typealias PaneSurfaceCreator = @MainActor (
        ghostty_app_t,
        TmuxSessionController,
        TmuxPaneID,
        ghostty_surface_config_s,
        TerminalTheme,
        @escaping @MainActor (Result<TmuxPaneSurface, TmuxPaneSurface.CreateError>) -> Void
    ) -> Void
    private let createPaneSurface: PaneSurfaceCreator

    /// Direct ownership: no projection, reducer, or second registry owns pane
    /// resources. A closing surface stays in this map until unbind completes.
    private var surfacesByPaneID: [TmuxPaneID: TmuxPaneSurface] = [:]
    private var creatingPaneIDs: Set<TmuxPaneID> = []
    private var pendingPaneID: TmuxPaneID?
    private var failedCreationPaneID: TmuxPaneID?

    private enum PaneZoomState: Equatable {
        case idle
        case awaiting(TmuxPaneID)
        case suppressed(TmuxPaneID)
    }

    private var paneZoomState = PaneZoomState.idle
    private var isAppActive = true
    private var isShutDown = false
    private var shutdownDrainContinuation: CheckedContinuation<Void, Never>?

    private final class Relay: @unchecked Sendable {
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
                onState: { state in
                    MainActor.assumeIsolated { relay.target?.handleState(state) }
                },
                onTopology: { snapshot in
                    MainActor.assumeIsolated { relay.target?.handleTopology(snapshot) }
                },
                onPaneRemoved: { paneID in
                    MainActor.assumeIsolated { relay.target?.handlePaneRemoved(paneID) }
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

    func connect(viewport: TmuxControlViewport?) {
        guard !isShutDown, link == nil else { return }
        transportFailure = nil
        let link = TmuxSessionLink(controller: controller, transport: makeTransport())
        self.link = link
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
        guard let isActive = await link.controlChannelIsActive(), !isActive else {
            return nil
        }
        guard self.link === link else { return nil }

        let reason = GhosttyTerminalDisconnectReasonClassifier.foregroundMissingHost()
        willInvalidate(reason)
        await link.invalidateTransport()
        return reason
    }

    /// Fence creation, drain every create, close every retained surface, then
    /// release transport and controller. Controller destruction is last.
    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        pendingPaneID = nil
        unpublishPane()

        if !creatingPaneIDs.isEmpty {
            await withCheckedContinuation { continuation in
                shutdownDrainContinuation = continuation
            }
        }

        await closeAllRetainedSurfaces()
        await disconnect()
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
    }

    private func closeAllRetainedSurfaces() async {
        let surfaces = Array(surfacesByPaneID.values)
        guard !surfaces.isEmpty else { return }

        await withCheckedContinuation { continuation in
            var remaining = surfaces.count
            for surface in surfaces {
                surface.close { [weak self, weak surface] _ in
                    if let self, let surface,
                       self.surfacesByPaneID[surface.paneID] === surface {
                        self.surfacesByPaneID.removeValue(forKey: surface.paneID)
                    }
                    remaining -= 1
                    if remaining == 0 {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func resumeShutdownDrainIfQuiescent() {
        guard creatingPaneIDs.isEmpty,
              let continuation = shutdownDrainContinuation
        else { return }
        shutdownDrainContinuation = nil
        continuation.resume()
    }

    // MARK: Retained presentation

    private func handleState(_ newState: TmuxSessionController.SessionState) {
        state = newState
        if case .detached = newState {
            paneZoomState = .idle
            pendingPaneID = nil
            failedCreationPaneID = nil
            if paneSurface == nil,
               let paneID = topology.flatMap(Self.activePaneID(in:)),
               let retained = surfacesByPaneID[paneID],
               !retained.isClosing {
                publish(retained)
            }
            if let link {
                self.link = nil
                Task { await link.stop() }
            }
        } else if newState == .ready, let topology {
            presentActivePane(from: topology)
        }
    }

    #if DEBUG
    private(set) var requestedZoomPaneIDsForTesting: [TmuxPaneID] = []
    var pendingPaneIDForTesting: TmuxPaneID? { pendingPaneID }
    var creatingPaneIDsForTesting: Set<TmuxPaneID> { creatingPaneIDs }

    func handleStateForTesting(_ newState: TmuxSessionController.SessionState) {
        handleState(newState)
    }

    func handleRequestFailedForTesting(_ request: TmuxSessionController.Request) {
        handleRequestFailed(request)
    }
    #endif

    func handleTopology(_ snapshot: TmuxSessionController.TopologySnapshot) {
        let previousActivePaneID = topology.flatMap(Self.activePaneID(in:))
        topology = snapshot
        let activePaneID = Self.activePaneID(in: snapshot)
        if pendingPaneID == nil,
           activePaneID != previousActivePaneID,
           failedCreationPaneID != activePaneID {
            failedCreationPaneID = nil
        }
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "presentation.topology.received",
            fields: ["active_pane": activePaneID.map(String.init) ?? "none"]
        )
        presentActivePane(from: snapshot)
    }

    private func handlePaneRemoved(_ paneID: TmuxPaneID) {
        if pendingPaneID == paneID { pendingPaneID = nil }
        // Prevent a stale topology callback from recreating a pane after its
        // authoritative removal event. A different active pane clears this.
        failedCreationPaneID = paneID
        if paneSurface?.paneID == paneID { unpublishPane() }
        guard let surface = surfacesByPaneID[paneID] else { return }
        closeRetainedSurface(surface)
    }

    private func handleRequestFailed(_ request: TmuxSessionController.Request) {
        lastFailedRequest = request
        if request == .selectPane || request == .selectWindow {
            pendingPaneID = nil
            if let topology {
                presentActivePane(from: topology)
            }
            return
        }
        guard request == .zoomPane else { return }
        guard case .awaiting(let paneID) = paneZoomState else { return }
        paneZoomState = .suppressed(paneID)
        if let topology { presentActivePane(from: topology) }
    }

    /// Record a validated target and immediately unpublish/occlude the outgoing
    /// terminal without destroying it. Ordered topology authorizes the target.
    func prepareForPaneSelection(paneID: TmuxPaneID) {
        guard !isShutDown, isAppActive else { return }
        guard topology?.panes.contains(where: { $0.id == paneID }) == true else { return }
        guard paneSurface?.paneID != paneID else { return }

        pendingPaneID = paneID
        failedCreationPaneID = nil
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "presentation.selection.prepared",
            fields: ["pane": "\(paneID)"]
        )
        unpublishPane()
        if let topology, Self.activePaneID(in: topology) == paneID {
            presentActivePane(from: topology)
        }
    }

    private func presentActivePane(
        from snapshot: TmuxSessionController.TopologySnapshot
    ) {
        guard !isShutDown, isAppActive else { return }
        guard let windowID = snapshot.activeWindowID,
              let window = snapshot.windows.first(where: { $0.id == windowID }),
              let paneID = window.activePaneID
        else { return }

        // A newer accepted intent is the only local authorization filter. An
        // intermediate topology may warm/store its late create, but never
        // publish it or enable input.
        if let pendingPaneID, pendingPaneID != paneID { return }

        switch paneZoomState {
        case .awaiting(let zoomPaneID), .suppressed(let zoomPaneID):
            if zoomPaneID != paneID { paneZoomState = .idle }
        case .idle:
            break
        }

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
        if window.zoomed { paneZoomState = .idle }

        if paneSurface?.paneID == paneID {
            if pendingPaneID == paneID { pendingPaneID = nil }
            return
        }
        if failedCreationPaneID == paneID { return }

        if paneSurface != nil { unpublishPane() }
        if let retained = surfacesByPaneID[paneID] {
            guard !retained.isClosing else { return }
            publish(retained)
            return
        }
        createSurfaceIfNeeded(paneID: paneID)
    }

    private func createSurfaceIfNeeded(paneID: TmuxPaneID) {
        guard !isShutDown,
              surfacesByPaneID[paneID] == nil,
              creatingPaneIDs.insert(paneID).inserted
        else { return }

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
            guard let self else {
                if case .success(let surface) = result { surface.close() }
                return
            }
            self.creatingPaneIDs.remove(paneID)

            switch result {
            case .failure(let error):
                GhosttyRuntimeTrace.perf(
                    "tmuxPane.transition create.failed pane=\(paneID) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: createStartedAt))"
                )
                GhosttyRuntimeTrace.diagnostics(
                    "tmuxPane.createFailed pane=\(paneID) error=\(String(describing: error))"
                )
                GhosttyRuntimeTrace.flowEndIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "presentation.create.failed",
                    fields: ["pane": "\(paneID)"]
                )
                let confirmedPaneID = self.topology.flatMap(Self.activePaneID(in:))
                let isStillDesired = confirmedPaneID == paneID
                    && (self.pendingPaneID == nil || self.pendingPaneID == paneID)
                if !self.isShutDown,
                   isStillDesired,
                   self.topology?.panes.contains(where: { $0.id == paneID }) == true {
                    self.failedCreationPaneID = paneID
                    if self.pendingPaneID == paneID { self.pendingPaneID = nil }
                }

            case .success(let surface):
                // Every successful native create becomes session-owned first.
                // This also lets shutdown observe and close a completion that
                // arrives while teardown is waiting for creates to drain.
                if let existing = self.surfacesByPaneID[paneID] {
                    assertionFailure("duplicate retained pane surface")
                    surface.close()
                    if !existing.isClosing { self.presentActivePaneIfPossible() }
                    break
                }
                self.surfacesByPaneID[paneID] = surface
                surface.setPresented(false)

                let paneStillExists = self.failedCreationPaneID != paneID
                    && self.topology?.panes.contains { $0.id == paneID } == true
                guard !self.isShutDown, paneStillExists else {
                    if !self.isShutDown { self.closeRetainedSurface(surface) }
                    break
                }

                let confirmedPaneID = self.topology.flatMap(Self.activePaneID(in:))
                let isAuthorized = confirmedPaneID == paneID
                    && (self.pendingPaneID == nil || self.pendingPaneID == paneID)
                if isAuthorized {
                    self.publish(surface, createStartedAt: createStartedAt)
                }
            }
            self.resumeShutdownDrainIfQuiescent()
        }
    }

    private func presentActivePaneIfPossible() {
        guard let topology else { return }
        presentActivePane(from: topology)
    }

    private func publish(
        _ surface: TmuxPaneSurface,
        createStartedAt: UInt64 = 0
    ) {
        guard !isShutDown, isAppActive, !surface.isClosing else { return }
        guard topology.flatMap(Self.activePaneID(in:)) == surface.paneID else { return }
        guard pendingPaneID == nil || pendingPaneID == surface.paneID else { return }
        if paneSurface === surface {
            pendingPaneID = nil
            return
        }

        paneSurface?.setPresented(false)
        paneSurface = surface
        pendingPaneID = nil
        failedCreationPaneID = nil

        if createStartedAt != 0 {
            GhosttyRuntimeTrace.perf(
                "tmuxPane.transition create.ready pane=\(surface.paneID) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: createStartedAt))"
            )
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.create.ready",
                fields: [
                    "pane": "\(surface.paneID)",
                    "surface": String(describing: surface.rawSurface),
                ]
            )
        } else {
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.retained.ready",
                fields: [
                    "pane": "\(surface.paneID)",
                    "surface": String(describing: surface.rawSurface),
                ]
            )
        }
    }

    private func unpublishPane() {
        guard let surface = paneSurface else { return }
        surface.setPresented(false)
        paneSurface = nil
    }

    private func closeRetainedSurface(_ surface: TmuxPaneSurface) {
        surface.close { [weak self, weak surface] releaseResult in
            guard let self, let surface else { return }
            if case .failure(let error) = releaseResult {
                GhosttyRuntimeTrace.diagnostics(
                    "tmuxPane.close releaseFailed pane=\(surface.paneID) error=\(error)"
                )
            }
            if self.surfacesByPaneID[surface.paneID] === surface {
                self.surfacesByPaneID.removeValue(forKey: surface.paneID)
            }
        }
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        if !active {
            unpublishPane()
        }
        for surface in surfacesByPaneID.values {
            surface.setPresented(active && surface === paneSurface)
        }
        if active, let topology {
            presentActivePane(from: topology)
        }
    }

    func applyTerminalTheme(_ theme: TerminalTheme) {
        for surface in surfacesByPaneID.values {
            surface.applyTerminalTheme(theme)
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
