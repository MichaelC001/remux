enum SSHTmuxControlChannelRequestKind: Equatable, Sendable, CustomStringConvertible {
    case exec
    case unknown

    var description: String {
        switch self {
        case .exec:
            return "exec"
        case .unknown:
            return "channel"
        }
    }
}

struct SSHTmuxControlChannelRequestReplyTracker {
    private var pendingRequests: [SSHTmuxControlChannelRequestKind] = []

    var pendingCount: Int {
        pendingRequests.count
    }

    mutating func expectReply(for request: SSHTmuxControlChannelRequestKind) {
        pendingRequests.append(request)
    }

    mutating func acknowledgeSuccess() -> SSHTmuxControlChannelRequestKind? {
        guard !pendingRequests.isEmpty else { return nil }
        return pendingRequests.removeFirst()
    }

    mutating func acknowledgeFailure() -> SSHTmuxControlChannelRequestKind {
        acknowledgeSuccess() ?? .unknown
    }
}
