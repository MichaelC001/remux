import Combine
import CoreGraphics
import Foundation
import GhosttyKit


/// Presents the new tmux session stack (`TmuxTerminalSession`) through the
/// `GhosttyTerminalScreenModeling` boundary so `GhosttySurfaceScreen` — the
/// full terminal UX — renders it unchanged.
///
/// Topology mapping: tmux window/pane IDs (UInt64) are mapped to stable UUIDs
/// for the screen's projections; the active window's active pane is the only
/// materialized surface (the phone presentation shows exactly the focused
/// leaf, matching the legacy pipeline). The bound pane is wrapped in a
/// `GhosttyManagedSurface` over a borrowed control surface, so the existing
/// input, scroll, and selection machinery operates on it directly.
@MainActor
final class TmuxTerminalScreenAdapter: ObservableObject {
    private static let panePreviewCacheByteLimit = 8 * 1024 * 1024

    private weak var session: TmuxTerminalSession?
    private var controller: TmuxSessionController?

    /// The last topology emitted by `session.$topology`. All adapter reads go
    /// through this value, never `session.topology`: `@Published` emits from
    /// `willSet`, so reading the property inside a sink returns the previous
    /// snapshot and the projection lags one topology update behind.
    private var latestTopology: TmuxSessionController.TopologySnapshot?

    private let leaseStore = GhosttyRuntimeCallbackLeaseStore()

    private var identities = TmuxTerminalIdentityRegistry()

    private var activeManagedSurface: GhosttyManagedSurface?
    private var activeManagedPaneID: TmuxPaneID?
    private var pendingRemovalSurfaces: [UUID: GhosttyManagedSurface] = [:]
    private var initialViewportHandler: ((CGSize, CGFloat) -> Void)?
    private var cachedTopologySnapshot = GhosttyRuntimeSurfaceTopologySnapshot.empty
    private var panePreviewCache = TmuxPanePreviewImageCache(
        byteLimit: TmuxTerminalScreenAdapter.panePreviewCacheByteLimit
    )
    private var panePreviewCaptureSession: GhosttyPanePreviewSession?
    private var pickerPreviewGeneration: UInt64 = 0
    private var pickerPreviewReleaseCoverage: PickerPreviewReleaseCoverage = .inactive

    private enum PanePreviewRequestPurpose {
        case picker(UInt64)
        case beforeRelease
    }

    private enum PickerPreviewReleaseCoverage {
        case inactive
        case refreshing(generation: UInt64)
        case ready(generation: UInt64, surfaceID: UUID)
        case armed(generation: UInt64, surfaceID: UUID)
    }

    /// Presentation hold: while the active leaf has no surface that has
    /// completed a layout-sized display update, the snapshot carries the
    /// leaf as pending and the tree view keeps the outgoing pane's frame
    /// on screen (presentation overlay) instead of flashing empty.
    private var displayedPresentationPaneID: TmuxPaneID?
    private var abandonedPendingPresentationPaneID: TmuxPaneID?
    private var pendingPresentationTimeoutTask: Task<Void, Never>?
    private var pendingPresentationTimeoutSurfaceID: UUID?
    /// Safety net: the visual handoff is allowed to cover a short
    /// bind/layout/render race, not wait for an app inside tmux to
    /// repaint. Tests shorten it further.
    var pendingPresentationTimeout: Duration = .milliseconds(180)

    private var commandFailureMessage: String?
    private(set) var commandFailureEvent: GhosttyTmuxCommandFailureEvent?
    private var commandFailureToken: UInt64 = 0

    private var subscriptions: [AnyCancellable] = []

    /// Connects the adapter to a live session. Called once, right after the
    /// session is created (the adapter itself must exist before the runtime,
    /// because it is the runtime's surface delegate).
    func activate(
        session: TmuxTerminalSession,
        initialViewportHandler: @escaping (CGSize, CGFloat) -> Void
    ) {
        self.session = session
        self.controller = session.controller
        self.initialViewportHandler = initialViewportHandler

        session.$state
            .sink { [weak self] state in
                guard let self else { return }
                if case .detached = state {
                    self.clearPanePreviewCache(reason: "detached")
                } else if case .closed = state {
                    self.clearPanePreviewCache(reason: "closed")
                }
                self.objectWillChange.send()
            }
            .store(in: &subscriptions)
        // Subscribed before $paneSurface so the replayed initial value seeds
        // latestTopology ahead of the surface rebuild below.
        session.$topology
            .sink { [weak self] topology in
                guard let self else { return }
                self.latestTopology = topology
                if let topology {
                    self.reconcilePanePreviewCache(with: topology)
                } else {
                    self.clearPanePreviewCache(reason: "topology-unavailable")
                }
                self.rebuildTopologySnapshot()
                self.objectWillChange.send()
            }
            .store(in: &subscriptions)
        session.$paneSurface
            .sink { [weak self] paneSurface in
                self?.rebuildActiveManagedSurface(for: paneSurface)
                self?.rebuildTopologySnapshot()
                self?.objectWillChange.send()
            }
            .store(in: &subscriptions)
        session.$lastFailedRequest
            .sink { [weak self] request in
                guard let request else { return }
                self?.presentCommandFailure(for: request)
            }
            .store(in: &subscriptions)
        session.$transportFailure
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }

