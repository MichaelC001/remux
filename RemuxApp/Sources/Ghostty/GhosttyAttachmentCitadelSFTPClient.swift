@preconcurrency import Citadel
import Foundation
import NIO

struct GhosttyAttachmentCitadelSFTPClient: GhosttyAttachmentSFTPClient {
    private static let pipelinedWriteMaxInFlight = 64

    let sftp: SFTPClient
    let chunkSize: Int
    let operationTimeout: TimeAmount
    private let leaseState: GhosttyAttachmentCitadelSFTPLeaseState

    fileprivate init(
        sftp: SFTPClient,
        chunkSize: Int = 4 * 1024 * 1024,
        operationTimeout: TimeAmount = .seconds(15),
        leaseState: GhosttyAttachmentCitadelSFTPLeaseState
    ) {
        self.sftp = sftp
        self.chunkSize = chunkSize
        self.operationTimeout = operationTimeout
        self.leaseState = leaseState
    }

    func realPath(atPath path: String) async throws -> String {
        try await withOperationTimeout {
            try await sftp.getRealPath(atPath: path)
        }
    }

    func ensureDirectoryExists(atPath path: String) async throws {
        do {
            _ = try await getAttributes(at: path)
            return
        } catch where isNoSuchFile(error) {
            do {
                try await withOperationTimeout {
                    try await sftp.createDirectory(atPath: path)
                }
            } catch {
                if try await exists(atPath: path) {
                    return
                }
                throw error
            }
        }
    }

    func uploadFile(
        from localURL: URL,
        to remotePath: String,
        progress: @escaping GhosttyAttachmentFileUploadProgressHandler
    ) async throws {
        let localFile = try FileHandle(forReadingFrom: localURL)
        defer {
            try? localFile.close()
        }

        let remoteFile = try await openRemoteFile(at: remotePath)

        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()

                let data = try localFile.read(upToCount: chunkSize) ?? Data()
                guard !data.isEmpty else { break }

                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                let writeBuffer = buffer
                let writeOffset = offset
                try await withOperationTimeout {
                    try await remoteFile.file.writePipelined(
                        writeBuffer,
                        at: writeOffset,
                        maxInFlight: Self.pipelinedWriteMaxInFlight
                    )
                }
                offset += UInt64(data.count)
                await progress(Int64(min(offset, UInt64(Int64.max))))
            }

            try await closeRemoteFile(remoteFile)
        } catch let error as GhosttyAttachmentSFTPClientError where error == .operationTimedOut {
            throw GhosttyAttachmentSFTPClientError.operationTimedOut
        } catch {
            try? await closeRemoteFile(remoteFile)
            throw error
        }
    }

    func renameFile(from temporaryPath: String, to finalPath: String) async throws {
        try await withOperationTimeout {
            try await sftp.rename(at: temporaryPath, to: finalPath)
        }
    }

    func removeFileIfExists(atPath path: String) async throws {
        do {
            try await withOperationTimeout {
                try await sftp.remove(at: path)
            }
        } catch where isNoSuchFile(error) {
            return
        }
    }

    private func openRemoteFile(at remotePath: String) async throws -> GhosttyAttachmentCitadelSFTPFileBox {
        try await withOperationTimeout {
            let file = try await sftp.openFile(
                filePath: remotePath,
                flags: [.write, .create, .truncate]
            )
            return GhosttyAttachmentCitadelSFTPFileBox(file: file)
        }
    }

    private func closeRemoteFile(_ fileBox: GhosttyAttachmentCitadelSFTPFileBox) async throws {
        try await withOperationTimeout {
            try await fileBox.file.close()
        }
    }

    private func exists(atPath path: String) async throws -> Bool {
        do {
            _ = try await getAttributes(at: path)
            return true
        } catch where isNoSuchFile(error) {
            return false
        }
    }

    private func getAttributes(at path: String) async throws -> SFTPFileAttributes {
        try await withOperationTimeout {
            try await sftp.getAttributes(at: path)
        }
    }

    private func withOperationTimeout<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let timeout = operationTimeout
        let leaseState = leaseState

        try await leaseState.checkActive()

        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(clamping: timeout.nanoseconds))
                await leaseState.invalidateAfterTimeout()
                throw GhosttyAttachmentSFTPClientError.operationTimedOut
            }

            do {
                guard let result = try await group.next() else {
                    throw GhosttyAttachmentSFTPClientError.operationTimedOut
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func isNoSuchFile(_ error: Error) -> Bool {
        guard let status = error as? SFTPMessage.Status else {
            return false
        }
        return status.errorCode == .noSuchFile
    }
}

private final class GhosttyAttachmentCitadelSFTPFileBox: @unchecked Sendable {
    let file: SFTPFile

    init(file: SFTPFile) {
        self.file = file
    }
}

private final class GhosttyAttachmentSFTPLeaseOpenTimeoutGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let pendingResult: Result<Value, Error>?
        lock.lock()
        if isFinished {
            pendingResult = self.pendingResult
        } else {
            self.continuation = continuation
            pendingResult = nil
        }
        lock.unlock()

        if let pendingResult {
            continuation.resume(with: pendingResult)
        }
    }

    func setTasks(_ tasks: [Task<Void, Never>]) {
        let tasksToCancel: [Task<Void, Never>]
        lock.lock()
        if isFinished {
            tasksToCancel = tasks
        } else {
            self.tasks = tasks
            tasksToCancel = []
        }
        lock.unlock()

        for task in tasksToCancel {
            task.cancel()
        }
    }

    @discardableResult
    func succeed(_ value: Value) -> Bool {
        finish(.success(value))
    }

    @discardableResult
    func fail(_ error: Error) -> Bool {
        finish(.failure(error))
    }

    func cancel() {
        _ = fail(CancellationError())
    }

    @discardableResult
    private func finish(_ result: Result<Value, Error>) -> Bool {
        let continuation: CheckedContinuation<Value, Error>?
        let tasksToCancel: [Task<Void, Never>]

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }

        isFinished = true
        pendingResult = result
        continuation = self.continuation
        self.continuation = nil
        tasksToCancel = tasks
        tasks.removeAll()
        lock.unlock()

        for task in tasksToCancel {
            task.cancel()
        }

        continuation?.resume(with: result)
        return true
    }
}

