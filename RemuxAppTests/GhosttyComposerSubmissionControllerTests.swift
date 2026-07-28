import XCTest
@testable import Remux

final class GhosttyComposerSubmissionControllerTests: XCTestCase {
    func testComposerMessagePlacesAttachmentReferencesAfterDraft() {
        XCTAssertEqual(
            GhosttyComposerMessageFormatter.message(
                draft: "Review these files",
                attachmentText: "~/first.txt ~/second.txt"
            ),
            "Review these files\n~/first.txt ~/second.txt"
        )
    }

    func testComposerMessageSupportsAttachmentOnlySubmission() {
        XCTAssertEqual(
            GhosttyComposerMessageFormatter.message(
                draft: "",
                attachmentText: "~/photo.png"
            ),
            "~/photo.png"
        )
    }

    func testComposerSessionRequiresEveryAttachmentToBeReady() {
        var session = GhosttyComposerSessionState()
        session.attachments = [.pasteboardImagePlaceholder()]

        XCTAssertTrue(session.hasContent)
        XCTAssertFalse(session.areAttachmentsReady)

        session.attachments = [.file(url: URL(fileURLWithPath: "/tmp/report.txt"))]
        XCTAssertTrue(session.areAttachmentsReady)
    }

    @MainActor
    func testComposerSessionCleansUnsentStagedFilesWhenTerminalIsReleased() async throws {
        let stagedURL = try GhosttyAttachmentStagingStore.stageDataSynchronously(
            Data("unsent".utf8),
            filename: "unsent.txt"
        )
        addTeardownBlock {
            GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
        }

        var session: GhosttyComposerSessionModel? = GhosttyComposerSessionModel()
        session?.draft = "Review this"
        session?.attachments = [.file(url: stagedURL)]
        XCTAssertEqual(
            session?.snapshot,
            GhosttyComposerSessionState(
                draft: "Review this",
                attachments: [.file(url: stagedURL)]
            )
        )
        session = nil

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while FileManager.default.fileExists(atPath: stagedURL.path), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testUploadedAttachmentAndDraftBecomeOnePasteThenOneEnter() {
        let sourceID = UUID()
        let transferResult = GhosttyAttachmentTransferResult(
            transferID: UUID(),
            items: [
                .remoteFile(
                    sourceID: sourceID,
                    path: GhosttyRemoteAttachmentPath(
                        sourceID: sourceID,
                        filename: "report.txt",
                        remoteDirectory: ".cache/remux/attachments/job",
                        remoteTemporaryPath: ".cache/remux/attachments/job/.report.txt.part",
                        remoteFinalPath: ".cache/remux/attachments/job/report.txt",
                        terminalPath: "~/.cache/remux/attachments/job/report.txt"
                    )
                ),
            ]
        )
        let message = GhosttyComposerMessageFormatter.message(
            draft: "Summarize this report",
            attachmentText: GhosttyAttachmentTerminalInsertionFormatter.insertionText(
                for: transferResult
            )
        )
        var controller = GhosttyComposerSubmissionController()
        var calls: [String] = []

        let result = controller.submitDraft(
            message,
            to: UUID(),
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
        XCTAssertEqual(
            calls,
            [
                "paste:Summarize this report\n~/.cache/remux/attachments/job/report.txt",
                "enter",
            ]
        )
    }

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
