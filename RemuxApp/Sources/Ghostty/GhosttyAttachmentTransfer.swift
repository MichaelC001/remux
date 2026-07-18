import Foundation

struct GhosttyAttachmentTransferSource: Identifiable, Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case file(URL, filename: String)
        case securityScopedFile(GhosttySecurityScopedAttachmentFile)
        case text(String)
        case link(URL)
    }

    let id: UUID
    let attachmentID: GhosttyPendingAttachment.ID?
    let title: String
    let payload: Payload

    init(
        id: UUID = UUID(),
        attachmentID: GhosttyPendingAttachment.ID? = nil,
        title: String,
        payload: Payload
    ) {
        self.id = id
        self.attachmentID = attachmentID
        self.title = title
        self.payload = payload
    }
}

struct GhosttyAttachmentTransferJob: Equatable, Sendable {
    let workspaceID: SavedWorkspace.ID
    let transferID: UUID
    let sources: [GhosttyAttachmentTransferSource]

    init(
        workspaceID: SavedWorkspace.ID,
        transferID: UUID = UUID(),
        sources: [GhosttyAttachmentTransferSource]
    ) {
        self.workspaceID = workspaceID
        self.transferID = transferID
        self.sources = sources
    }

    var uploadSourceCount: Int {
        sources.count(where: \.requiresSFTPTransfer)
    }
}

enum GhosttyAttachmentTransferJobBuilder {
    static func job(
        workspaceID: SavedWorkspace.ID,
        attachments: [GhosttyPendingAttachment]
    ) throws -> GhosttyAttachmentTransferJob {
        let sources = attachments.compactMap(\.transferSource)
        guard !sources.isEmpty else {
            throw GhosttyAttachmentTransferError.noSources
        }

        return GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            sources: sources
        )
    }
}

struct GhosttyAttachmentTransferResult: Equatable, Sendable {
    enum Item: Equatable, Sendable {
        case remoteFile(sourceID: GhosttyAttachmentTransferSource.ID, path: GhosttyRemoteAttachmentPath)
        case text(sourceID: GhosttyAttachmentTransferSource.ID, text: String)
        case link(sourceID: GhosttyAttachmentTransferSource.ID, url: URL)
    }

    let transferID: UUID
    let items: [Item]
}

struct GhosttyAttachmentTransferProgress: Equatable, Sendable {
    let completedUploadCount: Int
    let totalUploadCount: Int
    let currentUploadIndex: Int
    let currentUploadedBytes: Int64
    let currentTotalBytes: Int64

    var currentUploadFraction: Double {
        guard currentTotalBytes > 0 else {
            return 1
        }

        return min(1, max(0, Double(currentUploadedBytes) / Double(currentTotalBytes)))
    }
}

typealias GhosttyAttachmentTransferProgressHandler = @Sendable (GhosttyAttachmentTransferProgress) async -> Void

enum GhosttyAttachmentTerminalInsertionFormatter {
    static func insertionText(for result: GhosttyAttachmentTransferResult) -> String {
        result.items
            .map(insertionText(for:))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func insertionText(for item: GhosttyAttachmentTransferResult.Item) -> String {
        switch item {
        case .remoteFile(_, let path):
            return shellEscapedPath(path.terminalPath)
        case .text(_, let text):
            return text
        case .link(_, let url):
            return url.absoluteString
        }
    }

    private static func shellEscapedPath(_ path: String) -> String {
        if isShellSafeToken(path) {
            return path
        }

        if path.hasPrefix("~/") {
            return "~/" + singleQuote(String(path.dropFirst(2)))
        }

        return singleQuote(path)
    }

    private static func singleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func isShellSafeToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy { scalar in
                CharacterSet.ghosttyAttachmentShellSafeTokenScalars.contains(scalar)
            }
    }
}

private extension CharacterSet {
    static let ghosttyAttachmentShellSafeTokenScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./~-"
    )
}

enum GhosttyAttachmentTransferError: Error, Equatable, Sendable {
    case noSources
    case localSourceUnavailable(URL)
    case securityScopedSourceUnavailable(String)
    case remotePathResolutionFailed(String)
    case remoteDirectoryCreationFailed(String)
    case remoteOperationTimedOut
    case uploadFailed(remotePath: String)
    case remoteRenameFailed(from: String, to: String)
    case cancelled
    case terminalInsertionFailed
}

protocol GhosttyAttachmentTransferService: Sendable {
    func transfer(
        _ job: GhosttyAttachmentTransferJob,
        progress: @escaping GhosttyAttachmentTransferProgressHandler
    ) async throws -> GhosttyAttachmentTransferResult
}