    func invalidate() {
        subscriptions.removeAll()
        leaseStore.invalidateActiveLease()
        activeManagedSurface = nil
        activeManagedPaneID = nil
        pendingRemovalSurfaces.removeAll()
        clearPanePreviewCache(reason: "invalidate")
        session = nil
        controller = nil
        initialViewportHandler = nil
        latestTopology = nil
        cachedTopologySnapshot = Self.emptyTopologySnapshot
        pendingPresentationTimeoutTask?.cancel()
        pendingPresentationTimeoutTask = nil
        pendingPresentationTimeoutSurfaceID = nil
        displayedPresentationPaneID = nil
        abandonedPendingPresentationPaneID = nil
        clearPickerPreviewReleaseCoverage()
    }

    // MARK: Topology synthesis

    private static var emptyTopologySnapshot: GhosttyRuntimeSurfaceTopologySnapshot {
        GhosttyRuntimeSurfaceTopologySnapshot.empty
    }

    private var topologySnapshot: GhosttyRuntimeSurfaceTopologySnapshot {
        cachedTopologySnapshot
    }

    private func rebuildTopologySnapshot() {
        guard let topology = latestTopology else {
            updatePendingPresentationTimeout(nil)
            cachedTopologySnapshot = Self.emptyTopologySnapshot
            return
        }

        let topLevels = topology.windows.map { window in
            let paneIDs = topology.panes
                .filter { $0.windowID == window.id }
                .sorted { lhs, rhs in
                    (lhs.y, lhs.x, lhs.id) < (rhs.y, rhs.x, rhs.id)
                }
                .map { identities.surfaceID(for: $0.id) }
            return GhosttyTopLevelSurface(
                id: identities.surfaceID(for: window.id),
                tree: Self.linearTree(of: paneIDs),
                focusedLeafID: window.activePaneID.map { identities.surfaceID(for: $0) }
            )
        }

        let pending = pendingPresentationSurfaceID(in: topology)
        updatePendingPresentationTimeout(pending)
        cachedTopologySnapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: topLevels,
            selectedTopLevelID: topology.activeWindowID.map { identities.surfaceID(for: $0) },
            pendingPhonePresentationSurfaceID: pending
        )
    }

    /// The active leaf is pending while no surface for it has completed
    /// a layout-sized display update: the topology flips to the new pane
    /// several frames before its surface can draw (bind, create, attach,
    /// layout), and without the hold the tree flashes empty for that gap.
    private func pendingPresentationSurfaceID(
        in topology: TmuxSessionController.TopologySnapshot
    ) -> UUID? {
        let activePaneID = topology.activeWindowID
            .flatMap { activeID in topology.windows.first(where: { $0.id == activeID }) }
            .flatMap(\.activePaneID)
        if let abandoned = abandonedPendingPresentationPaneID, abandoned != activePaneID {
            abandonedPendingPresentationPaneID = nil
        }
        guard let activePaneID,
              activePaneID != displayedPresentationPaneID,
              activePaneID != abandonedPendingPresentationPaneID
        else { return nil }
        return identities.surfaceID(for: activePaneID)
    }

    /// Marks a managed surface as displayed at its laid-out size and, if
    /// it was the pending presentation, drops the hold. Deferred one
    /// runloop hop: this fires inside the container's layout pass (no
    /// observable mutation mid view update), which also gives the
    /// just-refreshed surface a frame to present before the overlay
    /// clears.
    func notePresentationSurfaceDisplayed(_ surfaceID: UUID) {
        guard activeManagedSurface?.id == surfaceID,
              let paneID = activeManagedPaneID,
              displayedPresentationPaneID != paneID
        else { return }
        displayedPresentationPaneID = paneID
        guard cachedTopologySnapshot.pendingPhonePresentationSurfaceID == identities.surfaceID(for: paneID) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildTopologySnapshot()
            self.objectWillChange.send()
        }
    }

    private func updatePendingPresentationTimeout(_ pending: UUID?) {
        guard pending != pendingPresentationTimeoutSurfaceID else { return }
        pendingPresentationTimeoutTask?.cancel()
        pendingPresentationTimeoutTask = nil
        pendingPresentationTimeoutSurfaceID = pending
        guard let pending else { return }
        let timeout = pendingPresentationTimeout
        pendingPresentationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            guard self.cachedTopologySnapshot.pendingPhonePresentationSurfaceID == pending else { return }
            self.abandonedPendingPresentationPaneID = self.identities.paneID(for: pending)
            self.rebuildTopologySnapshot()
            self.objectWillChange.send()
        }
    }

    /// Pane geometry is tmux-owned; the phone presents one leaf at a time, so
    /// the tree only needs to enumerate leaves in a stable order.
    private static func linearTree(of leafIDs: [UUID]) -> GhosttySurfaceTree {
        guard var node = leafIDs.first.map(GhosttySurfaceTree.Node.leaf) else {
            return GhosttySurfaceTree(root: .leaf(UUID()))
        }
        for leafID in leafIDs.dropFirst() {
            node = .split(axis: .horizontal, ratio: 0.5, left: node, right: .leaf(leafID))
        }
        return GhosttySurfaceTree(root: node)
    }

    private var runtimePhase: GhosttyTerminalRuntimePhase {
        guard let session else {
            return .failed(message: "terminal session unavailable", reason: nil)
        }
        switch session.state {
        case .attaching, .syncing:
            return .starting
        case .ready:
            return .running
        case .detached(nil):
            if let failure = session.transportFailure {
                return .failed(message: failure.message, reason: failure)
            }
            // Pre-connect; the first connect is imminent.
            return .starting
        case .detached(.some(let reason)):
            let mapped = reason.terminalDisconnectReason
            return .failed(message: mapped.message, reason: mapped)
        case .closed(let reason):
            let mapped = reason.terminalDisconnectReason
            return .failed(message: mapped.message, reason: mapped)
        }
    }

    private var isTransportWritable: Bool {
        session?.state == .ready
    }

    // MARK: Managed surface lifecycle

    private func rebuildActiveManagedSurface(for paneSurface: TmuxPaneSurface?) {
        if paneSurface == nil {
            captureActivePanePreviewBeforeRelease()
        }
        if let previous = activeManagedSurface {
            pendingRemovalSurfaces[previous.id] = previous
            activeManagedSurface = nil
            activeManagedPaneID = nil
            displayedPresentationPaneID = nil
            abandonedPendingPresentationPaneID = nil
        }

        guard let paneSurface, let controller else { return }

        let paneID = paneSurface.paneID
        let managedID = paneSurface.instanceID.rawValue

        let windowIDForPane = latestTopology?.panes
            .first(where: { $0.id == paneID })?.windowID

        let controlSurface = GhosttyKitControlSurface(
            surface: paneSurface.rawSurface,
            ownership: .borrowed,
            retainedObjects: [paneSurface]
        )
        activeManagedSurface = GhosttyManagedSurface(
            id: managedID,
            view: paneSurface.view,
            controlSurface: controlSurface,
            scrollState: controlSurface.scrollState(),
            scrollRoute: controlSurface.scrollRoute(),
            tmuxFocus: { [weak controller] in
                controller?.requestSelectPane(paneID: paneID)
                return .queued
            },
            tmuxSplit: { [weak controller] direction in
                // Zoomed split: the new pane immediately owns the full
                // client size (phone presentation policy).
                controller?.requestSplit(
                    paneID: paneID,
                    direction: TmuxSessionController.SplitDirection(actionDirection: direction),
                    zoom: true
                )
                return .queued
            },
            tmuxClosePane: { [weak controller] in
                controller?.requestClosePane(paneID: paneID)
                return .queued
            },
            tmuxCloseWindow: { [weak controller] in
                if let windowIDForPane {
                    controller?.requestCloseWindow(windowID: windowIDForPane)
                    return .queued
                }
                return .noTarget
            },
            tmuxCopyMode: { [weak controller] in
                controller?.requestCopyMode(paneID: paneID)
                return .queued
            },
            // The pane surface's lifecycle (surface free, then unbind) is
            // owned by TmuxTerminalSession; the managed wrapper must not
            // release anything itself.
            releaseBeforePermanentRemoval: {},
            transferRuntimeSurfaceLifetimeToAppShutdown: {}
        )
        activeManagedPaneID = paneID
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "presentation.managedSurface.ready",
            fields: [
                "pane": "\(paneID)",
                "surface": String(describing: paneSurface.rawSurface),
                "surface_uuid": managedID.uuidString,
            ]
        )
        // The first real layout-driven display update opens viewport
        // reporting (the placeholder frame's bogus size never reaches
        // tmux), reports the actual grid once, and ends the presentation
        // hold for this surface.
        activeManagedSurface?.onDisplayUpdate = { [weak self, weak paneSurface] _, size, _ in
            guard size.width > 1, size.height > 1 else { return }
            GhosttyRuntimeTrace.flowEventOnce(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.layout.ready",
                fields: [
                    "height": "\(size.height)",
                    "pane": "\(paneID)",
                    "surface": paneSurface.map { String(describing: $0.rawSurface) } ?? "released",
                    "width": "\(size.width)",
                ]
            )
            paneSurface?.enableClientSizeReports()
            paneSurface?.refreshAfterInitialLayout()
            self?.notePresentationSurfaceDisplayed(managedID)
        }
        // The session frees the pane surface on pane changes while the
        // tree may still hold this wrapper in an inactive container;
        // invalidate the borrowed handle the moment the close starts.
        paneSurface.onClose = { [weak controlSurface] in
            controlSurface?.invalidate()
        }
    }

    private func managedSurface(for id: UUID) -> GhosttyManagedSurface? {
        if let active = activeManagedSurface, active.id == id {
            return active
        }
        return nil
    }

    private func managedSurface(forHandle handle: ghostty_surface_t?) -> GhosttyManagedSurface? {
        guard let handle else { return nil }
        if let active = activeManagedSurface, active.controlSurface.handle == handle {
            return active
        }
        return pendingRemovalSurfaces.values.first { $0.controlSurface.handle == handle }
    }

    private var focusedManagedSurface: GhosttyManagedSurface? {
        activeManagedSurface
    }

    // MARK: Command failures

    private func presentCommandFailure(for request: TmuxSessionController.Request) {
        if case .armed(let generation, let surfaceID) = pickerPreviewReleaseCoverage {
            pickerPreviewReleaseCoverage = .ready(
                generation: generation,
                surfaceID: surfaceID
            )
        }
        commandFailureToken &+= 1
        let message = "tmux: \(Self.failureLabel(for: request)) failed"
        commandFailureMessage = message
        commandFailureEvent = GhosttyTmuxCommandFailureEvent(
            token: commandFailureToken,
            message: message
        )
        objectWillChange.send()

        let token = commandFailureToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.commandFailureToken == token else { return }
            self.commandFailureMessage = nil
            self.objectWillChange.send()
        }
    }

    private static func failureLabel(for request: TmuxSessionController.Request) -> String {
        switch request {
        case .newWindow: "new window"
        case .splitPane: "split pane"
        case .closePane: "close pane"
        case .closeWindow: "close window"
        case .selectWindow: "select window"
        case .selectPane: "select pane"
        case .zoomPane: "zoom pane"
        case .copyMode: "copy mode"
        case .setClientSize: "resize"
        case .sendInput: "input"
        }
    }
}

