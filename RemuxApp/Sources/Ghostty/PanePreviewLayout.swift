import CoreGraphics
import UIKit

/// Single source of truth for terminal preview geometry and capture budgets.
///
/// Used by:
/// - `GhosttyPanePreviewSession` for the local image budget
/// - the window and pane selection sheets for preview placement
///
/// Capture once per session at session-init time. Rotation while a selection
/// sheet is open does not justify reissuing previews; we keep the originally
/// requested image regardless.
enum PanePreviewLayout {
    struct TopologyPane: Equatable {
        let id: UUID
        let frame: GhosttyTerminalGridRect
    }

    struct TopologyMetrics: Equatable {
        let framesByPaneID: [UUID: CGRect]
        let orderedPaneIDs: [UUID]

        func frame(for paneID: UUID) -> CGRect? {
            framesByPaneID[paneID]
        }
    }

    struct PanePickerMetrics: Equatable {
        let topologySize: CGSize
        let cardSize: CGSize
        let columnCount: Int
        let gridSpacing: CGFloat
        let sectionSpacing: CGFloat
        let visibleContentHeight: CGFloat

        func gridHeight(itemCount: Int) -> CGFloat {
            guard itemCount > 0 else { return 0 }
            let rows = (itemCount + columnCount - 1) / columnCount
            return CGFloat(rows) * cardSize.height
                + CGFloat(rows - 1) * gridSpacing
        }

        func cardViewportHeight(itemCount: Int) -> CGFloat {
            min(
                gridHeight(itemCount: itemCount),
                max(1, visibleContentHeight - topologySize.height - sectionSpacing)
            )
        }
    }

    struct Metrics: Equatable {
        let columnCount: Int
        let tilePointSize: CGSize
        /// Snapshot budget remains independent from the visual card size.
        /// Card chrome can change without increasing renderer work.
        let capturePointSize: CGSize
        let gridSpacing: CGFloat

        func gridHeight(itemCount: Int) -> CGFloat {
            guard itemCount > 0 else { return 0 }
            let rows = (itemCount + columnCount - 1) / columnCount
            return CGFloat(rows) * tilePointSize.height
                + CGFloat(rows - 1) * gridSpacing
        }
    }

    /// Height for a selector sheet's scrollable grid. The whole grid shows
    /// exactly whenever it fits within the height budget — the sheet grows
    /// rather than hiding part of the final row. Only grids larger than the
    /// budget scroll, showing complete rows plus half of the next tile so
    /// the cut is an unmistakable scroll affordance.
    static func gridIdealHeight(
        itemCount: Int,
        metrics: Metrics,
        maximumContentHeight: CGFloat
    ) -> CGFloat {
        let fullHeight = metrics.gridHeight(itemCount: itemCount)
        let budget = max(0, maximumContentHeight)
        guard fullHeight > budget else { return fullHeight }
        guard budget > 0 else { return 0 }

        let tile = metrics.tilePointSize.height
        let spacing = metrics.gridSpacing
        let peek = tile * 0.5

        func completedHeight(rows: Int) -> CGFloat {
            CGFloat(rows) * tile + CGFloat(max(0, rows - 1)) * spacing
        }

        var rows = 0
        while completedHeight(rows: rows + 1) <= budget {
            rows += 1
        }
        guard rows > 0 else { return budget }

        let heightWithPeek = completedHeight(rows: rows) + spacing + peek
        return min(heightWithPeek, fullHeight, budget)
    }

    private static let defaultSheetContentWidth: CGFloat = 361
    private static let sheetHorizontalPadding: CGFloat = 32
    private static let defaultPreviewAspectRatio: CGFloat = 4.0 / 3.0
    private static let previewCaptureHorizontalInset: CGFloat = 8
    private static let previewCardHeightRatio: CGFloat = 1.10

    /// Window grid uses a fixed two-column layout. The "New Window" affordance
    /// is a fixed sheet action, not a trailing grid cell, so dense sessions can
    /// scroll windows without hiding the create command.
    private static let windowGridColumnCount: Int = 2
    private static let windowGridSpacing: CGFloat = 10

    private static let panePickerColumnCount: Int = 2
    private static let panePickerGridSpacing: CGFloat = 10
    private static let panePickerSectionSpacing: CGFloat = 12