struct GhosttyAttachmentSFTPClientProviderTransferService<Provider: RemuxSFTPClientProvider>: GhosttyAttachmentTransferService
where Provider.Client: RemuxSFTPUploadClient {
    let provider: Provider
    let pathBuilder: GhosttyRemoteAttachmentPathBuilder

    init(
        provider: Provider,
        pathBuilder: GhosttyRemoteAttachmentPathBuilder = GhosttyRemoteAttachmentPathBuilder()
    ) {
        self.provider = provider
        self.pathBuilder = pathBuilder
    }

    func transfer(
        _ job: GhosttyAttachmentTransferJob,
        progress: @escaping GhosttyAttachmentTransferProgressHandler
    ) async throws -> GhosttyAttachmentTransferResult {
        guard !job.sources.isEmpty else {
            throw GhosttyAttachmentTransferError.noSources
        }

        guard job.sources.contains(where: { $0.requiresSFTPTransfer }) else {
            return GhosttyAttachmentTransferResult(
                transferID: job.transferID,
                items: job.sources.compactMap(\.passthroughTransferItem)
            )
        }

        return try await provider.withClient { client in
            let service = GhosttyAttachmentSFTPTransferService(
                client: client,
                pathBuilder: pathBuilder
            )
            return try await service.transfer(job, progress: progress)
        }
    }
}

private extension GhosttyAttachmentTransferSource {
    var requiresSFTPTransfer: Bool {
        if payload.transferFilename != nil {
            return true
        }
        return false
    }

    var passthroughTransferItem: GhosttyAttachmentTransferResult.Item? {
        switch payload {
        case .file, .securityScopedFile:
            return nil
        case .text(let text):
            return .text(sourceID: id, text: text)
        case .link(let url):
            return .link(sourceID: id, url: url)
        }
    }
}

private extension GhosttyAttachmentTransferSource.Payload {
    var transferFilename: String? {
        switch self {
        case .file(_, let filename):
            return filename
        case .securityScopedFile(let file):
            return file.filename
        case .text, .link:
            return nil
        }
    }
}

struct GhosttyAttachmentSFTPTransferService<Client: RemuxSFTPUploadClient>: GhosttyAttachmentTransferService {
    let client: Client
    let pathBuilder: GhosttyRemoteAttachmentPathBuilder

    init(
        client: Client,
        pathBuilder: GhosttyRemoteAttachmentPathBuilder = GhosttyRemoteAttachmentPathBuilder()
    ) {
        self.client = client
        self.pathBuilder = pathBuilder
    }

    func transfer(
        _ job: GhosttyAttachmentTransferJob,
        progress: @escaping GhosttyAttachmentTransferProgressHandler
    ) async throws -> GhosttyAttachmentTransferResult {
        guard !job.sources.isEmpty else {
            throw GhosttyAttachmentTransferError.noSources
        }

        try checkCancellation()

        let totalUploadCount = job.uploadSourceCount
        let uploadPaths = Dictionary(
            uniqueKeysWithValues: pathBuilder.paths(for: job).map { ($0.sourceID, $0) }
        )
        try await validateLocalSources(job.sources, uploadPaths: uploadPaths)

        var ensuredDirectories = Set<String>()
        var items: [GhosttyAttachmentTransferResult.Item] = []
        var completedUploadCount = 0

        for source in job.sources {
            try checkCancellation()

            switch source.payload {
            case .file(let localURL, _):
                let remotePath = try remotePath(for: source, in: uploadPaths)
                try await ensureDirectories(for: remotePath, ensuredDirectories: &ensuredDirectories)
                let uploadedPath = try await upload(
                    localURL,
                    to: remotePath,
                    completedUploadCount: completedUploadCount,
                    totalUploadCount: totalUploadCount,
                    progress: progress
                )
                completedUploadCount += 1
                items.append(.remoteFile(sourceID: source.id, path: uploadedPath))
            case .securityScopedFile(let file):
                let remotePath = try remotePath(for: source, in: uploadPaths)
                try await ensureDirectories(for: remotePath, ensuredDirectories: &ensuredDirectories)
                let uploadedPath = try await withAccessibleURL(file) { localURL in
                    try await upload(
                        localURL,
                        to: remotePath,
                        completedUploadCount: completedUploadCount,
                        totalUploadCount: totalUploadCount,
                        progress: progress
                    )
                }
                completedUploadCount += 1
                items.append(.remoteFile(sourceID: source.id, path: uploadedPath))
            case .text(let text):
                items.append(.text(sourceID: source.id, text: text))
            case .link(let url):
                items.append(.link(sourceID: source.id, url: url))
            }
        }

        return GhosttyAttachmentTransferResult(
            transferID: job.transferID,
            items: items
        )
    }