// MARK: - GhosttyTerminalScreenModeling

extension TmuxTerminalScreenAdapter: GhosttyTerminalScreenModeling {
    func prepareInitialViewport(size: CGSize, scale: CGFloat) {
        initialViewportHandler?(size, scale)
    }

    var terminalScreenPresentationProjection: GhosttyTerminalScreenPresentationProjection {
        GhosttyTerminalPresentationProjector.terminalScreenPresentationProjection(
            phase: runtimePhase,
            transportWritable: isTransportWritable,
            commandFailureMessage: commandFailureMessage,
            debugStatus: stateTraceLabel,
            registryDebugSummary: "tmux session stack",
            presentedSurfaceID: activeManagedSurface?.id,
            snapshot: topologySnapshot
        )
    }

    var terminalInteractionProjection: GhosttyTerminalInteractionProjection {
        GhosttyTerminalPresentationProjector.terminalInteractionProjection(
            phase: runtimePhase,
            presentedSurfaceID: activeManagedSurface?.id,
            snapshot: topologySnapshot
        )
    }

    var terminalSurfaceMaterializationContext: GhosttyRuntimeSurfaceMaterializationContext {
        GhosttyRuntimeSurfaceMaterializationContext(
            sourceIdentity: ObjectIdentifier(self),
            isAvailable: { [weak self] in self?.session != nil },
            isRuntimeRemovalInProgress: { [weak self] in self?.session == nil },
            allManagedSurfaces: { [weak self] in
                self?.activeManagedSurface.map { [$0] } ?? []
            },
            managedSurfaceCount: { [weak self] in
                self?.activeManagedSurface != nil ? 1 : 0
            },
            managedSurface: { [weak self] id in self?.managedSurface(for: id) },
            surfacePendingPermanentRemoval: { [weak self] id in
                self?.pendingRemovalSurfaces[id]
            },
            completePermanentRemoval: { [weak self] id in
                self?.pendingRemovalSurfaces[id] = nil
            },
            diagnosticSelectionSummary: { [weak self] in
                guard let self else { return "tmux adapter released" }
                let active = self.activeManagedSurface
                    .map { ghosttyDiagnosticShortID($0.id) } ?? "none"
                return "tmux active pane surface=\(active)"
            },
            recordSurfacePresentation: { _, _ in }
        )
    }

