import Combine
import CoreGraphics
import Foundation
import GhosttyKit

/// Byte-bounded last-full-viewport thumbnails. The cache is deliberately a
/// Remux concern: libghostty renders surfaces but does not know that this
/// client presents one tmux pane per phone viewport.
struct TmuxPanePreviewImageCache {
    struct Entry {
        let image: CGImage
        let byteCost: Int
        var lastAccess: UInt64
    }

    let byteLimit: Int
    private(set) var entries: [UInt64: Entry] = [:]
    private(set) var totalByteCost = 0
    private var accessSequence: UInt64 = 0

    init(byteLimit: Int) {
        precondition(byteLimit > 0)
        self.byteLimit = byteLimit
    }

    mutating func image(for paneID: UInt64) -> CGImage? {
        guard var entry = entries[paneID] else { return nil }
        accessSequence &+= 1
        entry.lastAccess = accessSequence
        entries[paneID] = entry
        return entry.image
    }

    @discardableResult
    mutating func store(_ image: CGImage, for paneID: UInt64) -> [UInt64] {
        let (byteCost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, byteCost > 0, byteCost <= byteLimit else { return [] }

        if let replaced = entries.removeValue(forKey: paneID) {
            totalByteCost -= replaced.byteCost
        }
        accessSequence &+= 1
        entries[paneID] = Entry(
            image: image,
            byteCost: byteCost,
            lastAccess: accessSequence
        )
        totalByteCost += byteCost

        var evictedPaneIDs: [UInt64] = []
        while totalByteCost > byteLimit,
              let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            entries.removeValue(forKey: oldest.key)
            totalByteCost -= oldest.value.byteCost
            evictedPaneIDs.append(oldest.key)
        }
        return evictedPaneIDs
    }

    @discardableResult
    mutating func retainOnly(_ paneIDs: Set<UInt64>) -> [UInt64] {
        let removedPaneIDs = entries.keys.filter { !paneIDs.contains($0) }
        for paneID in removedPaneIDs {
            if let removed = entries.removeValue(forKey: paneID) {
                totalByteCost -= removed.byteCost
            }
        }
        return removedPaneIDs
    }

