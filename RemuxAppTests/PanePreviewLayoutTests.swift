import CoreGraphics
import XCTest
@testable import Remux

final class PanePreviewLayoutTests: XCTestCase {
    func testWindowGridUsesTwoColumnTileBudget() {
        let metrics = PanePreviewLayout.windowMetrics(availableWidth: 361)

        XCTAssertEqual(metrics.columnCount, 2)
        XCTAssertEqual(metrics.tilePointSize, CGSize(width: 175, height: 193))
        XCTAssertEqual(metrics.capturePointSize, CGSize(width: 159, height: 120))
    }

    func testWindowPhysicalPixelBudgetTracksWindowGridMetrics() {
        let budget = PanePreviewLayout.windowPhysicalPixelBudget(
            availableWidth: 361,
            scale: 3
        )

        XCTAssertEqual(budget.width, 477)
        XCTAssertEqual(budget.height, 360)
    }

    func testPanePickerUsesUniformTwoColumnCardsAndCapsDenseContent() {
        let metrics = PanePreviewLayout.panePickerMetrics(
            itemCount: 10,
            availableWidth: 361,
            maximumContentHeight: 520
        )

        XCTAssertEqual(metrics.columnCount, 2)
        XCTAssertEqual(metrics.cardSize.width, 175, accuracy: 0.001)
        XCTAssertEqual(metrics.cardSize.height, 193, accuracy: 0.001)
        XCTAssertEqual(metrics.topologySize.width, 361, accuracy: 0.001)
        XCTAssertEqual(metrics.visibleContentHeight, 520, accuracy: 0.001)
        XCTAssertLessThan(
            metrics.cardViewportHeight(itemCount: 10),
            metrics.gridHeight(itemCount: 10)
        )
    }

    func testPanePickerDoesNotReserveACardRowForZeroPanes() {
        let metrics = PanePreviewLayout.panePickerMetrics(
            itemCount: 0,
            availableWidth: 361,
            maximumContentHeight: 520
        )

        XCTAssertEqual(metrics.gridHeight(itemCount: 0), 0)
        XCTAssertEqual(metrics.cardViewportHeight(itemCount: 0), 0)
        XCTAssertEqual(metrics.visibleContentHeight, metrics.topologySize.height)
    }

    func testTopologyPreservesSplitStructureWithEqualPaneArea() throws {
        let panes = fivePaneTopology()
        let metrics = try XCTUnwrap(PanePreviewLayout.topologyMetrics(
            panes: panes,
            size: CGSize(width: 360, height: 100)
        ))
        let frames = try panes.map { try XCTUnwrap(metrics.frame(for: $0.id)) }
        let expectedArea = frames[0].width * frames[0].height

        for frame in frames {
            XCTAssertEqual(frame.width * frame.height, expectedArea, accuracy: 0.01)
        }
        XCTAssertEqual(frames[0].minX, 0, accuracy: 0.001)
        XCTAssertEqual(frames[1].minX, 0, accuracy: 0.001)
        XCTAssertEqual(frames[2].minX, frames[0].maxX, accuracy: 0.001)
        XCTAssertEqual(frames[3].minX, frames[0].maxX, accuracy: 0.001)
        XCTAssertEqual(frames[4].minX, frames[0].maxX, accuracy: 0.001)
        XCTAssertEqual(frames[0].maxY, frames[1].minY, accuracy: 0.001)
        XCTAssertEqual(frames[2].maxY, frames[3].minY, accuracy: 0.001)
        XCTAssertEqual(frames[3].maxY, frames[4].minY, accuracy: 0.001)
        XCTAssertEqual(metrics.orderedPaneIDs, panes.map(\.id))
    }

    private func fivePaneTopology() -> [PanePreviewLayout.TopologyPane] {
        [
            .init(id: UUID(), frame: .init(x: 0, y: 0, columns: 39, rows: 59)),
            .init(id: UUID(), frame: .init(x: 0, y: 60, columns: 39, rows: 40)),
            .init(id: UUID(), frame: .init(x: 40, y: 0, columns: 60, rows: 9)),
            .init(id: UUID(), frame: .init(x: 40, y: 10, columns: 60, rows: 69)),
            .init(id: UUID(), frame: .init(x: 40, y: 80, columns: 60, rows: 20)),
        ]
    }
}
