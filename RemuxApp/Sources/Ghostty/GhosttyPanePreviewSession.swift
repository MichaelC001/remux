import CoreGraphics
import Foundation
import GhosttyKit

/// Manages cached pane images plus the lifetime of asynchronous preview
/// requests for one picker presentation. Construction is cache-only: callers
/// explicitly invoke `startRefreshing()` after the sheet enters SwiftUI's
/// presentation lifecycle, so preview submission cannot delay the sheet's
/// initial state transaction.
///
/// Owned by the caller: normally `GhosttySurfaceScreen` for an open picker,
/// or the tmux adapter for a one-shot post-display cache warmup. Callers
/// explicitly tear it down via `cancelAll()` when that ownership ends.
/// Accepted request handles are also carried by the callback userdata so the
/// Ghostty callback can release them if the Swift session disappears before
/// completion.
///
/// Architecture invariants for preview request ownership:
///
/// - The session owns only preview request lifetime and image state. The pane
///   sheet owns its frozen top-level separately; the window sheet owns its
///   focused-leaf set separately.
/// - Every accepted C preview request handle is held in `pendingRequests`.
///   Every completion / cancel / reconcile-removal releases that handle
///   exactly once via its request lease. A pane may remain `.ready` while an
///   active-pane refresh is pending so its cached image never disappears.
/// - Pixel buffers are copied into Swift-owned memory in the C callback,
///   then `ghostty_surface_free_preview_image` is called immediately. The
///   resulting `CGImage` owns the Swift copy via a `CGDataProvider` whose
///   release callback frees the buffer. This avoids the Ghostty allocator
///   lifetime hazard at app teardown.
/// - The C callback hops to MainActor before mutating session state, and
///   verifies session liveness + generation match before building a CGImage
///   it would otherwise immediately discard.
///
/// Inline kitty/sixel graphics are not represented in v1 thumbnails; only
/// text, cursor, and colors are included.
@MainActor
final class GhosttyPanePreviewSession: ObservableObject {
    private static let transientRetryAttempts = 6
    private static let transientRetryDelay: Duration = .milliseconds(180)

    enum PreviewStartResult {
        case started(ghostty_surface_preview_request_t)
        case failed(ghostty_surface_preview_status_e)
        case surfaceUnavailable
        case rejected
    }

    struct PreviewRequestClient {
        typealias Start = @MainActor (
            UUID,
            ghostty_surface_preview_image_options_s,
            UnsafeMutableRawPointer?,
            ghostty_surface_preview_image_callback_f
        ) -> PreviewStartResult

        let start: Start
        let cancel: @MainActor (ghostty_surface_preview_request_t) -> Void
        let release: @MainActor (ghostty_surface_preview_request_t) -> Void
        let cachedImage: @MainActor (UUID) -> CGImage?
        let shouldCacheRenderedImage: @MainActor (UUID) -> Bool
        let cacheRenderedImage: @MainActor (UUID, CGImage) -> Void

        init(
            start: @escaping Start,
            cancel: @escaping @MainActor (ghostty_surface_preview_request_t) -> Void,
            release: @escaping @MainActor (ghostty_surface_preview_request_t) -> Void,
            cachedImage: @escaping @MainActor (UUID) -> CGImage? = { _ in nil },
            shouldCacheRenderedImage: @escaping @MainActor (UUID) -> Bool = { _ in false },
            cacheRenderedImage: @escaping @MainActor (UUID, CGImage) -> Void = { _, _ in }
        ) {
            self.start = start
            self.cancel = cancel
            self.release = release
            self.cachedImage = cachedImage
            self.shouldCacheRenderedImage = shouldCacheRenderedImage
            self.cacheRenderedImage = cacheRenderedImage
        }
    }

    enum PreviewSizing: Equatable {
        case paneGrid(availableWidth: CGFloat)
        case windowGrid(availableWidth: CGFloat)

        @MainActor
        static var paneGridForCurrentScreen: PreviewSizing {
            .paneGrid(availableWidth: PanePreviewLayout.currentSheetContentWidth())
        }

        @MainActor
        static var windowGridForCurrentScreen: PreviewSizing {
            .windowGrid(availableWidth: PanePreviewLayout.currentSheetContentWidth())
        }
    }

    /// Per-pane preview state observed by the panes sheet. The `failed` case
    /// preserves the raw Ghostty status so future UI can disambiguate
    /// surface-closed vs invalid-options vs render-failed.
    enum PreviewState {
        case pending
        case ready(CGImage)
        case failed(ghostty_surface_preview_status_e)
    }

