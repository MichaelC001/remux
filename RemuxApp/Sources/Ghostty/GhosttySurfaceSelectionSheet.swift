import SwiftUI

enum GhosttySurfaceSelectionSheet: Identifiable {
    case windows(GhosttyPanePreviewSession)
    case panes(topLevelID: UUID, previews: GhosttyPanePreviewSession)

    var id: String {
        switch self {
        case .windows(_):
            "windows"
        case .panes(let topLevelID, let previews):
            "panes-\(topLevelID.uuidString)-\(previews.id.uuidString)"
        }
    }

    var presentationKind: GhosttySelectionSheetPresentationKind {
        switch self {
        case .windows(_):
            return .windows
        case .panes(_, _):
            return .panes
        }
    }

    var paneTopLevelIDForTopologyValidation: UUID? {
        switch self {
        case .windows(_):
            nil
        case .panes(let topLevelID, _):
            topLevelID
        }
    }
}

enum GhosttySelectionSheetPresentationKind: Equatable, Sendable {
    case windows
    case panes
}

struct GhosttySelectionSheetPresentationChange: Equatable, Sendable {
    let currentKind: GhosttySelectionSheetPresentationKind?
    let nextKind: GhosttySelectionSheetPresentationKind?
    let shouldCancelCurrentPreviewSession: Bool
    let shouldResetBottomReplacementHeight: Bool

    init(
        currentKind: GhosttySelectionSheetPresentationKind?,
        nextKind: GhosttySelectionSheetPresentationKind?
    ) {
        self.currentKind = currentKind
        self.nextKind = nextKind
        self.shouldCancelCurrentPreviewSession = currentKind != nil && nextKind == nil
        self.shouldResetBottomReplacementHeight = nextKind == nil
    }
}

struct GhosttySelectionSheetPresentationState: Equatable {
    private(set) var presentedKind: GhosttySelectionSheetPresentationKind?
    private(set) var bottomReplacementHeight: CGFloat = 0

    mutating func captureBottomReplacementHeight(_ height: CGFloat) {
        bottomReplacementHeight = height
    }

    mutating func apply(
        nextKind: GhosttySelectionSheetPresentationKind?
    ) -> GhosttySelectionSheetPresentationChange {
        let change = GhosttySelectionSheetPresentationChange(
            currentKind: presentedKind,
            nextKind: nextKind
        )
        presentedKind = nextKind
        if change.shouldResetBottomReplacementHeight {
            bottomReplacementHeight = 0
        }
        return change
    }
}

enum GhosttySheetPalette {
    static let row = Color(uiColor: .secondarySystemFill)
    static let stroke = Color.primary.opacity(0.12)
    static let controlFill = Color(uiColor: .secondarySystemFill)
    static let destructiveControlFill = Color(uiColor: .systemRed).opacity(0.14)
    static let primary = Color.primary.opacity(0.92)
    static let secondary = Color.secondary.opacity(0.78)
    static let tertiary = Color.secondary.opacity(0.56)

    static func rowSelected(_ chromeStyle: GhosttyTerminalChromeStyle) -> Color {
        chromeStyle.selectedFill
    }

    static func selectedStroke(_ chromeStyle: GhosttyTerminalChromeStyle) -> Color {
        chromeStyle.selectedStroke
    }
}

