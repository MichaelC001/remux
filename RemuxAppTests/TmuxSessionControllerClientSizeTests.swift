import Foundation
import XCTest

@testable import Remux

@MainActor
final class TmuxSessionControllerClientSizeTests: XCTestCase {
    func testCrossWindowSelectionCommandPolicy() {
        XCTAssertEqual(
            TmuxSessionController.crossWindowSelectionCommands(
                windowID: 2,
                activePaneID: 20,
                preferredPaneID: 20,
                zoomed: false,
                hasSibling: true
            ),
            ["select-window -t @2", "resize-pane -Z -t %20"]
        )
        XCTAssertEqual(
            TmuxSessionController.crossWindowSelectionCommands(
                windowID: 2,
                activePaneID: 20,
                preferredPaneID: 21,
                zoomed: true,
                hasSibling: true
            ),
            ["select-window -t @2", "select-pane -Z -t %21"]
        )
        XCTAssertEqual(
            TmuxSessionController.crossWindowSelectionCommands(
                windowID: 2,
                activePaneID: 20,
                preferredPaneID: 20,
                zoomed: true,
                hasSibling: true
            ),
            ["select-window -t @2"]
        )
        XCTAssertEqual(
            TmuxSessionController.crossWindowSelectionCommands(
                windowID: 2,
                activePaneID: 20,
                preferredPaneID: nil,
                zoomed: false,
                hasSibling: true
            ),
            ["select-window -t @2"]
        )
    }

    func testSideBySideNavigationCoalescesAndRefreshesOnEachRevisit() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1",
            paneID: 1,
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %1\n"
                + responseBlock(commandNumber: &nextCommandNumber)
                + refreshResponseBlocks(
                    paneID: 1,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %2",
            paneID: 2,
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %2\n"
                + responseBlock(commandNumber: &nextCommandNumber)
                + refreshResponseBlocks(
                    paneID: 2,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)

        harness.controller.requestSelectPane(paneID: 1)
        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1",
            paneID: 1,
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %1\n"
                + responseBlock(commandNumber: &nextCommandNumber)
                + refreshResponseBlocks(
                    paneID: 1,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %2",
            paneID: 2,
        )
        await shutDown(harness.controller)
    }