    let id = UUID()

    @Published private(set) var imagesByPaneID: [UUID: PreviewState] = [:]

    private let displayScale: CGFloat
    private let previewSizing: PreviewSizing
    private let previewRequestClient: PreviewRequestClient
    private let retryDelay: Duration
    private let createdAt: UInt64
    private var pendingRequests: [UUID: GhosttyPreviewRequestLease] = [:]
    /// Whether each accepted request started from a live, full-viewport
    /// surface. Captured at submission so a pane switch before callback
    /// delivery cannot accidentally cache a split-geometry fallback.
    private var pendingCacheWrites: [UUID: Bool] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var trackedLeafIDs: [UUID] = []
    private var didStartRefreshing = false
    private var isCancelled = false
    private var generation: UInt64 = 0

    init(
        leafIDs: [UUID],
        scale: CGFloat = PanePreviewLayout.currentScale(),
        previewSizing: PreviewSizing? = nil,
        retryDelay: Duration? = nil,
        previewRequestClient: PreviewRequestClient
    ) {
        let createdAt = GhosttyRuntimeTrace.nowNanos()
        self.displayScale = scale
        self.previewSizing = previewSizing ?? .paneGridForCurrentScreen
        self.previewRequestClient = previewRequestClient
        self.retryDelay = retryDelay ?? Self.transientRetryDelay
        self.createdAt = createdAt
        trackedLeafIDs = Self.uniqueLeafIDs(leafIDs)
        seedCachedImages(for: trackedLeafIDs)
        GhosttyRuntimeTrace.perf(
            "panePreview.session construct panes=\(trackedLeafIDs.count) cached=\(readyImageCount) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: createdAt, to: GhosttyRuntimeTrace.nowNanos()))"
        )
    }

    private static func uniqueLeafIDs(_ leafIDs: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return leafIDs.filter { seen.insert($0).inserted }
    }

    private func seedCachedImages(for leafIDs: [UUID]) {
        for paneID in leafIDs where imagesByPaneID[paneID] == nil {
            guard let image = previewRequestClient.cachedImage(paneID) else { continue }
            imagesByPaneID[paneID] = .ready(image)
        }
    }

    deinit {
        // Request handles are not released from deinit. Under Swift isolation,
        // deinit is the wrong ownership boundary for MainActor state. The
        // callback userdata carries an idempotent lease and releases accepted
        // handles on completion even when the session is already gone.
    }

    // MARK: - Public API

    /// Starts any live refresh or cold fallback requests that were deferred
    /// during construction. Idempotent. Cached inactive panes issue no
    /// request; a cached active pane keeps its image visible while its live
    /// full-viewport refresh runs.
    func startRefreshing() {
        guard !didStartRefreshing, !isCancelled else { return }
        didStartRefreshing = true
        GhosttyRuntimeTrace.perf(
            "panePreview.session refresh panes=\(trackedLeafIDs.count) cached=\(readyImageCount) since_construct_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: createdAt, to: GhosttyRuntimeTrace.nowNanos()))"
        )

        let paneCount = max(1, trackedLeafIDs.count)
        for paneID in trackedLeafIDs {
            startRequestIfNeeded(for: paneID, previewItemCount: paneCount)
        }
    }

    /// Reconcile in-flight requests against an updated leaf ID set within
    /// the frozen top-level. Adds requests for new panes, cancels+releases
    /// requests for removed panes. Existing pending requests are untouched.
    func reconcile(leafIDs: [UUID]) {
        let uniqueLeafIDs = Self.uniqueLeafIDs(leafIDs)
        let newSet = Set(uniqueLeafIDs)
        let currentSet = Set(trackedLeafIDs)
        let paneCount = max(1, uniqueLeafIDs.count)

        for removedID in currentSet.subtracting(newSet) {
            dropRequest(for: removedID)
            imagesByPaneID.removeValue(forKey: removedID)
        }
        trackedLeafIDs = uniqueLeafIDs

        for addedID in newSet.subtracting(currentSet) {
            seedCachedImages(for: [addedID])
        }

        guard didStartRefreshing, !isCancelled else { return }

        for retainedID in currentSet.intersection(newSet) {
            guard shouldRetryPreview(for: retainedID) else { continue }
            startRequest(
                for: retainedID,
                previewItemCount: paneCount,
                remainingRetryAttempts: Self.transientRetryAttempts
            )
        }
        for addedID in newSet.subtracting(currentSet) {
            startRequestIfNeeded(for: addedID, previewItemCount: paneCount)
        }
    }