private actor GhosttyAttachmentCitadelSFTPLeaseState {
    private let sftp: SFTPClient
    private let closeRoot: @Sendable (RemuxSSHRootLeaseDisposition) async throws -> Void
    private var timedOut = false
    private var closeTask: Task<Void, Error>?

    init(
        sftp: SFTPClient,
        closeRoot: @escaping @Sendable (RemuxSSHRootLeaseDisposition) async throws -> Void
    ) {
        self.sftp = sftp
        self.closeRoot = closeRoot
    }

    func checkActive() throws {
        if timedOut {
            throw GhosttyAttachmentSFTPClientError.operationTimedOut
        }
    }

    func invalidateAfterTimeout() {
        timedOut = true
        let task = closeTaskIfNeeded()

        Task {
            do {
                try await task.value
            } catch {
                NSLog("Remux attachment SFTP close after timeout failed: %@", String(describing: error))
            }
        }
    }

    func close() async throws {
        if timedOut {
            _ = closeTaskIfNeeded()
            return
        }

        let task = closeTaskIfNeeded()
        try await task.value
    }

    private func closeTaskIfNeeded() -> Task<Void, Error> {
        if let closeTask {
            return closeTask
        }

        let sftp = sftp
        let closeRoot = closeRoot
        let invalidatedByTimeout = timedOut

        let task = Task {
            var closeFailure: Error?

            do {
                try await sftp.close()
            } catch {
                closeFailure = error
            }

            do {
                let disposition: RemuxSSHRootLeaseDisposition =
                    (invalidatedByTimeout || closeFailure != nil) ? .invalidated : .reusable
                try await closeRoot(disposition)
            } catch {
                if closeFailure == nil {
                    closeFailure = error
                } else {
                    NSLog("Remux attachment SFTP root release failed after SFTP close failure: %@", String(describing: error))
                }
            }

            if let closeFailure {
                throw closeFailure
            }
        }

        closeTask = task
        return task
    }
}

struct GhosttyAttachmentCitadelSFTPClientProvider: GhosttyAttachmentSFTPClientProvider {
    private let provider: GhosttyAttachmentShortLivedSFTPClientProvider<GhosttyAttachmentCitadelSFTPClient>

