import SwiftUI
import UIKit

/// Hosts Remux's single live terminal surface. Pane/window topology belongs to
/// the picker model; it never participates in viewport layout.
struct GhosttySingleViewportView: View {
    let materializationContext: GhosttyRuntimeSurfaceMaterializationContext
    let projection: GhosttyTerminalViewportPresentationProjection
    let terminalTheme: TerminalTheme
    let onSurfaceTap: ((UUID) -> Void)?
    let onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    let onCopySelection: ((UUID) -> Bool)?
    let selectionAvailability: (UUID) -> GhosttyTerminalSelectionAvailabilityOutcome
    let selectSurface: (UUID, String) -> GhosttySurfaceSelectionOutcome
    let isMouseCaptured: (UUID) -> Bool
    let submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMousePressure: ((UUID, GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome)?

    var body: some View {
        GhosttySingleViewportRepresentable(
            materializationContext: materializationContext,
            projection: projection,
            terminalTheme: terminalTheme,
            onSurfaceTap: onSurfaceTap,
            onWindowSwipe: onWindowSwipe,
            onCopySelection: onCopySelection,
            selectionAvailability: selectionAvailability,
            selectSurface: selectSurface,
            isMouseCaptured: isMouseCaptured,
            submitMouseButton: submitMouseButton,
            submitMousePosition: submitMousePosition,
            submitMouseScroll: submitMouseScroll,
            submitMousePressure: submitMousePressure
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GhosttySingleViewportRepresentable: UIViewRepresentable {
    let materializationContext: GhosttyRuntimeSurfaceMaterializationContext
    let projection: GhosttyTerminalViewportPresentationProjection
    let terminalTheme: TerminalTheme
    let onSurfaceTap: ((UUID) -> Void)?
    let onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    let onCopySelection: ((UUID) -> Bool)?
    let selectionAvailability: (UUID) -> GhosttyTerminalSelectionAvailabilityOutcome
    let selectSurface: (UUID, String) -> GhosttySurfaceSelectionOutcome
    let isMouseCaptured: (UUID) -> Bool
    let submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMousePressure: ((UUID, GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome)?

    func makeUIView(context: Context) -> GhosttySingleViewportContainerView {
        let view = GhosttySingleViewportContainerView()
        view.terminalTheme = terminalTheme
        view.backgroundColor = terminalTheme.terminalBackgroundUIColor
        return view
    }

    func updateUIView(_ view: GhosttySingleViewportContainerView, context: Context) {
        view.terminalTheme = terminalTheme
        view.backgroundColor = terminalTheme.terminalBackgroundUIColor
        view.update(
            projection: projection,
            materializationContext: materializationContext,
            onSurfaceTap: onSurfaceTap,
            onWindowSwipe: onWindowSwipe,
            onCopySelection: onCopySelection,
            selectionAvailability: selectionAvailability,
            selectSurface: selectSurface,
            isMouseCaptured: isMouseCaptured,
            submitMouseButton: submitMouseButton,
            submitMousePosition: submitMousePosition,
            submitMouseScroll: submitMouseScroll,
            submitMousePressure: submitMousePressure
        )
    }

    static func dismantleUIView(
        _ view: GhosttySingleViewportContainerView,
        coordinator: ()
    ) {
        view.dismantle()
    }
}

private final class GhosttySingleViewportContainerView: UIView,
    UIGestureRecognizerDelegate,
    @preconcurrency UIEditMenuInteractionDelegate
{
    private var materializationContext = GhosttyRuntimeSurfaceMaterializationContext.empty
    private var projection = GhosttyTerminalViewportPresentationProjection.empty
    private var activeContainer: GhosttyPaneScrollContainerView?
    private var activeSurfaceID: UUID?
    private var heldContainer: GhosttyPaneScrollContainerView?
    private var heldSurfaceID: UUID?
    private var heldInteractionEnabled = true
    private var presentationOverlayView: UIView?
    private var presentationOverlayPendingID: UUID?

    private var onSurfaceTap: ((UUID) -> Void)?
    private var onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    private var onCopySelection: ((UUID) -> Bool)?
    private var selectionAvailability: (UUID) -> GhosttyTerminalSelectionAvailabilityOutcome = { _ in
        .noFocusedSurface
    }
    private var selectSurface: (UUID, String) -> GhosttySurfaceSelectionOutcome = { surfaceID, _ in
        .missingSurface(surfaceID)
    }
    private var isMouseCaptured: (UUID) -> Bool = { _ in false }
    private var submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?
    private var submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    private var submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    private var submitMousePressure: ((UUID, GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome)?

    private var activePanAxis: GhosttySurfacePanGesture.Axis?
    private var isPanGestureActive = false
    private var didNavigateForActivePan = false
    private var activeSelectionSurfaceID: UUID?
    private var selectionCopyMenuSurfaceID: UUID?
    private var selectionCopyMenuSourcePoint = CGPoint.zero

    var terminalTheme: TerminalTheme = .ghosttyDefault

    private lazy var panRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handleSurfacePan(_:))
        )
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    private lazy var inputActivationTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleInputActivationTap(_:))
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var selectionEditMenuInteraction = UIEditMenuInteraction(delegate: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        panRecognizer.delegate = self
        addGestureRecognizer(panRecognizer)
        addGestureRecognizer(inputActivationTapRecognizer)
        addInteraction(selectionEditMenuInteraction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        projection: GhosttyTerminalViewportPresentationProjection,
        materializationContext: GhosttyRuntimeSurfaceMaterializationContext,
        onSurfaceTap: ((UUID) -> Void)?,
        onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?,
        onCopySelection: ((UUID) -> Bool)?,
        selectionAvailability: @escaping (UUID) -> GhosttyTerminalSelectionAvailabilityOutcome,
        selectSurface: @escaping (UUID, String) -> GhosttySurfaceSelectionOutcome,
        isMouseCaptured: @escaping (UUID) -> Bool,
        submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?,
        submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?,
        submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?,
        submitMousePressure: ((UUID, GhosttySurfaceMousePressureEvent) -> GhosttyMouseInputSubmissionOutcome)?
    ) {
        let previousSourceIdentity = self.materializationContext.sourceIdentity
        updatePresentationHold(
            pendingID: projection.pendingPresentationID,
            desiredSurfaceID: projection.surfaceID,
            canRetainActiveContainer: previousSourceIdentity == materializationContext.sourceIdentity
        )

        self.projection = projection
        self.materializationContext = materializationContext
        self.onSurfaceTap = onSurfaceTap
        self.onWindowSwipe = onWindowSwipe
        self.onCopySelection = onCopySelection
        self.selectionAvailability = selectionAvailability
        self.selectSurface = selectSurface
        self.isMouseCaptured = isMouseCaptured
        self.submitMouseButton = submitMouseButton
        self.submitMousePosition = submitMousePosition
        self.submitMouseScroll = submitMouseScroll
        self.submitMousePressure = submitMousePressure

        if activePanAxis == .horizontal, !projection.canNavigateWindows {
            resetActivePanState()
        }
        if activeSelectionSurfaceID != projection.surfaceID {
            activeSelectionSurfaceID = nil
        }
        if selectionCopyMenuSurfaceID != projection.surfaceID {
            selectionCopyMenuSurfaceID = nil
        }

        syncActiveSurface()
        flushLayoutIfPossible()
    }

    func dismantle() {
        disableInteractions()
        resetActivePanState()
        if let container = activeContainer {
            retire(container: container)
        }
        if let container = heldContainer {
            retire(container: container)
        }
        presentationOverlayView?.removeFromSuperview()
        activeContainer = nil
        activeSurfaceID = nil
        heldContainer = nil
        heldSurfaceID = nil
        presentationOverlayView = nil
        presentationOverlayPendingID = nil
        materializationContext = .empty
        projection = .empty

    }

    private func disableInteractions() {
        onSurfaceTap = nil
        onWindowSwipe = nil
        onCopySelection = nil
        selectionAvailability = { _ in .noFocusedSurface }
        selectSurface = { surfaceID, _ in .missingSurface(surfaceID) }
        isMouseCaptured = { _ in false }
        submitMouseButton = nil
        submitMousePosition = nil
        submitMouseScroll = nil
        submitMousePressure = nil
        activeSelectionSurfaceID = nil
        selectionCopyMenuSurfaceID = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutActiveSurface()
        layoutPresentationOverlay()
    }

    private func syncActiveSurface() {
        let startedAt = GhosttyRuntimeTrace.perfEnabled
            ? GhosttyRuntimeTrace.nowNanos()
            : nil
        defer {
            if let startedAt {
                GhosttyRuntimeTrace.perf(
                    "viewport.sync surface=\(ghosttyDiagnosticShortID(projection.surfaceID)) attached=\(activeContainer == nil ? 0 : 1) held=\(heldContainer == nil ? 0 : 1) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
                )
            }
        }

        guard materializationContext.isAvailable else {
            retireActiveContainer()
            return
        }

        guard let desiredID = projection.surfaceID else {
            retireActiveContainer()
            return
        }

        if activeSurfaceID != desiredID {
            retireActiveContainer()
        }
        guard heldSurfaceID != desiredID else { return }
        guard let surface = materializationContext.managedSurface(for: desiredID) else {
            retireActiveContainer()
            return
        }

        let container = activeContainer ?? GhosttyPaneScrollContainerView()
        activeContainer = container
        activeSurfaceID = desiredID
        container.backgroundColor = .clear
        ensureInteractionRecognizers(for: surface.view)
        let changed = container.update(
            surface: surface,
            displayScale: effectiveScale,
            submitRouteForwardedMouseScroll: submitMouseScroll,
            submitRouteForwardedMousePosition: submitMousePosition
        )
        if container.superview !== self {
            container.removeFromSuperview()
            addSubview(container)
        }
        if changed {
            container.layoutIfNeeded()
        }
    }

    private func retireActiveContainer() {
        guard let container = activeContainer else {
            activeContainer?.removeFromSuperview()
            activeContainer = nil
            activeSurfaceID = nil
            return
        }
        retire(container: container)
        activeContainer = nil
        activeSurfaceID = nil
    }

    private func retire(container: GhosttyPaneScrollContainerView) {
        container.detachCurrentSurfaceForRemoval()
        container.removeFromSuperview()
    }

    private func layoutActiveSurface() {
        guard materializationContext.isAvailable,
              let surfaceID = activeSurfaceID,
              let container = activeContainer,
              let surface = materializationContext.managedSurface(for: surfaceID)
        else { return }

        let startedAt = GhosttyRuntimeTrace.perfEnabled
            ? GhosttyRuntimeTrace.nowNanos()
            : nil
        let targetFrame = bounds.integral
        let changedFrame = container.frame != targetFrame
        if changedFrame {
            container.frame = targetFrame
        }
        let changedContainer = container.update(
            surface: surface,
            displayScale: effectiveScale,
            submitRouteForwardedMouseScroll: submitMouseScroll,
            submitRouteForwardedMousePosition: submitMousePosition
        )
        if changedFrame || changedContainer {
            container.layoutIfNeeded()
        }
        surface.setVisible(true)
        surface.setFocused(true)
        if let startedAt {
            GhosttyRuntimeTrace.perf(
                "viewport.layout bounds=\(ghosttyDiagnosticRect(bounds)) changed=\(changedFrame || changedContainer) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
            )
        }
    }

    private func flushLayoutIfPossible() {
        guard bounds.width > 1, bounds.height > 1 else {
            setNeedsLayout()
            return
        }
        layoutActiveSurface()
        layoutPresentationOverlay()
    }

    private func updatePresentationHold(
        pendingID: UUID?,
        desiredSurfaceID: UUID?,
        canRetainActiveContainer: Bool
    ) {
        guard let pendingID else {
            clearPresentationHold(desiredSurfaceID: desiredSurfaceID)
            return
        }
        // A selection can publish "outgoing pane has no surface" before tmux
        // confirms the incoming pane. That changes the pending identity, but
        // it is still one uninterrupted handoff: retain the outgoing frame.
        if presentationOverlayView != nil, canRetainActiveContainer {
            presentationOverlayPendingID = pendingID
            return
        }
        clearPresentationHold(desiredSurfaceID: desiredSurfaceID)
        guard bounds.width > 1, bounds.height > 1 else { return }

        let overlay = UIView(frame: bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.clipsToBounds = true
        overlay.isUserInteractionEnabled = false

        if canRetainActiveContainer,
           let container = activeContainer,
           let surfaceID = activeSurfaceID {
            heldInteractionEnabled = container.isUserInteractionEnabled
            container.isUserInteractionEnabled = false
            container.removeFromSuperview()
            overlay.addSubview(container)
            heldContainer = container
            heldSurfaceID = surfaceID
            activeContainer = nil
            activeSurfaceID = nil
            overlay.backgroundColor = .clear
        } else {
            overlay.backgroundColor = terminalTheme.terminalBackgroundUIColor
        }

        addSubview(overlay)
        presentationOverlayView = overlay
        presentationOverlayPendingID = pendingID
    }

    private func clearPresentationHold(desiredSurfaceID: UUID?) {
        guard presentationOverlayView != nil || heldContainer != nil else {
            presentationOverlayPendingID = nil
            return
        }

        if let container = heldContainer, let surfaceID = heldSurfaceID {
            container.isUserInteractionEnabled = heldInteractionEnabled
            if desiredSurfaceID == surfaceID,
               materializationContext.managedSurface(for: surfaceID) != nil {
                container.removeFromSuperview()
                addSubview(container)
                activeContainer = container
                activeSurfaceID = surfaceID
            } else {
                retire(container: container)
            }
        }

        heldContainer = nil
        heldSurfaceID = nil
        presentationOverlayView?.removeFromSuperview()
        presentationOverlayView = nil
        presentationOverlayPendingID = nil
    }

    private func layoutPresentationOverlay() {
        guard let overlay = presentationOverlayView else { return }
        overlay.frame = bounds
        heldContainer?.frame = overlay.bounds
        bringSubviewToFront(overlay)
    }

    private func ensureInteractionRecognizers(for view: UIView) {
        let recognizers = view.gestureRecognizers ?? []
        let existingLongPress = recognizers.compactMap { $0 as? UILongPressGestureRecognizer }.first
        let existingTap = recognizers.compactMap { $0 as? UITapGestureRecognizer }.first
        let longPress = existingLongPress ?? makeSelectionLongPressRecognizer(for: view)
        let tap = existingTap ?? makeTapRecognizer(for: view)
        longPress.delegate = self
        tap.delegate = self
        if existingLongPress == nil || existingTap == nil {
            tap.require(toFail: longPress)
        }
    }

    private func makeTapRecognizer(for view: UIView) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleSurfaceTap(_:))
        )
        view.addGestureRecognizer(recognizer)
        return recognizer
    }

    private func makeSelectionLongPressRecognizer(
        for view: UIView
    ) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleSelectionLongPress(_:))
        )
        recognizer.minimumPressDuration = 0.45
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        return recognizer
    }

    @objc
    private func handleSelectionLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard materializationContext.isAvailable,
              let surfaceID = projection.surfaceID,
              let surface = materializationContext.managedSurface(for: surfaceID),
              recognizer.view === surface.view,
              let phase = GhosttySurfaceLongPressSelectionGesture.Phase(recognizer.state)
        else { return }

        if phase == .began {
            guard !isPanGestureActive else {
                activeSelectionSurfaceID = nil
                return
            }
            _ = selectSurface(surfaceID, "viewport.longPress")
            guard !isMouseCaptured(surfaceID) else {
                activeSelectionSurfaceID = nil
                return
            }
            activeSelectionSurfaceID = surfaceID
        }

        guard activeSelectionSurfaceID == surfaceID else { return }
        _ = selectSurface(surfaceID, "viewport.longPress.update")
        for action in GhosttySurfaceLongPressSelectionGesture.actions(
            forLocalPoint: recognizer.location(in: surface.view),
            phase: phase
        ) {
            switch action {
            case .mousePosition(let position):
                _ = submitMousePosition?(surfaceID, position, [])
            case .mouseButton(let event):
                _ = submitMouseButton?(surfaceID, event)
            case .mousePressure(let event):
                _ = submitMousePressure?(surfaceID, event)
            }
        }

        if phase == .ended {
            presentSelectionCopyMenuIfAvailable(
                surfaceID: surfaceID,
                sourcePoint: recognizer.location(in: self)
            )
        }
        if phase == .ended || phase == .cancelled {
            activeSelectionSurfaceID = nil
        }
    }

    private func presentSelectionCopyMenuIfAvailable(
        surfaceID: UUID,
        sourcePoint: CGPoint
    ) {
        guard onCopySelection != nil,
              selectionAvailability(surfaceID).isAvailable
        else { return }
        selectionCopyMenuSourcePoint = sourcePoint
        selectionCopyMenuSurfaceID = surfaceID
        selectionEditMenuInteraction.presentEditMenu(
            with: UIEditMenuConfiguration(identifier: nil, sourcePoint: sourcePoint)
        )
    }

    @objc
    private func handleSurfaceTap(_ recognizer: UITapGestureRecognizer) {
        guard materializationContext.isAvailable,
              let surfaceID = projection.surfaceID,
              let surface = materializationContext.managedSurface(for: surfaceID),
              recognizer.view === surface.view
        else { return }

        let mouseCaptured = isMouseCaptured(surfaceID)
        _ = selectSurface(surfaceID, "viewport.tap")
        if activeContainer?.consumeMomentumCatchTap() == true {
            return
        }
        for action in GhosttySurfaceTapGesture.actions(
            forLocalPoint: recognizer.location(in: surface.view),
            mouseCaptured: mouseCaptured
        ) {
            switch action {
            case .activateInput:
                onSurfaceTap?(surfaceID)
            case .mousePosition(let position):
                _ = submitMousePosition?(surfaceID, position, [])
            case .mouseButton(let event):
                _ = submitMouseButton?(surfaceID, event)
            }
        }
    }

    @objc
    private func handleInputActivationTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let surfaceID = projection.surfaceID else { return }
        onSurfaceTap?(surfaceID)
    }

    @objc
    private func handleSurfacePan(_ recognizer: UIPanGestureRecognizer) {
        guard materializationContext.isAvailable,
              let phase = GhosttySurfacePanGesture.Phase(recognizer.state)
        else { return }

        if phase == .began {
            resetActivePanState()
            isPanGestureActive = true
        }
        if activeSelectionSurfaceID != nil {
            resetActivePanStateIfEnded(phase)
            return
        }

        let translation = recognizer.translation(in: self)
        activePanAxis = GhosttySurfacePanGesture.axis(
            forTranslation: translation,
            currentAxis: activePanAxis
        )
        if activePanAxis == .horizontal {
            routeHorizontalNavigation(
                translation: translation,
                velocity: recognizer.velocity(in: self)
            )
        }
        resetActivePanStateIfEnded(phase)
    }

    private func routeHorizontalNavigation(translation: CGPoint, velocity: CGPoint) {
        guard projection.canNavigateWindows,
              let direction = GhosttySurfacePanGesture.windowNavigationDirection(
                forTranslation: translation,
                velocity: velocity,
                axis: .horizontal,
                didNavigate: didNavigateForActivePan
              )
        else { return }

        didNavigateForActivePan = true
        onWindowSwipe?(direction.runtimeSelectionDirection)
    }

    private func resetActivePanStateIfEnded(_ phase: GhosttySurfacePanGesture.Phase) {
        if phase == .ended || phase == .cancelled {
            resetActivePanState()
        }
    }

    private func resetActivePanState() {
        activePanAxis = nil
        isPanGestureActive = false
        didNavigateForActivePan = false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === panRecognizer || otherGestureRecognizer === panRecognizer else {
            return false
        }
        return gestureRecognizer is UIPanGestureRecognizer &&
            otherGestureRecognizer is UIPanGestureRecognizer
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UILongPressGestureRecognizer {
            return !isPanGestureActive
        }
        guard gestureRecognizer === panRecognizer else { return true }
        return GhosttySurfacePanGesture.surfaceContainerPanShouldBegin(
            topLevelCount: projection.windowCount,
            velocity: panRecognizer.velocity(in: self)
        )
    }

    private var effectiveScale: CGFloat {
        max(window?.screen.scale ?? UIScreen.main.scale, 1)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        _ = interaction
        _ = configuration
        _ = suggestedActions
        guard let surfaceID = selectionCopyMenuSurfaceID,
              selectionAvailability(surfaceID).isAvailable
        else { return nil }

        return UIMenu(children: [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                _ = self?.onCopySelection?(surfaceID)
                if self?.selectionCopyMenuSurfaceID == surfaceID {
                    self?.selectionCopyMenuSurfaceID = nil
                }
            },
        ])
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        _ = interaction
        _ = configuration
        return CGRect(
            x: selectionCopyMenuSourcePoint.x - 1,
            y: selectionCopyMenuSourcePoint.y - 1,
            width: 2,
            height: 2
        )
    }
}

private extension GhosttySurfacePanGesture.WindowNavigationDirection {
    var runtimeSelectionDirection: GhosttyRuntimeSelectionDirection {
        switch self {
        case .previous: .previous
        case .next: .next
        }
    }
}

private extension GhosttySurfaceLongPressSelectionGesture.Phase {
    init?(_ state: UIGestureRecognizer.State) {
        switch state {
        case .began: self = .began
        case .changed: self = .changed
        case .ended: self = .ended
        case .cancelled, .failed: self = .cancelled
        case .possible: return nil
        @unknown default: return nil
        }
    }
}
