@preconcurrency import Citadel
import Foundation
import NIOCore

struct SSHPublicKeyInstallTarget: Equatable, Sendable {
    let serverID: SavedServer.ID
    let host: String
    let port: Int
    let username: String
    let privateKey: SSHPrivateKeyCredential
    let publicKeyLine: String
}

enum SSHPublicKeyPreflightOutcome: Equatable, Sendable {
    case alreadyInstalled
    case passwordRequired
}

enum SSHPublicKeyInstallerError: Error, Equatable, LocalizedError {
    case keyAcceptedButProbeFailed
    case passwordRejected
    case installationCommandFailed(exitStatus: Int, diagnostic: String?)
    case verificationRejected
    case verificationCommandFailed(exitStatus: Int, diagnostic: String?)

    var errorDescription: String? {
        switch self {
        case .keyAcceptedButProbeFailed:
            return "The SSH key was accepted, but Remux could not run the compatibility check."
        case .passwordRejected:
            return "The SSH server rejected password authentication."
        case .installationCommandFailed(let exitStatus, let diagnostic):
            return Self.commandFailureDescription(
                phase: "installing the public key",
                exitStatus: exitStatus,
                diagnostic: diagnostic
            )
        case .verificationRejected:
            return "The SSH server still rejected the public key after installation."
        case .verificationCommandFailed(let exitStatus, let diagnostic):
            return Self.commandFailureDescription(
                phase: "verifying the public key",
                exitStatus: exitStatus,
                diagnostic: diagnostic
            )
        }
    }

    private static func commandFailureDescription(
        phase: String,
        exitStatus: Int,
        diagnostic: String?
    ) -> String {
        let prefix = "The SSH server reported status \(exitStatus) while \(phase)."
        guard let diagnostic else { return prefix }
        return "\(prefix) \(diagnostic)"
    }
}

struct SSHPublicKeyCommandExecutionError: Error, Sendable {
    let underlying: Error
}

struct SSHPublicKeyInstaller: Sendable {
    typealias CommandRunner = @Sendable (
        SSHPublicKeyInstallTarget,
        SSHCredential,
        String,
        Data?
    ) async throws -> RemuxSSHExecResult

    private static let probeCommand = "exit 0"
    private static let maximumDiagnosticBytes = 4 * 1_024

    private let installationCommand: String
    private let commandRunner: CommandRunner

    init(
        installationCommand: String,
        commandRunner: @escaping CommandRunner
    ) {
        self.installationCommand = installationCommand
        self.commandRunner = commandRunner
    }

    init(
        trustedHostStore: TrustedHostStore,
        bundle: Bundle = .main
    ) throws {
        self.init(
            installationCommand: try SSHPublicKeyRemoteInstaller.command(bundle: bundle),
            commandRunner: Self.liveCommandRunner(trustedHostStore: trustedHostStore)
        )
    }

    func preflight(
        _ target: SSHPublicKeyInstallTarget
    ) async throws -> SSHPublicKeyPreflightOutcome {
        let result: RemuxSSHExecResult
        do {
            result = try await commandRunner(
                target,
                .privateKey(target.privateKey),
                Self.probeCommand,
                nil
            )
        } catch is SSHPublicKeyCommandExecutionError {
            throw SSHPublicKeyInstallerError.keyAcceptedButProbeFailed
        } catch {
            guard Self.isPrivateKeyAuthenticationRejection(error) else {
                throw error
            }
            return .passwordRequired
        }

        guard result.exitStatus == 0 else {
            throw SSHPublicKeyInstallerError.keyAcceptedButProbeFailed
        }
        return .alreadyInstalled
    }

    func append(
        _ target: SSHPublicKeyInstallTarget,
        password: String
    ) async throws {
        let result: RemuxSSHExecResult
        do {
            result = try await commandRunner(
                target,
                .password(password),
                installationCommand,
                Data("\(target.publicKeyLine)\n".utf8)
            )
        } catch {
            guard Self.isPasswordAuthenticationRejection(error) else {
                throw error
            }
            throw SSHPublicKeyInstallerError.passwordRejected
        }

        guard result.exitStatus == 0 else {
            throw SSHPublicKeyInstallerError.installationCommandFailed(
                exitStatus: result.exitStatus,
                diagnostic: Self.diagnostic(from: result)
            )
        }
    }

