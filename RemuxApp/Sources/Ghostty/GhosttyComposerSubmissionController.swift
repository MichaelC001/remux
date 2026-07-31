struct GhosttyComposerSubmissionController: Equatable {
    enum Phase: Equatable {
        case idle
        case sending
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
