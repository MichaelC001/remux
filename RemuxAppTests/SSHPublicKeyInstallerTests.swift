@preconcurrency import Citadel
@preconcurrency import Crypto
import Foundation
import NIO
@preconcurrency import NIOSSH
import XCTest
@testable import Remux

final class SSHPublicKeyInstallerTests: XCTestCase {
    func testPreflightReturnsAlreadyInstalledAfterZeroKeyProbe() async throws {
        let recorder = SSHPublicKeyCommandRecorder(results: [.success(.success)])
        let installer = makeInstaller(recorder: recorder)

        let outcome = try await installer.preflight(Self.target)

        XCTAssertEqual(outcome, .alreadyInstalled)
        let commands = await recorder.commands()
        let recordedCommand = try XCTUnwrap(commands.first)
        XCTAssertEqual(recordedCommand.target, Self.target)
        XCTAssertEqual(recordedCommand.credential, .privateKey(Self.target.privateKey))
        XCTAssertEqual(recordedCommand.command, "exit 0")
        XCTAssertNil(recordedCommand.stdin)
    }

    func testPreflightRequestsPasswordOnlyForAllAuthenticationOptionsFailed() async throws {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .failure(SSHClientError.allAuthenticationOptionsFailed),
        ])
        let installer = makeInstaller(recorder: recorder)

        let outcome = try await installer.preflight(Self.target)

        XCTAssertEqual(outcome, .passwordRequired)
    }

    func testPreflightRequestsPasswordWhenPublicKeyAuthenticationIsUnsupported() async throws {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .failure(SSHClientError.unsupportedPrivateKeyAuthentication),
        ])
        let installer = makeInstaller(recorder: recorder)

        let outcome = try await installer.preflight(Self.target)

        XCTAssertEqual(outcome, .passwordRequired)
    }

    func testPreflightDoesNotConvertHostTrustOrNetworkErrorsToPasswordRequired() async {
        await assertPreflightPassesThrough(TrustedHostStoreError.invalidHostKey) { error in
            error is TrustedHostStoreError
        }
        await assertPreflightPassesThrough(SSHPublicKeyInstallerTestError.networkUnavailable) { error in
            error as? SSHPublicKeyInstallerTestError == .networkUnavailable
        }
    }

    func testPreflightDoesNotConvertOtherCitadelAuthenticationErrorsToPasswordRequired() async {
        for error in [
            SSHClientError.unsupportedPasswordAuthentication,
            SSHClientError.unsupportedHostBasedAuthentication,
        ] {
            await assertPreflightPassesThrough(error) { received in
                guard let received = received as? SSHClientError else { return false }
                switch (error, received) {
                case (.unsupportedPasswordAuthentication, .unsupportedPasswordAuthentication),
                     (.unsupportedHostBasedAuthentication, .unsupportedHostBasedAuthentication):
                    return true
                default:
                    return false
                }
            }
        }
    }

    func testPreflightReportsAcceptedKeyWhenExecProbeFails() async {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .failure(
                SSHPublicKeyCommandExecutionError(
                    underlying: SSHPublicKeyInstallerTestError.execFailed
                )
            ),
        ])
        let installer = makeInstaller(recorder: recorder)

        await assertInstallerError(.keyAcceptedButProbeFailed) {
            _ = try await installer.preflight(Self.target)
        }
    }

    func testPreflightReportsAcceptedKeyWhenProbeExitsNonzero() async {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .success(.failure(exitStatus: 127, stderr: "missing shell")),
        ])
        let installer = makeInstaller(recorder: recorder)

        await assertInstallerError(.keyAcceptedButProbeFailed) {
            _ = try await installer.preflight(Self.target)
        }
    }

    func testAppendUsesPasswordAndSendsOnlyPublicKeyLineWithNewline() async throws {
        let recorder = SSHPublicKeyCommandRecorder(results: [.success(.success)])
        let installer = makeInstaller(recorder: recorder)
        let target = Self.target

        try await installer.append(target, password: "one-time-password")

        let commands = await recorder.commands()
        let recordedCommand = try XCTUnwrap(commands.first)
        XCTAssertEqual(recordedCommand.target, target)
        XCTAssertEqual(recordedCommand.credential, .password("one-time-password"))
        XCTAssertEqual(recordedCommand.stdin, Data("\(target.publicKeyLine)\n".utf8))
    }

    func testAppendMapsPasswordAuthenticationFailure() async {
        for error in [
            SSHClientError.allAuthenticationOptionsFailed,
            SSHClientError.unsupportedPasswordAuthentication,
        ] {
            let recorder = SSHPublicKeyCommandRecorder(results: [.failure(error)])
            let installer = makeInstaller(recorder: recorder)

            await assertInstallerError(.passwordRejected) {
                try await installer.append(Self.target, password: "rejected-password")
            }
        }
    }

    func testAppendPassesThroughPreAuthenticationHostTrustFailure() async {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .failure(TrustedHostStoreError.invalidHostKey),
        ])
        let installer = makeInstaller(recorder: recorder)

        do {
            try await installer.append(Self.target, password: "one-time-password")
            XCTFail("expected host-trust failure")
        } catch {
            XCTAssertTrue(error is TrustedHostStoreError)
        }
    }

    func testAppendMapsNonzeroStatusWithBoundedStderrDiagnostic() async {
        let diagnostic = String(repeating: "x", count: 8_192)
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .success(.failure(exitStatus: 73, stderr: diagnostic, stdout: "ignored stdout")),
        ])
        let installer = makeInstaller(recorder: recorder)

        do {
            try await installer.append(Self.target, password: "one-time-password")
            XCTFail("expected installation command failure")
        } catch let error as SSHPublicKeyInstallerError {
            guard case .installationCommandFailed(let exitStatus, let recordedDiagnostic) = error else {
                return XCTFail("unexpected installer error: \(error)")
            }
            XCTAssertEqual(exitStatus, 73)
            XCTAssertEqual(recordedDiagnostic, String(repeating: "x", count: 4_096))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAppendFallsBackToStdoutDiagnosticWhenStderrIsNotUTF8() async {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .success(
                RemuxSSHExecResult(
                    exitStatus: 74,
                    stdout: Data("home is unavailable".utf8),
                    stderr: Data([0xff])
                )
            ),
        ])
        let installer = makeInstaller(recorder: recorder)

        await assertInstallerError(
            .installationCommandFailed(exitStatus: 74, diagnostic: "home is unavailable")
        ) {
            try await installer.append(Self.target, password: "one-time-password")
        }
    }

    func testAppendPreservesValidUTF8BeforeDiagnosticBoundary() async {
        let validPrefix = String(repeating: "x", count: 4_095)
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .success(
                .failure(
                    exitStatus: 75,
                    stderr: "\(validPrefix)😀truncated",
                    stdout: "fallback"
                )
            ),
        ])
        let installer = makeInstaller(recorder: recorder)

        await assertInstallerError(
            .installationCommandFailed(exitStatus: 75, diagnostic: validPrefix)
        ) {
            try await installer.append(Self.target, password: "one-time-password")
        }
    }

    func testAppendPreservesValidUTF8WhenDiagnosticBoundaryIncludesThreeBytesOfScalar() async {
        let validPrefix = String(repeating: "x", count: 4_093)
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .success(
                .failure(
                    exitStatus: 76,
                    stderr: "\(validPrefix)😀truncated",
                    stdout: "fallback"
                )
            ),
        ])
        let installer = makeInstaller(recorder: recorder)

        await assertInstallerError(
            .installationCommandFailed(exitStatus: 76, diagnostic: validPrefix)
        ) {
            try await installer.append(Self.target, password: "one-time-password")
        }
    }

    func testVerifyMapsKeyAuthenticationFailure() async {
        for error in [
            SSHClientError.allAuthenticationOptionsFailed,
            SSHClientError.unsupportedPrivateKeyAuthentication,
        ] {
            let recorder = SSHPublicKeyCommandRecorder(results: [.failure(error)])
            let installer = makeInstaller(recorder: recorder)

            await assertInstallerError(.verificationRejected) {
                try await installer.verify(Self.target)
            }
        }
    }

    func testVerifyMapsNonzeroStatusWithStderrDiagnostic() async {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .success(.failure(exitStatus: 126, stderr: "exec prohibited")),
        ])
        let installer = makeInstaller(recorder: recorder)

        await assertInstallerError(
            .verificationCommandFailed(exitStatus: 126, diagnostic: "exec prohibited")
        ) {
            try await installer.verify(Self.target)
        }
    }

    func testVerifyUsesFreshKeyProbe() async throws {
        let recorder = SSHPublicKeyCommandRecorder(results: [.success(.success)])
        let installer = makeInstaller(recorder: recorder)

        try await installer.verify(Self.target)

        let commands = await recorder.commands()
        let recordedCommand = try XCTUnwrap(commands.first)
        XCTAssertEqual(recordedCommand.target, Self.target)
        XCTAssertEqual(recordedCommand.credential, .privateKey(Self.target.privateKey))
        XCTAssertEqual(recordedCommand.command, "exit 0")
        XCTAssertNil(recordedCommand.stdin)
    }

    func testEveryLiveCommandUsesDedicatedRootAndClosesIt() async throws {
        let generatedKey = SSHPrivateKeyInspector.generateEd25519(comment: "live-installer-test")
        let serverID = UUID()
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux")
        defer { server.stop() }
        let trustedHostRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHPublicKeyInstallerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trustedHostRoot) }
        let trustedHostStore = TrustedHostStore(
            rootURL: trustedHostRoot
        )
        try trustedHostStore.trustHostKey(
            SSHHostKeyTrustChallenge(
                kind: .unknown,
                serverID: serverID,
                host: "127.0.0.1",
                trustedKeyType: nil,
                trustedOpenSSHPublicKey: nil,
                receivedKeyType: server.hostKeyType,
                receivedOpenSSHPublicKey: server.openSSHPublicKey
            )
        )
        let target = SSHPublicKeyInstallTarget(
            serverID: serverID,
            host: "127.0.0.1",
            port: server.port,
            username: "remux",
            privateKey: SSHPrivateKeyCredential(privateKeyPEM: generatedKey.privateKeyPEM),
            publicKeyLine: generatedKey.publicKeyLine
        )
        let installer = try SSHPublicKeyInstaller(trustedHostStore: trustedHostStore)

        let preflightOutcome = try await installer.preflight(target)
        XCTAssertEqual(preflightOutcome, .alreadyInstalled)
        let didClosePreflightRoot = await server.waitForClosedRootCount(1)
        XCTAssertTrue(didClosePreflightRoot, "\(server.recordedRoots)")

        try await installer.append(target, password: "one-time-password")
        let didCloseAppendRoot = await server.waitForClosedRootCount(2)
        XCTAssertTrue(didCloseAppendRoot, "\(server.recordedRoots)")

        try await installer.verify(target)
        let didCloseVerificationRoot = await server.waitForClosedRootCount(3)
        XCTAssertTrue(didCloseVerificationRoot, "\(server.recordedRoots)")

        let roots = server.recordedRoots
        XCTAssertEqual(roots.opened.count, 3)
        XCTAssertEqual(Set(roots.opened).count, 3)
        XCTAssertEqual(Set(roots.closed), Set(roots.opened))
    }

    private func makeInstaller(
        recorder: SSHPublicKeyCommandRecorder
    ) -> SSHPublicKeyInstaller {
        SSHPublicKeyInstaller(
            installationCommand: "fixture installer command",
            commandRunner: { target, credential, command, stdin in
                try await recorder.run(
                    target: target,
                    credential: credential,
                    command: command,
                    stdin: stdin
                )
            }
        )
    }

    private func assertPreflightPassesThrough(
        _ expectedError: Error,
        matches: @escaping (Error) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let recorder = SSHPublicKeyCommandRecorder(results: [.failure(expectedError)])
        let installer = makeInstaller(recorder: recorder)

        do {
            _ = try await installer.preflight(Self.target)
            XCTFail("expected preflight failure", file: file, line: line)
        } catch {
            XCTAssertTrue(matches(error), "unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertInstallerError(
        _ expectedError: SSHPublicKeyInstallerError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected installer error", file: file, line: line)
        } catch let error as SSHPublicKeyInstallerError {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private static let target = SSHPublicKeyInstallTarget(
        serverID: UUID(uuidString: "CF6C1653-2B17-41DC-8277-FD31E6222F61")!,
        host: "server.example.test",
        port: 2222,
        username: "remux",
        privateKey: SSHPrivateKeyCredential(
            privateKeyPEM: "fixture private key",
            passphrase: "fixture passphrase"
        ),
        publicKeyLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixture remux@test"
    )
}

private actor SSHPublicKeyCommandRecorder {
    private var results: [Result<RemuxSSHExecResult, Error>]
    private var recordedCommands: [SSHPublicKeyRecordedCommand] = []

    init(results: [Result<RemuxSSHExecResult, Error>]) {
        self.results = results
    }

    func run(
        target: SSHPublicKeyInstallTarget,
        credential: SSHCredential,
        command: String,
        stdin: Data?
    ) throws -> RemuxSSHExecResult {
        recordedCommands.append(
            SSHPublicKeyRecordedCommand(
                target: target,
                credential: credential,
                command: command,
                stdin: stdin
            )
        )
        guard !results.isEmpty else {
            throw SSHPublicKeyInstallerTestError.missingResult
        }
        return try results.removeFirst().get()
    }

    func commands() -> [SSHPublicKeyRecordedCommand] {
        recordedCommands
    }
}

private struct SSHPublicKeyRecordedCommand: Equatable, Sendable {
    let target: SSHPublicKeyInstallTarget
    let credential: SSHCredential
    let command: String
    let stdin: Data?
}

private enum SSHPublicKeyInstallerTestError: Error, Equatable {
    case execFailed
    case missingResult
    case networkUnavailable
}

private final class SSHPublicKeyLiveTestServer: @unchecked Sendable {
    let port: Int
    let openSSHPublicKey: String
    let hostKeyType: String

    private let serverChannel: Channel
    private let rootRecorder: SSHPublicKeyLiveRootRecorder

    var recordedRoots: SSHPublicKeyLiveRootRecorder.Snapshot {
        rootRecorder.snapshot()
    }

    private init(
        serverChannel: Channel,
        hostPublicKey: NIOSSHPublicKey,
        rootRecorder: SSHPublicKeyLiveRootRecorder
    ) throws {
        guard let port = serverChannel.localAddress?.port else {
            throw SSHPublicKeyLiveTestServerError.missingPort
        }
        let openSSHPublicKey = String(openSSHPublicKey: hostPublicKey)
        guard let hostKeyType = openSSHPublicKey
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init) else {
            throw SSHPublicKeyLiveTestServerError.invalidHostKey
        }

        self.port = port
        self.openSSHPublicKey = openSSHPublicKey
        self.hostKeyType = hostKeyType
        self.serverChannel = serverChannel
        self.rootRecorder = rootRecorder
    }

    static func start(username: String) async throws -> SSHPublicKeyLiveTestServer {
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let authenticationDelegate = SSHPublicKeyLiveAuthenticationDelegate(username: username)
        let rootRecorder = SSHPublicKeyLiveRootRecorder()
        let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                let rootID = UUID()
                rootRecorder.open(rootID)
                channel.closeFuture.whenComplete { _ in
                    rootRecorder.close(rootID)
                }
                let sshConfiguration = SSHServerConfiguration(
                    hostKeys: [hostKey],
                    userAuthDelegate: authenticationDelegate
                )
                let sshHandler = NIOSSHHandler(
                    role: .server(sshConfiguration),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { childChannel, channelType in
                        guard channelType == .session else {
                            return childChannel.eventLoop.makeFailedFuture(
                                SSHPublicKeyLiveTestServerError.invalidChannelType
                            )
                        }
                        return childChannel
                            .setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                            .flatMap {
                                childChannel.pipeline.addHandler(SSHPublicKeyLiveExecHandler())
                            }
                    }
                )
                do {
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(SSHPublicKeyLiveErrorHandler())
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        return try SSHPublicKeyLiveTestServer(
            serverChannel: serverChannel,
            hostPublicKey: hostKey.publicKey,
            rootRecorder: rootRecorder
        )
    }

    func waitForClosedRootCount(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if rootRecorder.snapshot().closed.count == count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return rootRecorder.snapshot().closed.count == count
    }

    func stop() {
        serverChannel.close(promise: nil)
    }
}

private final class SSHPublicKeyLiveAuthenticationDelegate:
    NIOSSHServerUserAuthenticationDelegate,
    @unchecked Sendable
{
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [
        .password,
        .publicKey,
    ]

    private let username: String

    init(username: String) {
        self.username = username
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == username else {
            responsePromise.succeed(.failure)
            return
        }
        switch request.request {
        case .password, .publicKey:
            responsePromise.succeed(.success)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

private final class SSHPublicKeyLiveExecHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private var didAcceptExec = false

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let request as SSHChannelRequestEvent.ExecRequest:
            didAcceptExec = true
            if request.wantReply {
                context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
        case ChannelEvent.inputClosed:
            guard didAcceptExec else {
                context.close(promise: nil)
                return
            }
            let channel = context.channel
            _ = channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExitStatus(exitStatus: 0)
            ).flatMap {
                channel.close()
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

private final class SSHPublicKeyLiveErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private final class SSHPublicKeyLiveRootRecorder: @unchecked Sendable {
    struct Snapshot {
        let opened: [UUID]
        let closed: [UUID]
    }

    private let lock = NSLock()
    private var opened: [UUID] = []
    private var closed: [UUID] = []

    func open(_ rootID: UUID) {
        lock.withLock {
            opened.append(rootID)
        }
    }

    func close(_ rootID: UUID) {
        lock.withLock {
            closed.append(rootID)
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(opened: opened, closed: closed)
        }
    }
}

private enum SSHPublicKeyLiveTestServerError: Error {
    case invalidChannelType
    case invalidHostKey
    case missingPort
}

private extension RemuxSSHExecResult {
    static let success = RemuxSSHExecResult(
        exitStatus: 0,
        stdout: Data(),
        stderr: Data()
    )

    static func failure(
        exitStatus: Int,
        stderr: String,
        stdout: String = ""
    ) -> RemuxSSHExecResult {
        RemuxSSHExecResult(
            exitStatus: exitStatus,
            stdout: Data(stdout.utf8),
            stderr: Data(stderr.utf8)
        )
    }
}
