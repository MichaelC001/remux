import Foundation
import GhosttyKit
import UIKit

enum GhosttyRuntimeSelectionDirection {
    case previous
    case next

    func advancedIndex(from index: Int, count: Int) -> Int {
        precondition(count > 0)

        return switch self {
        case .previous:
            (index - 1 + count) % count
        case .next:
            (index + 1) % count
        }
    }
}

func ghosttyDiagnosticShortID(_ id: UUID?) -> String {
    guard let id else { return "nil" }
    return String(id.uuidString.prefix(8))
}

func ghosttyDiagnosticPointer(_ pointer: UnsafeMutableRawPointer?) -> String {
    guard let pointer else { return "nil" }
    return String(format: "0x%llx", UInt64(UInt(bitPattern: pointer)))
}

func ghosttyDiagnosticRect(_ rect: CGRect) -> String {
    String(
        format: "%.1fx%.1f@%.1f,%.1f",
        rect.width,
        rect.height,
        rect.minX,
        rect.minY
    )
}

func ghosttyDiagnosticSurfaceSize(_ size: ghostty_surface_size_s) -> String {
    "\(size.columns)x\(size.rows) cells \(size.width_px)x\(size.height_px)px cell=\(size.cell_width_px)x\(size.cell_height_px)"
}


final class GhosttyManagedSurface {
    let id: UUID
    let view: GhosttyKitSurfaceView
    let controlSurface: GhosttyKitControlSurface
    let manualUserdata: UnsafeMutableRawPointer?
    private(set) var isFocused = false
    private(set) var isVisible = false
    private(set) var scrollState: GhosttySurfaceScrollState
    private(set) var scrollRoute: GhosttySurfaceScrollRoute
    var onScrollStateChange: (@MainActor () -> Void)?
    var onDisplayUpdate: (@MainActor (GhosttyManagedSurface, CGSize, CGFloat) -> Void)?

    private let sendInputHandler: (@MainActor (String) -> Bool)?
    private let sendPasteHandler: (@MainActor (String) -> Bool)?
    private let hasSelectionHandler: (@MainActor () -> Bool)?
    private let readSelectionHandler: (@MainActor () -> String?)?
    private let sendKeyEventHandler: (@MainActor (GhosttySurfaceKeyEvent) -> Bool)?
    private let sendMouseButtonHandler: (@MainActor (GhosttySurfaceMouseButtonEvent) -> Bool)?
    private let sendMousePositionHandler: (@MainActor (CGPoint, GhosttySurfaceKeyEvent.Mods) -> Void)?
    private let sendMouseScrollHandler: (@MainActor (GhosttySurfaceMouseScrollEvent) -> Void)?
    private let sendMousePressureHandler: (@MainActor (GhosttySurfaceMousePressureEvent) -> Void)?
    private let isMouseCapturedHandler: (@MainActor () -> Bool)?
    private let setFocusedHandler: (@MainActor (Bool) -> Void)?
    private let visibilityChangedHandler: (@MainActor (Bool) -> Void)?
    private let updateDisplayHandler: (@MainActor (GhosttySurfaceDisplayMetrics) -> Void)?
    private let scrollToPositionHandler: (@MainActor (UInt64, Double) -> GhosttySurfaceScrollState)?
    private let tmuxFocusHandler: (@MainActor () -> TmuxActionSubmissionResult)?
    private let tmuxSplitHandler: (@MainActor (ghostty_action_split_direction_e) -> TmuxActionSubmissionResult)?
    private let tmuxClosePaneHandler: (@MainActor () -> TmuxActionSubmissionResult)?
    private let tmuxCloseWindowHandler: (@MainActor () -> TmuxActionSubmissionResult)?
    private let tmuxCopyModeHandler: (@MainActor () -> TmuxActionSubmissionResult)?
    private let releaseBeforePermanentRemovalHandler: (@MainActor () -> Void)?
    private let transferRuntimeSurfaceLifetimeToAppShutdownHandler: (@MainActor () -> Void)?
    private var displayUpdateTracker = GhosttySurfaceDisplayUpdateTracker()