    /// Cancel every in-flight request and release each handle. Bumps
    /// generation so any callback already past the C side becomes stale on
    /// arrival. Safe to call multiple times. Does not clear
    /// `imagesByPaneID` so currently-displayed previews remain visible
    /// while the sheet animates out.
    func cancelAll() {
        isCancelled = true
        generation &+= 1
        for task in retryTasks.values {
            task.cancel()
        }
        retryTasks.removeAll()
        for paneID in Array(pendingRequests.keys) {
            dropRequest(for: paneID)
        }
    }

    // MARK: - Internal: request lifecycle

    private var readyImageCount: Int {
        imagesByPaneID.values.reduce(into: 0) { count, state in
            if case .ready = state {
                count += 1
            }
        }
    }

    private func startRequestIfNeeded(for paneID: UUID, previewItemCount: Int) {
        guard pendingRequests[paneID] == nil else { return }
        if case .ready? = imagesByPaneID[paneID],
           !previewRequestClient.shouldCacheRenderedImage(paneID) {
            return
        }
        startRequest(
            for: paneID,
            previewItemCount: previewItemCount,
            remainingRetryAttempts: Self.transientRetryAttempts
        )
    }

    private func startRequest(
        for paneID: UUID,
        previewItemCount: Int,
        remainingRetryAttempts: Int
    ) {
        guard pendingRequests[paneID] == nil else { return }
        cancelRetry(for: paneID)
        let preservesCachedImage: Bool
        if case .ready? = imagesByPaneID[paneID] {
            preservesCachedImage = true
        } else {
            preservesCachedImage = false
        }

        let pixelBudget = physicalPixelBudget(previewItemCount: previewItemCount)

        let options = ghostty_surface_preview_image_options_s(
            max_width_px: pixelBudget.width,
            max_height_px: pixelBudget.height,
            include_cursor: true
        )

        let requestLease = GhosttyPreviewRequestLease(
            cancel: previewRequestClient.cancel,
            release: previewRequestClient.release
        )
        let box = PreviewCallbackBox(
            session: self,
            paneID: paneID,
            generation: generation,
            previewItemCount: previewItemCount,
            remainingRetryAttempts: remainingRetryAttempts,
            requestLease: requestLease
        )
        let userdata = Unmanaged.passRetained(box).toOpaque()

        switch startPreviewRequest(
            paneID: paneID,
            options: options,
            userdata: userdata
        ) {
        case .started(let request):
            pendingRequests[paneID] = requestLease
            pendingCacheWrites[paneID] = previewRequestClient.shouldCacheRenderedImage(paneID)
            if !preservesCachedImage {
                imagesByPaneID[paneID] = .pending
            }
            requestLease.install(request)

        case .failed(let status):
            Unmanaged<PreviewCallbackBox>.fromOpaque(userdata).release()
            guard !preservesCachedImage else { return }
            imagesByPaneID[paneID] = .failed(status)

        case .surfaceUnavailable:
            Unmanaged<PreviewCallbackBox>.fromOpaque(userdata).release()
            guard !preservesCachedImage else { return }
            imagesByPaneID[paneID] = .failed(GHOSTTY_SURFACE_PREVIEW_STATUS_SURFACE_CLOSED)
            scheduleRetry(
                for: paneID,
                previewItemCount: previewItemCount,
                remainingRetryAttempts: remainingRetryAttempts
            )

        case .rejected:
            // Synchronous rejection (e.g., immediate alloc failure). Reclaim
            // the box we just retained and mark the pane failed.
            Unmanaged<PreviewCallbackBox>.fromOpaque(userdata).release()
            guard !preservesCachedImage else { return }
            imagesByPaneID[paneID] = .failed(GHOSTTY_SURFACE_PREVIEW_STATUS_RENDER_FAILED)
            scheduleRetry(
                for: paneID,
                previewItemCount: previewItemCount,
                remainingRetryAttempts: remainingRetryAttempts
            )
        }
    }

    private func physicalPixelBudget(
        previewItemCount: Int
    ) -> (width: UInt32, height: UInt32) {
        switch previewSizing {
        case .paneGrid(let availableWidth):
            return PanePreviewLayout.physicalPixelBudget(
                paneCount: previewItemCount,
                availableWidth: availableWidth,
                scale: displayScale
            )

        case .windowGrid(let availableWidth):
            return PanePreviewLayout.windowPhysicalPixelBudget(
                availableWidth: availableWidth,
                scale: displayScale
            )
        }
    }

