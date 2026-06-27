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

private actor GhosttyAttachmentCitadelSFTPLeaseState {
    private let sftp: SFTPClient
    private let closeRoot: @Sendable () async throws -> Void
    private var timedOut = false
    private var closeTask: Task<Void, Error>?

    init(
        sftp: SFTPClient,
        closeRoot: @escaping @Sendable () async throws -> Void
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

        let task = Task {
            var closeFailure: Error?

            do {
                try await sftp.close()
            } catch {
                closeFailure = error
            }

            do {
                try await closeRoot()
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

    private static func openLease(
        sshRootService: RemuxSSHRootService,
        rootKey: RemuxSSHRootKey,
        rootConfiguration: RemuxSSHRootConfiguration,
        operationTimeout: TimeAmount,
        chunkSize: Int
    ) async throws -> GhosttyAttachmentSFTPClientLease<GhosttyAttachmentCitadelSFTPClient> {
        let trace = SSHTmuxControlStartupTrace(flowID: nil)
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
            let sftp = try await SFTPClient.open(overAuthenticatedSSHChannel: claimedRoot.sshRoot.rootChannel)
            if let sftpOpenStartedAt {
                GhosttyRuntimeTrace.latency(
                    "sftp.open end host=\(rootConfiguration.host):\(rootConfiguration.port) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: sftpOpenStartedAt))"
                )
            }
            let leaseState = GhosttyAttachmentCitadelSFTPLeaseState(
                sftp: sftp,
                closeRoot: {
                    await claimedRoot.releaseAfterSFTPLease()
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
            await claimedRoot.releaseAfterSFTPLease()
            throw error
        }
    }
}

private extension RemuxSSHClaimedRoot {
    func releaseAfterSFTPLease() async {
        await release(sshRoot.rootChannel.isActive ? .reusable : .invalidated)
    }
}
