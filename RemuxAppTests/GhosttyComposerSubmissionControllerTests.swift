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
        let attachment = GhosttyPendingAttachment.file(url: stagedURL)
        session?.attachments = [attachment]
        XCTAssertEqual(
            session?.snapshot,
            GhosttyComposerSessionState(
                draft: "Review this",
                attachments: [attachment]
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

    func testUploadedAttachmentAndDraftCanBeginSubmission() {
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

        XCTAssertTrue(controller.beginSubmission(message))
        XCTAssertEqual(controller.phase, .sending)
        XCTAssertEqual(controller.finishSubmission(.submitted), .submitted)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testSuccessfulSubmissionReturnsIdleAndMarksDraftDelivered() {
        var controller = GhosttyComposerSubmissionController()
        XCTAssertTrue(controller.beginSubmission("first\nsecond"))
        let result = controller.finishSubmission(.submitted)

        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(result.didDeliverDraft)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testRejectedPastePreservesDraft() {
        var controller = GhosttyComposerSubmissionController()
        XCTAssertTrue(controller.beginSubmission("draft"))
        let result = controller.finishSubmission(.pasteRejected)

        XCTAssertEqual(result, .pasteRejected)
        XCTAssertFalse(result.didDeliverDraft)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testAcceptedPasteWithRejectedEnterDoesNotOfferAnotherPaste() {
        var controller = GhosttyComposerSubmissionController()
        XCTAssertTrue(controller.beginSubmission("draft"))
        let result = controller.finishSubmission(.pastedAwaitingSubmit)

        XCTAssertEqual(result, .pastedAwaitingSubmit)
        XCTAssertTrue(result.didDeliverDraft)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testCannotBeginAnotherSubmissionWhileSending() {
        var controller = GhosttyComposerSubmissionController()
        XCTAssertTrue(controller.beginSubmission("first"))
        XCTAssertFalse(controller.beginSubmission("second"))
        XCTAssertEqual(controller.phase, .sending)
    }

    func testAttachmentTransferOwnsItsCountAndProgressAsOnePhase() {
        var controller = GhosttyComposerSubmissionController()
        let progress = GhosttyAttachmentTransferProgress(
            completedUploadCount: 1,
            totalUploadCount: 2,
            currentUploadIndex: 1,
            currentUploadedBytes: 25,
            currentTotalBytes: 100
        )

        XCTAssertTrue(controller.beginAttachmentTransfer(uploadCount: 2))
        XCTAssertTrue(controller.phase.isAttachmentTransferInProgress)
        XCTAssertEqual(controller.phase.attachmentUploadCount, 2)
        XCTAssertNil(controller.phase.attachmentTransferProgress)
        XCTAssertFalse(controller.beginSubmission("message"))

        controller.updateAttachmentTransferProgress(progress)
        XCTAssertEqual(controller.phase.attachmentTransferProgress, progress)
        XCTAssertTrue(controller.finishAttachmentTransfer())
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.phase.attachmentUploadCount, 0)
        XCTAssertNil(controller.phase.attachmentTransferProgress)
    }
}