    /// Cancel-and-release the C request handle for a pane. Ownership rule:
    /// every caller that stops tracking an accepted request MUST go through
    /// this method to release the handle exactly once.
    private func dropRequest(for paneID: UUID) {
        cancelRetry(for: paneID)
        pendingCacheWrites.removeValue(forKey: paneID)
        guard let requestLease = pendingRequests.removeValue(forKey: paneID) else {
            return
        }
        requestLease.cancelAndRelease()
    }

    /// Called from the C callback after main-actor hop. The callback has
    /// already done generation/liveness checks and built (or chose not to
    /// build) a CGImage. We finalize state and release the handle.
    fileprivate func deliver(
        paneID: UUID,
        generation: UInt64,
        status: ghostty_surface_preview_status_e,
        image: CGImage?,
        previewItemCount: Int,
        remainingRetryAttempts: Int,
        requestLease: GhosttyPreviewRequestLease
    ) {
        guard generation == self.generation else { return }
        guard pendingRequests[paneID] === requestLease else { return }
        pendingRequests.removeValue(forKey: paneID)
        let shouldCache = pendingCacheWrites.removeValue(forKey: paneID) ?? false

        if status == GHOSTTY_SURFACE_PREVIEW_STATUS_OK, let image = image {
            if shouldCache {
                previewRequestClient.cacheRenderedImage(paneID, image)
            }
            imagesByPaneID[paneID] = .ready(image)
        } else {
            let failureStatus = normalizedFailureStatus(status: status, image: image)
            if case .ready? = imagesByPaneID[paneID] {
                // A failed refresh must not replace a usable cached image
                // with an empty/error placeholder.
                return
            }
            imagesByPaneID[paneID] = .failed(failureStatus)
            guard isTransientPreviewFailure(failureStatus) else { return }
            scheduleRetry(
                for: paneID,
                previewItemCount: previewItemCount,
                remainingRetryAttempts: remainingRetryAttempts
            )
        }
    }

    fileprivate var currentGeneration: UInt64 { generation }

    private func shouldRetryPreview(for paneID: UUID) -> Bool {
        guard pendingRequests[paneID] == nil else { return false }

        switch imagesByPaneID[paneID] {
        case .failed(let status):
            return isTransientPreviewFailure(status)

        default:
            return false
        }
    }

    private func scheduleRetry(
        for paneID: UUID,
        previewItemCount: Int,
        remainingRetryAttempts: Int
    ) {
        guard remainingRetryAttempts > 0 else { return }
        guard imagesByPaneID[paneID] != nil else { return }

        cancelRetry(for: paneID)
        let retryDelay = retryDelay
        retryTasks[paneID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                return
            }
            guard let self else { return }

            retryTasks[paneID] = nil
            guard imagesByPaneID[paneID] != nil else { return }
            guard pendingRequests[paneID] == nil else { return }

            startRequest(
                for: paneID,
                previewItemCount: max(previewItemCount, imagesByPaneID.count),
                remainingRetryAttempts: remainingRetryAttempts - 1
            )
        }
    }

    private func cancelRetry(for paneID: UUID) {
        retryTasks.removeValue(forKey: paneID)?.cancel()
    }

    private func startPreviewRequest(
        paneID: UUID,
        options: ghostty_surface_preview_image_options_s,
        userdata: UnsafeMutableRawPointer?
    ) -> PreviewStartResult {
        previewRequestClient.start(paneID, options, userdata, previewImageCallback)
    }
}

@MainActor
private func isTransientPreviewFailure(_ status: ghostty_surface_preview_status_e) -> Bool {
    status == GHOSTTY_SURFACE_PREVIEW_STATUS_SURFACE_CLOSED ||
        status == GHOSTTY_SURFACE_PREVIEW_STATUS_RENDER_FAILED
}

@MainActor
private func normalizedFailureStatus(
    status: ghostty_surface_preview_status_e,
    image: CGImage?
) -> ghostty_surface_preview_status_e {
    if status == GHOSTTY_SURFACE_PREVIEW_STATUS_OK, image == nil {
        return GHOSTTY_SURFACE_PREVIEW_STATUS_RENDER_FAILED
    }
    return status
}

// MARK: - Callback box (heap-allocated, FFI-bridged)

