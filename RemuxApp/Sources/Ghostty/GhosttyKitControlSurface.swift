import CoreGraphics
import Foundation
import GhosttyKit

struct GhosttySurfaceDisplayMetrics: Equatable {
    let contentScale: Double
    let pixelWidth: UInt32
    let pixelHeight: UInt32

    init(
        contentScale: Double,
        pixelWidth: UInt32,
        pixelHeight: UInt32
    ) {
        self.contentScale = contentScale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    init(size: CGSize, scale: CGFloat) {
        let rawScale = Double(scale)
        let safeScale = rawScale.isFinite && rawScale > 0 ? rawScale : 1

        self.contentScale = safeScale
        self.pixelWidth = Self.pixelDimension(points: size.width, scale: safeScale)
        self.pixelHeight = Self.pixelDimension(points: size.height, scale: safeScale)
    }

    private static func pixelDimension(points: CGFloat, scale: Double) -> UInt32 {
        let value = Double(points)
        guard value.isFinite, value > 0 else { return 1 }
        let pixels = (value * scale).rounded(.toNearestOrAwayFromZero)
        guard pixels.isFinite, pixels > 0 else { return 1 }

        return max(
            UInt32(min(pixels, Double(UInt32.max))),
            1
        )
    }
}

struct GhosttySurfaceDisplayUpdateTracker {
    private var lastMetrics: GhosttySurfaceDisplayMetrics?

    mutating func nextMetrics(size: CGSize, scale: CGFloat) -> GhosttySurfaceDisplayMetrics? {
        let metrics = GhosttySurfaceDisplayMetrics(size: size, scale: scale)
        guard metrics != lastMetrics else { return nil }

        lastMetrics = metrics
        return metrics
    }

    mutating func reset() {
        lastMetrics = nil
    }
}

struct GhosttySurfaceScrollState: Equatable {
    static let empty = GhosttySurfaceScrollState(
        total: 0,
        offset: 0,
        len: 0,
        cellOffset: 0
    )

    let total: UInt64
    let offset: UInt64
    let len: UInt64
    let cellOffset: Double

    init(
        total: UInt64,
        offset: UInt64,
        len: UInt64,
        cellOffset: Double
    ) {
        self.total = total
        self.offset = offset
        self.len = len
        self.cellOffset = cellOffset
    }

    init(cValue: ghostty_surface_scrollbar_s) {
        self.init(
            total: cValue.total,
            offset: cValue.offset,
            len: cValue.len,
            cellOffset: cValue.cell_offset
        )
    }

    var maxRow: UInt64 {
        total > len ? total - len : 0
    }
}

enum GhosttySurfaceScrollRoute: Equatable {
    case viewport
    case altScreenCursor
    case mouseReport

    init(cValue: ghostty_surface_scroll_route_e) {
        switch cValue {
        case GHOSTTY_SURFACE_SCROLL_ROUTE_VIEWPORT:
            self = .viewport
        case GHOSTTY_SURFACE_SCROLL_ROUTE_ALT_SCREEN_CURSOR:
            self = .altScreenCursor
        case GHOSTTY_SURFACE_SCROLL_ROUTE_MOUSE_REPORT:
            self = .mouseReport
        default:
            self = .viewport
        }
    }
}

extension TmuxControlViewport {
    init?(ghosttySurfaceSize size: ghostty_surface_size_s) {
        guard size.columns > 0, size.rows > 0 else { return nil }

        self.init(
            columns: size.columns,
            rows: size.rows,
            pixelWidth: size.width_px,
            pixelHeight: size.height_px
        )
    }
}

enum GhosttyKitControlSurfaceOwnership {
    case borrowed
    case storageOwned
    case runtimeAppOwned
}

final class GhosttyKitControlSurface: GhosttyControlSurface {
    private let storage: GhosttyKitControlSurfaceStorage

    /// The raw handle for identity comparisons only. May be stale
    /// after invalidation — never dereference without `liveSurface`.
    var handle: ghostty_surface_t {
        storage.surface
    }

    /// The pane surface's owner (TmuxTerminalSession) frees borrowed
    /// surfaces on pane changes while the viewport may still hold
    /// the wrapper; invalidation makes every late call a no-op
    /// instead of a use-after-free.
    func invalidate() {
        storage.invalidate()
    }

    var isInvalidated: Bool {
        storage.isInvalidated
    }