struct GhosttyWindowSelectionSheet: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @ObservedObject var session: GhosttyPanePreviewSession
    @State private var pendingRemoval: GhosttyWindowRemovalRequest?
    @State private var pendingContextAction: GhosttyWindowRemovalRequest?

    let projection: GhosttyWindowSelectionSheetRenderProjection
    let sessionName: String
    let onCreateWindow: (() -> Void)?
    let onSelect: (UUID) -> Void
    let onRemoveWindow: (UUID) -> Void

    var body: some View {
        let layout = PanePreviewLayout.windowMetricsForCurrentScreen(cellCount: projection.cellCount)

        VStack(alignment: .leading, spacing: 14) {
            sheetHeader(caption: "SESSION", title: sessionName)

            ScrollView(showsIndicators: false) {
                windowGrid(
                    windows: projection.windows,
                    layout: layout
                )
            }
            .accessibilityIdentifier("terminal.windows.scroll")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            GhosttySheetBottomActionBar {
                GhosttySheetActionButton(
                    title: "New Window",
                    systemName: "plus",
                    accessibilityIdentifier: "terminal.window.new",
                    action: onCreateWindow
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .task(id: session.id) {
            session.reconcile(leafIDs: projection.previewLeafIDs)
            await Task.yield()
            guard !Task.isCancelled else { return }
            GhosttyRuntimeTrace.perf("panePreview.presentation activate kind=windows")
            session.startRefreshing()
        }
        .onChange(of: projection.previewLeafIDs) { _, newValue in
            session.reconcile(leafIDs: newValue)
        }
        .overlayPreferenceValue(GhosttySelectionTileBoundsPreferenceKey.self) { bounds in
            GhosttySelectionContextActionOverlay(
                bounds: bounds,
                action: pendingContextAction.map {
                    GhosttySelectionContextActionPresentation(
                        id: $0.id,
                        title: "Remove Window \($0.displayIndex)",
                        accessibilityIdentifier: "terminal.window.remove.\($0.displayIndex)"
                    )
                },
                perform: confirmPendingContextAction,
                dismiss: dismissPendingContextAction
            )
        }
        .confirmationDialog(
            "Remove Window?",
            isPresented: pendingRemovalBinding,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { request in
            Button("Remove Window \(request.displayIndex)", role: .destructive) {
                onRemoveWindow(request.id)
                pendingRemoval = nil
            }
            .accessibilityIdentifier("terminal.window.remove.confirm.\(request.displayIndex)")
        } message: { request in
            Text(windowRemovalMessage(for: request))
        }
        .accessibilityIdentifier("terminal.windows.sheet")
    }

    private func windowGrid(
        windows: [GhosttyWindowSelectionSheetRenderProjection.Window],
        layout: PanePreviewLayout.Metrics
    ) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(layout.tilePointSize.width), spacing: layout.gridSpacing),
                count: layout.columnCount
            ),
            alignment: .center,
            spacing: layout.gridSpacing
        ) {
            ForEach(windows) { window in
                Button {
                    Haptic.selection()
                    onSelect(window.id)
                } label: {
                    GhosttyWindowSelectionTile(
                        displayIndex: window.displayIndex,
                        totalCount: window.totalCount,
                        paneCount: window.paneCount,
                        isSelected: window.isSelected,
                        previewState: window.focusedPreviewPaneID
                            .flatMap { session.imagesByPaneID[$0] },
                        chromeStyle: chromeStyle,
                        layout: layout
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminal.window.tile.\(window.displayIndex)")
                .anchorPreference(key: GhosttySelectionTileBoundsPreferenceKey.self, value: .bounds) {
                    [window.id: $0]
                }
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.42, maximumDistance: 18)
                        .onEnded { _ in
                            Haptic.warning()
                            pendingContextAction = GhosttyWindowRemovalRequest(
                                id: window.id,
                                displayIndex: window.displayIndex,
                                paneCount: window.paneCount
                            )
                        }
                )
                .accessibilityAction(named: Text("Remove Window \(window.displayIndex)")) {
                    Haptic.warning()
                    pendingRemoval = GhosttyWindowRemovalRequest(
                        id: window.id,
                        displayIndex: window.displayIndex,
                        paneCount: window.paneCount
                    )
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var pendingRemovalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemoval = nil
                    pendingContextAction = nil
                }
            }
        )
    }

    private func confirmPendingContextAction() {
        pendingRemoval = pendingContextAction
        pendingContextAction = nil
    }

    private func dismissPendingContextAction() {
        pendingContextAction = nil
    }

    private func windowRemovalMessage(for request: GhosttyWindowRemovalRequest) -> String {
        "This will close Window \(request.displayIndex) and \(request.paneCount) \(request.paneCount == 1 ? "pane" : "panes")."
    }
}