    private func checkCancellation() throws {
        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            throw GhosttyAttachmentTransferError.cancelled
        }
    }

    private func validateLocalSources(
        _ sources: [GhosttyAttachmentTransferSource],
        uploadPaths: [GhosttyAttachmentTransferSource.ID: GhosttyRemoteAttachmentPath]
    ) async throws {
        for source in sources {
            try checkCancellation()

            switch source.payload {
            case .file(let localURL, _):
                _ = try remotePath(for: source, in: uploadPaths)
                try validateLocalSource(localURL)
            case .securityScopedFile(let file):
                _ = try remotePath(for: source, in: uploadPaths)
                try await withAccessibleURL(file) { localURL in
                    try validateLocalSource(localURL)
                }
            case .text, .link:
                continue
            }
        }
    }

    private func remotePath(
        for source: GhosttyAttachmentTransferSource,
        in uploadPaths: [GhosttyAttachmentTransferSource.ID: GhosttyRemoteAttachmentPath]
    ) throws -> GhosttyRemoteAttachmentPath {
        guard let remotePath = uploadPaths[source.id] else {
            throw GhosttyAttachmentTransferError.remotePathResolutionFailed(source.title)
        }
        return remotePath
    }

    private func validateLocalSource(_ localURL: URL) throws {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(
            atPath: localURL.path,
            isDirectory: &isDirectory
        )
        guard exists, !isDirectory.boolValue else {
            throw GhosttyAttachmentTransferError.localSourceUnavailable(localURL)
        }
    }

    private func localFileSize(_ localURL: URL) throws -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
            guard let size = attributes[.size] as? NSNumber else {
                return 0
            }
            return max(0, size.int64Value)
        } catch {
            throw GhosttyAttachmentTransferError.localSourceUnavailable(localURL)
        }
    }

    private func withAccessibleURL<ReturnValue: Sendable>(
        _ file: GhosttySecurityScopedAttachmentFile,
        operation: (URL) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        do {
            return try await file.withAccessibleURL(operation)
        } catch GhosttySecurityScopedAttachmentFile.AccessError.bookmarkResolutionFailed(let filename) {
            throw GhosttyAttachmentTransferError.securityScopedSourceUnavailable(filename)
        } catch GhosttySecurityScopedAttachmentFile.AccessError.staleBookmark(let filename) {
            throw GhosttyAttachmentTransferError.securityScopedSourceUnavailable(filename)
        }
    }

    private func ensureDirectories(
        for remotePath: GhosttyRemoteAttachmentPath,
        ensuredDirectories: inout Set<String>
    ) async throws {
        for directory in GhosttyRemoteAttachmentPathBuilder.directoryPrefixes(
            for: remotePath.remoteDirectory
        ) where ensuredDirectories.insert(directory).inserted {
            do {
                let mkdirStartedAt = GhosttyRuntimeTrace.latencyEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
                GhosttyRuntimeTrace.latency("upload.mkdir begin path=\(directory)")
                try await client.ensureDirectoryExists(atPath: directory)
                if let mkdirStartedAt {
                    GhosttyRuntimeTrace.latency(
                        "upload.mkdir end path=\(directory) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: mkdirStartedAt))"
                    )
                }
            } catch is CancellationError {
                throw GhosttyAttachmentTransferError.cancelled
            } catch let error as RemuxSFTPClientError where error == .operationTimedOut {
                throw GhosttyAttachmentTransferError.remoteOperationTimedOut
            } catch {
                throw GhosttyAttachmentTransferError.remoteDirectoryCreationFailed(directory)
            }
        }
    }

    private func upload(
        _ localURL: URL,
        to remotePath: GhosttyRemoteAttachmentPath,
        completedUploadCount: Int,
        totalUploadCount: Int,
        progress: @escaping GhosttyAttachmentTransferProgressHandler
    ) async throws -> GhosttyRemoteAttachmentPath {
        let totalBytes = try localFileSize(localURL)
        let currentUploadIndex = completedUploadCount + 1

        await progress(GhosttyAttachmentTransferProgress(
            completedUploadCount: completedUploadCount,
            totalUploadCount: totalUploadCount,
            currentUploadIndex: currentUploadIndex,
            currentUploadedBytes: 0,
            currentTotalBytes: totalBytes
        ))

        do {
            let writeStartedAt = GhosttyRuntimeTrace.latencyEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
            GhosttyRuntimeTrace.latency(
                "upload.write begin path=\(remotePath.remoteTemporaryPath) bytes=\(totalBytes)"
            )
            try await client.uploadFile(
                from: localURL,
                to: remotePath.remoteTemporaryPath,
                progress: { uploadedBytes in
                    await progress(GhosttyAttachmentTransferProgress(
                        completedUploadCount: completedUploadCount,
                        totalUploadCount: totalUploadCount,
                        currentUploadIndex: currentUploadIndex,
                        currentUploadedBytes: min(max(0, uploadedBytes), totalBytes),
                        currentTotalBytes: totalBytes
                    ))
                }
            )
            if let writeStartedAt {
                GhosttyRuntimeTrace.latency(
                    "upload.write end path=\(remotePath.remoteTemporaryPath) bytes=\(totalBytes) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: writeStartedAt))"
                )
            }
        } catch is CancellationError {
            await cleanupTemporaryFileIfPossible(at: remotePath.remoteTemporaryPath)
            throw GhosttyAttachmentTransferError.cancelled
        } catch let error as RemuxSFTPClientError where error == .operationTimedOut {
            throw GhosttyAttachmentTransferError.remoteOperationTimedOut
        } catch {
            await cleanupTemporaryFileIfPossible(at: remotePath.remoteTemporaryPath)
            throw GhosttyAttachmentTransferError.uploadFailed(
                remotePath: remotePath.remoteTemporaryPath
            )
        }

        do {
            let renameStartedAt = GhosttyRuntimeTrace.latencyEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
            GhosttyRuntimeTrace.latency(
                "upload.rename begin from=\(remotePath.remoteTemporaryPath) to=\(remotePath.remoteFinalPath)"
            )
            try await client.renameFile(
                from: remotePath.remoteTemporaryPath,
                to: remotePath.remoteFinalPath
            )
            if let renameStartedAt {
                GhosttyRuntimeTrace.latency(
                    "upload.rename end from=\(remotePath.remoteTemporaryPath) to=\(remotePath.remoteFinalPath) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: renameStartedAt))"
                )
            }
        } catch is CancellationError {
            await cleanupTemporaryFileIfPossible(at: remotePath.remoteTemporaryPath)
            throw GhosttyAttachmentTransferError.cancelled
        } catch let error as RemuxSFTPClientError where error == .operationTimedOut {
            throw GhosttyAttachmentTransferError.remoteOperationTimedOut
        } catch {
            await cleanupTemporaryFileIfPossible(at: remotePath.remoteTemporaryPath)
            throw GhosttyAttachmentTransferError.remoteRenameFailed(
                from: remotePath.remoteTemporaryPath,
                to: remotePath.remoteFinalPath
            )
        }

        do {
            let realPathStartedAt = GhosttyRuntimeTrace.latencyEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
            GhosttyRuntimeTrace.latency("upload.realpath begin path=\(remotePath.remoteFinalPath)")
            let terminalPath = try await client.realPath(atPath: remotePath.remoteFinalPath)
            if let realPathStartedAt {
                GhosttyRuntimeTrace.latency(
                    "upload.realpath end path=\(remotePath.remoteFinalPath) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: realPathStartedAt))"
                )
            }
            return remotePath.withTerminalPath(terminalPath)
        } catch let error as RemuxSFTPClientError where error == .operationTimedOut {
            throw GhosttyAttachmentTransferError.remoteOperationTimedOut
        } catch {
            return remotePath
        }
    }

    private func cleanupTemporaryFileIfPossible(at remotePath: String) async {
        do {
            try await client.removeFileIfExists(atPath: remotePath)
        } catch {
            NSLog(
                "Remux attachment temporary cleanup failed for %@: %@",
                remotePath,
                String(describing: error)
            )
        }
    }
}

