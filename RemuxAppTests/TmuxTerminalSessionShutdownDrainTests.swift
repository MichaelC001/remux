import XCTest

@testable import Remux

/// The async half of the teardown-race contract: `shutdown()` must wait
/// for an in-flight `TmuxPaneSurface.create` to resolve before it frees
/// the controller, because the late completion closes its surface
/// (`ghostty_surface_free` + `unbind`) and that is only safe while the
/// session it borrows is still alive. Driven through an injected creator
/// so the in-flight window is controllable without a live pane binding.
@MainActor
final class TmuxTerminalSessionShutdownDrainTests: XCTestCase {
    private func makeSession(
        runtime: GhosttyKitRuntime,
        createPaneSurface: @escaping TmuxTerminalSession.PaneSurfaceCreator
    ) -> TmuxTerminalSession {
        TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            makeTransport: { DeterministicTmuxControlTransport(chunks: []) },
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark },
            createPaneSurface: createPaneSurface
        )
    }

    private func snapshotPresentingPane(_ paneID: UInt64) -> TmuxSessionController.TopologySnapshot {
        TmuxSessionController.TopologySnapshot(
            sessionName: "drain-test",
            windows: [
                TmuxSessionController.WindowInfo(
                    id: 1,
                    name: "w",
                    active: true,
                    zoomed: true,
                    width: 80,
                    height: 24,
                    activePaneID: paneID
                )
            ],
            panes: [
                TmuxSessionController.PaneInfo(
                    id: paneID,
                    windowID: 1,
                    x: 0,
                    y: 0,
                    width: 80,
                    height: 24,
                    state: .live
                )
            ],
            activeWindowID: 1
        )
    }

    private func splitSnapshot(
        activePaneID: UInt64,
        zoomed: Bool
    ) -> TmuxSessionController.TopologySnapshot {
        TmuxSessionController.TopologySnapshot(
            sessionName: "zoom-test",
            windows: [
                TmuxSessionController.WindowInfo(
                    id: 1,
                    name: "w",
                    active: true,
                    zoomed: zoomed,
                    width: 80,
                    height: 24,
                    activePaneID: activePaneID
                )
            ],
            panes: [
                TmuxSessionController.PaneInfo(
                    id: 10,
                    windowID: 1,
                    x: 0,
                    y: 0,
                    width: zoomed && activePaneID == 10 ? 80 : 40,
                    height: 24,
                    state: .live
                ),
                TmuxSessionController.PaneInfo(
                    id: 11,
                    windowID: 1,
                    x: 40,
                    y: 0,
                    width: zoomed && activePaneID == 11 ? 80 : 40,
                    height: 24,
                    state: .live
                )
            ],
            activeWindowID: 1
        )
    }

    private func threePaneSnapshot(activePaneID: UInt64) -> TmuxSessionController.TopologySnapshot {
        TmuxSessionController.TopologySnapshot(
            sessionName: "selection-test",
            windows: [
                TmuxSessionController.WindowInfo(
                    id: 1,
                    name: "w",
                    active: true,
                    zoomed: true,
                    width: 80,
                    height: 24,
                    activePaneID: activePaneID
                )
            ],
            panes: [10, 11, 12].map {
                TmuxSessionController.PaneInfo(
                    id: $0,
                    windowID: 1,
                    x: 0,
                    y: 0,
                    width: 80,
                    height: 24,
                    state: .live
                )
            },
            activeWindowID: 1
        )
    }

    func testShutdownBlocksUntilInFlightCreateResolves() throws {
        let runtime = try GhosttyKitRuntime()
        var capturedCompletion: (@MainActor (Result<TmuxPaneSurface, TmuxPaneSurface.CreateError>) -> Void)?

        let session = makeSession(runtime: runtime) { _, _, _, _, _, completion in
            // Hold the completion: a create is now in flight and stays so
            // until the test resolves it.
            capturedCompletion = completion
        }

        session.handleTopology(snapshotPresentingPane(10))
        XCTAssertNotNil(capturedCompletion, "presenting a pane should start a create")

        var shutdownReturned = false
        let shutdownFinished = expectation(description: "shutdown returned")
        Task {
            await session.shutdown()
            shutdownReturned = true
            shutdownFinished.fulfill()
        }

        // While the create is unresolved, shutdown must not finish — even
        // though every other teardown step (no surface, no link, the real
        // controller shutdown) could otherwise complete within this window.
        let blockedWindow = expectation(description: "settle window")
        blockedWindow.isInverted = true
        wait(for: [blockedWindow], timeout: 0.3)
        XCTAssertFalse(shutdownReturned, "shutdown returned before the in-flight create resolved")

        // Resolve the create; shutdown drains and completes.
        capturedCompletion?(.failure(.surfaceCreationFailed))
        wait(for: [shutdownFinished], timeout: 2.0)
        XCTAssertTrue(shutdownReturned)
    }

    func testShutdownCompletesPromptlyWithoutInFlightCreate() throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime) { _, _, _, _, _, _ in
            XCTFail("no create should be started without a presented pane")
        }

        // No topology presented: nothing in flight, so the drain is a
        // no-op and shutdown proceeds straight through.
        let shutdownFinished = expectation(description: "shutdown returned")
        Task {
            await session.shutdown()
            shutdownFinished.fulfill()
        }
        wait(for: [shutdownFinished], timeout: 2.0)
    }

    func testPreparedPaneSelectionWaitsForConfirmingTopologyBeforeCreate() async throws {
        let runtime = try GhosttyKitRuntime()
        var createdPaneIDs: [UInt64] = []
        let session = makeSession(runtime: runtime) { _, _, paneID, _, _, completion in
            createdPaneIDs.append(paneID)
            completion(.failure(.surfaceCreationFailed))
        }

        session.handleTopology(splitSnapshot(activePaneID: 10, zoomed: true))
        XCTAssertEqual(createdPaneIDs, [10])

        session.prepareForPaneSelection(paneID: 11)
        XCTAssertEqual(createdPaneIDs, [10], "picker intent must not authorize an incoming bind")

        session.handleTopology(splitSnapshot(activePaneID: 11, zoomed: true))
        XCTAssertEqual(createdPaneIDs, [10, 11])
        await session.shutdown()
    }

    func testFailedPreparedPaneSelectionRecreatesConfirmedPane() async throws {
        let runtime = try GhosttyKitRuntime()
        var createdPaneIDs: [UInt64] = []
        let session = makeSession(runtime: runtime) { _, _, paneID, _, _, completion in
            createdPaneIDs.append(paneID)
            completion(.failure(.surfaceCreationFailed))
        }

        session.handleTopology(splitSnapshot(activePaneID: 10, zoomed: true))
        session.prepareForPaneSelection(paneID: 11)
        session.handleRequestFailedForTesting(.selectPane)

        XCTAssertEqual(
            createdPaneIDs,
            [10, 10],
            "select failure must re-drive the last server-confirmed pane"
        )
        await session.shutdown()
    }

    func testPreparedPaneSelectionRetargetsBeforeCreationStarts() async throws {
        let runtime = try GhosttyKitRuntime()
        var createdPaneIDs: [UInt64] = []
        let session = makeSession(runtime: runtime) { _, _, paneID, _, _, completion in
            createdPaneIDs.append(paneID)
            completion(.failure(.surfaceCreationFailed))
        }

        session.handleTopology(threePaneSnapshot(activePaneID: 10))
        session.prepareForPaneSelection(paneID: 11)
        session.prepareForPaneSelection(paneID: 12)
        session.handleTopology(threePaneSnapshot(activePaneID: 11))
        XCTAssertEqual(createdPaneIDs, [10], "an intermediate topology must not bind stale intent")

        session.handleTopology(threePaneSnapshot(activePaneID: 12))
        XCTAssertEqual(createdPaneIDs, [10, 12])
        await session.shutdown()
    }

    func testPreparedPaneSelectionStillWaitsForZoomConfirmation() async throws {
        let runtime = try GhosttyKitRuntime()
        var createdPaneIDs: [UInt64] = []
        let session = makeSession(runtime: runtime) { _, _, paneID, _, _, completion in
            createdPaneIDs.append(paneID)
            completion(.failure(.surfaceCreationFailed))
        }

        session.handleTopology(splitSnapshot(activePaneID: 10, zoomed: true))
        session.prepareForPaneSelection(paneID: 11)
        session.handleTopology(splitSnapshot(activePaneID: 11, zoomed: false))
        XCTAssertEqual(createdPaneIDs, [10], "unzoomed confirmation must not bind")

        session.handleTopology(splitSnapshot(activePaneID: 11, zoomed: true))
        XCTAssertEqual(createdPaneIDs, [10, 11])
        await session.shutdown()
    }

    func testShutdownCancelsPreparedSelectionWaitingForTopology() throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime) { _, _, _, _, _, completion in
            completion(.failure(.surfaceCreationFailed))
        }

        session.handleTopology(splitSnapshot(activePaneID: 10, zoomed: true))
        session.prepareForPaneSelection(paneID: 11)

        let shutdownFinished = expectation(description: "shutdown returned")
        Task {
            await session.shutdown()
            shutdownFinished.fulfill()
        }
        wait(for: [shutdownFinished], timeout: 2.0)
    }

    func testUnzoomedSplitWaitsForZoomBeforeCreatingPaneSurface() async throws {
        let runtime = try GhosttyKitRuntime()
        var createCount = 0
        let session = makeSession(runtime: runtime) { _, _, _, _, _, completion in
            createCount += 1
            completion(.failure(.surfaceCreationFailed))
        }

        session.handleTopology(splitSnapshot(activePaneID: 10, zoomed: false))
        XCTAssertEqual(createCount, 0, "unzoomed split should request zoom and delay bind")

        session.handleTopology(splitSnapshot(activePaneID: 10, zoomed: true))
        XCTAssertEqual(createCount, 1, "confirmed zoom topology should allow bind/create")
        await session.shutdown()
    }

    func testPresentedSamePaneRequestsZoomWhenWindowBecomesUnzoomed() async throws {
        let runtime = try GhosttyKitRuntime()
        var createCount = 0
        var capturedCompletion: (@MainActor (Result<TmuxPaneSurface, TmuxPaneSurface.CreateError>) -> Void)?
        let session = makeSession(runtime: runtime) { _, _, _, _, _, completion in
            createCount += 1
            capturedCompletion = completion
        }

        session.handleTopology(splitSnapshot(activePaneID: 10, zoomed: true))
        XCTAssertEqual(createCount, 1, "zoomed topology should start presenting the active pane")

        session.handleTopology(splitSnapshot(activePaneID: 10, zoomed: false))
        XCTAssertEqual(
            session.requestedZoomPaneIDsForTesting,
            [10],
            "the mobile zoom policy must run even when the active pane is already being presented"
        )
        XCTAssertEqual(createCount, 1, "requesting zoom should keep the existing presentation in place")

        capturedCompletion?(.failure(.surfaceCreationFailed))
        await session.shutdown()
    }

    func testZoomFailureFallsBackToCurrentGeometry() async throws {
        let runtime = try GhosttyKitRuntime()
        var createCount = 0
        let session = makeSession(runtime: runtime) { _, _, _, _, _, completion in
            createCount += 1
            completion(.failure(.surfaceCreationFailed))
        }

        session.handleTopology(splitSnapshot(activePaneID: 10, zoomed: false))
        XCTAssertEqual(createCount, 0, "unzoomed split should wait for zoom before bind")

        session.handleRequestFailedForTesting(.zoomPane)
        XCTAssertEqual(createCount, 1, "zoom rejection should bind current server geometry")
        await session.shutdown()
    }

    func testDetachDuringZoomWaitAllowsReconnectToRetryZoom() async throws {
        let runtime = try GhosttyKitRuntime()
        var createCount = 0
        let session = makeSession(runtime: runtime) { _, _, _, _, _, completion in
            createCount += 1
            completion(.failure(.surfaceCreationFailed))
        }

        let unzoomed = splitSnapshot(activePaneID: 10, zoomed: false)
        session.handleTopology(unzoomed)
        XCTAssertEqual(createCount, 0, "first unzoomed snapshot should wait for zoom")

        session.handleStateForTesting(.detached(.transportClosed))
        session.handleTopology(unzoomed)
        XCTAssertEqual(
            createCount,
            0,
            "reconnect with unzoomed topology should not bind before zoom confirmation"
        )

        session.handleTopology(splitSnapshot(activePaneID: 10, zoomed: true))
        XCTAssertEqual(
            createCount,
            1,
            "confirmed zoom after reconnect should allow bind instead of staying stuck"
        )
        await session.shutdown()
    }
}