    func testPaneNavigationWaitsWhenCommandEndsBeforeTopology() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        harness.controller.requestSelectPane(paneID: 0)
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1",
            paneID: 1,
        )

        harness.controller.pump(Data(
            responseBlock(commandNumber: &nextCommandNumber).utf8
        ))
        await drain(harness.controller)
        XCTAssertTrue(
            harness.recorder.takeStrings().isEmpty,
            "command completion must not admit the deferred intent against stale topology"
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %1\n"
                + refreshResponseBlocks(
                    paneID: 1,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %0",
            paneID: 0,
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %0\n"
                + responseBlock(commandNumber: &nextCommandNumber)
                + refreshResponseBlocks(
                    paneID: 0,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)
        await shutDown(harness.controller)
    }

    func testPaneNavigationUsesTopologyThatArrivedBeforeCompletion() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1",
            paneID: 1,
        )

        harness.controller.pump(Data("%window-pane-changed @0 %1\n".utf8))
        await drain(harness.controller)
        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)
        XCTAssertTrue(
            harness.recorder.takeStrings().isEmpty,
            "the outstanding mutation must still coalesce later navigation"
        )

        harness.controller.pump(Data(
            (responseBlock(commandNumber: &nextCommandNumber)
                + refreshResponseBlocks(
                    paneID: 1,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %2",
            paneID: 2,
        )
        await shutDown(harness.controller)
    }

    func testPaneNavigationWaitsWhenSubmittedAfterCompletionBeforeTopology() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1",
            paneID: 1,
        )

        harness.controller.pump(Data(
            responseBlock(commandNumber: &nextCommandNumber).utf8
        ))
        await drain(harness.controller)
        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)
        XCTAssertTrue(
            harness.recorder.takeStrings().isEmpty,
            "a successful mutation remains pending until newer topology arrives"
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %1\n"
                + refreshResponseBlocks(
                    paneID: 1,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %2",
            paneID: 2,
        )
        await shutDown(harness.controller)
    }

    func testPaneNavigationReevaluatesImmediatelyAfterCommandError() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1",
            paneID: 1,
        )

        harness.controller.pump(Data(
            errorBlock(commandNumber: &nextCommandNumber, body: "can't find pane: %1").utf8
        ))
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %2",
            paneID: 2,
        )
        await shutDown(harness.controller)
    }

    func testFailedPresentationRetryKeepsSameTargetRefreshAfterInFlightCompletion() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        harness.controller.requestSelectPane(paneID: 1)
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1",
            paneID: 1,
        )

        harness.controller.pump(Data(
            errorBlock(commandNumber: &nextCommandNumber, body: "can't find pane: %1").utf8
        ))
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["select-pane -Z -t %1\n"],
            "the retry executes after the already queued refresh"
        )

        harness.controller.pump(Data(
            refreshResponseBlocks(
                paneID: 1,
                commandNumber: &nextCommandNumber
            ).utf8
        ))
        await drain(harness.controller)
        let retryRefreshWrites = harness.recorder.takeStrings()
        XCTAssertEqual(retryRefreshWrites.count, 1)
        let retryRefresh = try XCTUnwrap(retryRefreshWrites.first)
        XCTAssertTrue(retryRefresh.hasPrefix("display-message -p -t %1 "))
        XCTAssertEqual(retryRefresh.components(separatedBy: "capture-pane").count - 1, 4)

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %1\n"
                + responseBlock(commandNumber: &nextCommandNumber)
                + refreshResponseBlocks(
                    paneID: 1,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)
        await shutDown(harness.controller)
    }

    func testRepeatedCrossWindowUnzoomedSelectionDoesNotQueueSecondToggle() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.splitTargetWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectWindow(windowID: 1, preferredPaneID: 1)
        harness.controller.requestSelectWindow(windowID: 1, preferredPaneID: 1)
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-window -t @1 ; resize-pane -Z -t %1",
            paneID: 1,
        )

        harness.controller.pump(Data(
            ("%session-window-changed $42 @1\n"
                + responseBlock(commandNumber: &nextCommandNumber)
                + "%layout-change @1 9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2} b7de,83x44,0,0,1 *Z\n"
                + responseBlock(commandNumber: &nextCommandNumber)
                + refreshResponseBlocks(
                    paneID: 1,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)
        XCTAssertTrue(
            harness.recorder.takeStrings().isEmpty,
            "the repeated intent must re-evaluate as zero after the first group zooms"
        )
        await shutDown(harness.controller)
    }

    func testDeferredZoomDoesNotToggleAfterWindowSelectionAlreadyZooms() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.splitTargetWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectWindow(windowID: 1, preferredPaneID: 1)
        harness.controller.requestZoomPane(paneID: 1)
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-window -t @1 ; resize-pane -Z -t %1",
            paneID: 1,
        )

        harness.controller.pump(Data(
            ("%session-window-changed $42 @1\n"
                + responseBlock(commandNumber: &nextCommandNumber)
                + "%layout-change @1 9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2} b7de,83x44,0,0,1 *Z\n"
                + responseBlock(commandNumber: &nextCommandNumber)
                + refreshResponseBlocks(
                    paneID: 1,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)
        XCTAssertTrue(
            harness.recorder.takeStrings().isEmpty,
            "the deferred zoom must re-evaluate to a no-op after the selection group zooms"
        )
        await shutDown(harness.controller)
    }

    func testWindowNavigationCoalescesRollbackToLatestWindow() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoSinglePaneWindows,
            expectedPaneCount: 2
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectWindow(windowID: 1, preferredPaneID: 1)
        harness.controller.requestSelectWindow(windowID: 0, preferredPaneID: 0)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["select-window -t @1\n"])

        harness.controller.pump(Data(
            ("%session-window-changed $42 @1\n"
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["select-window -t @0\n"])
        await shutDown(harness.controller)
    }

    func testColdSplitSelectionEnqueuesPresentationThenRefreshInOneWrite() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoPaneUnzoomedWindow,
            expectedPaneCount: 2
        )

        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)

        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "resize-pane -Z -t %2",
            paneID: 2,
        )
        await shutDown(harness.controller)
    }

    func testRefreshCompletionReleasesReadinessWithoutSecondTerminalHandoff() async throws {
        let lifecycle = ControllerLifecycleRecorder()
        let harness = try await readyController(
            listWindowsBody: Self.twoPaneUnzoomedWindow,
            expectedPaneCount: 2,
            callbacks: lifecycle.callbacks
        )
        try await waitUntil("initial terminals were not handed off") {
            lifecycle.terminalPaneIDs.count == 2
        }
        let initialTerminalPaneIDs = lifecycle.terminalPaneIDs
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)
        _ = harness.recorder.takeStrings()
        try await waitUntil("refresh did not gate pane readiness") {
            lifecycle.phaseChanges.contains { $0.paneID == 2 && $0.phase == .hydrating }
        }

        harness.controller.pump(Data(
            ("%window-pane-changed @1 %2\n"
                + responseBlock(commandNumber: &nextCommandNumber)
                + refreshResponseBlocks(
                    paneID: 2,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)
        try await waitUntil("refresh completion did not restore pane readiness") {
            lifecycle.phaseChanges.contains { $0.paneID == 2 && $0.phase == .live }
        }

        XCTAssertEqual(lifecycle.terminalPaneIDs, initialTerminalPaneIDs)
        await shutDown(harness.controller)
    }

    func testTopBottomRoundTripRefreshesEachFullToSplitGridChange() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoPaneSameColumnZoomedWindow,
            expectedPaneCount: 2
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        await drain(harness.controller)

        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1",
            paneID: 1,
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %1\n"
                + responseBlock(commandNumber: &nextCommandNumber)
                + refreshResponseBlocks(
                    paneID: 1,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)

        harness.controller.requestSelectPane(paneID: 0)
        await drain(harness.controller)
        assertPresentationWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %0",
            paneID: 0,
        )
        await shutDown(harness.controller)
    }

    func testClientSizeRefreshesForRowOrColumnChangesInOneWrite() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.setClientSize(cols: 83, rows: 44)
        await drain(harness.controller)
        XCTAssertTrue(
            harness.recorder.takeStrings().isEmpty,
            "the renderer reporting the already-submitted initial grid must do no work"
        )

        harness.controller.setClientSize(cols: 83, rows: 40)
        await drain(harness.controller)
        var writes = harness.recorder.takeStrings()
        XCTAssertEqual(writes.count, 1)
        var write = try XCTUnwrap(writes.first)
        XCTAssertTrue(write.hasPrefix("refresh-client -C 83x40\ndisplay-message"))
        XCTAssertEqual(write.components(separatedBy: "capture-pane").count - 1, 4)
        harness.controller.pump(Data(
            (responseBlock(commandNumber: &nextCommandNumber)
                + refreshResponseBlocks(
                    paneID: 0,
                    rows: 40,
                    commandNumber: &nextCommandNumber
                )).utf8
        ))
        await drain(harness.controller)

        harness.controller.setClientSize(cols: 100, rows: 40)
        await drain(harness.controller)
        writes = harness.recorder.takeStrings()
        XCTAssertEqual(writes.count, 1)
        write = try XCTUnwrap(writes.first)
        XCTAssertTrue(
            write.hasPrefix("refresh-client -C 100x40\ndisplay-message -p -t %0 ")
        )
        XCTAssertEqual(write.components(separatedBy: "capture-pane").count - 1, 4)
        await shutDown(harness.controller)
    }

    func testInFlightGridRefreshFollowsViewportRevertExactlyOnce() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.setClientSize(cols: 100, rows: 40)
        await drain(harness.controller)
        let outbound100 = try XCTUnwrap(harness.recorder.takeStrings().first)
        XCTAssertTrue(outbound100.hasPrefix("refresh-client -C 100x40\ndisplay-message"))

        harness.controller.setClientSize(cols: 83, rows: 44)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["refresh-client -C 83x44\n"])

        harness.controller.pump(Data(
            ("%layout-change @0 aa7d,100x40,0,0,0 aa7d,100x40,0,0,0 *\n"
                + responseBlock(commandNumber: &nextCommandNumber)
                + refreshResponseBlocks(
                    paneID: 0,
                    columns: 100,
                    rows: 40,
                    commandNumber: &nextCommandNumber
                )
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)

        let followUpWrites = harness.recorder.takeStrings()
        XCTAssertEqual(followUpWrites.count, 1)
        let followUp = try XCTUnwrap(followUpWrites.first)
        XCTAssertTrue(followUp.hasPrefix("display-message -p -t %0 "))
        XCTAssertEqual(followUp.components(separatedBy: "capture-pane").count - 1, 4)

        harness.controller.pump(Data(
            ("%layout-change @0 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 *\n"
                + refreshResponseBlocks(
                    paneID: 0,
                    columns: 83,
                    commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)
        await shutDown(harness.controller)
    }

    func testNewWindowAndSplitCommandsDoNotGainRefreshWork() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )

        harness.controller.requestSelectPane(paneID: 0)
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)

        harness.controller.requestNewWindow()
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["new-window\n"])

        harness.controller.requestSplit(paneID: 0, direction: .right, zoom: true)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["split-window -h -Z -t %0\n"])
        await shutDown(harness.controller)
    }

    func testNotReadyRefreshRetriesOnceAndDrainsAfterInitialPaneChanged() async throws {
        let harness = try await hydratingController(
            listWindowsBody: Self.twoPaneUnzoomedWindow,
            expectedPaneCount: 2
        )

        harness.controller.requestZoomPane(paneID: 1)
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["resize-pane -Z -t %1\n"],
            "initial hydration cannot yet accept the refresh"
        )

        let hydrationEnd = harness.firstHydrationCommandNumber + harness.hydrationCommandCount
        let hydration = (harness.firstHydrationCommandNumber..<hydrationEnd)
            .map { "%begin \($0) \($0) 1\n%end \($0) \($0) 1\n" }
            .joined()
        harness.controller.pump(Data(hydration.utf8))
        await drain(harness.controller)

        let writes = harness.recorder.takeStrings()
        XCTAssertEqual(writes.count, 1)
        let write = try XCTUnwrap(writes.first)
        XCTAssertTrue(write.hasPrefix("display-message -p -t %1 "))
        XCTAssertEqual(write.components(separatedBy: "capture-pane").count - 1, 4)
        await shutDown(harness.controller)
    }

    func testTopologyRemovalClearsDeferredPaneRefresh() async throws {
        let harness = try await hydratingController(
            listWindowsBody: Self.twoPaneUnzoomedWindow,
            expectedPaneCount: 2
        )

        harness.controller.requestZoomPane(paneID: 1)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["resize-pane -Z -t %1\n"])

        harness.controller.pump(Data("%unlinked-window-close @1\n".utf8))
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)

        let hydrationEnd = harness.firstHydrationCommandNumber + harness.hydrationCommandCount
        let hydration = (harness.firstHydrationCommandNumber..<hydrationEnd)
            .map { "%begin \($0) \($0) 1\n%end \($0) \($0) 1\n" }
            .joined()
        harness.controller.pump(Data(hydration.utf8))
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            [],
            "a removed pane must not retry its deferred refresh"
        )
        await shutDown(harness.controller)
    }

    func testDetachedRequestReportsImmediateFailure() async throws {
        let recorder = RequestFailureRecorder()
        let controller = TmuxSessionController(
            callbacks: .init(onRequestFailed: { request in
                Task { await recorder.append(request) }
            })
        )

        controller.requestCopyMode(paneID: 1)

        try await waitUntil("detached request failure was not reported") {
            await recorder.requests().contains(.copyMode)
        }
        await shutDown(controller)
    }

    func testDetachedInputSubmissionReturnsImmediatelyThenReportsFailure() async {
        let failureReported = expectation(description: "input failure reported")
        let controller = TmuxSessionController(
            callbacks: .init(onRequestFailed: { request in
                XCTAssertEqual(request, .sendInput)
                failureReported.fulfill()
            })
        )

        XCTAssertTrue(controller.sendInput(paneID: 1, Data([0x61])))
        await fulfillment(of: [failureReported], timeout: 1)
        await shutDown(controller)
    }

    func testInputSubmissionDoesNotWaitForEarlierWriterQueueWork() async {
        let failureReported = expectation(description: "input failure reported")
        let controller = TmuxSessionController(
            callbacks: .init(onRequestFailed: { request in
                XCTAssertEqual(request, .sendInput)
                failureReported.fulfill()
            })
        )
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        controller.queue.async {
            blockerStarted.signal()
            releaseBlocker.wait()
        }
        XCTAssertEqual(blockerStarted.wait(timeout: .now() + 1), .success)

        let clock = ContinuousClock()
        let startedAt = clock.now
        XCTAssertTrue(controller.sendInput(paneID: 1, Data([0x61])))
        XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(25))

        releaseBlocker.signal()
        await fulfillment(of: [failureReported], timeout: 1)
        await shutDown(controller)
    }

    private struct ReadyControllerHarness {
        let runtime: GhosttyKitRuntime
        let controller: TmuxSessionController
        let recorder: ControllerOutboundRecorder
        let nextCommandNumber: Int
    }

    private struct HydratingControllerHarness {
        let runtime: GhosttyKitRuntime
        let controller: TmuxSessionController
        let recorder: ControllerOutboundRecorder
        let firstHydrationCommandNumber: Int
        let hydrationCommandCount: Int
    }

    private func readyController(
        listWindowsBody: String,
        expectedPaneCount: Int,
        callbacks: TmuxSessionController.Callbacks = .init()
    ) async throws -> ReadyControllerHarness {
        let harness = try await hydratingController(
            listWindowsBody: listWindowsBody,
            expectedPaneCount: expectedPaneCount,
            callbacks: callbacks
        )
        let hydrationEnd = harness.firstHydrationCommandNumber + harness.hydrationCommandCount
        let hydration = (harness.firstHydrationCommandNumber..<hydrationEnd)
            .map { "%begin \($0) \($0) 1\n%end \($0) \($0) 1\n" }
            .joined()
        harness.controller.pump(Data(hydration.utf8))
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)
        return ReadyControllerHarness(
            runtime: harness.runtime,
            controller: harness.controller,
            recorder: harness.recorder,
            nextCommandNumber: harness.firstHydrationCommandNumber
                + harness.hydrationCommandCount
        )
    }

    private func hydratingController(
        listWindowsBody: String,
        expectedPaneCount: Int,
        callbacks: TmuxSessionController.Callbacks = .init()
    ) async throws -> HydratingControllerHarness {
        let runtime = try GhosttyKitRuntime()
        let recorder = ControllerOutboundRecorder()
        let controller = TmuxSessionController(callbacks: callbacks)
        controller.setOutboundSink { recorder.append($0) }
        await drain(controller)
        try await withCheckedThrowingContinuation { continuation in
            controller.start(initialSize: .init(cols: 83, rows: 44)) { result in
                continuation.resume(with: result)
            }
        }
        controller.pump(Data(
            "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n".utf8
        ))
        await drain(controller)
        XCTAssertEqual(
            recorder.takeStrings(),
            [
                "display-message -p '#{version}'\n"
                    + "refresh-client -C 83x44\n"
                    + "list-windows -F '#{session_id} #{window_id} #{window_active} #{pane_id} #{window_width} #{window_height} #{window_layout} #{window_visible_layout}'\n"
            ]
        )
        controller.pump(Data(
            ("%begin 2 2 1\n3.1\n%end 2 2 1\n"
                + "%begin 3 3 1\n%end 3 3 1\n"
                + "%begin 4 4 1\n\(listWindowsBody)%end 4 4 1\n").utf8
        ))
        await drain(controller)
        let hydrationWrites = recorder.takeStrings()
        let hydrationOutbound = hydrationWrites.joined()
        let hydrationCommandCount = hydrationOutbound
            .split(separator: "\n")
            .reduce(0) { count, line in
                count + 1 + line.components(separatedBy: " ; ").count - 1
            }
        XCTAssertEqual(
            hydrationCommandCount,
            1 + expectedPaneCount * 4,
            "hydration must use one pane-state scan and four captures per pane"
        )
        let firstHydrationCommandNumber = 5
        return HydratingControllerHarness(
            runtime: runtime,
            controller: controller,
            recorder: recorder,
            firstHydrationCommandNumber: firstHydrationCommandNumber,
            hydrationCommandCount: hydrationCommandCount
        )
    }

    private func responseBlock(commandNumber: inout Int) -> String {
        defer { commandNumber += 1 }
        return "%begin \(commandNumber) \(commandNumber) 1\n"
            + "%end \(commandNumber) \(commandNumber) 1\n"
    }

    private func responseBlock(
        commandNumber: inout Int,
        body: String
    ) -> String {
        defer { commandNumber += 1 }
        return "%begin \(commandNumber) \(commandNumber) 1\n"
            + body
            + "%end \(commandNumber) \(commandNumber) 1\n"
    }

    private func refreshResponseBlocks(
        paneID: TmuxPaneID,
        columns: UInt32 = 83,
        rows: UInt32 = 44,
        commandNumber: inout Int
    ) -> String {
        let cursorY = rows - 1
        let state = "%\(paneID.rawValue);\(columns);\(rows);0;0;1;;;;0;"
            + "4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;0;\(cursorY);8,16\n"
        return responseBlock(commandNumber: &commandNumber, body: state)
            + responseBlock(commandNumber: &commandNumber)
            + responseBlock(commandNumber: &commandNumber)
            + responseBlock(commandNumber: &commandNumber)
            + responseBlock(commandNumber: &commandNumber)
    }

    private func assertPresentationWrite(
        _ writes: [String],
        command: String,
        paneID: TmuxPaneID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(writes.count, 1, file: file, line: line)
        guard let write = writes.first else { return }
        XCTAssertTrue(
            write.hasPrefix(command + "\ndisplay-message -p -t %\(paneID.rawValue) "),
            "presentation must precede refresh in the same outbound write: \(write)",
            file: file,
            line: line
        )
        let refresh = String(write.dropFirst(command.utf8.count + 1))
        XCTAssertEqual(
            refresh.components(separatedBy: "capture-pane").count - 1,
            4,
            file: file,
            line: line
        )
        XCTAssertEqual(
            refresh.components(separatedBy: " ; ").count - 1,
            4,
            file: file,
            line: line
        )
    }

    private func errorBlock(commandNumber: inout Int, body: String) -> String {
        defer { commandNumber += 1 }
        return "%begin \(commandNumber) \(commandNumber) 1\n"
            + "\(body)\n"
            + "%error \(commandNumber) \(commandNumber) 1\n"
    }

    private func drain(_ controller: TmuxSessionController) async {
        await withCheckedContinuation { continuation in
            controller.queue.async { continuation.resume() }
        }
    }

    private func shutDown(_ controller: TmuxSessionController) async {
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(failureMessage)
    }

    private static let threePaneZoomedWindow =
        "$42 @0 1 %0 83 44 "
        + "85ff,83x44,0,0{27x44,0,0,0,27x44,28,0,1,27x44,56,0,2} "
        + "b7dd,83x44,0,0,0\n"

    private static let splitTargetWindow =
        "$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0\n"
        + "$42 @1 0 %1 83 44 "
        + "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2} "
        + "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2}\n"

    private static let twoSinglePaneWindows =
        "$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0\n"
        + "$42 @1 0 %1 83 44 b7de,83x44,0,0,1 b7de,83x44,0,0,1\n"

    private static let onePaneWindow =
        "$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0\n"

    private static let twoPaneUnzoomedWindow =
        "$42 @1 1 %1 83 44 "
        + "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2} "
        + "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2}\n"

    private static let twoPaneSameColumnZoomedWindow =
        "$42 @0 1 %0 83 44 "
        + "607b,83x44,0,0[83x22,0,0,0,83x21,0,23,1] "
        + "b7dd,83x44,0,0,0\n"
}