struct GhosttyPaneSelectionSheet: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @ObservedObject var session: GhosttyPanePreviewSession
    @State private var pendingRemoval: GhosttyPaneRemovalRequest?
    @State private var pendingContextAction: GhosttyPaneRemovalRequest?

    let projection: GhosttyPaneSelectionSheetRenderProjection
    let onSplitPane: (() -> Void)?
    let onStackPane: (() -> Void)?
    let onSelect: (UUID) -> Void
    let onRemovePane: (UUID) -> Void

    var body: some View {
        let layout = PanePreviewLayout.metricsForCurrentScreen(for: projection.paneCount)

        VStack(alignment: .leading, spacing: 14) {
            sheetHeader(
                caption: "PANES",
                title: "\(projection.paneCount) \(projection.paneCount == 1 ? "pane" : "panes")"
            )

            ScrollView(showsIndicators: false) {
                paneLayout(
                    panes: projection.panes,
                    layout: layout,
                    onRemove: { pane in
                        pendingContextAction = GhosttyPaneRemovalRequest(
                            id: pane.id,
                            displayIndex: pane.displayIndex,
                            isOnlyPane: projection.paneCount == 1
                        )
                    }
                )
            }
            .accessibilityIdentifier("terminal.panes.scroll")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            GhosttySheetBottomActionBar {
                HStack(spacing: 10) {
                    GhosttySheetActionButton(
                        title: "Split",
                        systemName: "square.split.2x1",
                        accessibilityIdentifier: "terminal.pane.split",
                        action: onSplitPane
                    )

                    GhosttySheetActionButton(
                        title: "Stack",
                        systemName: "square.split.1x2",
                        accessibilityIdentifier: "terminal.pane.stack",
                        action: onStackPane
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .task(id: session.id) {
            // First-render reconcile closes the gap between tap-time session
            // creation and the sheet's initial body render. If pane
            // membership changed during presentation, the session must align
            // immediately with the leaf IDs the sheet is actually showing.
            session.reconcile(leafIDs: projection.previewLeafIDs)
            await Task.yield()
            guard !Task.isCancelled else { return }
            GhosttyRuntimeTrace.perf("panePreview.presentation activate kind=panes")
            session.startRefreshing()
        }
        .onChange(of: projection.previewLeafIDs) { _, newValue in
            session.reconcile(leafIDs: newValue)
        }
        .overlayPreferenceValue(GhosttySelectionTileBoundsPreferenceKey.self) { bounds in
            GhosttySelectionContextActionOverlay(
                bounds: bounds,
                action: pendingContextAction.map {
                    GhosttySelectionContextActionPresentation(
                        id: $0.id,
                        title: "Remove Pane \($0.displayIndex)",
                        accessibilityIdentifier: "terminal.pane.remove.\($0.displayIndex)"
                    )
                },
                perform: confirmPendingContextAction,
                dismiss: dismissPendingContextAction
            )
        }
        .confirmationDialog(
            "Remove Pane?",
            isPresented: pendingRemovalBinding,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { request in
            Button("Remove Pane \(request.displayIndex)", role: .destructive) {
                onRemovePane(request.id)
                pendingRemoval = nil
            }
            .accessibilityIdentifier("terminal.pane.remove.confirm.\(request.displayIndex)")
        } message: { request in
            Text(paneRemovalMessage(for: request))
        }
        .accessibilityIdentifier("terminal.panes.sheet")
    }

    private func paneLayout(
        panes: [GhosttyPaneSelectionSheetRenderProjection.Pane],
        layout: PanePreviewLayout.Metrics,
        onRemove: @escaping (GhosttyPaneSelectionSheetRenderProjection.Pane) -> Void
    ) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(layout.tilePointSize.width), spacing: layout.gridSpacing),
                count: layout.columnCount
            ),
            alignment: .center,
            spacing: layout.gridSpacing
        ) {
            ForEach(panes) { pane in
                Button {
                    Haptic.selection()
                    onSelect(pane.id)
                } label: {
                    GhosttyPaneSelectionTile(
                        displayIndex: pane.displayIndex,
                        totalCount: pane.totalCount,
                        isSelected: pane.isSelected,
                        state: session.imagesByPaneID[pane.id],
                        chromeStyle: chromeStyle,
                        layout: layout
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminal.pane.tile.\(pane.displayIndex)")
                .anchorPreference(key: GhosttySelectionTileBoundsPreferenceKey.self, value: .bounds) {
                    [pane.id: $0]
                }
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.42, maximumDistance: 18)
                        .onEnded { _ in
                            Haptic.warning()
                            onRemove(pane)
                        }
                )
                .accessibilityAction(named: Text("Remove Pane \(pane.displayIndex)")) {
                    Haptic.warning()
                    pendingRemoval = GhosttyPaneRemovalRequest(
                        id: pane.id,
                        displayIndex: pane.displayIndex,
                        isOnlyPane: pane.totalCount == 1
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var pendingRemovalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemoval = nil
                    pendingContextAction = nil
                }
            }
        )
    }

    private func confirmPendingContextAction() {
        pendingRemoval = pendingContextAction
        pendingContextAction = nil
    }

    private func dismissPendingContextAction() {
        pendingContextAction = nil
    }

    private func paneRemovalMessage(for request: GhosttyPaneRemovalRequest) -> String {
        if request.isOnlyPane {
            return "This is the only pane in the window, so removing it can close the window too."
        }
        return "This will close Pane \(request.displayIndex)."
    }
}

private struct GhosttyWindowRemovalRequest: Identifiable {
    let id: UUID
    let displayIndex: Int
    let paneCount: Int
}

private struct GhosttyPaneRemovalRequest: Identifiable {
    let id: UUID
    let displayIndex: Int
    let isOnlyPane: Bool
}

private struct GhosttySelectionContextActionPresentation: Identifiable, Equatable {
    let id: UUID
    let title: String
    let accessibilityIdentifier: String
}

private struct GhosttySelectionTileBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct GhosttySelectionContextActionOverlay: View {
    let bounds: [UUID: Anchor<CGRect>]
    let action: GhosttySelectionContextActionPresentation?
    let perform: () -> Void
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            if let action, let anchor = bounds[action.id] {
                let tileFrame = proxy[anchor]

                ZStack {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismiss)

                    GhosttySelectionContextActionButton(
                        title: action.title,
                        accessibilityIdentifier: action.accessibilityIdentifier,
                        action: perform
                    )
                    .position(actionPosition(for: tileFrame, in: proxy.size))
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                }
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: action)
            }
        }
    }

    private func actionPosition(for tileFrame: CGRect, in containerSize: CGSize) -> CGPoint {
        let actionSize = GhosttySelectionContextActionButton.metrics.size
        let edgeMargin: CGFloat = 10
        let cornerInset: CGFloat = 18
        let x = min(
            max(tileFrame.maxX - cornerInset, actionSize.width / 2 + edgeMargin),
            containerSize.width - actionSize.width / 2 - edgeMargin
        )
        let y = min(
            max(tileFrame.minY + cornerInset, actionSize.height / 2 + edgeMargin),
            containerSize.height - actionSize.height / 2 - edgeMargin
        )
        return CGPoint(x: x, y: y)
    }
}

