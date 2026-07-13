import GhosttyKit
import XCTest

@testable import Remux

@MainActor
final class TmuxTerminalScreenAdapterTests: XCTestCase {
    func testCellSizeRuntimeActionIsPreservedAsViewportSignal() {
        var native = ghostty_action_s()
        native.tag = GHOSTTY_ACTION_CELL_SIZE

        XCTAssertEqual(GhosttyRuntimeSurfaceAction(native: native), .cellSize)
    }

    func testIdentityRegistryKeepsPaneRoundTripStable() {
        var registry = TmuxTerminalIdentityRegistry()
        let paneID = TmuxPaneID(41)

        let surfaceID = registry.surfaceID(for: paneID)

        XCTAssertEqual(registry.surfaceID(for: paneID), surfaceID)
        XCTAssertEqual(registry.paneID(for: surfaceID), paneID)
        XCTAssertNil(registry.paneID(for: UUID()))
    }

    func testIdentityRegistryKeepsWindowRoundTripStable() {
        var registry = TmuxTerminalIdentityRegistry()
        let windowID = TmuxWindowID(17)

        let surfaceID = registry.surfaceID(for: windowID)

        XCTAssertEqual(registry.surfaceID(for: windowID), surfaceID)
        XCTAssertEqual(registry.windowID(for: surfaceID), windowID)
        XCTAssertNil(registry.windowID(for: UUID()))
    }

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
        id: TmuxWindowID,
        active: Bool,
        paneID: TmuxPaneID?,
        zoomed: Bool = true
    ) -> TmuxSessionController.WindowInfo {
        TmuxSessionController.WindowInfo(
            id: id,
            name: "w\(id)",
            active: active,
            zoomed: zoomed,
            width: 80,
            height: 24,
            activePaneID: paneID
        )
    }

    private func pane(
        id: TmuxPaneID,
        windowID: TmuxWindowID
    ) -> TmuxSessionController.PaneInfo {
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

    func testGroupedWindowSelectionRequiresCanonicalUnzoomedSplitTarget() {
        let targetWindow = window(id: 2, active: false, paneID: 20, zoomed: false)
        let targetPanes = [pane(id: 20, windowID: 2), pane(id: 21, windowID: 2)]
        func groupedPane(
            for target: TmuxSessionController.WindowInfo,
            panes: [TmuxSessionController.PaneInfo] = targetPanes,
            activeWindowID: TmuxWindowID? = 1
        ) -> TmuxPaneID? {
            let topology = TmuxSessionController.TopologySnapshot(
                sessionName: "grouped-selection",
                windows: [window(id: 1, active: true, paneID: 10), target],
                panes: [pane(id: 10, windowID: 1)] + panes,
                activeWindowID: activeWindowID
            )
            return TmuxTerminalScreenAdapter.groupedWindowSelectionPane(
                for: target,
                in: topology
            )
        }

        XCTAssertEqual(groupedPane(for: targetWindow), 20)
        XCTAssertNil(groupedPane(for: targetWindow, activeWindowID: 2))
        XCTAssertNil(groupedPane(for: targetWindow, activeWindowID: nil))
        XCTAssertNil(groupedPane(
            for: window(id: 2, active: false, paneID: 20, zoomed: true)
        ))
        XCTAssertNil(groupedPane(
            for: window(id: 2, active: false, paneID: nil, zoomed: false)
        ))
        XCTAssertNil(groupedPane(for: targetWindow, panes: [targetPanes[0]]))
        XCTAssertNil(groupedPane(for: targetWindow, panes: [targetPanes[1]]))
    }

    func testWindowProjectionReflectsEmittedTopologyImmediately() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(
            session: session,
            initialViewportHandler: { _, _ in },
            clientSizeHandler: { _ in }
        )

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

    func testTopologyNeverPublishesOutgoingFrameHold() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(
            session: session,
            initialViewportHandler: { _, _ in },
            clientSizeHandler: { _ in }
        )

        session.handleTopology(TmuxSessionController.TopologySnapshot(
            sessionName: "background-test",
            windows: [window(id: 1, active: true, paneID: 10)],
            panes: [pane(id: 10, windowID: 1), pane(id: 20, windowID: 1)],
            activeWindowID: 1
        ))
        XCTAssertNil(
            adapter.terminalScreenPresentationProjection.viewport.pendingPresentationID
        )

        session.handleTopology(TmuxSessionController.TopologySnapshot(
            sessionName: "background-test",
            windows: [window(id: 1, active: true, paneID: 20)],
            panes: [pane(id: 10, windowID: 1), pane(id: 20, windowID: 1)],
            activeWindowID: 1
        ))
        XCTAssertNil(
            adapter.terminalScreenPresentationProjection.viewport.pendingPresentationID
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

    func testPanePreviewCacheEvictsLeastRecentlyUsedImageWithinByteLimit() throws {
        let first = try makeImage(width: 4, height: 4)
        let second = try makeImage(width: 4, height: 4)
        let third = try makeImage(width: 4, height: 4)
        let imageCost = first.bytesPerRow * first.height
        var cache = TmuxPanePreviewImageCache(byteLimit: imageCost * 2)

        XCTAssertEqual(cache.store(preview(first), for: 1), [])
        XCTAssertEqual(cache.store(preview(second), for: 2), [])
        XCTAssertNotNil(cache.preview(for: 1), "reading pane 1 must refresh its LRU age")
        XCTAssertEqual(cache.store(preview(third), for: 3), [2])
        XCTAssertNotNil(cache.preview(for: 1))
        XCTAssertNil(cache.preview(for: 2))
        XCTAssertNotNil(cache.preview(for: 3))
        XCTAssertEqual(cache.totalByteCost, imageCost * 2)
    }

    func testPanePreviewCacheDropsRemovedTopologyPanes() throws {
        let image = try makeImage(width: 4, height: 4)
        var cache = TmuxPanePreviewImageCache(byteLimit: 1024)
        cache.store(preview(image), for: 1)
        cache.store(preview(image), for: 2)

        XCTAssertEqual(Set(cache.retainOnly(Set([2]))), Set([1]))
        XCTAssertNil(cache.preview(for: 1))
        XCTAssertNotNil(cache.preview(for: 2))
    }

    func testPanePreviewCacheRejectsImageLargerThanByteLimit() throws {
        let image = try makeImage(width: 4, height: 4)
        var cache = TmuxPanePreviewImageCache(
            byteLimit: image.bytesPerRow * image.height - 1
        )

        XCTAssertEqual(cache.store(preview(image), for: 1), [])
        XCTAssertNil(cache.preview(for: 1))
        XCTAssertEqual(cache.totalByteCost, 0)
    }

    func testPanePreviewCacheRetainsFullViewportProvenance() throws {
        let image = try makeImage(width: 4, height: 4)
        let expected = provenance()
        var cache = TmuxPanePreviewImageCache(byteLimit: 1024)

        cache.store(
            .init(image: image, source: .fullViewport(expected)),
            for: 1
        )

        XCTAssertEqual(cache.entries[1]?.preview.source, .fullViewport(expected))
    }

    func testPanePreviewCacheRetainsRemoteGeometrySource() throws {
        let image = try makeImage(width: 4, height: 4)
        var cache = TmuxPanePreviewImageCache(byteLimit: 1024)

        cache.store(preview(image), for: 1)

        XCTAssertEqual(cache.preview(for: 1)?.source, .remotePaneGeometry)
    }

    func testPanePreviewOptionsRequireNonzeroPixelBudget() {
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

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private func provenance() -> GhosttyPanePreviewSession.FullViewportProvenance {
        GhosttyPanePreviewSession.FullViewportProvenance(
            surfaceID: UUID(),
            pixelWidth: 390,
            pixelHeight: 709
        )
    }

    private func preview(
        _ image: CGImage
    ) -> GhosttyPanePreviewSession.RenderedPreview {
        .init(image: image, source: .remotePaneGeometry)
    }
}
