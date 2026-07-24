import Foundation
import NIOCore
import NIOPosix

enum GhosttyTerminalDisconnectReasonClassifier {
    static func transportStartFailure(_ error: any Error) -> TerminalDisconnectReason {
        let message = String(describing: error)

        if isServerUnreachable(error) {
            return TerminalDisconnectReason(kind: .serverUnreachable, message: message)
        }

        if let trustedHostError = error as? TrustedHostStoreError {
            switch trustedHostError {
            case .hostKeyTrustRequired(let challenge):
                return TerminalDisconnectReason(
                    kind: .hostKey,
                    message: message,
                    hostKeyChallenge: challenge
                )
            case .staleHostKeyTrust, .invalidHostKey:
                return TerminalDisconnectReason(kind: .hostKey, message: message)
            }
        }

        if let sshError = error as? SSHTmuxControlTransportError {
            switch sshError {
            case .remoteExit(let status, let diagnostics):
                if let message = tmuxExecutableFailureMessage(
                    status: status,
                    diagnostics: diagnostics
                ) {
                    return TerminalDisconnectReason(
                        kind: .tmuxUnavailable,
                        message: message
                    )
                }
                return TerminalDisconnectReason(kind: .remoteExit, message: message)
            case .channelRequestFailed:
                return TerminalDisconnectReason(kind: .profile, message: message)
            case .closed:
                return TerminalDisconnectReason(kind: .transportIO, message: message)
            case .stalePreparedConnection:
                return TerminalDisconnectReason(kind: .transportIO, message: message)
            case .alreadyStarted, .unsupportedInboundChannel, .controlSessionNoResponse:
                return TerminalDisconnectReason(kind: .profile, message: message)
            }
        }

        let lowercasedMessage = message.lowercased()
        if lowercasedMessage.contains("auth") ||
            lowercasedMessage.contains("password") ||
            lowercasedMessage.contains("permission denied") {
            return TerminalDisconnectReason(kind: .authentication, message: message)
        }

        return TerminalDisconnectReason(kind: .unknown, message: message)
    }

    private static func tmuxExecutableFailureMessage(
        status: Int,
        diagnostics: SSHTmuxStartupDiagnostics?
    ) -> String? {
        guard status == 126 || status == 127 else {
            return nil
        }

        let stderr = diagnostics?.stderrPreview?.lowercased() ?? ""
        let tmuxWasNotFound = stderr.contains("command not found") ||
            stderr.contains("no such file or directory")

        if status == 127 || tmuxWasNotFound {
            return "Install tmux on this server or update Executable Path."
        }

        return "Check the tmux executable and its permissions, then try again."
    }

    private static func isServerUnreachable(_ error: any Error) -> Bool {
        if error is NIOConnectionError {
            return true
        }

        if let channelError = error as? ChannelError,
           case .connectTimeout = channelError {
            return true
        }

        return false
    }

    static func foregroundMissingHost() -> TerminalDisconnectReason {
        TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport unavailable after foreground"
        )
    }
}