    var stateTraceLabel: String {
        guard let session else { return "released" }
        return switch session.state {
        case .detached: "detached"
        case .attaching: "attaching"
        case .syncing: "syncing"
        case .ready: "ready"
        case .closed: "closed"
        }
    }

    func setViewportStabilityHint(stable: Bool) {
        controller?.setViewportStability(stable)
    }

    func makePanePreviewSession(
        leafIDs: [UUID],
        previewSizing: GhosttyPanePreviewSession.PreviewSizing
    ) -> GhosttyPanePreviewSession {
        pickerPreviewGeneration &+= 1
        pickerPreviewReleaseCoverage = .refreshing(
            generation: pickerPreviewGeneration
        )
        return newPanePreviewSession(
            leafIDs: leafIDs,
            previewSizing: previewSizing,
            purpose: .picker(pickerPreviewGeneration)
        )
    }

    private func newPanePreviewSession(
        leafIDs: [UUID],
        previewSizing: GhosttyPanePreviewSession.PreviewSizing,
        purpose: PanePreviewRequestPurpose
    ) -> GhosttyPanePreviewSession {
        GhosttyPanePreviewSession(
            leafIDs: leafIDs,
            previewSizing: previewSizing,
            previewRequestClient: GhosttyPanePreviewSession.PreviewRequestClient(
                start: { [weak self] leafID, options, userdata, callback, completion in
                    guard let self else {
                        completion(.surfaceUnavailable)
                        return
                    }
                    guard let paneID = self.identities.paneID(for: leafID) else {
                        completion(.surfaceUnavailable)
                        return
                    }
                    if let activeSurface = self.activeManagedSurface,
                       self.activeManagedPaneID == paneID {
                        GhosttyRuntimeTrace.perf(
                            "tmuxPane.preview.request pane=\(paneID) source=live"
                        )
                        guard let request = activeSurface.controlSurface.renderPreviewImageAsync(
                            options: options,
                            userdata: userdata,
                            callback: callback
                        ) else {
                            completion(.rejected)
                            return
                        }
                        let size = activeSurface.controlSurface.currentSize()
                        let source: GhosttyPanePreviewSession.PreviewSource
                        if size.width_px > 0, size.height_px > 0 {
                            source = .fullViewport(
                                GhosttyPanePreviewSession.FullViewportProvenance(
                                    surfaceID: activeSurface.id,
                                    pixelWidth: size.width_px,
                                    pixelHeight: size.height_px
                                )
                            )
                        } else {
                            source = .remotePaneGeometry
                        }
                        completion(
                            .started(
                                request,
                                source: source
                            )
                        )
                        return
                    }
                    guard let styleSurface = self.activeManagedSurface?.controlSurface.handle else {
                        completion(.surfaceUnavailable)
                        return
                    }
                    guard let renderRequest = self.panePreviewRequest(
                        paneID: paneID,
                        options: options
                    ) else {
                        completion(.surfaceUnavailable)
                        return
                    }
                    GhosttyRuntimeTrace.perf(
                        "tmuxPane.preview.request pane=\(paneID) source=remote-split-fallback"
                    )
                    guard let controller = self.controller else {
                        completion(.rejected)
                        return
                    }
                    controller.renderPanePreviewImageAsync(
                        paneID: paneID,
                        styleSurface: styleSurface,
                        options: renderRequest.options,
                        previewGrid: renderRequest.grid,
                        userdata: userdata,
                        callback: callback
                    ) { request in
                        guard let request else {
                            completion(.rejected)
                            return
                        }
                        completion(.started(request, source: .remotePaneGeometry))
                    }
                },
                cancel: { GhosttyKitControlSurface.cancelPreviewRequest($0) },
                release: { GhosttyKitControlSurface.releasePreviewRequest($0) },
                cachedPreview: { [weak self] leafID in
                    guard let self,
                          let paneID = self.identities.paneID(for: leafID)
                    else { return nil }
                    guard let preview = self.panePreviewCache.preview(for: paneID) else {
                        GhosttyRuntimeTrace.perf(
                            "tmuxPane.preview.cache pane=\(paneID) result=miss"
                        )
                        return nil
                    }
                    GhosttyRuntimeTrace.perf(
                        "tmuxPane.preview.cache pane=\(paneID) result=hit source=\(Self.previewSourceLabel(preview.source)) bytes=\(preview.image.bytesPerRow * preview.image.height)"
                    )
                    return preview
                },
                shouldRefreshCachedImage: { [weak self] leafID in
                    guard let self,
                          let paneID = self.identities.paneID(for: leafID),
                          self.activeManagedPaneID == paneID,
                          self.activeManagedSurface != nil
                    else { return false }
                    // Full-viewport provenance describes geometry, not
                    // freshness. Always refresh the currently live pane when
                    // a picker opens while keeping its cached image visible.
                    return true
                },
                cacheRenderedPreview: { [weak self] leafID, preview in
                    guard let self,
                          self.session?.state == .ready,
                          let paneID = self.identities.paneID(for: leafID),
                          self.latestTopology?.panes.contains(where: { $0.id == paneID }) == true
                    else { return }
                    let evictedPaneIDs = self.panePreviewCache.store(
                        preview,
                        for: paneID
                    )
                    guard self.panePreviewCache.entries[paneID]?.preview.image === preview.image else {
                        GhosttyRuntimeTrace.perf(
                            "tmuxPane.preview.cache pane=\(paneID) result=reject-oversize bytes=\(preview.image.bytesPerRow * preview.image.height) limit=\(self.panePreviewCache.byteLimit)"
                        )
                        return
                    }
                    GhosttyRuntimeTrace.perf(
                        "tmuxPane.preview.cache pane=\(paneID) result=store source=\(Self.previewSourceLabel(preview.source)) bytes=\(preview.image.bytesPerRow * preview.image.height) total=\(self.panePreviewCache.totalByteCost)"
                    )
                    if !evictedPaneIDs.isEmpty {
                        GhosttyRuntimeTrace.perf(
                            "tmuxPane.preview.cache result=evict panes=\(evictedPaneIDs) total=\(self.panePreviewCache.totalByteCost)"
                        )
                    }
                    if case .picker(let generation) = purpose,
                       case .fullViewport(let provenance) = preview.source,
                       case .refreshing(generation) = self.pickerPreviewReleaseCoverage,
                       self.activeManagedPaneID == paneID,
                       self.activeManagedSurface?.id == provenance.surfaceID {
                        self.pickerPreviewReleaseCoverage = .ready(
                            generation: generation,
                            surfaceID: provenance.surfaceID
                        )
                    }
                }
            )
        )
    }