    init(
        id: UUID,
        view: GhosttyKitSurfaceView,
        controlSurface: GhosttyKitControlSurface,
        manualUserdata: UnsafeMutableRawPointer? = nil,
        scrollState: GhosttySurfaceScrollState = .empty,
        scrollRoute: GhosttySurfaceScrollRoute = .viewport,
        sendInput: (@MainActor (String) -> Bool)? = nil,
        sendPaste: (@MainActor (String) -> Bool)? = nil,
        hasSelection: (@MainActor () -> Bool)? = nil,
        readSelection: (@MainActor () -> String?)? = nil,
        sendKeyEvent: (@MainActor (GhosttySurfaceKeyEvent) -> Bool)? = nil,
        sendMouseButton: (@MainActor (GhosttySurfaceMouseButtonEvent) -> Bool)? = nil,
        sendMousePosition: (@MainActor (CGPoint, GhosttySurfaceKeyEvent.Mods) -> Void)? = nil,
        sendMouseScroll: (@MainActor (GhosttySurfaceMouseScrollEvent) -> Void)? = nil,
        sendMousePressure: (@MainActor (GhosttySurfaceMousePressureEvent) -> Void)? = nil,
        isMouseCaptured: (@MainActor () -> Bool)? = nil,
        setFocused: (@MainActor (Bool) -> Void)? = nil,
        visibilityChanged: (@MainActor (Bool) -> Void)? = nil,
        updateDisplay: (@MainActor (GhosttySurfaceDisplayMetrics) -> Void)? = nil,
        scrollToPosition: (@MainActor (UInt64, Double) -> GhosttySurfaceScrollState)? = nil,
        tmuxFocus: (@MainActor () -> TmuxActionSubmissionResult)? = nil,
        tmuxSplit: (@MainActor (ghostty_action_split_direction_e) -> TmuxActionSubmissionResult)? = nil,
        tmuxClosePane: (@MainActor () -> TmuxActionSubmissionResult)? = nil,
        tmuxCloseWindow: (@MainActor () -> TmuxActionSubmissionResult)? = nil,
        tmuxCopyMode: (@MainActor () -> TmuxActionSubmissionResult)? = nil,
        releaseBeforePermanentRemoval: (@MainActor () -> Void)? = nil,
        transferRuntimeSurfaceLifetimeToAppShutdown: (@MainActor () -> Void)? = nil
    ) {
        self.id = id
        self.view = view
        self.controlSurface = controlSurface
        self.manualUserdata = manualUserdata
        self.scrollState = scrollState
        self.scrollRoute = scrollRoute
        self.sendInputHandler = sendInput
        self.sendPasteHandler = sendPaste
        self.hasSelectionHandler = hasSelection
        self.readSelectionHandler = readSelection
        self.sendKeyEventHandler = sendKeyEvent
        self.sendMouseButtonHandler = sendMouseButton
        self.sendMousePositionHandler = sendMousePosition
        self.sendMouseScrollHandler = sendMouseScroll
        self.sendMousePressureHandler = sendMousePressure
        self.isMouseCapturedHandler = isMouseCaptured
        self.setFocusedHandler = setFocused
        self.visibilityChangedHandler = visibilityChanged
        self.updateDisplayHandler = updateDisplay
        self.scrollToPositionHandler = scrollToPosition
        self.tmuxFocusHandler = tmuxFocus
        self.tmuxSplitHandler = tmuxSplit
        self.tmuxClosePaneHandler = tmuxClosePane
        self.tmuxCloseWindowHandler = tmuxCloseWindow
        self.tmuxCopyModeHandler = tmuxCopyMode
        self.releaseBeforePermanentRemovalHandler = releaseBeforePermanentRemoval
        self.transferRuntimeSurfaceLifetimeToAppShutdownHandler = transferRuntimeSurfaceLifetimeToAppShutdown
    }

    @MainActor
    func applyTerminalTheme(_ theme: TerminalTheme) {
        view.applyTerminalTheme(theme)
    }

    @MainActor
    @discardableResult
    func sendInput(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        if let sendInputHandler {
            return sendInputHandler(text) ? .accepted : .surfaceRejected
        }

        return controlSurface.sendInput(text) ? .accepted : .surfaceRejected
    }

