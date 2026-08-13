import CoreGraphics
import UIKit

/// Single source of truth for window-preview geometry and capture budgets.
///
/// Used by:
/// - `GhosttyPanePreviewSession` for the local image budget
/// - the window selection sheet for preview placement
///
/// Capture once per session at session-init time. Rotation while a selection
/// sheet is open does not justify reissuing previews; we keep the originally
/// requested image regardless.
enum PanePreviewLayout {
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

}