    private static func previewSourceLabel(
        _ source: GhosttyPanePreviewSession.PreviewSource
    ) -> String {
        switch source {
        case .remotePaneGeometry:
            return "remote-pane-geometry"
        case .fullViewport(let provenance):
            return "full-viewport-\(provenance.pixelWidth)x\(provenance.pixelHeight)"
        }
    }

    /// Request acceptance snapshots the live terminal synchronously inside
    /// libghostty, before `TmuxPaneSurface.close()` frees the native surface.
    /// Pixel rendering and cache delivery remain asynchronous and therefore
    /// do not extend the native release critical path.
    private func captureActivePanePreviewBeforeRelease() {
        guard session?.state == .ready,
              let activeSurface = activeManagedSurface,
              let paneID = activeManagedPaneID
        else { return }

        if case .armed(_, let coveredSurfaceID) = pickerPreviewReleaseCoverage,
           coveredSurfaceID == activeSurface.id {
            pickerPreviewReleaseCoverage = .inactive
            GhosttyRuntimeTrace.perf(
                "tmuxPane.preview.capture pane=\(paneID) event=picker-covered-release"
            )
            return
        }
        pickerPreviewReleaseCoverage = .inactive

        let paneUUID = identities.surfaceID(for: paneID)
        let captureSession = newPanePreviewSession(
            leafIDs: [paneUUID],
            previewSizing: .paneGridForCurrentScreen,
            purpose: .beforeRelease
        )
        cancelPanePreviewCapture()
        panePreviewCaptureSession = captureSession
        GhosttyRuntimeTrace.perf(
            "tmuxPane.preview.capture pane=\(paneID) event=before-release"
        )
        captureSession.startRefreshing()
    }

    private func coverNextReleaseWithReadyPickerPreview() {
        guard let activeSurface = activeManagedSurface,
              case .ready(let generation, let surfaceID) = pickerPreviewReleaseCoverage,
              generation == pickerPreviewGeneration,
              surfaceID == activeSurface.id
        else {
            pickerPreviewReleaseCoverage = .inactive
            return
        }
        pickerPreviewReleaseCoverage = .armed(
            generation: generation,
            surfaceID: surfaceID
        )
    }