private actor RequestFailureRecorder {
    private var recordedRequests: [TmuxSessionController.Request] = []

    func append(_ request: TmuxSessionController.Request) {
        recordedRequests.append(request)
    }

    func requests() -> [TmuxSessionController.Request] {
        recordedRequests
    }
}

private final class ControllerOutboundRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [Data] = []

    func append(_ data: Data) {
        lock.withLock { writes.append(data) }
    }

    func takeStrings() -> [String] {
        lock.withLock {
            defer { writes.removeAll() }
            return writes.map { String(decoding: $0, as: UTF8.self) }
        }
    }
}

private final class ControllerLifecycleRecorder: @unchecked Sendable {
    struct PhaseChange: Equatable {
        let paneID: TmuxPaneID
        let phase: TmuxSessionController.PaneInfo.Phase
    }

    private let lock = NSLock()
    private var terminals: [TmuxSessionController.RetainedPaneTerminal] = []
    private var phases: [PhaseChange] = []

    var callbacks: TmuxSessionController.Callbacks {
        .init(
            onPaneTerminal: { [self] terminal in
                lock.withLock { terminals.append(terminal) }
            },
            onPanePhaseChanged: { [self] paneID, phase in
                lock.withLock { phases.append(.init(paneID: paneID, phase: phase)) }
            }
        )
    }

    var terminalPaneIDs: [TmuxPaneID] {
        lock.withLock { terminals.map(\.paneID).sorted() }
    }

    var phaseChanges: [PhaseChange] {
        lock.withLock { phases }
    }
}
