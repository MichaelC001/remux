import Foundation
import XCTest
@testable import Remux

@MainActor
final class TmuxSessionControllerClientSizeTests: XCTestCase {
    private func makeController() throws -> (GhosttyKitRuntime, TmuxSessionController) {
        let runtime = try GhosttyKitRuntime()
        let controller = TmuxSessionController(
            app: runtime.appHandleForTesting,
            callbacks: TmuxSessionController.Callbacks()
        )
        return (runtime, controller)
    }

    private func shutDown(_ controller: TmuxSessionController) async {
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
    }

    func testCarriedClientSizePrefersStableViewportReports() async throws {
        let (runtime, controller) = try makeController()
        defer { _ = runtime }

        // Settled viewport: the report is recorded as stable.
        controller.setClientSize(cols: 80, rows: 45)
        XCTAssertEqual(
            controller.carriedClientSize,
            TmuxSessionController.ClientSize(cols: 80, rows: 45)
        )

        // Software keyboard up: the shrunken report must not replace
        // the carried size (disconnecting now would otherwise make the
        // next attach first-paint keyboard-shrunken).
        controller.setViewportStability(false)
        controller.setClientSize(cols: 80, rows: 24)
        XCTAssertEqual(
            controller.lastClientSize,
            TmuxSessionController.ClientSize(cols: 80, rows: 24)
        )
        XCTAssertEqual(
            controller.carriedClientSize,
            TmuxSessionController.ClientSize(cols: 80, rows: 45)
        )

        // Keyboard dismissed: the restored report becomes the carry.
        controller.setViewportStability(true)
        controller.setClientSize(cols: 80, rows: 45)
        XCTAssertEqual(
            controller.carriedClientSize,
            TmuxSessionController.ClientSize(cols: 80, rows: 45)
        )

        await shutDown(controller)
    }

    func testCarriedClientSizeFallsBackToLastReportWithoutStableRecord() async throws {
        let (runtime, controller) = try makeController()
        defer { _ = runtime }

        // A session whose only reports happened mid-transient still
        // carries something rather than attaching unsized.
        controller.setViewportStability(false)
        controller.setClientSize(cols: 80, rows: 24)
        XCTAssertEqual(
            controller.carriedClientSize,
            TmuxSessionController.ClientSize(cols: 80, rows: 24)
        )

        await shutDown(controller)
    }

    func testViewportStartsStable() async throws {
        let (runtime, controller) = try makeController()
        defer { _ = runtime }

        // The keyboard starts hidden, so reports before any hint are
        // stable (covers the carried-size report at sized attach).
        controller.setClientSize(cols: 100, rows: 50)
        XCTAssertEqual(
            controller.lastStableClientSize,
            TmuxSessionController.ClientSize(cols: 100, rows: 50)
        )

        await shutDown(controller)
    }

    func testDetachedRequestReportsImmediateFailure() async throws {
        let runtime = try GhosttyKitRuntime()
        let recorder = RequestFailureRecorder()
        let controller = TmuxSessionController(
            app: runtime.appHandleForTesting,
            callbacks: TmuxSessionController.Callbacks(
                onRequestFailed: { request in
                    Task { await recorder.append(request) }
                }
            )
        )
        defer { _ = runtime }

        controller.requestCopyMode(paneID: 1)

        try await waitUntil("detached request failure was not reported") {
            await recorder.requests().contains(.copyMode)
        }

        await shutDown(controller)
    }

    func testDetachedInputIsRejectedSynchronously() async throws {
        let (runtime, controller) = try makeController()
        defer { _ = runtime }

        XCTAssertFalse(controller.sendInput(paneID: 1, Data([0x61])))

        await shutDown(controller)
    }

    func testInputReturnWaitsForEarlierWriterQueueWork() async throws {
        let (runtime, controller) = try makeController()
        defer { _ = runtime }

        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        controller.queue.async {
            blockerStarted.signal()
            releaseBlocker.wait()
        }
        XCTAssertEqual(blockerStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            releaseBlocker.signal()
        }
        let clock = ContinuousClock()
        let startedAt = clock.now
        XCTAssertFalse(controller.sendInput(paneID: 1, Data([0x61])))
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(75))
        await shutDown(controller)
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(failureMessage)
    }
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
