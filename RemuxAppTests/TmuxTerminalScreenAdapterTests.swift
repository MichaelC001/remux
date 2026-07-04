import GhosttyKit
import XCTest

@testable import Remux

@MainActor
final class TmuxTerminalScreenAdapterTests: XCTestCase {
    private func makeSession(runtime: GhosttyKitRuntime) -> TmuxTerminalSession {
        TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            makeTransport: { DeterministicTmuxControlTransport(chunks: []) },
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark },
            createPaneSurface: { _, _, _, _, _, completion in
                completion(.failure(.surfaceCreationFailed))
            }
        )
    }

    private func window(
        id: UInt64,
        active: Bool,
        paneID: UInt64
    ) -> TmuxSessionController.WindowInfo {
        TmuxSessionController.WindowInfo(
            id: id,
            name: "w\(id)",
            active: active,
            zoomed: true,
            width: 80,
            height: 24,
            activePaneID: paneID
        )
    }

    private func pane(id: UInt64, windowID: UInt64) -> TmuxSessionController.PaneInfo {
        TmuxSessionController.PaneInfo(
            id: id,
            windowID: windowID,
            x: 0,
            y: 0,
            width: 80,
            height: 24,
            state: .live
        )
    }

    func testWindowProjectionReflectsEmittedTopologyImmediately() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(session: session, initialViewportHandler: { _, _ in })

        let twoWindows = TmuxSessionController.TopologySnapshot(
            sessionName: "fresh-test",
            windows: [
                window(id: 1, active: true, paneID: 10),
                window(id: 2, active: false, paneID: 20)
            ],
            panes: [pane(id: 10, windowID: 1), pane(id: 20, windowID: 2)],
            activeWindowID: 1
        )
        session.handleTopology(twoWindows)

        let first = adapter.windowSelectionSheetRenderProjection()
        XCTAssertEqual(
            first.windows.count, 2,
            "the first emitted topology must project immediately, not lag one update behind"
        )

        let oneWindow = TmuxSessionController.TopologySnapshot(
            sessionName: "fresh-test",
            windows: [window(id: 1, active: true, paneID: 10)],
            panes: [pane(id: 10, windowID: 1)],
            activeWindowID: 1
        )
        session.handleTopology(oneWindow)

        let second = adapter.windowSelectionSheetRenderProjection()
        XCTAssertEqual(
            second.windows.count, 1,
            "removing a non-current window must drop its tile on the same topology update"
        )
        XCTAssertEqual(second.windows.first?.totalCount, 1)
        XCTAssertEqual(second.cellCount, 1)

        await session.shutdown()
    }

    func testPanePreviewOptionsScaleWidthForSplitPane() {
        let options = ghostty_surface_preview_image_options_s(
            max_width_px: 400,
            max_height_px: 300,
            include_cursor: true
        )
        let scaled = TmuxTerminalScreenAdapter.panePreviewOptions(
            options: options,
            paneWidth: 80,
            windowWidth: 160
        )

        XCTAssertEqual(scaled?.max_width_px, 200)
        XCTAssertEqual(scaled?.max_height_px, 300)
        XCTAssertEqual(scaled?.include_cursor, true)
    }

    func testPanePreviewGridPreservesWindowScaleForSplitPane() {
        let grid = TmuxTerminalScreenAdapter.panePreviewGrid(
            paneWidth: 80,
            paneHeight: 24,
            windowWidth: 160,
            cellWidthPx: 10,
            cellHeightPx: 20,
            budgetWidthPx: 200,
            budgetHeightPx: 300
        )
        XCTAssertEqual(grid, TmuxSessionController.ClientSize(cols: 80, rows: 24))
    }

    func testPanePreviewGridCropsTallPanesToTileAspect() {
        let grid = TmuxTerminalScreenAdapter.panePreviewGrid(
            paneWidth: 160,
            paneHeight: 200,
            windowWidth: 160,
            cellWidthPx: 10,
            cellHeightPx: 20,
            budgetWidthPx: 400,
            budgetHeightPx: 300
        )
        XCTAssertEqual(grid, TmuxSessionController.ClientSize(cols: 160, rows: 60))
    }

    func testPanePreviewGridRequiresRealGeometry() {
        XCTAssertNil(
            TmuxTerminalScreenAdapter.panePreviewGrid(
                paneWidth: 0,
                paneHeight: 24,
                windowWidth: 160,
                cellWidthPx: 10,
                cellHeightPx: 20,
                budgetWidthPx: 400,
                budgetHeightPx: 300
            )
        )
        XCTAssertNil(
            TmuxTerminalScreenAdapter.panePreviewGrid(
                paneWidth: 80,
                paneHeight: 24,
                windowWidth: 0,
                cellWidthPx: 10,
                cellHeightPx: 20,
                budgetWidthPx: 400,
                budgetHeightPx: 300
            )
        )
        XCTAssertNil(
            TmuxTerminalScreenAdapter.panePreviewGrid(
                paneWidth: 80,
                paneHeight: 24,
                windowWidth: 160,
                cellWidthPx: 0,
                cellHeightPx: 20,
                budgetWidthPx: 400,
                budgetHeightPx: 300
            )
        )
        XCTAssertNil(
            TmuxTerminalScreenAdapter.panePreviewGrid(
                paneWidth: 80,
                paneHeight: 24,
                windowWidth: 160,
                cellWidthPx: 10,
                cellHeightPx: 20,
                budgetWidthPx: 0,
                budgetHeightPx: 300
            )
        )
        XCTAssertNil(
            TmuxTerminalScreenAdapter.panePreviewOptions(
                options: ghostty_surface_preview_image_options_s(
                    max_width_px: 400,
                    max_height_px: 300,
                    include_cursor: true
                ),
                paneWidth: 0,
                windowWidth: 160
            )
        )
    }
}
