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
    }

    func testTwoPaneUsesTwoColumnGridLayout() {
        let metrics = PanePreviewLayout.metrics(for: 2, availableWidth: 361)

        XCTAssertEqual(metrics.columnCount, 2)
        XCTAssertEqual(metrics.tilePointSize, CGSize(width: 175, height: 156))
        XCTAssertEqual(metrics.previewPointSize, CGSize(width: 159, height: 120))
    }

    func testThreePaneKeepsTwoColumnTileGeometry() {
        let twoPane = PanePreviewLayout.metrics(for: 2, availableWidth: 361)
        let threePane = PanePreviewLayout.metrics(for: 3, availableWidth: 361)

        XCTAssertEqual(threePane.columnCount, 2)
        XCTAssertEqual(threePane.previewPointSize, twoPane.previewPointSize)
    }

    func testWindowGridUsesTwoColumnTileBudget() {
        let metrics = PanePreviewLayout.windowMetrics(availableWidth: 361)

        XCTAssertEqual(metrics.columnCount, 2)
        XCTAssertEqual(metrics.tilePointSize, CGSize(width: 175, height: 172))
        XCTAssertEqual(metrics.previewPointSize, CGSize(width: 159, height: 120))
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