    private func clearPickerPreviewReleaseCoverage() {
        pickerPreviewReleaseCoverage = .inactive
    }

    private func cancelPanePreviewCapture() {
        panePreviewCaptureSession?.cancelAll()
        panePreviewCaptureSession = nil
    }

    private struct PanePreviewRequest {
        let options: ghostty_surface_preview_image_options_s
        let grid: TmuxSessionController.ClientSize
    }

    private func panePreviewRequest(
        paneID: TmuxPaneID,
        options: ghostty_surface_preview_image_options_s
    ) -> PanePreviewRequest? {
        guard let topology = latestTopology else {
            return nil
        }
        guard let pane = topology.panes.first(where: { $0.id == paneID }) else {
            return nil
        }
        guard let window = topology.windows.first(where: { $0.id == pane.windowID }) else {
            return nil
        }
        guard let surfaceSize = activeManagedSurface?.controlSurface.currentSize() else {
            return nil
        }
        guard let scaledOptions = Self.panePreviewOptions(
            options: options
        ) else {
            return nil
        }
        guard let grid = Self.panePreviewGrid(
            windowWidth: window.width,
            windowHeight: window.height,
            cellWidthPx: Double(surfaceSize.cell_width_px),
            cellHeightPx: Double(surfaceSize.cell_height_px),
            budgetWidthPx: scaledOptions.max_width_px,
            budgetHeightPx: scaledOptions.max_height_px
        ) else {
            return nil
        }
        return PanePreviewRequest(options: scaledOptions, grid: grid)
    }

    /// Validate the request budget. Split geometry is accepted here only as
    /// the cold-cache fallback; visited panes use their cached image from a
    /// real full-viewport live surface.
    static func panePreviewOptions(
        options: ghostty_surface_preview_image_options_s
    ) -> ghostty_surface_preview_image_options_s? {
        guard options.max_width_px > 0, options.max_height_px > 0 else { return nil }
        return options
    }

    /// The offscreen grid for a previewable pane uses the full window
    /// grid, matching Remux's zoomed phone presentation.
    static func panePreviewGrid(
        windowWidth: UInt32,
        windowHeight: UInt32,
        cellWidthPx: Double,
        cellHeightPx: Double,
        budgetWidthPx: UInt32,
        budgetHeightPx: UInt32
    ) -> TmuxSessionController.ClientSize? {
        guard windowWidth > 0, windowHeight > 0 else { return nil }
        guard cellWidthPx > 0, cellHeightPx > 0 else { return nil }
        guard budgetWidthPx > 0, budgetHeightPx > 0 else { return nil }

        let aspectRows = Double(windowWidth) *
            Double(budgetHeightPx) *
            cellWidthPx /
            (Double(budgetWidthPx) * cellHeightPx)
        let rows = min(max(1, aspectRows.rounded()), Double(windowHeight))
        return TmuxSessionController.ClientSize(
            cols: windowWidth,
            rows: UInt32(rows)
        )
    }

    private func reconcilePanePreviewCache(
        with topology: TmuxSessionController.TopologySnapshot
    ) {
        let removedPaneIDs = panePreviewCache.retainOnly(Set(topology.panes.map(\.id)))
        guard !removedPaneIDs.isEmpty else { return }
        GhosttyRuntimeTrace.perf(
            "tmuxPane.preview.cache result=topology-remove panes=\(removedPaneIDs) total=\(panePreviewCache.totalByteCost)"
        )
    }

    private func clearPanePreviewCache(reason: String) {
        cancelPanePreviewCapture()
        clearPickerPreviewReleaseCoverage()
        guard !panePreviewCache.entries.isEmpty else { return }
        panePreviewCache.removeAll()
        GhosttyRuntimeTrace.perf(
            "tmuxPane.preview.cache result=clear reason=\(reason)"
        )
    }

    // MARK: Input routing

    private func preflightFocusedInput() -> FocusedTerminalInputSubmissionResult? {
        guard isTransportWritable else { return .transportUnavailable }
        guard focusedManagedSurface != nil else { return .noFocusedSurface }
        return nil
    }

