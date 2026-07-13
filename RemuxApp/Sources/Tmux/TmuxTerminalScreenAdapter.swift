import Combine
import CoreGraphics
import Foundation
import GhosttyKit


/// Presents the new tmux session stack (`TmuxTerminalSession`) through the
/// `GhosttyTerminalScreenModeling` boundary so `GhosttySurfaceScreen` — the
/// full terminal UX — renders it unchanged.
///
/// Topology mapping: tmux window/pane IDs (UInt64) are mapped to stable UUIDs
/// for the screen's projections. The session may retain multiple real pane
/// surfaces, while this adapter publishes only the active pane's stable
/// `GhosttyManagedSurface` to the phone viewport.
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
    private var initialViewportHandler: ((CGSize, CGFloat) -> Void)?
    private var clientSizeHandler: ((TmuxSessionController.ClientSize) -> Void)?
    private var cachedTopologySnapshot = GhosttyRuntimeSurfaceTopologySnapshot.empty
    private var panePreviewCache = TmuxPanePreviewImageCache(
        byteLimit: TmuxTerminalScreenAdapter.panePreviewCacheByteLimit
    )
    private var panePreviewCaptureSession: GhosttyPanePreviewSession?
    private var warmingPreviewProvenance: GhosttyPanePreviewSession.FullViewportProvenance?
    private var warmingPreviewPaneID: TmuxPaneID?

    private var commandFailureMessage: String?
    private(set) var commandFailureEvent: GhosttyTmuxCommandFailureEvent?
    private var commandFailureToken: UInt64 = 0

    private var subscriptions: [AnyCancellable] = []

    /// Connects the adapter to a live session. Called once, right after the
    /// session is created (the adapter itself must exist before the runtime,
    /// because it is the runtime's surface delegate).
    func activate(
        session: TmuxTerminalSession,
        initialViewportHandler: @escaping (CGSize, CGFloat) -> Void,
        clientSizeHandler: @escaping (TmuxSessionController.ClientSize) -> Void
    ) {
        self.session = session
        self.controller = session.controller
        self.initialViewportHandler = initialViewportHandler
        self.clientSizeHandler = clientSizeHandler

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
                if let paneSurface = self.session?.paneSurface {
                    let windowID = topology?.panes
                        .first(where: { $0.id == paneSurface.paneID })?.windowID
                    paneSurface.updateWindowID(windowID)
                }
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
        clearPanePreviewCache(reason: "invalidate")
        session = nil
        controller = nil
        initialViewportHandler = nil
        clientSizeHandler = nil
        latestTopology = nil
        cachedTopologySnapshot = Self.emptyTopologySnapshot
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

        cachedTopologySnapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: topLevels,
            selectedTopLevelID: topology.activeWindowID.map { identities.surfaceID(for: $0) },
            pendingPhonePresentationSurfaceID: nil
        )
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
        if activeManagedSurface != nil {
            activeManagedSurface = nil
            activeManagedPaneID = nil
        }

        guard let paneSurface else { return }

        let paneID = paneSurface.paneID
        let windowIDForPane = latestTopology?.panes
            .first(where: { $0.id == paneID })?.windowID
        let wasAlreadyWrapped = paneSurface.managedSurface != nil
        let managed = paneSurface.screenSurface(
            windowID: windowIDForPane
        ) { [weak self, weak paneSurface] managed, size, _ in
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
            self?.reportClientSizeIfActive(managed)
            paneSurface?.completeInitialLayout()
            if let paneSurface {
                self?.warmFullViewportPreviewIfNeeded(
                    paneSurface: paneSurface,
                    managedSurface: managed
                )
            }
        }
        activeManagedSurface = managed
        activeManagedPaneID = paneID
        if !wasAlreadyWrapped {
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.managedSurface.ready",
                fields: [
                    "pane": "\(paneID)",
                    "surface": String(describing: paneSurface.rawSurface),
                    "surface_uuid": managed.id.uuidString,
                ]
            )
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
        return nil
    }

    private var focusedManagedSurface: GhosttyManagedSurface? {
        activeManagedSurface
    }

    private func reportClientSizeIfActive(_ managed: GhosttyManagedSurface) {
        guard activeManagedSurface === managed else { return }
        let size = managed.controlSurface.currentSize()
        guard size.columns >= 2, size.rows >= 2 else { return }
        clientSizeHandler?(TmuxSessionController.ClientSize(
            cols: UInt32(size.columns),
            rows: UInt32(size.rows)
        ))
    }

    // MARK: Command failures

    private func presentCommandFailure(for request: TmuxSessionController.Request) {
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
            managedSurface: { [weak self] id in self?.managedSurface(for: id) }
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
        return newPanePreviewSession(
            leafIDs: leafIDs,
            previewSizing: previewSizing
        )
    }

    private func newPanePreviewSession(
        leafIDs: [UUID],
        previewSizing: GhosttyPanePreviewSession.PreviewSizing
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
                    guard let styleSurface = self.activeManagedSurface?.controlSurface else {
                        completion(.surfaceUnavailable)
                        return
                    }
                    guard self.latestTopology?.panes.contains(where: { $0.id == paneID }) == true,
                          let renderOptions = Self.panePreviewOptions(options: options)
                    else {
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
                        options: renderOptions,
                        previewGrid: nil,
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
                    if case .fullViewport(let provenance) = preview.source,
                       provenance == self.warmingPreviewProvenance,
                       paneID == self.warmingPreviewPaneID {
                        self.panePreviewCaptureSession?.cancelAll()
                        self.panePreviewCaptureSession = nil
                        self.warmingPreviewProvenance = nil
                        self.warmingPreviewPaneID = nil
                        if let currentPane = self.session?.paneSurface,
                           let currentManaged = self.activeManagedSurface {
                            self.warmFullViewportPreviewIfNeeded(
                                paneSurface: currentPane,
                                managedSurface: currentManaged
                            )
                        }
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

    /// After the real surface has completed its first full-viewport layout and
    /// queued its reveal render, warm the picker cache asynchronously. This
    /// records layout/provenance, not GPU frame completion.
    private func warmFullViewportPreviewIfNeeded(
        paneSurface: TmuxPaneSurface,
        managedSurface: GhosttyManagedSurface
    ) {
        guard paneSurface.hasCompletedInitialLayout,
              session?.state == .ready,
              activeManagedSurface === managedSurface,
              activeManagedPaneID == paneSurface.paneID
        else { return }

        let size = managedSurface.controlSurface.currentSize()
        guard size.width_px > 0, size.height_px > 0 else { return }
        let provenance = GhosttyPanePreviewSession.FullViewportProvenance(
            surfaceID: managedSurface.id,
            pixelWidth: size.width_px,
            pixelHeight: size.height_px
        )
        if case .fullViewport(let cached)? = panePreviewCache
            .preview(for: paneSurface.paneID)?.source,
           cached == provenance {
            return
        }
        if let warmingPreviewProvenance {
            guard warmingPreviewProvenance != provenance else { return }
            cancelPanePreviewCapture()
        }

        // Defer submission out of the display-layout callback. The native
        // preview request snapshots synchronously at acceptance, while pixel
        // rendering/cache delivery remains off the first-layout path.
        DispatchQueue.main.async { [weak self, weak paneSurface, weak managedSurface] in
            guard let self, let paneSurface, let managedSurface,
                  self.activeManagedSurface === managedSurface,
                  self.activeManagedPaneID == paneSurface.paneID,
                  self.warmingPreviewProvenance == nil
            else { return }

            let currentSize = managedSurface.controlSurface.currentSize()
            let currentProvenance = GhosttyPanePreviewSession.FullViewportProvenance(
                surfaceID: managedSurface.id,
                pixelWidth: currentSize.width_px,
                pixelHeight: currentSize.height_px
            )
            guard currentProvenance.pixelWidth > 0,
                  currentProvenance.pixelHeight > 0
            else { return }
            if case .fullViewport(let cached)? = self.panePreviewCache
                .preview(for: paneSurface.paneID)?.source,
               cached == currentProvenance {
                return
            }

            let paneUUID = self.identities.surfaceID(for: paneSurface.paneID)
            let captureSession = self.newPanePreviewSession(
                leafIDs: [paneUUID],
                previewSizing: .paneGridForCurrentScreen
            )
            self.warmingPreviewProvenance = currentProvenance
            self.warmingPreviewPaneID = paneSurface.paneID
            self.panePreviewCaptureSession = captureSession
            GhosttyRuntimeTrace.perf(
                "tmuxPane.preview.capture pane=\(paneSurface.paneID) event=post-display-warm"
            )
            captureSession.startRefreshing()
        }
    }

    private func cancelPanePreviewCapture() {
        panePreviewCaptureSession?.cancelAll()
        panePreviewCaptureSession = nil
        warmingPreviewProvenance = nil
        warmingPreviewPaneID = nil
    }

    /// Validate the request budget. Cold remote previews leave their grid
    /// unspecified so libghostty renders the actual captured pane geometry;
    /// visited panes use their cached genuine full-viewport image.
    static func panePreviewOptions(
        options: ghostty_surface_preview_image_options_s
    ) -> ghostty_surface_preview_image_options_s? {
        guard options.max_width_px > 0, options.max_height_px > 0 else { return nil }
        return options
    }

    private func reconcilePanePreviewCache(
        with topology: TmuxSessionController.TopologySnapshot
    ) {
        let removedPaneIDs = panePreviewCache.retainOnly(Set(topology.panes.map(\.id)))
        if let warmingPreviewPaneID,
           !topology.panes.contains(where: { $0.id == warmingPreviewPaneID }) {
            cancelPanePreviewCapture()
        }
        guard !removedPaneIDs.isEmpty else { return }
        GhosttyRuntimeTrace.perf(
            "tmuxPane.preview.cache result=topology-remove panes=\(removedPaneIDs) total=\(panePreviewCache.totalByteCost)"
        )
    }

    private func clearPanePreviewCache(reason: String) {
        cancelPanePreviewCapture()
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
        // Only the active retained surface is published through this adapter;
        // native-side selection is therefore redundant or impossible.
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
        session?.prepareForPaneSelection(paneID: paneID)
        controller.requestSelectPane(paneID: paneID)
        return .queued
    }

    func focusTmuxTopLevel(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let windowID = identities.windowID(for: id), let controller else {
            return .missingTarget(.window(id))
        }
        if latestTopology?.activeWindowID != windowID,
           let targetPaneID = latestTopology?.windows
               .first(where: { $0.id == windowID })?.activePaneID {
            session?.prepareForPaneSelection(paneID: targetPaneID)
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
        let targetWindow = topology.windows[targetIndex]
        if let targetPaneID = targetWindow.activePaneID {
            session?.prepareForPaneSelection(paneID: targetPaneID)
        }
        controller.requestSelectWindow(windowID: targetWindow.id)
        return .queued
    }

    func createTmuxWindow() -> GhosttyTmuxModelActionOutcome {
        guard let controller else { return .missingTarget(.host) }
        controller.requestNewWindow()
        return .queued
    }

    func splitFocusedTmuxPane(
        _ direction: ghostty_action_split_direction_e
    ) -> GhosttyTmuxModelActionOutcome {
        guard let controller, let paneSurface = session?.paneSurface else {
            return .missingTarget(.focusedPane)
        }
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
        controller.requestClosePane(paneID: paneID)
        return .queued
    }

    func closeTmuxWindow(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let windowID = identities.windowID(for: id), let controller else {
            return .missingTarget(.window(id))
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
        case .cellSize:
            // A content-scale update changes the cell size before the same
            // display update applies its final pixel size. Defer one main turn
            // and read the completed grid instead of reporting that transient.
            DispatchQueue.main.async { [weak self, weak managed] in
                guard let self,
                      let managed,
                      self.activeManagedSurface === managed
                else { return }
                self.reportClientSizeIfActive(managed)
            }
            return true
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
