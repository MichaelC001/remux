import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

struct RemuxSSHExecResult: Equatable, Sendable {
    let exitStatus: Int
    let stdout: Data
    let stderr: Data
}

enum RemuxSSHExecSessionError: Error, Equatable, LocalizedError {
    case requestFailed
    case missingExitStatus
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .requestFailed:
            return "The SSH server rejected the exec request."
        case .missingExitStatus:
            return "The SSH command closed without reporting an exit status."
        case .outputTooLarge:
            return "The SSH command produced more output than Remux can capture."
        }
    }
}

final class RemuxSSHExecConnection: @unchecked Sendable {
    private let sessionChannel: Channel
    private let isRootActive: @Sendable () -> Bool
    private let releaseRoot: @Sendable (RemuxSSHRootLeaseDisposition) async -> Void
    private let allocator = ByteBufferAllocator()
    private let closeLock = NIOLock()
    private var didClose = false

    init(
        sessionChannel: Channel,
        isRootActive: @escaping @Sendable () -> Bool = { true },
        releaseRoot: @escaping @Sendable (RemuxSSHRootLeaseDisposition) async -> Void
    ) {
        self.sessionChannel = sessionChannel
        self.isRootActive = isRootActive
        self.releaseRoot = releaseRoot
    }

    var isActive: Bool {
        isRootActive() && sessionChannel.isActive
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }

        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await sessionChannel.writeAndFlush(
            SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        )
    }

    func finishInput() async throws {
        do {
            try await sessionChannel.close(mode: .output)
        } catch ChannelError.alreadyClosed {
            return
        }
    }

    func close(disposition: RemuxSSHRootLeaseDisposition) async {
        let shouldClose = closeLock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldClose else { return }

        let rootDisposition: RemuxSSHRootLeaseDisposition
        do {
            try await sessionChannel.close()
            rootDisposition = disposition
        } catch ChannelError.alreadyClosed {
            rootDisposition = disposition
        } catch {
            NSLog("Remux SSH exec channel close failed: %@", String(describing: error))
            rootDisposition = .invalidated
        }
        await releaseRoot(rootDisposition)
    }
}

enum RemuxSSHExecSession {
    static func open(
        using claimedRoot: RemuxSSHClaimedRoot,
        command: String,
        trace: RemuxTransportStartupTrace,
        onData: @escaping @Sendable (SSHChannelData.DataType, Data) -> Void,
        onFinish: @escaping @Sendable (Int?, Error?) -> Void
    ) async throws -> RemuxSSHExecConnection {
        var connection: RemuxSSHExecConnection?
        do {
            let sessionChannel = try await claimedRoot.sshRoot.openSessionChannel(trace: trace)
            let openedConnection = RemuxSSHExecConnection(
                sessionChannel: sessionChannel,
                isRootActive: {
                    claimedRoot.sshRoot.rootChannel.isActive
                },
                releaseRoot: { disposition in
                    await claimedRoot.release(disposition)
                }
            )
            connection = openedConnection
            let handler = RemuxSSHExecChannelHandler(
                onData: onData,
                onFinish: onFinish
            )

            try await trace.stage("sessionChannel.handler.add") {
                try await sessionChannel.pipeline.addHandler(handler).get()
            }
            try await trace.stage(
                "exec.request",
                fields: ["commandBytes": "\(command.lengthOfBytes(using: .utf8))"]
            ) {
                handler.expectExecReply()
                try await sessionChannel.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.ExecRequest(
                        command: command,
                        wantReply: true
                    )
                )
            }
            return openedConnection
        } catch {
            if let connection {
                await connection.close(disposition: .invalidated)
            } else {
                await claimedRoot.release(.invalidated)
            }
            throw error
        }
    }

    static func run(
        using claimedRoot: RemuxSSHClaimedRoot,
        command: String,
        stdin: Data?,
        trace: RemuxTransportStartupTrace
    ) async throws -> RemuxSSHExecResult {
        let collector = RemuxSSHExecResultCollector()

        return try await withTaskCancellationHandler {
            var connection: RemuxSSHExecConnection?
            do {
                let openedConnection = try await open(
                    using: claimedRoot,
                    command: command,
                    trace: trace,
                    onData: { type, data in
                        collector.receive(type: type, data: data)
                    },
                    onFinish: { exitStatus, error in
                        collector.finish(exitStatus: exitStatus, error: error)
                    }
                )
                connection = openedConnection
                try Task.checkCancellation()

                if let stdin {
                    try await openedConnection.write(stdin)
                }
                try Task.checkCancellation()
                try await openedConnection.finishInput()
                try Task.checkCancellation()

                let result = try await collector.value()
                try Task.checkCancellation()
                await openedConnection.close(disposition: .reusable)
                return result
            } catch {
                await connection?.close(disposition: .invalidated)
                throw error
            }
        } onCancel: {
            collector.cancel()
        }
    }
}

final class RemuxSSHExecResultCollector: @unchecked Sendable {
    private static let maximumCapturedStreamBytes = 64 * 1024