struct GhosttyRemoteAttachmentPath: Equatable, Sendable {
    let sourceID: GhosttyAttachmentTransferSource.ID
    let filename: String
    let remoteDirectory: String
    let remoteTemporaryPath: String
    let remoteFinalPath: String
    let terminalPath: String

    func withTerminalPath(_ terminalPath: String) -> GhosttyRemoteAttachmentPath {
        GhosttyRemoteAttachmentPath(
            sourceID: sourceID,
            filename: filename,
            remoteDirectory: remoteDirectory,
            remoteTemporaryPath: remoteTemporaryPath,
            remoteFinalPath: remoteFinalPath,
            terminalPath: terminalPath
        )
    }
}

struct GhosttyRemoteAttachmentPathBuilder: Equatable, Sendable {
    static let defaultRemoteRoot = ".cache/remux/attachments"
    static let defaultTerminalRoot = "~/.cache/remux/attachments"

    let remoteRoot: String
    let terminalRoot: String

    init(
        remoteRoot: String = Self.defaultRemoteRoot,
        terminalRoot: String = Self.defaultTerminalRoot
    ) {
        self.remoteRoot = Self.normalizedRoot(
            remoteRoot,
            fallback: Self.defaultRemoteRoot
        )
        self.terminalRoot = Self.normalizedRoot(
            terminalRoot,
            fallback: Self.defaultTerminalRoot
        )
    }

