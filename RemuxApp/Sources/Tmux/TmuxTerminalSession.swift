import Foundation
import GhosttyKit

/// MainActor owner of one control attachment and one retained real renderer
/// surface for every live pane. Only `paneSurface` is published to the phone
/// viewport; the retained map is not presentation state.
@MainActor
final class TmuxTerminalSession: ObservableObject {
    @Published private(set) var state: TmuxSessionController.SessionState = .detached(nil)
    @Published private(set) var topology: TmuxSessionController.TopologySnapshot?
    @Published private(set) var paneSurface: TmuxPaneSurface?
    @Published private(set) var livePaneIDs: Set<TmuxPaneID> = []
    @Published private(set) var lastFailedRequest: TmuxSessionController.Request?
    @Published private(set) var transportFailure: TerminalDisconnectReason?

    private let app: ghostty_app_t
    private(set) var controller: TmuxSessionController!
    private var link: TmuxSessionLink?
    private let makeTransport: () -> any TmuxControlTransport
    private let baseSurfaceConfig: () -> ghostty_terminal_surface_config_s
    private let paneViewTheme: () -> TerminalTheme

    typealias PaneSurfaceCreator = @MainActor (
        ghostty_app_t,
        TmuxSessionController,
        TmuxSessionController.RetainedPaneTerminal,
        ghostty_terminal_surface_config_s,
        GhosttySurfaceDisplayMetrics,
        TerminalTheme,
        @escaping @MainActor (TmuxPaneID) -> Void,
        @escaping @MainActor (Result<TmuxPaneSurface, TmuxPaneSurface.CreateError>) -> Void
    ) -> Void
    private let createPaneSurface: PaneSurfaceCreator

    private var surfacesByPaneID: [TmuxPaneID: TmuxPaneSurface] = [:]
    private var pendingTerminalsByPaneID: [
        TmuxPaneID: TmuxSessionController.RetainedPaneTerminal
    ] = [:]
    private var creatingPaneIDs: Set<TmuxPaneID> = []
    private var failedCreationPaneIDs: Set<TmuxPaneID> = []
    private var pendingPaneID: TmuxPaneID?
    private var zoomRequestedPaneID: TmuxPaneID?
    private var preparingSurface: TmuxPaneSurface?
    private var viewportMetrics: GhosttySurfaceDisplayMetrics?
    private struct AppearanceSnapshot {
        let baseConfig: ghostty_terminal_surface_config_s
        let metrics: GhosttySurfaceDisplayMetrics
        let theme: TerminalTheme
    }
    private var appearancePassInFlight = false
    private var appearancePassWaitingForBusySurface = false
    private var pendingAppearanceSnapshot: AppearanceSnapshot?
    private var isAppActive = true
    private var isShutDown = false
    private var shutdownDrainContinuation: CheckedContinuation<Void, Never>?

    private final class Relay: @unchecked Sendable {
        weak var target: TmuxTerminalSession?
    }

    init(
        app: ghostty_app_t,
        makeTransport: @escaping () -> any TmuxControlTransport,
        baseSurfaceConfig: @escaping () -> ghostty_terminal_surface_config_s,
        paneViewTheme: @escaping () -> TerminalTheme,
        createPaneSurface: @escaping PaneSurfaceCreator = TmuxPaneSurface.create
    ) {
        self.app = app
        self.makeTransport = makeTransport
        self.baseSurfaceConfig = baseSurfaceConfig
        self.paneViewTheme = paneViewTheme
        self.createPaneSurface = createPaneSurface

        let relay = Relay()
        controller = TmuxSessionController(callbacks: TmuxSessionController.Callbacks(
            onState: { state in
                MainActor.assumeIsolated { relay.target?.handleState(state) }
            },
            onTopology: { topology in
                MainActor.assumeIsolated { relay.target?.handleTopology(topology) }
            },
            onPaneRemoved: { paneID in
                MainActor.assumeIsolated { relay.target?.handlePaneRemoved(paneID) }
            },
            onPaneTerminal: { terminal in
                MainActor.assumeIsolated { relay.target?.handlePaneTerminal(terminal) }
            },
            onPanePhaseChanged: { paneID, phase in
                MainActor.assumeIsolated {
                    relay.target?.handlePanePhaseChanged(paneID, phase: phase)
                }
            },
            onActivePaneChanged: { paneID in
                MainActor.assumeIsolated { relay.target?.handleActivePaneChanged(paneID) }
            },
            onPaneSurfaceFailed: { paneID in
                MainActor.assumeIsolated { relay.target?.handleRendererFailure(paneID) }
            },
            onRequestFailed: { request in
                MainActor.assumeIsolated { relay.target?.handleRequestFailed(request) }
            }
        ))
        relay.target = self
    }