/// Userdata payload retained across the FFI boundary. Heap-allocated on
/// `Unmanaged.passRetained` at submit time and consumed by
/// `Unmanaged.takeRetainedValue` at the start of the callback. Holds a weak
/// session reference so a callback that arrives after the session is gone
/// no-ops cleanly without touching freed state.
///
/// Sendability: `@unchecked Sendable` because `paneID`/`generation` are
/// immutable Sendable values and the weak `session` reference is only
/// dereferenced on the MainActor (after the hop in `previewImageCallback`).
/// We never touch `session.someProperty` from the Ghostty preview thread.
private final class PreviewCallbackBox: @unchecked Sendable {
    weak var session: GhosttyPanePreviewSession?
    let paneID: UUID
    let generation: UInt64
    let previewItemCount: Int
    let remainingRetryAttempts: Int
    let requestLease: GhosttyPreviewRequestLease

    init(
        session: GhosttyPanePreviewSession,
        paneID: UUID,
        generation: UInt64,
        previewItemCount: Int,
        remainingRetryAttempts: Int,
        requestLease: GhosttyPreviewRequestLease
    ) {
        self.session = session
        self.paneID = paneID
        self.generation = generation
        self.previewItemCount = previewItemCount
        self.remainingRetryAttempts = remainingRetryAttempts
        self.requestLease = requestLease
    }
}

// MARK: - C callback (runs on Ghostty's preview thread)

/// File-scope `let` so the function pointer address is stable for the C ABI.
/// Closures with captures cannot be passed as `@convention(c)` callbacks.
///
/// Responsibilities, in order:
/// 1. Take ownership of the userdata box (balances `passRetained` on submit).
/// 2. Capture image metadata (width/height/stride/status) into local
///    constants, copy pixels into a Swift-owned buffer, then call
///    `ghostty_surface_free_preview_image` immediately.
/// 3. Hop to MainActor; verify session liveness + generation match.
/// 4. Build a `CGImage` from the Swift-owned copy if status is OK; otherwise
///    deallocate the copy.
/// 5. Hand off to the session's `deliver` for state transition.
private let previewImageCallback: ghostty_surface_preview_image_callback_f = { userdata, status, image in
    guard let userdata else { return }
    let box = Unmanaged<PreviewCallbackBox>.fromOpaque(userdata).takeRetainedValue()

    // Capture metadata before freeing the Ghostty buffer.
    let width = image.width
    let height = image.height
    let stride = image.stride
    let pixelResult = GhosttyPreviewImageDecoder.copyPixels(status: status, image: image)
    let pixelStatus = pixelResult.status
    let pixelCopy = pixelResult.pixelCopy

    // Always free the Ghostty-owned image regardless of status. Safe on a
    // zeroed image.
    var mutableImage = image
    GhosttyKitControlSurface.freePreviewImage(&mutableImage)

    // Capture immutable values for the MainActor hop. `box` is Sendable
    // (declared @unchecked above); paneID/generation are primitive
    // Sendable values; pixel buffers go through a Sendable wrapper.
    let capturedBox = box
    let capturedPixelBuffer = pixelCopy
    let capturedPaneID = box.paneID
    let capturedGeneration = box.generation
    let capturedPreviewItemCount = box.previewItemCount
    let capturedRetryAttempts = box.remainingRetryAttempts
    let capturedRequestLease = box.requestLease

    Task { @MainActor in
        // Local mutable copy so makeCGImage can null it out on ownership
        // transfer to a CGDataProvider.
        var localPixelCopy = capturedPixelBuffer.pointer
        capturedRequestLease.release()

        // Stale check: session gone, or generation mismatch, or pane already
        // removed via reconcile.
        guard let session = capturedBox.session else {
            localPixelCopy?.deallocate()
            return
        }
        guard session.currentGeneration == capturedGeneration else {
            localPixelCopy?.deallocate()
            return
        }
        guard session.imagesByPaneID[capturedPaneID] != nil else {
            localPixelCopy?.deallocate()
            return
        }

        let cgImage = GhosttyPreviewImageDecoder.makeCGImage(
            pixelCopy: &localPixelCopy,
            width: width,
            height: height,
            stride: stride
        )

        // makeCGImage sets localPixelCopy to nil iff ownership transferred
        // into a CGDataProvider. Otherwise we still own it.
        localPixelCopy?.deallocate()

        session.deliver(
            paneID: capturedPaneID,
            generation: capturedGeneration,
            status: pixelStatus,
            image: cgImage,
            previewItemCount: capturedPreviewItemCount,
            remainingRetryAttempts: capturedRetryAttempts,
            requestLease: capturedRequestLease
        )
    }
}