    @MainActor
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        visibilityChangedHandler?(visible)
        controlSurface.setVisible(visible)
    }

    @MainActor
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        if let setFocusedHandler {
            setFocusedHandler(focused)
        } else {
            controlSurface.setFocused(focused)
        }
    }

    @MainActor
    func releaseBeforePermanentRemoval() {
        if let releaseBeforePermanentRemovalHandler {
            releaseBeforePermanentRemovalHandler()
            return
        }
        controlSurface.releaseRuntimeManagedSurface()
    }

    @MainActor
    func transferRuntimeSurfaceLifetimeToAppShutdown() {
        if let transferRuntimeSurfaceLifetimeToAppShutdownHandler {
            transferRuntimeSurfaceLifetimeToAppShutdownHandler()
            return
        }
        controlSurface.transferRuntimeManagedSurfaceToAppShutdown()
    }

    @MainActor
    func prepareForPermanentRemoval() {
        onDisplayUpdate = nil
        onScrollStateChange = nil
        setFocused(false)
        setVisible(false)
        view.isHidden = true
        if view.superview != nil {
            view.removeFromSuperview()
        }
    }

    @MainActor
    func prepareForRuntimeTeardown() {
        onDisplayUpdate = nil
        onScrollStateChange = nil
    }

    @MainActor
    @discardableResult
    func updateDisplay(size: CGSize, scale: CGFloat) -> Bool {
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "managed.updateDisplay.begin",
            fields: [
                "scale": String(format: "%.1f", Double(scale)),
                "size": "\(Int(size.width))x\(Int(size.height))",
                "surface": ghosttyDiagnosticShortID(id),
            ]
        )
        guard let metrics = displayUpdateTracker.nextMetrics(size: size, scale: scale) else {
            GhosttyRuntimeTrace.tmuxViewport(
                "managed.updateDisplay skip surface=\(ghosttyDiagnosticShortID(id)) visible=\(isVisible) focused=\(isFocused) points=\(Int(size.width))x\(Int(size.height)) scale=\(scale) current=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize()))"
            )
            GhosttyRuntimeTrace.perf(
                "managed.updateDisplay outcome=skip size=\(Int(size.width))x\(Int(size.height)) scale=\(scale)"
            )
            GhosttyTmuxActionTrace.traceActiveTopologyFlows(
                event: "managed.updateDisplay.skip",
                fields: [
                    "scale": String(format: "%.1f", Double(scale)),
                    "size": "\(Int(size.width))x\(Int(size.height))",
                    "surface": ghosttyDiagnosticShortID(id),
                ]
            )
            return false
        }

        GhosttyRuntimeTrace.tmuxViewport(
            "managed.updateDisplay hit surface=\(ghosttyDiagnosticShortID(id)) visible=\(isVisible) focused=\(isFocused) points=\(Int(size.width))x\(Int(size.height)) metrics=\(metrics.pixelWidth)x\(metrics.pixelHeight) scale=\(scale) before=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize()))"
        )
        GhosttyRuntimeTrace.perfMeasure(
            "managed.updateDisplay outcome=hit size=\(Int(size.width))x\(Int(size.height)) scale=\(scale)"
        ) {
            if let updateDisplayHandler {
                updateDisplayHandler(metrics)
            } else {
                controlSurface.updateDisplay(metrics: metrics)
            }
        }
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "managed.updateDisplay.applied",
            fields: [
                "pixelSize": "\(metrics.pixelWidth)x\(metrics.pixelHeight)",
                "scale": String(format: "%.1f", Double(scale)),
                "size": "\(Int(size.width))x\(Int(size.height))",
                "surface": ghosttyDiagnosticShortID(id),
            ]
        )
        GhosttyRuntimeTrace.tmuxViewport(
            "managed.updateDisplay applied surface=\(ghosttyDiagnosticShortID(id)) visible=\(isVisible) focused=\(isFocused) after=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize()))"
        )
        onDisplayUpdate?(self, size, scale)
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(
            event: "managed.updateDisplay.end",
            fields: [
                "pixelSize": "\(metrics.pixelWidth)x\(metrics.pixelHeight)",
                "scale": String(format: "%.1f", Double(scale)),
                "size": "\(Int(size.width))x\(Int(size.height))",
                "surface": ghosttyDiagnosticShortID(id),
            ]
        )
        return true
    }

    @MainActor
    @discardableResult
    func sendPaste(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        if let sendPasteHandler {
            return sendPasteHandler(text) ? .accepted : .surfaceRejected
        }

        return controlSurface.sendPaste(text) ? .accepted : .surfaceRejected
    }

    @MainActor
    func hasSelection() -> Bool {
        if let hasSelectionHandler {
            return hasSelectionHandler()
        }

        return controlSurface.hasSelection()
    }

    @MainActor
    func readSelection() -> String? {
        if let readSelectionHandler {
            return readSelectionHandler()
        }

        return controlSurface.readSelection()
    }

    @MainActor
    @discardableResult
    func sendKeyEvent(_ event: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        if let sendKeyEventHandler {
            return sendKeyEventHandler(event) ? .accepted : .surfaceRejected
        }

        return controlSurface.sendKeyEvent(event) ? .accepted : .surfaceRejected
    }

    @MainActor
    @discardableResult
    func sendMouseButton(_ event: GhosttySurfaceMouseButtonEvent) -> Bool {
        if let sendMouseButtonHandler {
            return sendMouseButtonHandler(event)
        }

        return controlSurface.sendMouseButton(event)
    }

    @MainActor
    func sendMousePosition(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) {
        if let sendMousePositionHandler {
            sendMousePositionHandler(position, mods)
            return
        }

        controlSurface.sendMousePosition(position, mods: mods)
    }

    @MainActor
    func sendMouseScroll(_ event: GhosttySurfaceMouseScrollEvent) {
        if let sendMouseScrollHandler {
            sendMouseScrollHandler(event)
            return
        }

        controlSurface.sendMouseScroll(event)
    }

    @MainActor
    func updateScrollState(_ state: GhosttySurfaceScrollState) {
        guard state != scrollState else { return }
        scrollState = state
        onScrollStateChange?()
    }

    @MainActor
    func updateScrollRoute(_ route: GhosttySurfaceScrollRoute) {
        guard route != scrollRoute else { return }
        scrollRoute = route
        onScrollStateChange?()
    }

    @MainActor
    @discardableResult
    func scrollToPosition(row: UInt64, cellOffset: Double) -> GhosttySurfaceScrollState {
        let nextState: GhosttySurfaceScrollState
        if let scrollToPositionHandler {
            nextState = scrollToPositionHandler(row, cellOffset)
        } else {
            controlSurface.scrollToPosition(row: row, cellOffset: cellOffset)
            nextState = controlSurface.scrollState()
        }

        updateScrollState(nextState)
        return scrollState
    }

    @MainActor
    func sendMousePressure(_ event: GhosttySurfaceMousePressureEvent) {
        if let sendMousePressureHandler {
            sendMousePressureHandler(event)
            return
        }

        controlSurface.sendMousePressure(event)
    }

    @MainActor
    func isMouseCaptured() -> Bool {
        if let isMouseCapturedHandler {
            return isMouseCapturedHandler()
        }

        return controlSurface.isMouseCaptured()
    }

    @MainActor
    @discardableResult
    func tmuxFocus() -> TmuxActionSubmissionResult {
        guard let tmuxFocusHandler else { return .notTmuxBound }
        return tmuxFocusHandler()
    }

    @MainActor
    @discardableResult
    func tmuxSplit(_ direction: ghostty_action_split_direction_e) -> TmuxActionSubmissionResult {
        guard let tmuxSplitHandler else { return .notTmuxBound }
        return tmuxSplitHandler(direction)
    }

    @MainActor
    @discardableResult
    func tmuxClosePane() -> TmuxActionSubmissionResult {
        guard let tmuxClosePaneHandler else { return .notTmuxBound }
        return tmuxClosePaneHandler()
    }

    @MainActor
    @discardableResult
    func tmuxCloseWindow() -> TmuxActionSubmissionResult {
        guard let tmuxCloseWindowHandler else { return .notTmuxBound }
        return tmuxCloseWindowHandler()
    }

    @MainActor
    @discardableResult
    func tmuxCopyMode() -> TmuxActionSubmissionResult {
        guard let tmuxCopyModeHandler else { return .notTmuxBound }
        return tmuxCopyModeHandler()
    }

    @MainActor
    func diagnosticSummary() -> String {
        "surface=\(ghosttyDiagnosticShortID(id)) handle=\(String(describing: controlSurface.handle)) manual=\(ghosttyDiagnosticPointer(manualUserdata)) visible=\(isVisible) focused=\(isFocused) view=\(ghosttyDiagnosticRect(view.frame)) bounds=\(ghosttyDiagnosticRect(view.bounds)) size=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize())) scroll=total:\(scrollState.total) offset:\(scrollState.offset) len:\(scrollState.len) route:\(scrollRoute)"
    }
}
