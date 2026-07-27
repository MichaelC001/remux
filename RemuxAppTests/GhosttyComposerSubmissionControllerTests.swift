import XCTest
@testable import Remux

final class GhosttyComposerSubmissionControllerTests: XCTestCase {
    func testSuccessfulSubmissionPastesBeforeEnterAndReturnsIdle() {
        var controller = GhosttyComposerSubmissionController()
        let surfaceID = UUID()
        var calls: [String] = []

        let result = controller.submitDraft(
            "first\nsecond",
            to: surfaceID,
            sendPaste: {
                calls.append("paste:\($0)")
                return true
            },
            sendEnter: {
                calls.append("enter")
                return true
            }
        )

        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(result.didDeliverDraft)
        XCTAssertEqual(calls, ["paste:first\nsecond", "enter"])
        XCTAssertEqual(controller.phase, .idle)
    }

    func testRejectedPastePreservesRetryPathWithoutSendingEnter() {
        var controller = GhosttyComposerSubmissionController()
        var didSendEnter = false

        let result = controller.submitDraft(
            "draft",
            to: UUID(),
            sendPaste: { _ in false },
            sendEnter: {
                didSendEnter = true
                return true
            }
        )

        XCTAssertEqual(result, .pasteRejected)
        XCTAssertFalse(result.didDeliverDraft)
        XCTAssertFalse(didSendEnter)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testRejectedEnterTransitionsToEnterOnlyRecovery() {
        var controller = GhosttyComposerSubmissionController()
        let surfaceID = UUID()
        var pasteCount = 0
        var enterCount = 0

        let result = controller.submitDraft(
            "draft",
            to: surfaceID,
            sendPaste: { _ in
                pasteCount += 1
                return true
            },
            sendEnter: {
                enterCount += 1
                return false
            }
        )

        XCTAssertEqual(result, .pastedAwaitingSubmit)
        XCTAssertTrue(result.didDeliverDraft)
        XCTAssertEqual(controller.phase, .awaitingSubmit(surfaceID: surfaceID))

        let submitResult = controller.submitDeliveredPaste(
            on: surfaceID,
            sendEnter: {
                enterCount += 1
                return true
            }
        )

        XCTAssertEqual(submitResult, .submitted)
        XCTAssertEqual(pasteCount, 1)
        XCTAssertEqual(enterCount, 2)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testEnterOnlyRecoveryNeverTargetsAChangedSurface() {
        var controller = GhosttyComposerSubmissionController()
        let originalSurfaceID = UUID()
        var didSendEnter = false

        _ = controller.submitDraft(
            "draft",
            to: originalSurfaceID,
            sendPaste: { _ in true },
            sendEnter: { false }
        )

        let result = controller.submitDeliveredPaste(
            on: UUID(),
            sendEnter: {
                didSendEnter = true
                return true
            }
        )

        XCTAssertEqual(result, .destinationChanged)
        XCTAssertFalse(didSendEnter)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testClosingComposerClearsEnterOnlyRecovery() {
        var controller = GhosttyComposerSubmissionController()

        _ = controller.submitDraft(
            "draft",
            to: UUID(),
            sendPaste: { _ in true },
            sendEnter: { false }
        )
        controller.clearAwaitingSubmit()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(
            controller.submitDeliveredPaste(on: nil, sendEnter: { true }),
            .notWaiting
        )
    }
}