    private var liveSurface: ghostty_surface_t? {
        storage.isInvalidated ? nil : storage.surface
    }

    init(
        surface: ghostty_surface_t,
        ownership: GhosttyKitControlSurfaceOwnership = .borrowed,
        retainedObjects: [AnyObject] = []
    ) {
        self.storage = GhosttyKitControlSurfaceStorage(
            surface: surface,
            ownership: ownership,
            retainedObjects: retainedObjects
        )
    }

    @discardableResult
    @MainActor
    func processOutput(_ data: Data) -> Bool {
        guard let surface = liveSurface else { return false }
        guard !data.isEmpty else { return true }

        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            let pointer = baseAddress.assumingMemoryBound(to: CChar.self)
            return ghostty_surface_process_output(surface, pointer, rawBuffer.count)
        }
    }

    @MainActor
    func setBackingExited(_ exited: Bool) {
        guard let surface = liveSurface else { return }
        ghostty_surface_set_backing_exited(surface, exited)
    }

    @MainActor
    func releaseRuntimeManagedSurface() {
        storage.releaseRuntimeManagedSurface()
    }

    @MainActor
    func transferRuntimeManagedSurfaceToAppShutdown() {
        storage.transferRuntimeManagedSurfaceToAppShutdown()
    }

    @MainActor
    @discardableResult
    func sendInput(_ text: String) -> Bool {
        guard let surface = liveSurface else { return false }
        guard !text.isEmpty else { return true }

        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.diagnostics(
            "control.sendInput handle=\(String(describing: surface)) bytes=\(text.lengthOfBytes(using: .utf8)) size=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
        GhosttyRuntimeTrace.latency(
            "control.sendInput begin handle=\(String(describing: surface)) bytes=\(text.lengthOfBytes(using: .utf8)) size=\(ghosttyDiagnosticSurfaceSize(currentSize())) preview=\(text.debugDescription)"
        )
        let accepted = text.withCString { pointer in
            let byteCount = text.lengthOfBytes(using: .utf8)
            return ghostty_surface_input(surface, pointer, UInt(byteCount))
        }
        GhosttyRuntimeTrace.latency(
            "control.sendInput end accepted=\(accepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        return accepted
    }

    @MainActor
    func sendText(_ text: String) {
        guard let surface = liveSurface else { return }
        guard !text.isEmpty else { return }

        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "control.sendText begin handle=\(String(describing: surface)) bytes=\(text.lengthOfBytes(using: .utf8)) preview=\(text.debugDescription)"
        )
        text.withCString { pointer in
            let byteCount = text.lengthOfBytes(using: .utf8)
            ghostty_surface_text(surface, pointer, UInt(byteCount))
        }
        GhosttyRuntimeTrace.latency(
            "control.sendText end elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    @MainActor
    @discardableResult
    func sendPaste(_ text: String) -> Bool {
        guard let surface = liveSurface else { return false }
        sendText(text)
        return true
    }


    @MainActor
    @discardableResult
    func sendKeyEvent(_ event: GhosttySurfaceKeyEvent) -> Bool {
        guard let surface = liveSurface else { return false }
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "control.sendKey begin handle=\(String(describing: surface)) event=\(event)"
        )
        let accepted = event.withCValue { ghostty_surface_key(surface, $0) }
        GhosttyRuntimeTrace.latency(
            "control.sendKey end accepted=\(accepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        return accepted
    }

    @MainActor
    func isMouseCaptured() -> Bool {
        guard let surface = liveSurface else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    @MainActor
    @discardableResult
    func sendMouseButton(_ event: GhosttySurfaceMouseButtonEvent) -> Bool {
        guard let surface = liveSurface else { return false }
        return event.withCValues {
            ghostty_surface_mouse_button(surface, $0, $1, $2)
        }
    }

    @MainActor
    func sendMousePosition(_ position: CGPoint, mods: GhosttySurfaceKeyEvent.Mods = []) {
        guard let surface = liveSurface else { return }
        ghostty_surface_mouse_pos(
            surface,
            position.x,
            position.y,
            ghostty_input_mods_e(mods.rawValue)
        )
    }

    @MainActor
    func sendMouseScroll(_ event: GhosttySurfaceMouseScrollEvent) {
        guard let surface = liveSurface else { return }
        ghostty_surface_mouse_scroll(
            surface,
            event.deltaX,
            event.deltaY,
            ghostty_input_scroll_mods_t(event.mods.rawValue)
        )
    }

    @MainActor
    func scrollState() -> GhosttySurfaceScrollState {
        guard let surface = liveSurface else { return .empty }
        return GhosttySurfaceScrollState(cValue: ghostty_surface_scrollbar(surface))
    }

    @MainActor
    func scrollRoute() -> GhosttySurfaceScrollRoute {
        guard let surface = liveSurface else { return .viewport }
        return GhosttySurfaceScrollRoute(cValue: ghostty_surface_scroll_route(surface))
    }

    @MainActor
    func scrollToPosition(row: UInt64, cellOffset: Double) {
        guard let surface = liveSurface else { return }
        ghostty_surface_scroll_to_position(surface, row, cellOffset)
    }

    @MainActor
    func scrollToRow(_ row: UInt64) {
        guard let surface = liveSurface else { return }
        ghostty_surface_scroll_to_row(surface, row)
    }

    @MainActor
    func scrollByLines(_ delta: Int64) {
        guard let surface = liveSurface else { return }
        ghostty_surface_scroll_by_lines(surface, delta)
    }

    @MainActor
    func scrollToTop() {
        guard let surface = liveSurface else { return }
        ghostty_surface_scroll_to_top(surface)
    }

    @MainActor
    func scrollToBottom() {
        guard let surface = liveSurface else { return }
        ghostty_surface_scroll_to_bottom(surface)
    }

    @MainActor
    func sendMousePressure(_ event: GhosttySurfaceMousePressureEvent) {
        guard let surface = liveSurface else { return }
        event.withCValues {
            ghostty_surface_mouse_pressure(surface, $0, $1)
        }
    }

    @MainActor
    func hasSelection() -> Bool {
        guard let surface = liveSurface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    @MainActor
    func readSelection() -> String? {
        guard let surface = liveSurface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }
        return Self.decodeGhosttyText(text)
    }

    @MainActor
    func updateDisplay(size: CGSize, scale: CGFloat) {
        let metrics = GhosttySurfaceDisplayMetrics(size: size, scale: scale)
        updateDisplay(metrics: metrics)
    }

    @MainActor
    func updateDisplay(metrics: GhosttySurfaceDisplayMetrics) {
        guard let surface = liveSurface else { return }
        let before = currentSize()
        GhosttyRuntimeTrace.tmuxViewport(
            "control.updateDisplay begin handle=\(String(describing: surface)) before=\(ghosttyDiagnosticSurfaceSize(before)) metrics=\(metrics.pixelWidth)x\(metrics.pixelHeight) scale=\(metrics.contentScale)"
        )
        GhosttyRuntimeTrace.diagnostics(
            "control.updateDisplay handle=\(String(describing: surface)) before=\(ghosttyDiagnosticSurfaceSize(before)) metrics=\(metrics.pixelWidth)x\(metrics.pixelHeight) scale=\(metrics.contentScale)"
        )
        ghostty_surface_set_content_scale(surface, metrics.contentScale, metrics.contentScale)
        ghostty_surface_set_size(surface, metrics.pixelWidth, metrics.pixelHeight)
        GhosttyRuntimeTrace.tmuxViewport(
            "control.updateDisplay end handle=\(String(describing: surface)) after=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
        GhosttyRuntimeTrace.diagnostics(
            "control.updateDisplay applied handle=\(String(describing: surface)) after=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
    }

    // Submits an async raster preview request. The Ghostty preview thread
    // invokes `callback` exactly once on its own queue. `userdata` is passed
    // through verbatim and must outlive the request from the caller's side
    // until the callback fires. Returns the opaque request handle, or nil if
    // Ghostty rejected the request synchronously (null surface, immediate
    // allocation failure, etc).
    @MainActor
    func renderPreviewImageAsync(
        options: ghostty_surface_preview_image_options_s,
        userdata: UnsafeMutableRawPointer?,
        callback: ghostty_surface_preview_image_callback_f
    ) -> ghostty_surface_preview_request_t? {
        guard let surface = liveSurface else { return nil }
        return ghostty_surface_render_preview_image_async(
            surface,
            options,
            userdata,
            callback
        )
    }

    // Cancels an in-flight preview request. Safe before or after completion;
    // a no-op after the callback has fired. Does not release the caller's
    // handle and does not suppress the callback (which still fires once with
    // GHOSTTY_SURFACE_PREVIEW_STATUS_CANCELLED).
    static func cancelPreviewRequest(_ request: ghostty_surface_preview_request_t) {
        ghostty_surface_cancel_preview_image(request)
    }

    // Releases the caller's reference to a preview request. Must be called
    // exactly once per request. Releasing before completion does not suppress
    // the callback. After this returns the handle is invalid.
    static func releasePreviewRequest(_ request: ghostty_surface_preview_request_t) {
        ghostty_surface_release_preview_request(request)
    }

    // Frees pixels owned by a successful preview image and zeroes the struct.
    // Safe to call on a zeroed image. Does not require a surface or request
    // handle.
    static func freePreviewImage(_ image: inout ghostty_surface_preview_image_s) {
        ghostty_surface_free_preview_image(&image)
    }

    @MainActor
    func setFocused(_ focused: Bool) {
        guard let surface = liveSurface else { return }
        GhosttyRuntimeTrace.diagnostics(
            "control.setFocused handle=\(String(describing: surface)) focused=\(focused) size=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
        ghostty_surface_set_focus(surface, focused)
    }

    @MainActor
    func setVisible(_ visible: Bool) {
        guard let surface = liveSurface else { return }
        GhosttyRuntimeTrace.diagnostics(
            "control.setVisible handle=\(String(describing: surface)) visible=\(visible) size=\(ghosttyDiagnosticSurfaceSize(currentSize()))"
        )
        ghostty_surface_set_occlusion(surface, visible)
    }

    @MainActor
    func currentSize() -> ghostty_surface_size_s {
        guard let surface = liveSurface else { return ghostty_surface_size_s() }
        return ghostty_surface_size(surface)
    }

    static func decodeGhosttyText(_ text: ghostty_text_s) -> String {
        guard
            let pointer = text.text,
            text.text_len > 0
        else {
            return ""
        }

        let buffer = UnsafeRawBufferPointer(
            start: UnsafeRawPointer(pointer),
            count: Int(text.text_len)
        )
        return String(decoding: buffer, as: UTF8.self)
    }
}

private final class GhosttyKitControlSurfaceStorage: @unchecked Sendable {
    let surface: ghostty_surface_t

    private let invalidationLock = NSLock()
    private var _isInvalidated = false

    var isInvalidated: Bool {
        invalidationLock.withLock { _isInvalidated }
    }

    /// Borrowed handles dangle once their owner frees the surface;
    /// after this, every wrapper call is a benign no-op.
    func invalidate() {
        invalidationLock.withLock { _isInvalidated = true }
    }

    private let ownership: GhosttyKitControlSurfaceOwnership
    private let retainedObjects: [AnyObject]
    private var runtimeManagedSurfaceReleaseHandled = false

    init(
        surface: ghostty_surface_t,
        ownership: GhosttyKitControlSurfaceOwnership,
        retainedObjects: [AnyObject]
    ) {
        self.surface = surface
        self.ownership = ownership
        self.retainedObjects = retainedObjects
    }

    deinit {
        if ownership == .storageOwned {
            ghostty_surface_free(surface)
        }
#if DEBUG
        if ownership == .runtimeAppOwned && !runtimeManagedSurfaceReleaseHandled {
            assertionFailure("runtime-managed surfaces must be released before dropping storage")
        }
#endif
        _ = retainedObjects
    }

    @MainActor
    func releaseRuntimeManagedSurface() {
        guard ownership == .runtimeAppOwned else {
            if ownership == .storageOwned {
                assertionFailure("storage-owned surfaces are freed by GhosttyKitControlSurfaceStorage.deinit")
            }
            return
        }
        guard !runtimeManagedSurfaceReleaseHandled else { return }

        runtimeManagedSurfaceReleaseHandled = true
        ghostty_surface_set_backing_exited(surface, true)
        ghostty_surface_free(surface)
    }

    @MainActor
    func transferRuntimeManagedSurfaceToAppShutdown() {
        guard ownership == .runtimeAppOwned else {
            if ownership == .storageOwned {
                assertionFailure("storage-owned surfaces are freed by GhosttyKitControlSurfaceStorage.deinit")
            }
            return
        }
        guard !runtimeManagedSurfaceReleaseHandled else { return }

        runtimeManagedSurfaceReleaseHandled = true
    }
}
