import Foundation

struct GhosttyComposerSubmissionController: Equatable {
    enum Phase: Equatable {
        case idle
        case sending
        case awaitingSubmit(surfaceID: UUID)
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

    enum SubmitResult: Equatable {
        case notWaiting
        case destinationChanged
        case enterRejected
        case submitted
    }

    private(set) var phase: Phase = .idle

    mutating func submitDraft(
        _ text: String,
        to surfaceID: UUID,
        sendPaste: (String) -> Bool,
        sendEnter: () -> Bool
    ) -> DraftResult {
        guard !text.isEmpty, phase == .idle else { return .notStarted }

        phase = .sending
        guard sendPaste(text) else {
            phase = .idle
            return .pasteRejected
        }

        guard sendEnter() else {
            phase = .awaitingSubmit(surfaceID: surfaceID)
            return .pastedAwaitingSubmit
        }

        phase = .idle
        return .submitted
    }

    mutating func submitDeliveredPaste(
        on currentSurfaceID: UUID?,
        sendEnter: () -> Bool
    ) -> SubmitResult {
        guard case .awaitingSubmit(let surfaceID) = phase else {
            return .notWaiting
        }
        guard currentSurfaceID == surfaceID else {
            phase = .idle
            return .destinationChanged
        }

        phase = .sending
        guard sendEnter() else {
            phase = .awaitingSubmit(surfaceID: surfaceID)
            return .enterRejected
        }

        phase = .idle
        return .submitted
    }

    mutating func clearAwaitingSubmit() {
        guard case .awaitingSubmit = phase else { return }
        phase = .idle
    }
}
