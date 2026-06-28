import Foundation

struct TerminalRuntimeStatusPresentation: Equatable, Sendable {
    static let defaultLoadingTitle = "Opening session"

    enum Tone: Equatable, Sendable {
        case connecting
        case reconnecting
        case connected
        case disconnected
    }

    let label: String
    let tone: Tone
    let loadingTitle: String?

    static func projection(for state: TerminalRuntimeState) -> TerminalRuntimeStatusPresentation {
        switch state {
        case .connecting:
            TerminalRuntimeStatusPresentation(
                label: "Connecting",
                tone: .connecting,
                loadingTitle: defaultLoadingTitle
            )
        case .reconnecting:
            TerminalRuntimeStatusPresentation(
                label: "Reconnecting",
                tone: .reconnecting,
                loadingTitle: "Reconnecting"
            )
        case .connected:
            TerminalRuntimeStatusPresentation(
                label: "Connected",
                tone: .connected,
                loadingTitle: nil
            )
        case .disconnected(let reason):
            TerminalRuntimeStatusPresentation(
                label: disconnectedLabel(for: reason),
                tone: .disconnected,
                loadingTitle: nil
            )
        }
    }

    private static func disconnectedLabel(for reason: TerminalDisconnectReason) -> String {
        switch reason.kind {
        case .authentication:
            "Auth Failed"
        case .serverUnreachable:
            "Unreachable"
        case .hostKey:
            "Host Key"
        case .profile:
            "Profile Error"
        case .remoteExit:
            "Exited"
        case .runtime:
            "Terminal Error"
        case .userClosed:
            "Closed"
        case .transportIO, .unknown:
            "Disconnected"
        }
    }
}