    init(
        sshRootService: RemuxSSHRootService,
        rootKey: RemuxSSHRootKey,
        rootConfiguration: RemuxSSHRootConfiguration,
        operationTimeout: TimeAmount,
        chunkSize: Int = 4 * 1024 * 1024,
        closeFailureHandler: @escaping @Sendable (Error) -> Void = { error in
            NSLog("Remux attachment Citadel SFTP lease close failed: %@", String(describing: error))
        }
    ) {
        self.provider = GhosttyAttachmentShortLivedSFTPClientProvider(
            openLease: {
                try await Self.openLease(
                    sshRootService: sshRootService,
                    rootKey: rootKey,
                    rootConfiguration: rootConfiguration,
                    operationTimeout: operationTimeout,
                    chunkSize: chunkSize
                )
            },
            closeFailureHandler: closeFailureHandler
        )
    }

    func withClient<ReturnValue: Sendable>(
        _ operation: @Sendable (GhosttyAttachmentCitadelSFTPClient) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        try await provider.withClient(operation)
    }

    static func withLeaseOpenTimeout<Value: Sendable>(
        operationTimeout: TimeAmount,
        operation: @escaping @Sendable () async throws -> Value,
        cleanupLateSuccess: @escaping @Sendable (Value) async -> Void = { _ in }
    ) async throws -> Value {
        let gate = GhosttyAttachmentSFTPLeaseOpenTimeoutGate<Value>()
        let timeoutNanos = UInt64(clamping: operationTimeout.nanoseconds)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let operationTask = Task {
                    do {
                        let value = try await operation()
                        if !gate.succeed(value) {
                            await cleanupLateSuccess(value)
                        }
                    } catch {
                        _ = gate.fail(error)
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanos)
                        _ = gate.fail(GhosttyAttachmentSFTPClientError.operationTimedOut)
                    } catch {
                        _ = gate.fail(error)
                    }
                }
                gate.setTasks([operationTask, timeoutTask])
            }
        } onCancel: {
            gate.cancel()
        }
    }

    private static func openLease(
        sshRootService: RemuxSSHRootService,
        rootKey: RemuxSSHRootKey,
        rootConfiguration: RemuxSSHRootConfiguration,
        operationTimeout: TimeAmount,
        chunkSize: Int
    ) async throws -> GhosttyAttachmentSFTPClientLease<GhosttyAttachmentCitadelSFTPClient> {
        let trace = RemuxTransportStartupTrace(flowID: nil)
        let preparedRoot = await sshRootService.preparedRoot(
            for: rootKey,
            configuration: rootConfiguration,
            trace: trace
        )

        let sshRoot: RemuxSSHRoot
        do {
            sshRoot = try await trace.stage("sshRoot.ready") {
                try await preparedRoot.sshRoot()
            }
        } catch {
            await preparedRoot.cancelAndCleanup()
            throw error
        }

        let claimedRoot: RemuxSSHClaimedRoot
        do {
            claimedRoot = try await preparedRoot.claim(sshRoot, trace: trace)
        } catch {
            await preparedRoot.cancelAndCleanup()
            throw error
        }

        do {
            let sftpOpenStartedAt = GhosttyRuntimeTrace.latencyEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
            GhosttyRuntimeTrace.latency("sftp.open begin host=\(rootConfiguration.host):\(rootConfiguration.port)")
            let sftp = try await Self.withLeaseOpenTimeout(
                operationTimeout: operationTimeout,
                operation: {
                    try await SFTPClient.open(overAuthenticatedSSHChannel: claimedRoot.sshRoot.rootChannel)
                },
                cleanupLateSuccess: { sftp in
                    do {
                        try await sftp.close()
                    } catch {
                        NSLog("Remux attachment SFTP late open close failed: %@", String(describing: error))
                    }
                }
            )
            if let sftpOpenStartedAt {
                GhosttyRuntimeTrace.latency(
                    "sftp.open end host=\(rootConfiguration.host):\(rootConfiguration.port) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: sftpOpenStartedAt))"
                )
            }
            let leaseState = GhosttyAttachmentCitadelSFTPLeaseState(
                sftp: sftp,
                closeRoot: { disposition in
                    await claimedRoot.release(disposition)
                }
            )
            let client = GhosttyAttachmentCitadelSFTPClient(
                sftp: sftp,
                chunkSize: chunkSize,
                operationTimeout: operationTimeout,
                leaseState: leaseState
            )
            return GhosttyAttachmentSFTPClientLease(
                client: client,
                close: {
                    try await leaseState.close()
                }
            )
        } catch {
            await claimedRoot.release(.invalidated)
            throw error
        }
    }
}
