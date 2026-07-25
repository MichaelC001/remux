import CoreGraphics
import XCTest
@testable import Remux

final class PanePreviewLayoutTests: XCTestCase {
    func testSinglePaneUsesFeaturedLayout() {
        let single = PanePreviewLayout.metrics(for: 1, availableWidth: 361)
        let grid = PanePreviewLayout.metrics(for: 2, availableWidth: 361)

        XCTAssertEqual(single.columnCount, 1)
        XCTAssertEqual(single.tilePointSize.width, 361)
        XCTAssertEqual(single.previewPointSize, CGSize(width: 345, height: 259))
        XCTAssertGreaterThan(single.previewPointSize.width, grid.previewPointSize.width)
        XCTAssertEqual(single.sheetDetent, .fixed(457))
    }

    func testTwoPaneUsesTwoColumnGridLayout() {
        let metrics = PanePreviewLayout.metrics(for: 2, availableWidth: 361)

        XCTAssertEqual(metrics.columnCount, 2)
        XCTAssertEqual(metrics.tilePointSize, CGSize(width: 175, height: 156))
        XCTAssertEqual(metrics.previewPointSize, CGSize(width: 159, height: 120))
        XCTAssertEqual(metrics.sheetDetent, .fixed(318))
    }

    func testThreePaneUsesTwoRowsWithoutLargeDetentWaste() {
        let twoPane = PanePreviewLayout.metrics(for: 2, availableWidth: 361)
        let threePane = PanePreviewLayout.metrics(for: 3, availableWidth: 361)

        XCTAssertEqual(threePane.columnCount, 2)
        XCTAssertEqual(threePane.previewPointSize, twoPane.previewPointSize)
        XCTAssertEqual(threePane.sheetDetent, .fixed(484))
    }

    func testFivePaneUsesLargeDetent() {
        let metrics = PanePreviewLayout.metrics(for: 5, availableWidth: 361)

        XCTAssertEqual(metrics.columnCount, 2)
        XCTAssertEqual(metrics.sheetDetent, .large)
    }

    func testWindowGridUsesTwoColumnTileBudget() {
        let metrics = PanePreviewLayout.windowMetrics(cellCount: 2, availableWidth: 361)

        XCTAssertEqual(metrics.columnCount, 2)
        XCTAssertEqual(metrics.tilePointSize, CGSize(width: 175, height: 172))
        XCTAssertEqual(metrics.previewPointSize, CGSize(width: 159, height: 120))
        XCTAssertEqual(metrics.sheetDetent, .fixed(334))
    }

    func testWindowGridUsesLargeDetentAfterThreeRows() {
        XCTAssertEqual(
            PanePreviewLayout.windowMetrics(cellCount: 6, availableWidth: 361).sheetDetent,
            .fixed(698)
        )
        XCTAssertEqual(
            PanePreviewLayout.windowMetrics(cellCount: 7, availableWidth: 361).sheetDetent,
            .large
        )
    }

    func testPhysicalPixelBudgetTracksLayoutMetrics() {
        let budget = PanePreviewLayout.physicalPixelBudget(
            paneCount: 1,
            availableWidth: 361,
            scale: 3
        )

        XCTAssertEqual(budget.width, 1035)
        XCTAssertEqual(budget.height, 777)
    }

    func testWindowPhysicalPixelBudgetTracksWindowGridMetrics() {
        let budget = PanePreviewLayout.windowPhysicalPixelBudget(
            availableWidth: 361,
            scale: 3
        )

        XCTAssertEqual(budget.width, 477)
        XCTAssertEqual(budget.height, 360)
    }
}
