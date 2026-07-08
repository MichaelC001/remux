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

    /// Resumes after everything already enqueued on the main queue ran,
    /// including the adapter's deferred pending-presentation rebuild.
    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testPendingPresentationHoldsUntilActiveSurfaceDisplays() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(session: session, initialViewportHandler: { _, _ in })

        session.handleTopology(TmuxSessionController.TopologySnapshot(
            sessionName: "pending-test",
            windows: [window(id: 1, active: true, paneID: 10)],
            panes: [pane(id: 10, windowID: 1)],
            activeWindowID: 1
        ))

        let tree = adapter.terminalScreenPresentationProjection.tree
        let activeLeaf = try XCTUnwrap(tree.selectedActiveLeafID)
        XCTAssertEqual(
            tree.pendingPresentationSurfaceID, activeLeaf,
            "an active pane with no displayed surface must hold presentation"
        )

        adapter.notePresentationSurfaceDisplayed(activeLeaf)
        await nextMainQueueTurn()

        XCTAssertNil(
            adapter.terminalScreenPresentationProjection.tree.pendingPresentationSurfaceID,
            "the hold must drop after the surface's first layout-sized display update"
        )

        await session.shutdown()
    }

    func testPendingPresentationFollowsActivePaneSwitch() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(session: session, initialViewportHandler: { _, _ in })

        session.handleTopology(TmuxSessionController.TopologySnapshot(
            sessionName: "pending-test",
            windows: [window(id: 1, active: true, paneID: 10)],
            panes: [pane(id: 10, windowID: 1), pane(id: 20, windowID: 1)],
            activeWindowID: 1
        ))
        let firstLeaf = try XCTUnwrap(
            adapter.terminalScreenPresentationProjection.tree.selectedActiveLeafID
        )
        adapter.notePresentationSurfaceDisplayed(firstLeaf)
        await nextMainQueueTurn()

        session.handleTopology(TmuxSessionController.TopologySnapshot(
            sessionName: "pending-test",
            windows: [window(id: 1, active: true, paneID: 20)],
            panes: [pane(id: 10, windowID: 1), pane(id: 20, windowID: 1)],
            activeWindowID: 1
        ))

        let tree = adapter.terminalScreenPresentationProjection.tree
        let secondLeaf = try XCTUnwrap(tree.selectedActiveLeafID)
        XCTAssertNotEqual(secondLeaf, firstLeaf)
        XCTAssertEqual(
            tree.pendingPresentationSurfaceID, secondLeaf,
            "switching the active pane must hold presentation until the new surface displays"
        )

        await session.shutdown()
    }

    func testPendingPresentationTimeoutDropsHoldUntilPaneChanges() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        let adapter = TmuxTerminalScreenAdapter()
        adapter.pendingPresentationTimeout = .milliseconds(40)
        adapter.activate(session: session, initialViewportHandler: { _, _ in })

        let firstTopology = TmuxSessionController.TopologySnapshot(
            sessionName: "pending-test",
            windows: [window(id: 1, active: true, paneID: 10)],
            panes: [pane(id: 10, windowID: 1), pane(id: 20, windowID: 1)],
            activeWindowID: 1
        )
        session.handleTopology(firstTopology)
        XCTAssertNotNil(
            adapter.terminalScreenPresentationProjection.tree.pendingPresentationSurfaceID
        )

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              adapter.terminalScreenPresentationProjection.tree.pendingPresentationSurfaceID != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(
            adapter.terminalScreenPresentationProjection.tree.pendingPresentationSurfaceID,
            "a pending surface that never displays must stop holding presentation"
        )

        session.handleTopology(firstTopology)
        XCTAssertNil(
            adapter.terminalScreenPresentationProjection.tree.pendingPresentationSurfaceID,
            "an abandoned pending pane must not re-hold until the active pane changes"
        )

        session.handleTopology(TmuxSessionController.TopologySnapshot(
            sessionName: "pending-test",
            windows: [window(id: 1, active: true, paneID: 20)],
            panes: [pane(id: 10, windowID: 1), pane(id: 20, windowID: 1)],
            activeWindowID: 1
        ))
        XCTAssertNotNil(
            adapter.terminalScreenPresentationProjection.tree.pendingPresentationSurfaceID,
            "a different active pane must hold presentation again"
        )

        await session.shutdown()
    }

    func testPanePreviewOptionsPreserveRequestedBudget() {
        let options = ghostty_surface_preview_image_options_s(
            max_width_px: 400,
            max_height_px: 300,
            include_cursor: true
        )
        let scaled = TmuxTerminalScreenAdapter.panePreviewOptions(
            options: options
        )

        XCTAssertEqual(scaled?.max_width_px, 400)
        XCTAssertEqual(scaled?.max_height_px, 300)
        XCTAssertEqual(scaled?.include_cursor, true)
    }

    func testPanePreviewRejectsSplitGeometryForRasterPreview() {
        XCTAssertFalse(TmuxTerminalScreenAdapter.canRenderPanePreview(
            previewSizing: .paneGrid(availableWidth: 361),
            paneWidth: 80,
            paneHeight: 24,
            windowWidth: 160,
            windowHeight: 24
        ))
        XCTAssertFalse(TmuxTerminalScreenAdapter.canRenderPanePreview(
            previewSizing: .paneGrid(availableWidth: 361),
            paneWidth: 160,
            paneHeight: 12,
            windowWidth: 160,
            windowHeight: 24
        ))
        XCTAssertTrue(TmuxTerminalScreenAdapter.canRenderPanePreview(
            previewSizing: .paneGrid(availableWidth: 361),
            paneWidth: 160,
            paneHeight: 24,
            windowWidth: 160,
            windowHeight: 24
        ))
    }

    func testPanePreviewGridUsesFullWindowGeometry() {
        let grid = TmuxTerminalScreenAdapter.panePreviewGrid(
            windowWidth: 160,
            windowHeight: 24,
            cellWidthPx: 10,
            cellHeightPx: 20,
            budgetWidthPx: 400,
            budgetHeightPx: 300
        )
        XCTAssertEqual(grid, TmuxSessionController.ClientSize(cols: 160, rows: 24))
    }

    func testPanePreviewGridCropsTallPanesToTileAspect() {
        let grid = TmuxTerminalScreenAdapter.panePreviewGrid(
            windowWidth: 160,
            windowHeight: 200,
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
                windowWidth: 0,
                windowHeight: 24,
                cellWidthPx: 10,
                cellHeightPx: 20,
                budgetWidthPx: 400,
                budgetHeightPx: 300
            )
        )
        XCTAssertNil(
            TmuxTerminalScreenAdapter.panePreviewGrid(
                windowWidth: 160,
                windowHeight: 0,
                cellWidthPx: 10,
                cellHeightPx: 20,
                budgetWidthPx: 400,
                budgetHeightPx: 300
            )
        )
        XCTAssertNil(
            TmuxTerminalScreenAdapter.panePreviewGrid(
                windowWidth: 160,
                windowHeight: 24,
                cellWidthPx: 0,
                cellHeightPx: 20,
                budgetWidthPx: 400,
                budgetHeightPx: 300
            )
        )
        XCTAssertNil(
            TmuxTerminalScreenAdapter.panePreviewGrid(
                windowWidth: 160,
                windowHeight: 24,
                cellWidthPx: 10,
                cellHeightPx: 20,
                budgetWidthPx: 0,
                budgetHeightPx: 300
            )
        )
        XCTAssertNil(
            TmuxTerminalScreenAdapter.panePreviewOptions(
                options: ghostty_surface_preview_image_options_s(
                    max_width_px: 0,
                    max_height_px: 300,
                    include_cursor: true
                )
            )
        )
    }
}