    func sendInputToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        if let preflight = preflightFocusedInput() { return preflight }
        return focusedManagedSurface?.sendInput(text) ?? .noFocusedSurface
    }

    func sendPasteToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        if let preflight = preflightFocusedInput() { return preflight }
        return focusedManagedSurface?.sendPaste(text) ?? .noFocusedSurface
    }

    func sendPaste(_ text: String, to surfaceID: UUID) -> FocusedTerminalInputSubmissionResult {
        guard isTransportWritable else { return .transportUnavailable }
        guard let managed = managedSurface(for: surfaceID) else { return .noFocusedSurface }
        return managed.sendPaste(text)
    }

    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        if let preflight = preflightFocusedInput() { return preflight }
        return focusedManagedSurface?.sendKeyEvent(event) ?? .noFocusedSurface
    }

    func readSelection(from surfaceID: UUID) -> GhosttyTerminalSelectionReadOutcome {
        guard let managed = managedSurface(for: surfaceID) else {
            return .missingSurface(surfaceID)
        }
        guard let text = managed.readSelection(), !text.isEmpty else {
            return .emptySelection
        }
        return .text(text)
    }

    func selectionAvailability(for surfaceID: UUID) -> GhosttyTerminalSelectionAvailabilityOutcome {
        guard let managed = managedSurface(for: surfaceID) else {
            return .missingSurface(surfaceID)
        }
        return managed.hasSelection() ? .available : .emptySelection
    }

    func selectTerminalSurface(_ surfaceID: UUID, reason: String) -> GhosttySurfaceSelectionOutcome {
        // The active pane is the only materialized surface; native-side
        // selection is therefore always either redundant or impossible.
        guard let managed = managedSurface(for: surfaceID) else {
            return .missingSurface(surfaceID)
        }
        _ = reason
        managed.setFocused(true)
        return .alreadySelected
    }

    func isMouseCaptured(for surfaceID: UUID) -> Bool {
        managedSurface(for: surfaceID)?.controlSurface.isMouseCaptured() ?? false
    }

    func sendMouseButton(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseButtonEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let managed = managedSurface(for: surfaceID) else {
            return .missingTarget(surfaceID)
        }
        return managed.sendMouseButton(event) ? .sent : .surfaceRejected
    }

    func sendMousePosition(
        to surfaceID: UUID,
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let managed = managedSurface(for: surfaceID) else {
            return .missingTarget(surfaceID)
        }
        managed.sendMousePosition(position, mods: mods)
        return .sent
    }

    func sendMouseScroll(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseScrollEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let managed = managedSurface(for: surfaceID) else {
            return .missingTarget(surfaceID)
        }
        managed.sendMouseScroll(event)
        return .sent
    }

    func sendMousePressure(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMousePressureEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let managed = managedSurface(for: surfaceID) else {
            return .missingTarget(surfaceID)
        }
        managed.controlSurface.sendMousePressure(event)
        return .sent
    }

    // MARK: tmux topology actions

    func focusTmuxPane(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let paneID = identities.paneID(for: id), let controller else {
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "adapter.resolve.failed",
                fields: ["target_uuid": id.uuidString]
            )
            return .missingTarget(.pane(id))
        }
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "adapter.resolve.ready",
            fields: [
                "pane": "\(paneID)",
                "target_uuid": id.uuidString,
            ]
        )
        if paneID != activeManagedPaneID {
            coverNextReleaseWithReadyPickerPreview()
        }
        controller.requestSelectPane(paneID: paneID)
        session?.prepareForPaneSelection(paneID: paneID)
        return .queued
    }

    func focusTmuxTopLevel(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let windowID = identities.windowID(for: id), let controller else {
            return .missingTarget(.window(id))
        }
        if latestTopology?.activeWindowID != windowID {
            coverNextReleaseWithReadyPickerPreview()
        }
        controller.requestSelectWindow(windowID: windowID)
        return .queued
    }

    func focusAdjacentTmuxTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection
    ) -> GhosttyTmuxModelActionOutcome {
        guard
            let controller,
            let topology = latestTopology,
            !topology.windows.isEmpty,
            let activeWindowID = topology.activeWindowID,
            let activeIndex = topology.windows.firstIndex(where: { $0.id == activeWindowID })
        else {
            return .missingTarget(.adjacentWindow)
        }

        let targetIndex = direction.advancedIndex(
            from: activeIndex,
            count: topology.windows.count
        )
        guard targetIndex != activeIndex else {
            return .missingTarget(.adjacentWindow)
        }
        controller.requestSelectWindow(windowID: topology.windows[targetIndex].id)
        return .queued
    }

    func createTmuxWindow() -> GhosttyTmuxModelActionOutcome {
        guard let controller else { return .missingTarget(.host) }
        coverNextReleaseWithReadyPickerPreview()
        controller.requestNewWindow()
        return .queued
    }

    func splitFocusedTmuxPane(
        _ direction: ghostty_action_split_direction_e
    ) -> GhosttyTmuxModelActionOutcome {
        guard let controller, let paneSurface = session?.paneSurface else {
            return .missingTarget(.focusedPane)
        }
        coverNextReleaseWithReadyPickerPreview()
        controller.requestSplit(
            paneID: paneSurface.paneID,
            direction: TmuxSessionController.SplitDirection(actionDirection: direction),
            zoom: true
        )
        return .queued
    }

    func closeTmuxPane(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let paneID = identities.paneID(for: id), let controller else {
            return .missingTarget(.pane(id))
        }
        if paneID == activeManagedPaneID {
            coverNextReleaseWithReadyPickerPreview()
        }
        controller.requestClosePane(paneID: paneID)
        return .queued
    }

    func closeTmuxWindow(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let windowID = identities.windowID(for: id), let controller else {
            return .missingTarget(.window(id))
        }
        if windowID == latestTopology?.activeWindowID {
            coverNextReleaseWithReadyPickerPreview()
        }
        controller.requestCloseWindow(windowID: windowID)
        return .queued
    }

    func enterFocusedTmuxCopyMode() -> GhosttyTmuxModelActionOutcome {
        guard let controller, let paneSurface = session?.paneSurface else {
            return .missingTarget(.focusedPane)
        }
        controller.requestCopyMode(paneID: paneSurface.paneID)
        return .queued
    }

    // MARK: Selection sheet projections

    func createTmuxWindowInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.createTmuxWindowInteractionEffect()
    }

    func splitFocusedTmuxPaneInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.splitFocusedTmuxPaneInteractionEffect()
    }

    func closeTmuxWindowInteractionEffect(_ id: UUID) -> GhosttyTmuxTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.closeTmuxWindowInteractionEffect(
            id,
            snapshot: topologySnapshot
        )
    }

    func closeTmuxPaneInteractionEffect(
        _ id: UUID,
        inTopLevel topLevelID: UUID
    ) -> GhosttyTmuxTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.closeTmuxPaneInteractionEffect(
            id,
            inTopLevel: topLevelID,
            snapshot: topologySnapshot
        )
    }

    func windowSheetPresentationProjection() -> GhosttyWindowSheetPresentationProjection? {
        GhosttyTerminalPresentationProjector.windowSheetPresentationProjection(
            snapshot: topologySnapshot
        )
    }

    func selectedPaneSheetPresentationProjection() -> GhosttyPaneSheetPresentationProjection? {
        GhosttyTerminalPresentationProjector.selectedPaneSheetPresentationProjection(
            snapshot: topologySnapshot
        )
    }

    func paneSheetDetentPaneCount(topLevelID: UUID) -> Int {
        GhosttyTerminalPresentationProjector.paneSheetDetentPaneCount(
            topLevelID: topLevelID,
            snapshot: topologySnapshot
        )
    }

    func windowSheetDetentCellCount() -> Int {
        GhosttyTerminalPresentationProjector.windowSheetDetentCellCount(
            snapshot: topologySnapshot
        )
    }

    func paneSelectionSheetTopologyProjection(
        topLevelID: UUID?
    ) -> GhosttyPaneSelectionSheetTopologyProjection {
        GhosttyTerminalPresentationProjector.paneSelectionSheetTopologyProjection(
            topLevelID: topLevelID,
            snapshot: topologySnapshot
        )
    }

    func windowSelectionSheetRenderProjection() -> GhosttyWindowSelectionSheetRenderProjection {
        GhosttyTerminalPresentationProjector.windowSelectionSheetRenderProjection(
            snapshot: topologySnapshot
        )
    }

    func paneSelectionSheetRenderProjection(
        topLevelID: UUID
    ) -> GhosttyPaneSelectionSheetRenderProjection {
        GhosttyTerminalPresentationProjector.paneSelectionSheetRenderProjection(
            topLevelID: topLevelID,
            snapshot: topologySnapshot
        )
    }
}

