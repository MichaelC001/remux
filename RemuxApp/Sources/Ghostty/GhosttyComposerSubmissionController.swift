struct GhosttyComposerSubmissionController: Equatable {
    enum Phase: Equatable {
        case idle
        case transferringAttachments(
            uploadCount: Int,
            progress: GhosttyAttachmentTransferProgress?
        )
        case sending

        var isAttachmentTransferInProgress: Bool {
            if case .transferringAttachments = self { return true }
            return false
        }

        var attachmentUploadCount: Int {
            guard case .transferringAttachments(let uploadCount, _) = self else {
                return 0
            }
            return uploadCount
        }

        var attachmentTransferProgress: GhosttyAttachmentTransferProgress? {
            guard case .transferringAttachments(_, let progress) = self else {
                return nil
            }
            return progress
        }
    }

    enum DraftResult: Equatable {
        case notStarted
        case pasteRejected
        case submitted
        case pastedAwaitingSubmit

        var didDeliverDraft: Bool {
            switch self {
            case .submitted, .pastedAwaitingSubmit:
                true
            case .notStarted, .pasteRejected:
                false
            }
        }
    }

    private(set) var phase: Phase = .idle

    mutating func beginAttachmentTransfer(uploadCount: Int) -> Bool {
        guard phase == .idle else { return false }
        phase = .transferringAttachments(
            uploadCount: uploadCount,
            progress: nil
        )
        return true
    }

    mutating func updateAttachmentTransferProgress(
        _ progress: GhosttyAttachmentTransferProgress
    ) {
        guard case .transferringAttachments(let uploadCount, _) = phase else {
            return
        }
        phase = .transferringAttachments(
            uploadCount: uploadCount,
            progress: progress
        )
    }

    @discardableResult
    mutating func finishAttachmentTransfer() -> Bool {
        guard case .transferringAttachments = phase else { return false }
        phase = .idle
        return true
    }

    mutating func beginSubmission(_ text: String) -> Bool {
        guard !text.isEmpty, phase == .idle else { return false }
        phase = .sending
        return true
    }

    mutating func finishSubmission(_ result: DraftResult) -> DraftResult {
        guard phase == .sending else { return .notStarted }
        phase = .idle
        return result
    }
}