    // MARK: Connection

    func connect(viewport: TmuxControlViewport?) {
        guard !isShutDown, link == nil, viewport != nil else { return }
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
        transportFailure = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(error)
        state = .detached(nil)
    }

    func disconnect() async {
        guard let link else { return }
        self.link = nil
        await link.stop()
        controller.attachmentStopped()
    }

    func invalidateInactiveTransportOnForeground(
        willInvalidate: (TerminalDisconnectReason) -> Void
    ) async -> TerminalDisconnectReason? {
        guard let link else { return nil }
        guard let isActive = await link.controlChannelIsActive(), !isActive else { return nil }
        guard self.link === link else { return nil }
        let reason = GhosttyTerminalDisconnectReasonClassifier.foregroundMissingHost()
        willInvalidate(reason)
        await link.invalidateTransport()
        return reason
    }

    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        pendingPaneID = nil
        zoomRequestedPaneID = nil
        cancelPendingPresentation()
        livePaneIDs.removeAll()
        pendingTerminalsByPaneID.removeAll()
        unpublishPane()

        if !creatingPaneIDs.isEmpty {
            await withCheckedContinuation { shutdownDrainContinuation = $0 }
        }
        await closeAllRetainedSurfaces()
        if let link {
            self.link = nil
            await link.stop()
        }
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
                surface.close { [weak self, weak surface] in
                    if let self, let surface,
                       self.surfacesByPaneID[surface.paneID] === surface {
                        self.surfacesByPaneID.removeValue(forKey: surface.paneID)
                    }
                    remaining -= 1
                    if remaining == 0 { continuation.resume() }
                }
            }
        }
    }

    private func resumeShutdownDrainIfQuiescent() {
        guard creatingPaneIDs.isEmpty, let continuation = shutdownDrainContinuation else { return }
        shutdownDrainContinuation = nil
        continuation.resume()
    }

    // MARK: Native callbacks

    private func handleState(_ newState: TmuxSessionController.SessionState) {
        state = newState
        switch newState {
        case .detached, .closed:
            pendingPaneID = nil
            zoomRequestedPaneID = nil
            cancelPendingPresentation()
            if let link {
                self.link = nil
                Task { await link.stop() }
            }
        case .ready:
            if let topology { presentActivePane(from: topology) }
        case .attaching, .syncing:
            break
        }
    }

    func handleTopology(_ snapshot: TmuxSessionController.TopologySnapshot) {
        topology = snapshot
        let paneIDs = Set(snapshot.panes.map(\.id))
        livePaneIDs = Set(snapshot.panes.lazy.filter { $0.phase == .live }.map(\.id))
        pendingTerminalsByPaneID = pendingTerminalsByPaneID.filter { paneIDs.contains($0.key) }
        failedCreationPaneIDs.formIntersection(paneIDs)
        if let zoomRequestedPaneID,
           activePaneID(in: snapshot) != zoomRequestedPaneID
            || isFullViewport(paneID: zoomRequestedPaneID, in: snapshot) {
            self.zoomRequestedPaneID = nil
        }
        presentActivePane(from: snapshot)
    }

    private func handlePaneRemoved(_ paneID: TmuxPaneID) {
        livePaneIDs.remove(paneID)
        pendingTerminalsByPaneID.removeValue(forKey: paneID)
        failedCreationPaneIDs.remove(paneID)
        if pendingPaneID == paneID { pendingPaneID = nil }
        if zoomRequestedPaneID == paneID { zoomRequestedPaneID = nil }
        if preparingSurface?.paneID == paneID { cancelPendingPresentation() }
        if paneSurface?.paneID == paneID { unpublishPane() }
        guard let surface = surfacesByPaneID[paneID] else { return }
        closeRetainedSurface(surface)
    }

    private func handlePaneTerminal(
        _ terminal: TmuxSessionController.RetainedPaneTerminal
    ) {
        let paneID = terminal.paneID
        guard !isShutDown,
              topology?.panes.contains(where: { $0.id == paneID }) == true
        else { return }

        // The retained terminal handoff is the native client's live boundary.
        // Hydration completion does not emit a second topology snapshot, so a
        // pane first reported as hydrating must become capture-eligible here.
        markPaneLiveAfterTerminalHandoff(paneID)

        guard
              surfacesByPaneID[paneID] == nil,
              pendingTerminalsByPaneID[paneID] == nil
        else { return }
        pendingTerminalsByPaneID[paneID] = terminal
        createSurfaceIfPossible(paneID: paneID)
    }

    private func markPaneLiveAfterTerminalHandoff(_ paneID: TmuxPaneID) {
        livePaneIDs.insert(paneID)
    }

    private func handlePanePhaseChanged(
        _ paneID: TmuxPaneID,
        phase: TmuxSessionController.PaneInfo.Phase
    ) {
        switch phase {
        case .hydrating:
            livePaneIDs.remove(paneID)
            if preparingSurface?.paneID == paneID { cancelPendingPresentation() }
        case .live:
            livePaneIDs.insert(paneID)
            if let topology, activePaneID(in: topology) == paneID {
                presentActivePane(from: topology)
            }
        }
    }

    private func handleActivePaneChanged(_ paneID: TmuxPaneID) {
        guard paneSurface?.paneID == paneID else { return }
        paneSurface?.refreshInteractionState()
    }

    private func handleRendererFailure(_ paneID: TmuxPaneID) {
        guard !isShutDown,
              let surface = surfacesByPaneID[paneID],
              let viewportMetrics
        else { return }
        relinquishPresentationOwnership(of: surface)
        surface.replaceRenderer(
            baseConfig: baseSurfaceConfig(),
            metrics: viewportMetrics,
            theme: paneViewTheme()
        ) { [weak self, weak surface] result in
            guard let self else { return }
            switch result {
            case .replaced:
                if let surface,
                   surfacesByPaneID[paneID] === surface {
                    if let currentViewportMetrics = self.viewportMetrics {
                        surface.updateCanonicalViewportMetrics(currentViewportMetrics)
                    }
                    if let topology { presentActivePane(from: topology) }
                }
            case .busy:
                break
            case .failed:
                GhosttyRuntimeTrace.diagnostics(
                    "tmuxPane.rendererReplacement failed pane=\(paneID)"
                )
            }
            resumeAppearancePassAfterBusySurface()
        }
    }

    private func handleRequestFailed(_ request: TmuxSessionController.Request) {
        lastFailedRequest = request
        if request == .selectPane || request == .selectWindow {
            pendingPaneID = nil
            zoomRequestedPaneID = nil
            cancelPendingPresentation()
        }
        if request == .zoomPane {
            // Keep the terminal unpresented: split geometry is not the phone's
            // canonical terminal viewport.
            return
        }
        if let topology { presentActivePane(from: topology) }
    }

    // MARK: Viewport and surface creation

    func updateViewportMetrics(size: CGSize, scale: CGFloat) {
        let metrics = GhosttySurfaceDisplayMetrics(size: size, scale: scale)
        let changed = metrics != viewportMetrics
        viewportMetrics = metrics
        for surface in surfacesByPaneID.values {
            surface.updateCanonicalViewportMetrics(metrics)
        }
        if changed, preparingSurface != nil {
            cancelPendingPresentation()
        }
        for paneID in pendingTerminalsByPaneID.keys.sorted() {
            createSurfaceIfPossible(paneID: paneID)
        }
        if changed, let topology {
            presentActivePane(from: topology)
        }
    }

    private func createSurfaceIfPossible(paneID: TmuxPaneID) {
        guard !isShutDown,
              let metrics = viewportMetrics,
              let terminal = pendingTerminalsByPaneID.removeValue(forKey: paneID),
              surfacesByPaneID[paneID] == nil,
              creatingPaneIDs.insert(paneID).inserted
        else { return }

        createPaneSurface(
            app,
            controller,
            terminal,
            baseSurfaceConfig(),
            metrics,
            paneViewTheme(),
            { [weak self] paneID in self?.handleRendererFailure(paneID) }
        ) { [weak self] result in
            guard let self else {
                if case .success(let surface) = result { surface.close() }
                return
            }
            creatingPaneIDs.remove(paneID)
            switch result {
            case .failure(let error):
                failedCreationPaneIDs.insert(paneID)
                GhosttyRuntimeTrace.diagnostics(
                    "tmuxPane.createFailed pane=\(paneID) error=\(String(describing: error))"
                )
            case .success(let surface):
                guard !isShutDown,
                      topology?.panes.contains(where: { $0.id == paneID }) == true
                else {
                    surface.close()
                    resumeShutdownDrainIfQuiescent()
                    return
                }
                surfacesByPaneID[paneID] = surface
                if let topology { presentActivePane(from: topology) }
            }
            resumeShutdownDrainIfQuiescent()
        }
    }

    // MARK: Singular presentation

    func prepareForPaneSelection(paneID: TmuxPaneID) {
        guard !isShutDown,
              isAppActive,
              let topology,
              topology.panes.contains(where: { $0.id == paneID })
        else { return }
        if activePaneID(in: topology) == paneID,
           isFullViewport(paneID: paneID, in: topology) {
            let hasConflictingIntent = pendingPaneID != nil && pendingPaneID != paneID
            if !hasConflictingIntent {
                if paneSurface?.paneID == paneID || preparingSurface?.paneID == paneID {
                    return
                }
                pendingPaneID = nil
                cancelPendingPresentation()
                presentActivePane(from: topology)
                return
            }
        }
        surfacesByPaneID[paneID]?.cancelPickerCaptureForPresentation()
        cancelPendingPresentation()
        pendingPaneID = paneID
        zoomRequestedPaneID = isFullViewport(paneID: paneID, in: topology)
            ? nil
            : paneID
        unpublishPane()
    }

    func capturePickerPreview(
        paneID: TmuxPaneID,
        columns: UInt32,
        rows: UInt32,
        budget: GhosttyPanePreviewSession.PixelBudget
    ) async -> GhosttyPanePreviewSession.RenderedPreview? {
        guard !isShutDown,
              state == .ready,
              livePaneIDs.contains(paneID),
              let surface = surfacesByPaneID[paneID],
              !surface.isClosing
        else { return nil }
        return await surface.capturePickerPreview(
            columns: columns,
            rows: rows,
            budget: budget
        )
    }

    func cancelPickerPreview(paneID: TmuxPaneID) {
        surfacesByPaneID[paneID]?.cancelPickerCaptureForPresentation()
    }

    private func presentActivePane(from snapshot: TmuxSessionController.TopologySnapshot) {
        guard !isShutDown, isAppActive, state == .ready,
              let paneID = activePaneID(in: snapshot)
        else { return }
        if let pendingPaneID, pendingPaneID != paneID { return }
        guard livePaneIDs.contains(paneID) else {
            // A refresh of the pane already on screen changes its terminal
            // contents in place. Keep that real surface focused so input can
            // remain ordered through the control-client queue; only a pane
            // that has not yet been presented must wait for hydration.
            if paneSurface?.paneID == paneID,
               isFullViewport(paneID: paneID, in: snapshot) {
                return
            }
            if preparingSurface?.paneID == paneID { cancelPendingPresentation() }
            unpublishPane()
            return
        }

        guard isFullViewport(paneID: paneID, in: snapshot) else {
            unpublishPane()
            if zoomRequestedPaneID != paneID {
                zoomRequestedPaneID = paneID
                controller.requestZoomPane(paneID: paneID)
            }
            return
        }
        zoomRequestedPaneID = nil

        guard paneSurface?.paneID != paneID else {
            pendingPaneID = nil
            return
        }
        guard !failedCreationPaneIDs.contains(paneID),
              let surface = surfacesByPaneID[paneID],
              !surface.isClosing
        else { return }
        if preparingSurface === surface { return }

        cancelPendingPresentation()
        unpublishPane()
        preparingSurface = surface
        surface.prepareForPresentation { [weak self, weak surface] ready in
            guard let self, let surface,
                  preparingSurface === surface
            else { return }
            preparingSurface = nil
            guard ready,
                  !isShutDown,
                  isAppActive,
                  state == .ready,
                  let topology,
                  activePaneID(in: topology) == surface.paneID,
                  livePaneIDs.contains(surface.paneID),
                  pendingPaneID == nil || pendingPaneID == surface.paneID,
                  isFullViewport(paneID: surface.paneID, in: topology)
            else {
                surface.cancelPresentationPreparation()
                return
            }
            paneSurface = surface
            pendingPaneID = nil
            surface.setPresented(true)
        }
    }

    private func cancelPendingPresentation() {
        guard let surface = preparingSurface else { return }
        preparingSurface = nil
        surface.cancelPresentationPreparation()
    }

    private func unpublishPane() {
        guard let surface = paneSurface else { return }
        surface.setPresented(false)
        paneSurface = nil
    }

    private func relinquishPresentationOwnership(of surface: TmuxPaneSurface) {
        if preparingSurface === surface {
            cancelPendingPresentation()
        }
        if paneSurface === surface {
            unpublishPane()
        }
    }

    private func closeRetainedSurface(_ surface: TmuxPaneSurface) {
        surface.close { [weak self, weak surface] in
            guard let self, let surface else { return }
            if surfacesByPaneID[surface.paneID] === surface {
                surfacesByPaneID.removeValue(forKey: surface.paneID)
            }
        }
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        if !active {
            cancelPendingPresentation()
            unpublishPane()
        }
        if active, let topology { presentActivePane(from: topology) }
    }

    func applyTerminalTheme(_ theme: TerminalTheme) {
        guard let viewportMetrics, !surfacesByPaneID.isEmpty else { return }
        let snapshot = AppearanceSnapshot(
            baseConfig: baseSurfaceConfig(),
            metrics: viewportMetrics,
            theme: theme
        )
        guard !appearancePassInFlight, !appearancePassWaitingForBusySurface else {
            pendingAppearanceSnapshot = snapshot
            return
        }
        startAppearancePass(snapshot)
    }

    private func startAppearancePass(_ snapshot: AppearanceSnapshot) {
        guard !isShutDown else { return }
        var surfaces = Array(surfacesByPaneID.values)
        if let active = paneSurface ?? preparingSurface,
           let index = surfaces.firstIndex(where: { $0 === active }) {
            surfaces.swapAt(0, index)
        }
        appearancePassInFlight = true
        replaceRenderersForAppearance(
            surfaces,
            index: 0,
            snapshot: snapshot
        )
    }

    private func replaceRenderersForAppearance(
        _ surfaces: [TmuxPaneSurface],
        index: Int,
        snapshot: AppearanceSnapshot
    ) {
        guard !isShutDown, index < surfaces.count else {
            appearancePassInFlight = false
            startPendingAppearancePassIfPossible()
            return
        }
        let surface = surfaces[index]
        guard surfacesByPaneID[surface.paneID] === surface, !surface.isClosing else {
            replaceRenderersForAppearance(surfaces, index: index + 1, snapshot: snapshot)
            return
        }
        relinquishPresentationOwnership(of: surface)
        surface.replaceRenderer(
            baseConfig: snapshot.baseConfig,
            metrics: snapshot.metrics,
            theme: snapshot.theme
        ) { [weak self, weak surface] result in
            guard let self else { return }
            switch result {
            case .replaced:
                if let surface,
                   surfacesByPaneID[surface.paneID] === surface {
                    if let currentViewportMetrics = self.viewportMetrics {
                        surface.updateCanonicalViewportMetrics(currentViewportMetrics)
                    }
                    if let topology,
                       activePaneID(in: topology) == surface.paneID {
                        presentActivePane(from: topology)
                    }
                }
            case .busy:
                if pendingAppearanceSnapshot == nil {
                    pendingAppearanceSnapshot = snapshot
                }
                appearancePassWaitingForBusySurface = true
            case .failed:
                GhosttyRuntimeTrace.diagnostics(
                    "tmuxPane.settingsReplacement failed pane=\(surface.map { String(describing: $0.paneID) } ?? "released")"
                )
            }
            replaceRenderersForAppearance(
                surfaces,
                index: index + 1,
                snapshot: snapshot
            )
        }
    }

    private func resumeAppearancePassAfterBusySurface() {
        guard appearancePassWaitingForBusySurface else { return }
        appearancePassWaitingForBusySurface = false
        startPendingAppearancePassIfPossible()
    }

    private func startPendingAppearancePassIfPossible() {
        guard !appearancePassInFlight,
              !appearancePassWaitingForBusySurface,
              let snapshot = pendingAppearanceSnapshot
        else { return }
        pendingAppearanceSnapshot = nil
        startAppearancePass(snapshot)
    }

    private func activePaneID(
        in snapshot: TmuxSessionController.TopologySnapshot
    ) -> TmuxPaneID? {
        guard let windowID = snapshot.activeWindowID else { return nil }
        return snapshot.windows.first(where: { $0.id == windowID })?.activePaneID
    }

    private func isFullViewport(
        paneID: TmuxPaneID,
        in snapshot: TmuxSessionController.TopologySnapshot
    ) -> Bool {
        guard let pane = snapshot.panes.first(where: { $0.id == paneID }),
              let window = snapshot.windows.first(where: { $0.id == pane.windowID })
        else { return false }
        if window.zoomed { return true }
        return !snapshot.panes.contains {
            $0.windowID == window.id && $0.id != paneID
        }
    }

    #if DEBUG
    var pendingPaneIDForTesting: TmuxPaneID? { pendingPaneID }
    var zoomRequestedPaneIDForTesting: TmuxPaneID? { zoomRequestedPaneID }
    var creatingPaneIDsForTesting: Set<TmuxPaneID> { creatingPaneIDs }
    func handleStateForTesting(_ state: TmuxSessionController.SessionState) { handleState(state) }
    func handleRequestFailedForTesting(_ request: TmuxSessionController.Request) {
        handleRequestFailed(request)
    }
    func handlePaneRemovedForTesting(_ paneID: TmuxPaneID) { handlePaneRemoved(paneID) }
    func handlePaneTerminalForTesting(_ paneID: TmuxPaneID) {
        guard !isShutDown,
              topology?.panes.contains(where: { $0.id == paneID }) == true
        else { return }
        markPaneLiveAfterTerminalHandoff(paneID)
    }
    #endif
}
