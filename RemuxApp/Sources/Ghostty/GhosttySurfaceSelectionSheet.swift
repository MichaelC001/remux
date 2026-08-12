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

    var paneTopLevelIDForTopologyValidation: UUID? {
        switch self {
        case .windows(_):
            nil
        case .panes(let topLevelID, _):
            topLevelID
        }
    }
}

struct GhosttyWindowSelectionSheet: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @ObservedObject var session: GhosttyPanePreviewSession
    @State private var pendingRemoval: GhosttyWindowRemovalRequest?
    @State private var pendingContextAction: GhosttyWindowRemovalRequest?

    let projection: GhosttyWindowSelectionSheetRenderProjection
    let sessionName: String
    let commandFailureMessage: String?
    let onCreateWindow: (() -> Void)?
    let onSelect: (UUID) -> Void
    let onRemoveWindow: (UUID) -> Void

    var body: some View {
        let layout = PanePreviewLayout.windowMetricsForCurrentScreen()

        TerminalSelectionSheetScaffold(
            title: "Windows",
            context: "\(sessionName) · \(projection.windows.count) \(projection.windows.count == 1 ? "window" : "windows")",
            closeAccessibilityIdentifier: "terminal.windows.close"
        ) {
            ScrollView(showsIndicators: false) {
                windowGrid(
                    windows: projection.windows,
                    layout: layout
                )
            }
            .accessibilityIdentifier("terminal.windows.scroll")
            .contentMargins(.horizontal, 16, for: .scrollContent)
        } actions: {
            TerminalSelectionSheetActionButton(
                title: "New Window",
                systemName: "plus",
                accessibilityIdentifier: "terminal.window.new",
                action: onCreateWindow
            )
        }
        .task(id: session.id) {
            session.reconcile(leafIDs: projection.previewLeafIDs)
            await Task.yield()
            guard !Task.isCancelled else { return }
            GhosttyRuntimeTrace.perf("panePreview.presentation activate kind=windows")
            session.startRefreshing()
        }
        .onChange(of: projection.previewLeafIDs) { _, newValue in
            session.reconcile(leafIDs: newValue)
            if let pendingContextAction, !newValue.contains(pendingContextAction.id) {
                self.pendingContextAction = nil
            }
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
        .overlay(alignment: .bottom) {
            if let commandFailureMessage {
                GhosttySelectionSheetFailureBanner(message: commandFailureMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, TerminalSelectionSheetLayout.actionBarHeight + 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: commandFailureMessage)
        .accessibilityElement(children: .contain)
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
                let request = GhosttyWindowRemovalRequest(
                    id: window.id,
                    displayIndex: window.displayIndex,
                    paneCount: window.paneCount
                )

                ZStack(alignment: .topTrailing) {
                    Button {
                        pendingContextAction = nil
                        Haptic.selection()
                        onSelect(window.id)
                    } label: {
                        GhosttyWindowSelectionTile(
                            displayIndex: window.displayIndex,
                            displayName: window.displayName,
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
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.42, maximumDistance: 18)
                            .onEnded { _ in
                                Haptic.warning()
                                pendingContextAction = request
                            }
                    )
                    .allowsHitTesting(pendingContextAction?.id != window.id)

                    if pendingContextAction?.id == window.id {
                        GhosttySelectionContextActionButton(
                            title: "Remove Window \(window.displayIndex)",
                            accessibilityIdentifier: "terminal.window.remove.\(window.displayIndex)",
                            action: confirmPendingContextAction
                        )
                        .padding(4)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
                .frame(width: layout.tilePointSize.width, height: layout.tilePointSize.height)
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: pendingContextAction?.id)
                .accessibilityAction(named: Text("Remove Window \(window.displayIndex)")) {
                    Haptic.warning()
                    pendingRemoval = request
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
    let commandFailureMessage: String?
    let onSplitPane: (() -> Void)?
    let onStackPane: (() -> Void)?
    let onSetZoomed: (Bool) -> Void
    let onSelect: (UUID) -> Void
    let onRemovePane: (UUID) -> Void

    var body: some View {
        TerminalSelectionSheetScaffold(
            title: "Panes",
            context: "\(projection.paneCount) \(projection.paneCount == 1 ? "pane" : "panes")",
            closeAccessibilityIdentifier: "terminal.panes.close"
        ) {
            panePicker
                .padding(.horizontal, 16)
        } actions: {
            HStack(spacing: 0) {
                GhosttyPaneSheetActionButton(
                    title: "Split",
                    systemName: "arrow.right",
                    accessibilityLabel: "Split right",
                    accessibilityIdentifier: "terminal.pane.split.right",
                    action: onSplitPane
                )

                GhosttyPaneSheetControlDivider()

                GhosttyPaneSheetActionButton(
                    title: "Split",
                    systemName: "arrow.down",
                    accessibilityLabel: "Split down",
                    accessibilityIdentifier: "terminal.pane.split.down",
                    action: onStackPane
                )

                if projection.paneCount > 1 {
                    GhosttyPaneSheetControlDivider()

                    GhosttyPaneSheetZoomControl(
                        isOn: Binding(
                            get: { projection.isServerZoomed },
                            set: { zoomed in onSetZoomed(zoomed) }
                        ),
                        accent: chromeStyle.accent
                    )
                }
            }
            .frame(height: TerminalSelectionSheetLayout.actionBarHeight)
            .terminalSelectionSheetControlGroupSurface()
        }
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
            if let pendingContextAction, !newValue.contains(pendingContextAction.id) {
                self.pendingContextAction = nil
            }
        }
        .confirmationDialog(
            "Remove Pane?",
            isPresented: pendingRemovalBinding,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { request in
            Button("Remove Pane", role: .destructive) {
                onRemovePane(request.id)
                pendingRemoval = nil
                pendingContextAction = nil
            }
            .accessibilityIdentifier("terminal.pane.remove.confirm")
        } message: { request in
            Text(paneRemovalMessage(for: request))
        }
        .overlay(alignment: .bottom) {
            if let commandFailureMessage {
                GhosttySelectionSheetFailureBanner(message: commandFailureMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, TerminalSelectionSheetLayout.actionBarHeight + 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: commandFailureMessage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.panes.sheet")
    }

    private var panePicker: some View {
        let metrics = PanePreviewLayout.panePickerMetricsForCurrentScreen(
            itemCount: projection.paneCount
        )
        let topology = paneTopologyMetrics(size: metrics.topologySize)
        let panesByID = Dictionary(uniqueKeysWithValues: projection.panes.map { ($0.id, $0) })
        let orderedPanes = topology?.orderedPaneIDs.compactMap { panesByID[$0] }
            ?? projection.panes
        let displayIndices = Dictionary(
            uniqueKeysWithValues: orderedPanes.enumerated().map { ($0.element.id, $0.offset + 1) }
        )

        return VStack(spacing: metrics.sectionSpacing) {
            GhosttyPaneTopologyDiagram(
                panes: orderedPanes,
                selectedPaneID: projection.selectedPaneID,
                layout: topology,
                displayIndices: displayIndices,
                size: metrics.topologySize,
                accent: chromeStyle.selectedStroke,
                onSelect: { paneID in
                    Haptic.selection()
                    pendingContextAction = nil
                    onSelect(paneID)
                }
            )

            if !orderedPanes.isEmpty {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(
                                .fixed(metrics.cardSize.width),
                                spacing: metrics.gridSpacing
                            ),
                            count: metrics.columnCount
                        ),
                        alignment: .center,
                        spacing: metrics.gridSpacing
                    ) {
                        ForEach(orderedPanes) { pane in
                            paneCard(
                                pane,
                                displayIndex: displayIndices[pane.id] ?? 1,
                                size: metrics.cardSize
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(height: metrics.cardViewportHeight(itemCount: projection.paneCount))
                .accessibilityIdentifier("terminal.panes.scroll")
            }
        }
        .frame(height: metrics.visibleContentHeight, alignment: .top)
        .accessibilityIdentifier("terminal.panes.picker")
    }

    private func paneCard(
        _ pane: GhosttyPaneSelectionSheetRenderProjection.Pane,
        displayIndex: Int,
        size: CGSize
    ) -> some View {
        let request = removalRequest(for: pane)

        return ZStack(alignment: .topTrailing) {
            Button {
                Haptic.selection()
                pendingContextAction = nil
                onSelect(pane.id)
            } label: {
                GhosttyPanePreviewCard(
                    displayIndex: displayIndex,
                    isSelected: pane.isSelected,
                    state: session.imagesByPaneID[pane.id],
                    size: size,
                    chromeStyle: chromeStyle
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("terminal.pane.tile.\(pane.id.uuidString)")
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.42, maximumDistance: 18)
                    .onEnded { _ in
                        Haptic.warning()
                        pendingContextAction = request
                    }
            )
            .allowsHitTesting(pendingContextAction?.id != pane.id)

            if pendingContextAction?.id == pane.id {
                GhosttySelectionContextActionButton(
                    title: "Remove Pane",
                    accessibilityIdentifier: "terminal.pane.remove.\(pane.id.uuidString)",
                    action: { performRemoval(request) }
                )
                .padding(4)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: pendingContextAction?.id)
        .accessibilityAction(named: Text("Remove Pane")) {
            Haptic.warning()
            pendingContextAction = request
        }
    }

    private func paneTopologyMetrics(
        size: CGSize
    ) -> PanePreviewLayout.TopologyMetrics? {
        let topologyPanes = projection.panes.compactMap { pane in
            pane.frame.map { PanePreviewLayout.TopologyPane(id: pane.id, frame: $0) }
        }
        guard topologyPanes.count == projection.panes.count else { return nil }
        return PanePreviewLayout.topologyMetrics(panes: topologyPanes, size: size)
    }

    private func removalRequest(
        for pane: GhosttyPaneSelectionSheetRenderProjection.Pane
    ) -> GhosttyPaneRemovalRequest {
        GhosttyPaneRemovalRequest(
            id: pane.id,
            isOnlyPane: projection.paneCount == 1
        )
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

    private func performRemoval(_ request: GhosttyPaneRemovalRequest) {
        if request.isOnlyPane {
            pendingRemoval = request
        } else {
            onRemovePane(request.id)
            pendingContextAction = nil
        }
    }

    private func paneRemovalMessage(for request: GhosttyPaneRemovalRequest) -> String {
        if request.isOnlyPane {
            return "This is the only pane in the window, so removing it can close the window too."
        }
        return "This will close the pane."
    }
}

private struct GhosttyWindowRemovalRequest: Identifiable {
    let id: UUID
    let displayIndex: Int
    let paneCount: Int
}

private struct GhosttyPaneRemovalRequest: Identifiable {
    let id: UUID
    let isOnlyPane: Bool
}

private struct GhosttySelectionSheetFailureBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemRed))
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TerminalSelectionSheetPalette.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(TerminalSelectionSheetPalette.stroke, lineWidth: 0.75)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 7)
        .accessibilityIdentifier("terminal.selection.failure")
    }
}

private struct GhosttySelectionContextActionButton: View {
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
                .frame(width: 44, height: 44)
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

private struct GhosttyRenderedPreviewSurface: View {
    let preview: GhosttyPanePreviewSession.RenderedPreview
    let size: CGSize

    var body: some View {
        Image(decorative: preview.image, scale: PanePreviewLayout.currentScale())
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .background(Color.black.opacity(0.30))
            .clipped()
    }

}

private struct GhosttyWindowSelectionTile: View {
    let displayIndex: Int
    let displayName: String
    let totalCount: Int
    let paneCount: Int
    let isSelected: Bool
    let previewState: GhosttyPanePreviewSession.PreviewState?
    let chromeStyle: GhosttyTerminalChromeStyle
    let layout: PanePreviewLayout.Metrics

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            previewSurface

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 58)
            .allowsHitTesting(false)

            metadata
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
        }
        .frame(
            width: layout.tilePointSize.width,
            height: layout.tilePointSize.height,
            alignment: .topLeading
        )
        .terminalSelectionTileChrome(isSelected: isSelected, chromeStyle: chromeStyle)
        .overlay(alignment: .topLeading) {
            GhosttyPreviewIndexBadge(
                displayIndex: displayIndex,
                isSelected: isSelected,
                chromeStyle: chromeStyle
            )
            .padding(8)
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
                size: layout.tilePointSize
            )

        case .pending, .none, .failed:
            Color.black.opacity(0.30)
                .frame(width: layout.tilePointSize.width, height: layout.tilePointSize.height)
        }
    }

    private var metadata: some View {
        HStack(spacing: 4) {
            Text(displayName.isEmpty ? "Window \(displayIndex)" : displayName)
                .fontWeight(.semibold)

            Text("·")

            Text("\(paneCount) \(paneCount == 1 ? "pane" : "panes")")

            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.white.opacity(0.94))
        .lineLimit(1)
        .truncationMode(.tail)
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
    }

    private var accessibilityLabel: String {
        let paneText = "\(paneCount) \(paneCount == 1 ? "pane" : "panes")"
        let positional = "Window \(displayIndex) of \(totalCount)"
        let named = displayName.isEmpty ? positional : "\(positional), \(displayName)"
        if isSelected {
            return "\(named), \(paneText), active"
        }
        return "\(named), \(paneText)"
    }
}

private struct GhosttyPanePreviewCard: View {
    let displayIndex: Int
    let isSelected: Bool
    let state: GhosttyPanePreviewSession.PreviewState?
    let size: CGSize
    let chromeStyle: GhosttyTerminalChromeStyle

    var body: some View {
        previewSurface(size: size)
            .frame(width: size.width, height: size.height)
            .terminalSelectionTileChrome(isSelected: isSelected, chromeStyle: chromeStyle)
            .overlay(alignment: .topLeading) {
                GhosttyPreviewIndexBadge(
                    displayIndex: displayIndex,
                    isSelected: isSelected,
                    chromeStyle: chromeStyle
                )
                    .padding(8)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(state.accessibilityValue)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityLabel: String {
        isSelected ? "Pane \(displayIndex), selected" : "Pane \(displayIndex)"
    }

    @ViewBuilder
    private func previewSurface(size: CGSize) -> some View {
        switch state {
        case .ready(let preview):
            Image(decorative: preview.image, scale: PanePreviewLayout.currentScale())
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()

        case .pending, .none, .failed:
            Color.black.opacity(0.30)
                .frame(width: size.width, height: size.height)
        }
    }
}

private struct GhosttyPreviewIndexBadge: View {
    let displayIndex: Int
    let isSelected: Bool
    let chromeStyle: GhosttyTerminalChromeStyle

    var body: some View {
        Text("\(displayIndex)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(
                isSelected
                    ? chromeStyle.accentForeground
                    : TerminalSelectionSheetPalette.primary
            )
            .frame(width: 28, height: 28)
            .background(
                isSelected
                    ? chromeStyle.accent
                    : TerminalSelectionSheetPalette.controlFill,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                if !isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(TerminalSelectionSheetPalette.stroke, lineWidth: 0.75)
                }
            }
    }
}

private struct GhosttyPaneTopologyDiagram: View {
    let panes: [GhosttyPaneSelectionSheetRenderProjection.Pane]
    let selectedPaneID: UUID?
    let layout: PanePreviewLayout.TopologyMetrics?
    let displayIndices: [UUID: Int]
    let size: CGSize
    let accent: Color
    let onSelect: (UUID) -> Void

    var body: some View {
        Canvas { context, _ in
            guard let layout else { return }
            for pane in panes {
                guard let frame = layout.frame(for: pane.id) else { continue }
                let tile = frame.insetBy(dx: 2, dy: 2)
                let radius = min(6, min(tile.width, tile.height) * 0.18)
                let path = Path(roundedRect: tile, cornerRadius: max(1, radius))
                let selected = pane.id == selectedPaneID
                context.fill(
                    path,
                    with: .color(
                        selected
                            ? accent.opacity(0.24)
                            : TerminalSelectionSheetPalette.row.opacity(0.84)
                    )
                )
                context.stroke(
                    path,
                    with: .color(selected ? accent : TerminalSelectionSheetPalette.stroke),
                    lineWidth: selected ? 2 : 1
                )

                if let displayIndex = displayIndices[pane.id] {
                    let labelSize = min(16, max(10, min(tile.width, tile.height) * 0.34))
                    let label = context.resolve(
                        Text("\(displayIndex)")
                            .font(.system(size: labelSize, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                selected ? accent : TerminalSelectionSheetPalette.primary
                            )
                    )
                    context.draw(
                        label,
                        at: CGPoint(x: tile.midX, y: tile.midY),
                        anchor: .center
                    )
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TerminalSelectionSheetPalette.stroke, lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            if let layout {
                ForEach(panes) { pane in
                    if let frame = layout.frame(for: pane.id) {
                        let tile = frame.insetBy(dx: 2, dy: 2)
                        Button {
                            onSelect(pane.id)
                        } label: {
                            Color.clear
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: tile.width, height: tile.height)
                        .offset(x: tile.minX, y: tile.minY)
                    }
                }
            }
        }
        .accessibilityIdentifier("terminal.panes.topology")
        .accessibilityHidden(true)
    }
}

private struct GhosttyPaneSheetActionButton: View {
    let title: String
    let systemName: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: (() -> Void)?

    var body: some View {
        Button {
            Haptic.tap()
            action?()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: systemName)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(TerminalSelectionSheetPalette.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(GhosttyPaneSheetActionButtonStyle(isEnabled: action != nil))
        .frame(maxWidth: .infinity)
        .frame(height: TerminalSelectionSheetLayout.actionBarHeight)
        .contentShape(Rectangle())
        .disabled(action == nil)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct GhosttyPaneSheetActionButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed && isEnabled
                    ? TerminalSelectionSheetPalette.controlPressedFill
                    : Color.clear
            )
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct GhosttyPaneSheetZoomControl: View {
    @Binding var isOn: Bool
    let accent: Color

    var body: some View {
        Toggle(isOn: $isOn) {
            Text("Zoom")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TerminalSelectionSheetPalette.primary)
                .lineLimit(1)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(accent)
        .padding(.horizontal, 11)
        .frame(height: TerminalSelectionSheetLayout.actionBarHeight)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .accessibilityLabel("Zoom")
        .accessibilityIdentifier("terminal.pane.zoom")
    }
}

private struct GhosttyPaneSheetControlDivider: View {
    var body: some View {
        Rectangle()
            .fill(TerminalSelectionSheetPalette.stroke)
            .frame(width: 0.75, height: 24)
            .accessibilityHidden(true)
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

}