private struct GhosttySelectionContextActionButton: View {
    struct Metrics {
        let size = CGSize(width: 44, height: 44)
    }

    static let metrics = Metrics()

    let title: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(GhosttySelectionContextActionPalette.destructiveText)
                .frame(width: Self.metrics.size.width, height: Self.metrics.size.height)
                .ghosttySelectionContextActionSurface()
        }
        .buttonStyle(GhosttySelectionContextActionButtonStyle())
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(title)
    }
}

private struct GhosttySelectionContextActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum GhosttySelectionContextActionPalette {
    static let fallbackFill = Color(uiColor: .secondarySystemBackground).opacity(0.92)
    static let glassTint = Color.primary.opacity(0.055)
    static let destructiveText = Color(uiColor: .systemRed)
    static let stroke = Color.primary.opacity(0.11)
    static let shadow = Color.black.opacity(0.20)
}

@ViewBuilder
private func sheetHeader(caption: String, title: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(caption)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.0)
            .foregroundStyle(GhosttySheetPalette.tertiary)

        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(GhosttySheetPalette.primary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct GhosttySheetBottomActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.top, 6)
    }
}

private struct GhosttySheetActionButton: View {
    let title: String
    let systemName: String
    let accessibilityIdentifier: String
    let action: (() -> Void)?
    var isDestructive = false