    /// Display scale captured once at session init. Avoids touching
    /// UIScreen.main during request construction or rendering.
    @MainActor
    static func currentScale() -> CGFloat {
        let scale = UIScreen.main.scale
        return scale.isFinite && scale > 0 ? scale : 1
    }

    @MainActor
    static func currentSheetContentWidth() -> CGFloat {
        let width = UIScreen.main.bounds.width - sheetHorizontalPadding
        return width.isFinite && width > 0 ? width : defaultSheetContentWidth
    }

    static func panePickerMetrics(
        itemCount: Int,
        availableWidth: CGFloat,
        maximumContentHeight: CGFloat
    ) -> PanePickerMetrics {
        let safeWidth = max(1, availableWidth)
        let totalGridSpacing = CGFloat(panePickerColumnCount - 1) * panePickerGridSpacing
        let cardWidth = max(
            1,
            floor((safeWidth - totalGridSpacing) / CGFloat(panePickerColumnCount))
        )
        let cardHeight = ceil(cardWidth * previewCardHeightRatio)
        let topologyHeight = min(112, max(88, safeWidth * 0.28))
        let topologySize = CGSize(width: safeWidth, height: topologyHeight)
        let rows = max(0, (itemCount + panePickerColumnCount - 1) / panePickerColumnCount)
        let fullGridHeight: CGFloat = if rows == 0 {
            0
        } else {
            CGFloat(rows) * cardHeight
                + CGFloat(rows - 1) * panePickerGridSpacing
        }
        let fullContentHeight = topologyHeight
            + (rows == 0 ? 0 : panePickerSectionSpacing + fullGridHeight)

        return PanePickerMetrics(
            topologySize: topologySize,
            cardSize: CGSize(width: cardWidth, height: cardHeight),
            columnCount: panePickerColumnCount,
            gridSpacing: panePickerGridSpacing,
            sectionSpacing: panePickerSectionSpacing,
            visibleContentHeight: min(max(0, maximumContentHeight), fullContentHeight)
        )
    }

    static func topologyMetrics(
        panes: [TopologyPane],
        size: CGSize
    ) -> TopologyMetrics? {
        guard size.width.isFinite, size.width > 0,
              size.height.isFinite, size.height > 0,
              let topology = PaneTopology(panes: panes)
        else { return nil }

        var framesByPaneID: [UUID: CGRect] = [:]
        topology.place(
            in: CGRect(origin: .zero, size: size),
            framesByPaneID: &framesByPaneID
        )
        var orderedPaneIDs: [UUID] = []
        orderedPaneIDs.reserveCapacity(panes.count)
        topology.appendPaneIDs(to: &orderedPaneIDs)
        return TopologyMetrics(
            framesByPaneID: framesByPaneID,
            orderedPaneIDs: orderedPaneIDs
        )
    }

    @MainActor
    static func windowMetricsForCurrentScreen() -> Metrics {
        windowMetrics(availableWidth: currentSheetContentWidth())
    }

    static func windowMetrics(
        availableWidth: CGFloat
    ) -> Metrics {
        let safeAvailableWidth = max(availableWidth, 1)
        let columnCount = windowGridColumnCount
        let totalGridSpacing = CGFloat(columnCount - 1) * windowGridSpacing
        let tileWidth = max(
            1,
            floor((safeAvailableWidth - totalGridSpacing) / CGFloat(columnCount))
        )
        let captureWidth = max(1, tileWidth - previewCaptureHorizontalInset * 2)
        let captureHeight = ceil(captureWidth / defaultPreviewAspectRatio)
        let tileHeight = ceil(tileWidth * previewCardHeightRatio)
        return .init(
            columnCount: columnCount,
            tilePointSize: CGSize(width: tileWidth, height: tileHeight),
            capturePointSize: CGSize(width: captureWidth, height: captureHeight),
            gridSpacing: windowGridSpacing
        )
    }

    static func windowPhysicalPixelBudget(
        availableWidth: CGFloat,
        scale: CGFloat
    ) -> (width: UInt32, height: UInt32) {
        let metrics = windowMetrics(availableWidth: availableWidth)
        let safeScale = max(scale, 1)
        let widthPx = (metrics.capturePointSize.width * safeScale).rounded(.up)
        let heightPx = (metrics.capturePointSize.height * safeScale).rounded(.up)
        return (
            clampUInt32(widthPx),
            clampUInt32(heightPx)
        )
    }