    mutating func removeAll() {
        entries.removeAll()
        totalByteCost = 0
        accessSequence = 0
    }
}

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
    private static let panePreviewWarmupDelay: Duration = .milliseconds(250)

    private weak var session: TmuxTerminalSession?
    private var controller: TmuxSessionController?

    /// The last topology emitted by `session.$topology`. All adapter reads go
    /// through this value, never `session.topology`: `@Published` emits from
    /// `willSet`, so reading the property inside a sink returns the previous
    /// snapshot and the projection lags one topology update behind.
    private var latestTopology: TmuxSessionController.TopologySnapshot?

    private let leaseStore = GhosttyRuntimeCallbackLeaseStore()

    private var paneUUIDsByID: [UInt64: UUID] = [:]
    private var paneIDsByUUID: [UUID: UInt64] = [:]
    private var windowUUIDsByID: [UInt64: UUID] = [:]
    private var windowIDsByUUID: [UUID: UInt64] = [:]

    private var activeManagedSurface: GhosttyManagedSurface?
    private var pendingRemovalSurfaces: [UUID: GhosttyManagedSurface] = [:]
    private var initialViewportHandler: ((CGSize, CGFloat) -> Void)?
    private var cachedTopologySnapshot = GhosttyRuntimeSurfaceTopologySnapshot.empty
    private var panePreviewCache = TmuxPanePreviewImageCache(
        byteLimit: TmuxTerminalScreenAdapter.panePreviewCacheByteLimit
    )
    private var panePreviewWarmupTask: Task<Void, Never>?
    private var panePreviewWarmupSession: GhosttyPanePreviewSession?

    /// Presentation hold: while the active leaf has no surface that has
    /// completed a layout-sized display update, the snapshot carries the
    /// leaf as pending and the tree view keeps the outgoing pane's frame
    /// on screen (presentation overlay) instead of flashing empty.
    private var displayedPresentationSurfaceID: UUID?
    private var abandonedPendingPresentationSurfaceID: UUID?
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
        displayedPresentationSurfaceID = nil
        abandonedPendingPresentationSurfaceID = nil
    }

    // MARK: ID mapping

    private func paneUUID(_ id: UInt64) -> UUID {
        if let existing = paneUUIDsByID[id] { return existing }
        let uuid = UUID()
        paneUUIDsByID[id] = uuid
        paneIDsByUUID[uuid] = id
        return uuid
    }

    private func windowUUID(_ id: UInt64) -> UUID {
        if let existing = windowUUIDsByID[id] { return existing }
        let uuid = UUID()
        windowUUIDsByID[id] = uuid
        windowIDsByUUID[uuid] = id
        return uuid
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
                .map { paneUUID($0.id) }
            return GhosttyTopLevelSurface(
                id: windowUUID(window.id),
                tree: Self.linearTree(of: paneIDs),
                focusedLeafID: window.activePaneID.map { paneUUID($0) }
            )
        }

        let pending = pendingPresentationSurfaceID(in: topology)
        updatePendingPresentationTimeout(pending)
        cachedTopologySnapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: topLevels,
            selectedTopLevelID: topology.activeWindowID.map { windowUUID($0) },
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
        let activeLeafUUID = topology.activeWindowID
            .flatMap { activeID in topology.windows.first(where: { $0.id == activeID }) }
            .flatMap(\.activePaneID)
            .map { paneUUID($0) }
        if let abandoned = abandonedPendingPresentationSurfaceID, abandoned != activeLeafUUID {
            abandonedPendingPresentationSurfaceID = nil
        }
        guard let activeLeafUUID,
              activeLeafUUID != displayedPresentationSurfaceID,
              activeLeafUUID != abandonedPendingPresentationSurfaceID
        else { return nil }
        return activeLeafUUID
    }

    /// Marks a managed surface as displayed at its laid-out size and, if
    /// it was the pending presentation, drops the hold. Deferred one
    /// runloop hop: this fires inside the container's layout pass (no
    /// observable mutation mid view update), which also gives the
    /// just-refreshed surface a frame to present before the overlay
    /// clears.
    func notePresentationSurfaceDisplayed(_ surfaceID: UUID) {
        guard displayedPresentationSurfaceID != surfaceID else { return }
        displayedPresentationSurfaceID = surfaceID
        schedulePanePreviewWarmup(for: surfaceID)
        guard cachedTopologySnapshot.pendingPhonePresentationSurfaceID == surfaceID else { return }
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
            self.abandonedPendingPresentationSurfaceID = pending
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
        cancelPanePreviewWarmup()
        if let previous = activeManagedSurface {
            pendingRemovalSurfaces[previous.id] = previous
            activeManagedSurface = nil
        }

        guard let paneSurface, let controller else { return }

        let paneID = paneSurface.paneID
        let surfaceUUID = paneUUID(paneID)
        // A rebind of the same pane id produces a NEW surface; the UUID must
        // be fresh so the tree container swaps views instead of aliasing.
        let managedID: UUID
        if pendingRemovalSurfaces[surfaceUUID] != nil {
            paneUUIDsByID[paneID] = nil
            paneIDsByUUID[surfaceUUID] = nil
            managedID = paneUUID(paneID)
        } else {
            managedID = surfaceUUID
        }

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
        // The first real layout-driven display update opens viewport
        // reporting (the placeholder frame's bogus size never reaches
        // tmux), reports the actual grid once, and ends the presentation
        // hold for this surface.
        activeManagedSurface?.onDisplayUpdate = { [weak self, weak paneSurface] _, size, _ in
            guard size.width > 1, size.height > 1 else { return }
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
            snapshot: topologySnapshot
        )
    }

    var terminalInteractionProjection: GhosttyTerminalInteractionProjection {
        GhosttyTerminalPresentationProjector.terminalInteractionProjection(
            phase: runtimePhase,
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

    func reportRuntimeReadinessIfNeeded() {
        // Readiness is structural in the new stack: the root model receives
        // domain runtime states straight from the session model.
    }

    func setViewportStabilityHint(stable: Bool) {
        controller?.setViewportStability(stable)
    }

    func makePanePreviewSession(
        leafIDs: [UUID],
        previewSizing: GhosttyPanePreviewSession.PreviewSizing
    ) -> GhosttyPanePreviewSession {
        // If background prewarming is still running, the sheet becomes the
        // sole request owner. A completed warmup has already populated the
        // shared cache; an incomplete one is canceled before the sheet starts
        // its deferred refresh.
        cancelPanePreviewWarmup()
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
                start: { [weak self] leafID, options, userdata, callback in
                    guard let self else {
                        return .surfaceUnavailable
                    }
                    guard let paneID = self.paneIDsByUUID[leafID] else {
                        return .surfaceUnavailable
                    }
                    if let activeSurface = self.activeManagedSurface,
                       activeSurface.id == leafID {
                        GhosttyRuntimeTrace.perf(
                            "tmuxPane.preview.request pane=\(paneID) source=live"
                        )
                        guard let request = activeSurface.controlSurface.renderPreviewImageAsync(
                            options: options,
                            userdata: userdata,
                            callback: callback
                        ) else {
                            return .rejected
                        }
                        return .started(request)
                    }
                    guard let styleSurface = self.activeManagedSurface?.controlSurface.handle else {
                        return .surfaceUnavailable
                    }
                    guard let renderRequest = self.panePreviewRequest(
                        paneID: paneID,
                        options: options
                    ) else {
                        return .surfaceUnavailable
                    }
                    GhosttyRuntimeTrace.perf(
                        "tmuxPane.preview.request pane=\(paneID) source=remote-split-fallback"
                    )
                    guard let request = self.controller?.renderPanePreviewImageAsync(
                        paneID: paneID,
                        styleSurface: styleSurface,
                        options: renderRequest.options,
                        previewGrid: renderRequest.grid,
                        userdata: userdata,
                        callback: callback
                    ) else {
                        return .rejected
                    }
                    return .started(request)
                },
                cancel: { GhosttyKitControlSurface.cancelPreviewRequest($0) },
                release: { GhosttyKitControlSurface.releasePreviewRequest($0) },
                cachedImage: { [weak self] leafID in
                    guard let self,
                          let paneID = self.paneIDsByUUID[leafID]
                    else { return nil }
                    guard let image = self.panePreviewCache.image(for: paneID) else {
                        GhosttyRuntimeTrace.perf(
                            "tmuxPane.preview.cache pane=\(paneID) result=miss"
                        )
                        return nil
                    }
                    GhosttyRuntimeTrace.perf(
                        "tmuxPane.preview.cache pane=\(paneID) result=hit bytes=\(image.bytesPerRow * image.height)"
                    )
                    return image
                },
                shouldCacheRenderedImage: { [weak self] leafID in
                    self?.activeManagedSurface?.id == leafID
                },
                cacheRenderedImage: { [weak self] leafID, image in
                    guard let self,
                          self.session?.state == .ready,
                          let paneID = self.paneIDsByUUID[leafID],
                          self.latestTopology?.panes.contains(where: { $0.id == paneID }) == true
                    else { return }
                    let evictedPaneIDs = self.panePreviewCache.store(image, for: paneID)
                    guard self.panePreviewCache.entries[paneID]?.image === image else {
                        GhosttyRuntimeTrace.perf(
                            "tmuxPane.preview.cache pane=\(paneID) result=reject-oversize bytes=\(image.bytesPerRow * image.height) limit=\(self.panePreviewCache.byteLimit)"
                        )
                        return
                    }
                    GhosttyRuntimeTrace.perf(
                        "tmuxPane.preview.cache pane=\(paneID) result=store bytes=\(image.bytesPerRow * image.height) total=\(self.panePreviewCache.totalByteCost)"
                    )
                    if !evictedPaneIDs.isEmpty {
                        GhosttyRuntimeTrace.perf(
                            "tmuxPane.preview.cache result=evict panes=\(evictedPaneIDs) total=\(self.panePreviewCache.totalByteCost)"
                        )
                    }
                }
            )
        )
    }

    private func schedulePanePreviewWarmup(for surfaceID: UUID) {
        panePreviewWarmupTask?.cancel()
        let delay = Self.panePreviewWarmupDelay
        panePreviewWarmupTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  self.session?.state == .ready,
                  self.activeManagedSurface?.id == surfaceID,
                  let paneID = self.paneIDsByUUID[surfaceID]
            else { return }

            let warmupSession = self.newPanePreviewSession(
                leafIDs: [surfaceID],
                previewSizing: .paneGridForCurrentScreen
            )
            self.panePreviewWarmupSession?.cancelAll()
            self.panePreviewWarmupSession = warmupSession
            self.panePreviewWarmupTask = nil
            GhosttyRuntimeTrace.perf(
                "tmuxPane.preview.prewarm pane=\(paneID) event=start"
            )
            warmupSession.startRefreshing()
        }
    }

    private func cancelPanePreviewWarmup() {
        panePreviewWarmupTask?.cancel()
        panePreviewWarmupTask = nil
        panePreviewWarmupSession?.cancelAll()
        panePreviewWarmupSession = nil
    }

    private struct PanePreviewRequest {
        let options: ghostty_surface_preview_image_options_s
        let grid: TmuxSessionController.ClientSize
    }

    private func panePreviewRequest(
        paneID: UInt64,
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
        cancelPanePreviewWarmup()
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
        guard let paneID = paneIDsByUUID[id], let controller else {
            return .missingTarget(.pane(id))
        }
        controller.requestSelectPane(paneID: paneID)
        return .queued
    }

    func focusTmuxTopLevel(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let windowID = windowIDsByUUID[id], let controller else {
            return .missingTarget(.window(id))
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
        guard let paneID = paneIDsByUUID[id], let controller else {
            return .missingTarget(.pane(id))
        }
        controller.requestClosePane(paneID: paneID)
        return .queued
    }

    func closeTmuxWindow(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let windowID = windowIDsByUUID[id], let controller else {
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