    private struct Completion {
        let result: Result<RemuxSSHExecResult, Error>
        let continuation: CheckedContinuation<RemuxSSHExecResult, Error>?
    }

    private let lock = NIOLock()
    private var stdout = Data()
    private var stderr = Data()
    private var result: Result<RemuxSSHExecResult, Error>?
    private var continuation: CheckedContinuation<RemuxSSHExecResult, Error>?

    func receive(type: SSHChannelData.DataType, data: Data) {
        guard !data.isEmpty else { return }

        let completion = lock.withLock { () -> Completion? in
            guard result == nil else { return nil }

            switch type {
            case .channel:
                guard stdout.count <= Self.maximumCapturedStreamBytes - data.count else {
                    let terminalResult: Result<RemuxSSHExecResult, Error> = .failure(
                        RemuxSSHExecSessionError.outputTooLarge
                    )
                    return Completion(
                        result: terminalResult,
                        continuation: finishLocked(terminalResult)
                    )
                }
                stdout.append(data)
            case .stdErr:
                guard stderr.count <= Self.maximumCapturedStreamBytes - data.count else {
                    let terminalResult: Result<RemuxSSHExecResult, Error> = .failure(
                        RemuxSSHExecSessionError.outputTooLarge
                    )
                    return Completion(
                        result: terminalResult,
                        continuation: finishLocked(terminalResult)
                    )
                }
                stderr.append(data)
            default:
                break
            }
            return nil
        }
        if let completion {
            completion.result.resume(completion.continuation)
        }
    }

    func finish(exitStatus: Int?, error: Error?) {
        let completion = lock.withLock { () -> Completion? in
            guard result == nil else { return nil }

            let terminalResult: Result<RemuxSSHExecResult, Error>
            if let error {
                terminalResult = .failure(error)
            } else if let exitStatus {
                terminalResult = .success(
                    RemuxSSHExecResult(
                        exitStatus: exitStatus,
                        stdout: stdout,
                        stderr: stderr
                    )
                )
            } else {
                terminalResult = .failure(RemuxSSHExecSessionError.missingExitStatus)
            }
            return Completion(
                result: terminalResult,
                continuation: finishLocked(terminalResult)
            )
        }
        if let completion {
            completion.result.resume(completion.continuation)
        }
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    func value() async throws -> RemuxSSHExecResult {
        try await withCheckedThrowingContinuation { continuation in
            let completedResult = lock.withLock { () -> Result<RemuxSSHExecResult, Error>? in
                if let result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            completedResult?.resume(continuation)
        }
    }

    private func complete(_ terminalResult: Result<RemuxSSHExecResult, Error>) {
        let completion = lock.withLock { () -> Completion? in
            guard result == nil else { return nil }
            return Completion(
                result: terminalResult,
                continuation: finishLocked(terminalResult)
            )
        }
        if let completion {
            completion.result.resume(completion.continuation)
        }
    }

    private func finishLocked(
        _ terminalResult: Result<RemuxSSHExecResult, Error>
    ) -> CheckedContinuation<RemuxSSHExecResult, Error>? {
        guard result == nil else { return nil }
        result = terminalResult
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}

final class RemuxSSHExecChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let onData: @Sendable (SSHChannelData.DataType, Data) -> Void
    private let onFinish: @Sendable (Int?, Error?) -> Void
    private let lock = NIOLock()
    private var pendingExecReplies = 0
    private var exitStatus: Int?
    private var didFinish = false

    init(
        onData: @escaping @Sendable (SSHChannelData.DataType, Data) -> Void,
        onFinish: @escaping @Sendable (Int?, Error?) -> Void
    ) {
        self.onData = onData
        self.onFinish = onFinish
    }

    func expectExecReply() {
        lock.withLock {
            pendingExecReplies += 1
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(
            ChannelOptions.allowRemoteHalfClosure,
            value: true
        ).whenFailure { [weak self] error in
            self?.finish(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            lock.withLock {
                exitStatus = Int(status.exitStatus)
            }
        case is ChannelSuccessEvent:
            lock.withLock {
                pendingExecReplies = max(0, pendingExecReplies - 1)
            }
        case is NIOSSH.ChannelFailureEvent:
            lock.withLock {
                pendingExecReplies = max(0, pendingExecReplies - 1)
            }
            finish(RemuxSSHExecSessionError.requestFailed)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty
        else {
            return
        }

        onData(channelData.type, Data(bytes))
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(nil)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish(nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(error)
        context.close(promise: nil)
    }

    private func finish(_ error: Error?) {
        let completion = lock.withLock { () -> (Int?, Error?)? in
            guard !didFinish else { return nil }
            didFinish = true
            return (exitStatus, error)
        }
        guard let completion else { return }
        onFinish(completion.0, completion.1)
    }
}

private extension Result where Success == RemuxSSHExecResult, Failure == Error {
    func resume(_ continuation: CheckedContinuation<Success, Failure>?) {
        guard let continuation else { return }
        switch self {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