    func paths(for job: GhosttyAttachmentTransferJob) -> [GhosttyRemoteAttachmentPath] {
        let uploadDirectory = [
            remoteRoot,
            job.workspaceID.uuidString.lowercased(),
            job.transferID.uuidString.lowercased(),
        ].joined(separator: "/")
        let terminalDirectory = [
            terminalRoot,
            job.workspaceID.uuidString.lowercased(),
            job.transferID.uuidString.lowercased(),
        ].joined(separator: "/")

        var usedFilenames = Set<String>()
        return job.sources.compactMap { source in
            guard let filename = source.payload.transferFilename else { return nil }

            let sanitizedFilename = Self.uniqueFilename(
                Self.sanitizedFilename(filename),
                usedFilenames: &usedFilenames
            )
            let finalPath = "\(uploadDirectory)/\(sanitizedFilename)"
            return GhosttyRemoteAttachmentPath(
                sourceID: source.id,
                filename: sanitizedFilename,
                remoteDirectory: uploadDirectory,
                remoteTemporaryPath: "\(uploadDirectory)/.\(sanitizedFilename).part",
                remoteFinalPath: finalPath,
                terminalPath: "\(terminalDirectory)/\(sanitizedFilename)"
            )
        }
    }

    static func sanitizedFilename(_ filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 || scalar == "/" || scalar == "\\" || scalar == "\0" {
                return "_"
            }
            return Character(scalar)
        }
        let sanitized = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "._")))

        if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
            return "attachment"
        }

        return String(sanitized.prefix(180))
    }

    static func directoryPrefixes(for directory: String) -> [String] {
        let normalized = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let isAbsolute = normalized.hasPrefix("/")
        let components = normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return [] }

        var prefixes: [String] = []
        for index in components.indices {
            let prefix = components[...index].joined(separator: "/")
            prefixes.append(isAbsolute ? "/\(prefix)" : prefix)
        }
        return prefixes
    }

    private static func uniqueFilename(
        _ filename: String,
        usedFilenames: inout Set<String>
    ) -> String {
        guard usedFilenames.contains(filename) else {
            usedFilenames.insert(filename)
            return filename
        }

        let url = URL(fileURLWithPath: filename)
        let fileExtension = url.pathExtension
        let stem = fileExtension.isEmpty
            ? filename
            : String(filename.dropLast(fileExtension.count + 1))

        var counter = 2
        while true {
            let candidate = fileExtension.isEmpty
                ? "\(stem)-\(counter)"
                : "\(stem)-\(counter).\(fileExtension)"
            if !usedFilenames.contains(candidate) {
                usedFilenames.insert(candidate)
                return candidate
            }
            counter += 1
        }
    }

    private static func normalizedRoot(_ path: String, fallback: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            normalized = fallback
        }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

extension GhosttyPendingAttachment {
    var isPreparingTransferSource: Bool {
        payload == nil && detail == "Loading preview"
    }

    var transferSource: GhosttyAttachmentTransferSource? {
        guard let payload else { return nil }

        switch payload {
        case .file(let url):
            return GhosttyAttachmentTransferSource(
                attachmentID: id,
                title: title,
                payload: .file(url, filename: transferFilename(for: url))
            )
        case .securityScopedFile(let file):
            return GhosttyAttachmentTransferSource(
                attachmentID: id,
                title: title,
                payload: .securityScopedFile(file)
            )
        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return GhosttyAttachmentTransferSource(
                attachmentID: id,
                title: title,
                payload: .text(text)
            )
        case .link(let url):
            return GhosttyAttachmentTransferSource(
                attachmentID: id,
                title: title,
                payload: .link(url)
            )
        }
    }

    private func transferFilename(for url: URL) -> String {
        let filename = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty ? title : filename
    }
}