// MARK: - Runtime surface delegate (scroll state delivery)

extension TmuxTerminalScreenAdapter: GhosttyKitRuntimeSurfaceDelegate {
    func makeRuntimeCallbackLease() -> GhosttyRuntimeCallbackLease? {
        leaseStore.makeLease(registryID: ObjectIdentifier(self))
    }

    nonisolated func acceptsRuntimeCallback(_ lease: GhosttyRuntimeCallbackLease) -> Bool {
        leaseStore.accepts(lease)
    }

    nonisolated func runtimeCallbackLeaseDidEnd(_ lease: GhosttyRuntimeCallbackLease) {
        leaseStore.invalidate(lease)
    }

    func runtimeCreateSurface(
        app: ghostty_app_t?,
        request: GhosttyRuntimeSurfaceCreationRequest,
        lease: GhosttyRuntimeCallbackLease
    ) -> ghostty_surface_t? {
        // The new stack creates surfaces host-side only (pane bindings); the
        // runtime never asks for one.
        nil
    }

    func runtimeCreateSurfaceTree(
        app: ghostty_app_t?,
        request: GhosttyRuntimeSurfaceTreeCreationRequest,
        lease: GhosttyRuntimeCallbackLease
    ) -> Bool {
        false
    }

    func runtimeSelectSurface(
        app: ghostty_app_t?,
        surface: ghostty_surface_t?,
        lease: GhosttyRuntimeCallbackLease
    ) {}

    func runtimeAction(
        app: ghostty_app_t?,
        target: GhosttyRuntimeSurfaceActionTarget,
        action: GhosttyRuntimeSurfaceAction,
        lease: GhosttyRuntimeCallbackLease
    ) -> Bool {
        guard case .surface(let handle) = target,
              let managed = managedSurface(forHandle: handle)
        else {
            return false
        }

        switch action {
        case .scrollbar(let state):
            managed.updateScrollState(state)
            return true
        case .scrollRoute(let route):
            GhosttyRuntimeTrace.diagnostics(
                "tmuxAdapter.scrollRoute surface=\(ghosttyDiagnosticShortID(managed.id)) route=\(route)"
            )
            managed.updateScrollRoute(route)
            return true
        case .render, .ignored:
            return false
        }
    }
}

// MARK: - Shared reason mapping

extension TmuxSessionController.DetachReason {
    var terminalDisconnectReason: TerminalDisconnectReason {
        switch self {
        case .serverExited(let message):
            TerminalDisconnectReason(
                kind: .remoteExit,
                message: message ?? "tmux server exited"
            )
        case .transportClosed:
            TerminalDisconnectReason(
                kind: .transportIO,
                message: "connection lost"
            )
        case .channelAborted:
            TerminalDisconnectReason(
                kind: .runtime,
                message: "tmux control protocol error"
            )
        case .outOfMemory, .baselineFailed, .reconcileFailed:
            TerminalDisconnectReason(
                kind: .runtime,
                message: "tmux session sync failed"
            )
        }
    }
}

extension TmuxSessionController.CloseReason {
    var terminalDisconnectReason: TerminalDisconnectReason {
        switch self {
        case .attachFailed(let message):
            TerminalDisconnectReason(
                kind: .runtime,
                message: message.isEmpty ? "tmux attach failed" : message
            )
        case .unsupportedVersion(let version):
            TerminalDisconnectReason(
                kind: .runtime,
                message: "unsupported tmux version \(version) (requires 3.2+)"
            )
        }
    }
}

private extension TmuxSessionController.SplitDirection {
    init(actionDirection: ghostty_action_split_direction_e) {
        switch actionDirection {
        case GHOSTTY_SPLIT_DIRECTION_LEFT: self = .left
        case GHOSTTY_SPLIT_DIRECTION_UP: self = .up
        case GHOSTTY_SPLIT_DIRECTION_DOWN: self = .down
        default: self = .right
        }
    }
}
