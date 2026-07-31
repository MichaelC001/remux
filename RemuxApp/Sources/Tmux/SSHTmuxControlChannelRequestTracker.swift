enum SSHTmuxControlChannelRequestKind: Equatable, Sendable, CustomStringConvertible {
    case exec

    var description: String {
        switch self {
        case .exec:
            return "exec"
        }
    }
}