    func verify(_ target: SSHPublicKeyInstallTarget) async throws {
        let result: RemuxSSHExecResult
        do {
            result = try await commandRunner(
                target,
                .privateKey(target.privateKey),
                Self.probeCommand,
                nil
            )
        } catch {
            guard Self.isPrivateKeyAuthenticationRejection(error) else {
                throw error
            }
            throw SSHPublicKeyInstallerError.verificationRejected
        }

        guard result.exitStatus == 0 else {
            throw SSHPublicKeyInstallerError.verificationCommandFailed(
                exitStatus: result.exitStatus,
                diagnostic: Self.diagnostic(from: result)
            )
        }
    }

    private static func liveCommandRunner(
        trustedHostStore: TrustedHostStore
    ) -> CommandRunner {
        { target, credential, command, stdin in
            let server = SavedServer(
                id: target.serverID,
                displayName: target.host,
                host: target.host,
                port: target.port,
                username: target.username,
                identityID: target.serverID
            )
            let configuration = RemuxSSHRootConfiguration(
                host: target.host,
                port: target.port,
                authenticationMethod: {
                    try SSHAuthenticationMethodFactory.make(
                        username: target.username,
                        credential: credential
                    )
                },
                hostKeyValidator: trustedHostStore.validator(for: server),
                connectTimeout: .seconds(10)
            )
            let trace = RemuxTransportStartupTrace(
                flowID: "public-key-install.\(target.serverID.uuidString)"
            )
            let prepared = RemuxSSHPreparedRoot.dedicated(
                configuration: configuration,
                trace: trace
            )
            let root: RemuxSSHRoot
            do {
                root = try await prepared.sshRoot()
            } catch {
                await prepared.cancelAndCleanup()
                throw error
            }
            let claimed: RemuxSSHClaimedRoot
            do {
                claimed = try await prepared.claim(root, trace: trace)
            } catch {
                await prepared.cancelAndCleanup()
                throw error
            }
            do {
                return try await RemuxSSHExecSession.run(
                    using: claimed,
                    command: command,
                    stdin: stdin,
                    trace: trace
                )
            } catch {
                throw SSHPublicKeyCommandExecutionError(underlying: error)
            }
        }
    }

    private static func isPrivateKeyAuthenticationRejection(_ error: Error) -> Bool {
        guard let error = error as? SSHClientError else { return false }
        switch error {
        case .allAuthenticationOptionsFailed, .unsupportedPrivateKeyAuthentication:
            return true
        case .unsupportedPasswordAuthentication,
             .unsupportedHostBasedAuthentication,
             .channelCreationFailed:
            return false
        }
    }

    private static func isPasswordAuthenticationRejection(_ error: Error) -> Bool {
        guard let error = error as? SSHClientError else { return false }
        switch error {
        case .allAuthenticationOptionsFailed, .unsupportedPasswordAuthentication:
            return true
        case .unsupportedPrivateKeyAuthentication,
             .unsupportedHostBasedAuthentication,
             .channelCreationFailed:
            return false
        }
    }

    private static func diagnostic(from result: RemuxSSHExecResult) -> String? {
        decodeDiagnostic(result.stderr) ?? decodeDiagnostic(result.stdout)
    }

    private static func decodeDiagnostic(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let bounded = Data(data.prefix(maximumDiagnosticBytes))
        let minimumCandidateCount = max(1, bounded.count - 3)
        var candidateCount = bounded.count
        while candidateCount >= minimumCandidateCount {
            let candidate = Data(bounded.prefix(candidateCount))
            if let diagnostic = String(data: candidate, encoding: .utf8),
               !diagnostic.isEmpty {
                return diagnostic
            }
            candidateCount -= 1
        }
        return nil
    }
}