    private static func clampUInt32(_ value: CGFloat) -> UInt32 {
        guard value.isFinite, value > 0 else { return 1 }
        let clamped = min(value, CGFloat(UInt32.max))
        return max(1, UInt32(clamped))
    }

    private indirect enum PaneTopology {
        case pane(UUID)
        case split(Axis, PaneTopology, PaneTopology)

        enum Axis {
            case horizontal
            case vertical
        }

        init?(panes: [TopologyPane]) {
            guard !panes.isEmpty else { return nil }
            if panes.count == 1 {
                self = .pane(panes[0].id)
                return
            }

            if let groups = Self.partition(panes, axis: .horizontal),
               let first = PaneTopology(panes: groups.0),
               let second = PaneTopology(panes: groups.1) {
                self = .split(.horizontal, first, second)
                return
            }
            if let groups = Self.partition(panes, axis: .vertical),
               let first = PaneTopology(panes: groups.0),
               let second = PaneTopology(panes: groups.1) {
                self = .split(.vertical, first, second)
                return
            }
            return nil
        }

        private var paneCount: Int {
            switch self {
            case .pane:
                1
            case .split(_, let first, let second):
                first.paneCount + second.paneCount
            }
        }

        func place(
            in frame: CGRect,
            framesByPaneID: inout [UUID: CGRect]
        ) {
            switch self {
            case .pane(let id):
                framesByPaneID[id] = frame

            case .split(let axis, let first, let second):
                let firstFraction = CGFloat(first.paneCount) / CGFloat(paneCount)
                let firstFrame: CGRect
                let secondFrame: CGRect
                switch axis {
                case .horizontal:
                    let firstWidth = frame.width * firstFraction
                    firstFrame = CGRect(
                        x: frame.minX,
                        y: frame.minY,
                        width: firstWidth,
                        height: frame.height
                    )
                    secondFrame = CGRect(
                        x: firstFrame.maxX,
                        y: frame.minY,
                        width: frame.width - firstWidth,
                        height: frame.height
                    )

                case .vertical:
                    let firstHeight = frame.height * firstFraction
                    firstFrame = CGRect(
                        x: frame.minX,
                        y: frame.minY,
                        width: frame.width,
                        height: firstHeight
                    )
                    secondFrame = CGRect(
                        x: frame.minX,
                        y: firstFrame.maxY,
                        width: frame.width,
                        height: frame.height - firstHeight
                    )
                }
                first.place(in: firstFrame, framesByPaneID: &framesByPaneID)
                second.place(in: secondFrame, framesByPaneID: &framesByPaneID)
            }
        }

        func appendPaneIDs(to paneIDs: inout [UUID]) {
            switch self {
            case .pane(let id):
                paneIDs.append(id)
            case .split(_, let first, let second):
                first.appendPaneIDs(to: &paneIDs)
                second.appendPaneIDs(to: &paneIDs)
            }
        }

        private static func partition(
            _ panes: [TopologyPane],
            axis: Axis
        ) -> ([TopologyPane], [TopologyPane])? {
            let sorted = panes.sorted {
                axis == .horizontal
                    ? $0.frame.x < $1.frame.x
                    : $0.frame.y < $1.frame.y
            }
            for index in 1..<sorted.count {
                let first = Array(sorted[..<index])
                let second = Array(sorted[index...])
                let firstEnd = first.map {
                    axis == .horizontal ? $0.maxX : $0.maxY
                }.max() ?? 0
                let secondStart = second.map {
                    axis == .horizontal ? $0.frame.x : $0.frame.y
                }.min() ?? 0
                if firstEnd < UInt64(secondStart) {
                    return (first, second)
                }
            }
            return nil
        }
    }
}

private extension PanePreviewLayout.TopologyPane {
    var maxX: UInt64 {
        UInt64(frame.x) + UInt64(frame.columns)
    }

    var maxY: UInt64 {
        UInt64(frame.y) + UInt64(frame.rows)
    }
}