    var body: some View {
        Button {
            Haptic.tap()
            action?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(foreground)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(foreground)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .padding(.horizontal, 14)
            .ghosttySheetActionSurface(isDestructive: isDestructive)
        }
        .buttonStyle(GhosttySheetActionButtonStyle(isEnabled: action != nil))
        .accessibilityIdentifier(accessibilityIdentifier)
        .disabled(action == nil)
    }

    private var foreground: Color {
        isDestructive ? Color(uiColor: .systemRed) : GhosttySheetPalette.primary
    }
}

private struct GhosttySheetActionButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct GhosttyRenderedPreviewSurface: View {
    let preview: GhosttyPanePreviewSession.RenderedPreview
    let size: CGSize

    var body: some View {
        Image(decorative: preview.image, scale: PanePreviewLayout.currentScale())
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .frame(width: size.width, height: size.height)
            .background(Color.black.opacity(0.30))
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var contentMode: ContentMode {
        switch preview.source {
        case .fullViewport: .fill
        case .paneGeometry: .fit
        }
    }
}

private struct GhosttyWindowSelectionTile: View {
    let displayIndex: Int
    let totalCount: Int
    let paneCount: Int
    let isSelected: Bool
    let previewState: GhosttyPanePreviewSession.PreviewState?
    let chromeStyle: GhosttyTerminalChromeStyle
    let layout: PanePreviewLayout.Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            previewSurface
            captionRow
        }
        .padding(layout.tilePadding)
        .frame(
            width: layout.tilePointSize.width,
            height: layout.tilePointSize.height,
            alignment: .topLeading
        )
        .background(isSelected ? GhosttySheetPalette.rowSelected(chromeStyle) : GhosttySheetPalette.row)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? GhosttySheetPalette.selectedStroke(chromeStyle) : GhosttySheetPalette.stroke,
                    lineWidth: isSelected ? 1.25 : 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(previewState.accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var previewSurface: some View {
        switch previewState {
        case .ready(let preview):
            GhosttyRenderedPreviewSurface(
                preview: preview,
                size: layout.previewPointSize
            )

        case .pending, .none, .failed:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.30))
                .frame(
                    width: layout.previewPointSize.width,
                    height: layout.previewPointSize.height
                )
        }
    }

    private var captionRow: some View {
        HStack(spacing: 6) {
            Text("\(displayIndex)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(GhosttySheetPalette.tertiary)

            Text(paneCountLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(GhosttySheetPalette.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if isSelected {
                HStack(spacing: 4) {
                    Circle()
                        .fill(chromeStyle.accent)
                        .frame(width: 6, height: 6)

                    Text("active")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(chromeStyle.accent)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var paneCountLabel: String {
        "\(paneCount) \(paneCount == 1 ? "pane" : "panes")"
    }

    private var accessibilityLabel: String {
        let paneText = "\(paneCount) \(paneCount == 1 ? "pane" : "panes")"
        let positional = "Window \(displayIndex) of \(totalCount)"
        if isSelected {
            return "\(positional), \(paneText), active"
        }
        return "\(positional), \(paneText)"
    }
}

private struct GhosttyPaneSelectionTile: View {
    let displayIndex: Int
    let totalCount: Int
    let isSelected: Bool
    let state: GhosttyPanePreviewSession.PreviewState?
    let chromeStyle: GhosttyTerminalChromeStyle
    let layout: PanePreviewLayout.Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            previewSurface
            captionRow
        }
        .padding(layout.tilePadding)
        .frame(
            width: layout.tilePointSize.width,
            height: layout.tilePointSize.height,
            alignment: .topLeading
        )
        .background(isSelected ? GhosttySheetPalette.rowSelected(chromeStyle) : GhosttySheetPalette.row)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? GhosttySheetPalette.selectedStroke(chromeStyle) : GhosttySheetPalette.stroke,
                    lineWidth: isSelected ? 1.25 : 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(state.accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityLabel: String {
        let positional = "Pane \(displayIndex) of \(totalCount)"
        return isSelected ? "\(positional), active" : positional
    }

    @ViewBuilder
    private var previewSurface: some View {
        switch state {
        case .ready(let preview):
            GhosttyRenderedPreviewSurface(
                preview: preview,
                size: layout.previewPointSize
            )

        case .pending, .none:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.30))
                .frame(
                    width: layout.previewPointSize.width,
                    height: layout.previewPointSize.height
                )

        case .failed:
            // Failed state still shows a neutral placeholder; we don't
            // surface different copy per status reason in v1.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.30))
                .frame(
                    width: layout.previewPointSize.width,
                    height: layout.previewPointSize.height
                )
        }
    }

    private var captionRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)

            if isSelected {
                HStack(spacing: 4) {
                    Circle()
                        .fill(chromeStyle.accent)
                        .frame(width: 6, height: 6)

                    Text("active")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(chromeStyle.accent)
                }
            }
        }
        .padding(.horizontal, 2)
    }
}

private extension Optional where Wrapped == GhosttyPanePreviewSession.PreviewState {
    var accessibilityValue: String {
        switch self {
        case .ready:
            "Preview ready"
        case .failed:
            "Preview unavailable"
        case .pending, .none:
            "Preview loading"
        }
    }
}

private extension View {
    @ViewBuilder
    func ghosttySelectionContextActionSurface() -> some View {
        let shape = Circle()

        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular.tint(GhosttySelectionContextActionPalette.glassTint).interactive(), in: shape)
                .overlay {
                    shape.strokeBorder(GhosttySelectionContextActionPalette.stroke, lineWidth: 0.75)
                }
                .shadow(color: GhosttySelectionContextActionPalette.shadow, radius: 18, y: 9)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .background {
                    shape.fill(GhosttySelectionContextActionPalette.fallbackFill)
                }
                .overlay {
                    shape.strokeBorder(GhosttySelectionContextActionPalette.stroke, lineWidth: 1)
                }
                .shadow(color: GhosttySelectionContextActionPalette.shadow, radius: 18, y: 10)
        }
    }

    @ViewBuilder
    func ghosttySheetActionSurface(isDestructive: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        if #available(iOS 26.0, *) {
            self
                .background(
                    isDestructive
                        ? GhosttySheetPalette.destructiveControlFill
                        : GhosttySheetPalette.controlFill,
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(GhosttySheetPalette.stroke, lineWidth: 1)
                }
        } else {
            self
                .background(
                    isDestructive
                        ? GhosttySheetPalette.destructiveControlFill
                        : GhosttySheetPalette.controlFill,
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(GhosttySheetPalette.stroke, lineWidth: 1)
                }
        }
    }
}
