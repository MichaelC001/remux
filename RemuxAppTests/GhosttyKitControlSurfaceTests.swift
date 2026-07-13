import CoreGraphics
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyKitControlSurfaceTests: XCTestCase {
    func testAdapterTypeIsAvailableToRemuxAppTarget() {
        XCTAssertTrue(GhosttyKitControlSurface.self is AnyClass)
    }

    func testDisplayMetricsUseScaleForPixelDimensions() {
        XCTAssertEqual(
            GhosttySurfaceDisplayMetrics(
                size: CGSize(width: 390, height: 641),
                scale: 3
            ),
            GhosttySurfaceDisplayMetrics(
                contentScale: 3,
                pixelWidth: 1170,
                pixelHeight: 1923
            )
        )

        XCTAssertEqual(
            TmuxControlViewport(
                ghosttySurfaceSize: ghostty_surface_size_s(
                    columns: 41,
                    rows: 28,
                    width_px: 1170,
                    height_px: 1923,
                    cell_width_px: 28,
                    cell_height_px: 68
                )
            ),
            TmuxControlViewport(
                columns: 41,
                rows: 28,
                pixelWidth: 1170,
                pixelHeight: 1923
            )
        )
        XCTAssertNil(
            TmuxControlViewport(
                ghosttySurfaceSize: ghostty_surface_size_s(
                    columns: 0,
                    rows: 28,
                    width_px: 1170,
                    height_px: 1923,
                    cell_width_px: 28,
                    cell_height_px: 68
                )
            )
        )
        XCTAssertNil(
            TmuxControlViewport(
                ghosttySurfaceSize: ghostty_surface_size_s(
                    columns: 41,
                    rows: 0,
                    width_px: 1170,
                    height_px: 1923,
                    cell_width_px: 28,
                    cell_height_px: 68
                )
            )
        )
    }

    func testDisplayMetricsClampTransientInvalidScale() {
        XCTAssertEqual(
            GhosttySurfaceDisplayMetrics(
                size: CGSize(width: 390, height: 641),
                scale: 0
            ),
            GhosttySurfaceDisplayMetrics(
                contentScale: 1,
                pixelWidth: 390,
                pixelHeight: 641
            )
        )
    }

    func testDisplayMetricsClampNonFiniteScale() {
        XCTAssertEqual(
            GhosttySurfaceDisplayMetrics(
                size: CGSize(width: 390, height: 641),
                scale: .nan
            ),
            GhosttySurfaceDisplayMetrics(
                contentScale: 1,
                pixelWidth: 390,
                pixelHeight: 641
            )
        )
        XCTAssertEqual(
            GhosttySurfaceDisplayMetrics(
                size: CGSize(width: 390, height: 641),
                scale: .infinity
            ),
            GhosttySurfaceDisplayMetrics(
                contentScale: 1,
                pixelWidth: 390,
                pixelHeight: 641
            )
        )
    }

    func testDisplayMetricsClampInvalidSizeToOnePixel() {
        XCTAssertEqual(
            GhosttySurfaceDisplayMetrics(
                size: CGSize(width: 0, height: CGFloat.nan),
                scale: 3
            ),
            GhosttySurfaceDisplayMetrics(
                contentScale: 3,
                pixelWidth: 1,
                pixelHeight: 1
            )
        )
    }

    func testDisplayMetricsClampOversizedPixelDimensions() {
        XCTAssertEqual(
            GhosttySurfaceDisplayMetrics(
                size: CGSize(width: CGFloat(UInt32.max), height: 10),
                scale: 3
            ),
            GhosttySurfaceDisplayMetrics(
                contentScale: 3,
                pixelWidth: UInt32.max,
                pixelHeight: 30
            )
        )
    }

    func testDisplayUpdateTrackerSuppressesUnchangedMetrics() {
        var tracker = GhosttySurfaceDisplayUpdateTracker()
        let size = CGSize(width: 390, height: 641)

        XCTAssertEqual(
            tracker.nextMetrics(size: size, scale: 3),
            GhosttySurfaceDisplayMetrics(
                contentScale: 3,
                pixelWidth: 1170,
                pixelHeight: 1923
            )
        )
        XCTAssertNil(tracker.nextMetrics(size: size, scale: 3))
    }

    func testDisplayUpdateTrackerEmitsWhenRoundedPixelSizeChanges() {
        var tracker = GhosttySurfaceDisplayUpdateTracker()

        XCTAssertNotNil(tracker.nextMetrics(size: CGSize(width: 390, height: 641), scale: 3))
        XCTAssertNil(tracker.nextMetrics(size: CGSize(width: 390, height: 641), scale: 3))
        XCTAssertEqual(
            tracker.nextMetrics(size: CGSize(width: 390, height: 640.5), scale: 3),
            GhosttySurfaceDisplayMetrics(
                contentScale: 3,
                pixelWidth: 1170,
                pixelHeight: 1922
            )
        )
    }

    func testDisplayUpdateTrackerResetAllowsSameMetricsAgain() {
        var tracker = GhosttySurfaceDisplayUpdateTracker()
        let size = CGSize(width: 390, height: 641)

        XCTAssertNotNil(tracker.nextMetrics(size: size, scale: 3))
        XCTAssertNil(tracker.nextMetrics(size: size, scale: 3))

        tracker.reset()

        XCTAssertNotNil(tracker.nextMetrics(size: size, scale: 3))
    }


    func testDecodeGhosttyTextReturnsEmptyStringForMissingBuffer() {
        XCTAssertEqual(
            GhosttyKitControlSurface.decodeGhosttyText(
                ghostty_text_s(
                    tl_px_x: 0,
                    tl_px_y: 0,
                    offset_start: 0,
                    offset_len: 0,
                    text: nil,
                    text_len: 0
                )
            ),
            ""
        )
    }

    func testDecodeGhosttyTextPreservesUtf8Content() {
        let value = "café λ"

        let decoded = value.withCString { pointer in
            GhosttyKitControlSurface.decodeGhosttyText(
                ghostty_text_s(
                    tl_px_x: 0,
                    tl_px_y: 0,
                    offset_start: 0,
                    offset_len: UInt32(value.utf8.count),
                    text: pointer,
                    text_len: UInt(value.utf8.count)
                )
            )
        }

        XCTAssertEqual(decoded, value)
    }

    func testManagedSurfaceReportsOnlyRealVisibilityTransitions() throws {
        let runtime = try GhosttyKitRuntime()
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let controlSurface = try runtime.makeManualHostSurface(view: view)
        var transitions: [Bool] = []
        let surface = GhosttyManagedSurface(
            id: UUID(),
            view: view,
            controlSurface: controlSurface,
            visibilityChanged: { transitions.append($0) }
        )

        surface.setVisible(true)
        surface.setVisible(true)
        surface.setVisible(false)
        surface.setVisible(false)

        XCTAssertEqual(transitions, [true, false])
    }

    @MainActor
    func testInvalidatedControlSurfaceNoOpsSafely() throws {
        let runtime = try GhosttyKitRuntime()
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let surface = try runtime.makeManualHostSurface(view: view)

        surface.invalidate()

        // Every call must be a benign no-op (the real hazard is a
        // borrowed handle freed by its owner; here the surface is
        // still alive, which proves the guard path, not UIKit luck).
        XCTAssertFalse(surface.processOutput(Data("x".utf8)))
        XCTAssertFalse(surface.sendInput("q"))
        XCTAssertFalse(surface.isMouseCaptured())
        XCTAssertFalse(surface.hasSelection())
        XCTAssertNil(surface.readSelection())
        surface.setFocused(true)
        surface.setVisible(true)
        surface.scrollToTop()
        let size = surface.currentSize()
        XCTAssertEqual(size.columns, 0)
        XCTAssertEqual(surface.scrollState(), .empty)
        XCTAssertTrue(surface.isInvalidated)
    }

    func testSynchronousBorrowedSurfaceRejectsAfterInvalidation() throws {
        let runtime = try GhosttyKitRuntime()
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let owner = try runtime.makeManualHostSurface(view: view)
        let borrowed = GhosttyKitControlSurface(
            surface: owner.handle,
            ownership: .borrowed,
            retainedObjects: [owner]
        )
        var bodyCallCount = 0

        borrowed.invalidate()
        let result = borrowed.withSynchronousBorrowedSurface { _ in
            bodyCallCount += 1
            return 1
        }

        XCTAssertNil(result)
        XCTAssertEqual(bodyCallCount, 0)
    }

    func testSynchronousBorrowedSurfaceFencesInvalidationUntilBodyReturns() throws {
        let runtime = try GhosttyKitRuntime()
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let owner = try runtime.makeManualHostSurface(view: view)
        let borrowed = GhosttyKitControlSurface(
            surface: owner.handle,
            ownership: .borrowed,
            retainedObjects: [owner]
        )
        let borrowedBox = UncheckedSendableTestBox(borrowed)
        let borrowEntered = DispatchSemaphore(value: 0)
        let allowBorrowReturn = DispatchSemaphore(value: 0)
        let borrowFinished = DispatchSemaphore(value: 0)
        let invalidationStarted = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)

        let borrowThread = Thread {
            _ = borrowedBox.value.withSynchronousBorrowedSurface { _ in
                borrowEntered.signal()
                _ = allowBorrowReturn.wait(timeout: .now() + 10)
            }
            borrowFinished.signal()
        }
        borrowThread.qualityOfService = .userInteractive
        borrowThread.start()

        guard borrowEntered.wait(timeout: .now() + 10) == .success else {
            allowBorrowReturn.signal()
            _ = borrowFinished.wait(timeout: .now() + 10)
            return XCTFail("borrow body did not start")
        }

        let invalidationThread = Thread {
            invalidationStarted.signal()
            borrowedBox.value.invalidate()
            invalidationFinished.signal()
        }
        invalidationThread.qualityOfService = .userInteractive
        invalidationThread.start()

        XCTAssertEqual(invalidationStarted.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(
            invalidationFinished.wait(timeout: .now() + 0.05),
            .timedOut,
            "invalidation must not pass an active native-handle borrow"
        )

        allowBorrowReturn.signal()
        XCTAssertEqual(borrowFinished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 10), .success)

        var laterBorrowExecuted = false
        let laterResult = borrowed.withSynchronousBorrowedSurface { _ in
            laterBorrowExecuted = true
            return 1
        }
        XCTAssertNil(laterResult)
        XCTAssertFalse(laterBorrowExecuted)
    }

}

private struct UncheckedSendableTestBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
