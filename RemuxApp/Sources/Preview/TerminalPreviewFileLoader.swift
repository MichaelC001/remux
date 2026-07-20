import Foundation

enum TerminalPreviewFileError: LocalizedError, Equatable, Sendable {
    case tooLarge(maximumByteCount: UInt64)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .tooLarge(let maximumByteCount):
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(maximumByteCount),
                countStyle: .file
            )
            return "This file is larger than the \(size) preview limit."
        case .unsupported:
            return "This file type cannot be previewed."
        }
    }
}

enum TerminalPreviewRemoteFileReader {
    typealias MetadataHandler = @Sendable (RemuxSFTPFileMetadata) async throws -> Void
    typealias ChunkHandler = @Sendable (Data) async throws -> Void

    static func stream<Client: RemuxSFTPReadOnlyClient>(
        client: Client,
        remotePath: String,
        maximumByteCount: UInt64,
        knownMetadata: RemuxSFTPFileMetadata? = nil,
        onMetadata: @escaping MetadataHandler = { _ in },
        onChunk: @escaping ChunkHandler
    ) async throws -> RemuxSFTPFileMetadata {
        let metadata: RemuxSFTPFileMetadata
        if let knownMetadata {
            metadata = knownMetadata
        } else {
            metadata = try await client.metadata(atPath: remotePath)
        }
        if let size = metadata.size, size > maximumByteCount {
            throw TerminalPreviewFileError.tooLarge(
                maximumByteCount: maximumByteCount
            )
        }
        try await onMetadata(metadata)

        try await client.withFile(atPath: remotePath) { remoteFile in
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let remaining = maximumByteCount - min(offset, maximumByteCount)
                let requestedLength = Int(min(
                    UInt64(RemuxSFTPReadableFile.maximumChunkLength),
                    remaining + 1
                ))
                let data = try await remoteFile.readChunk(
                    from: offset,
                    length: requestedLength
                )
                guard !data.isEmpty else { break }
                guard UInt64(data.count) <= remaining else {
                    throw TerminalPreviewFileError.tooLarge(
                        maximumByteCount: maximumByteCount
                    )
                }
                try await onChunk(data)
                offset += UInt64(data.count)
            }
        }
        return metadata
    }
}

final class TerminalPreviewFileResource: @unchecked Sendable, Equatable {
    let url: URL
    private let directoryURL: URL

    init(url: URL, directoryURL: URL) {
        self.url = url
        self.directoryURL = directoryURL
    }

    static func == (lhs: TerminalPreviewFileResource, rhs: TerminalPreviewFileResource) -> Bool {
        lhs === rhs
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: directoryURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
        } catch {
            NSLog(
                "Remux preview temp cleanup failed for %@: %@",
                directoryURL.path,
                String(describing: error)
            )
        }
    }
}

struct TerminalPreviewFileLoader<Provider>: Sendable
where Provider: RemuxSFTPClientProvider,
      Provider.Client: RemuxSFTPReadOnlyClient {
    static var defaultMaximumByteCount: UInt64 { 64 * 1024 * 1024 }

    let provider: Provider
    let temporaryDirectory: URL
    let maximumByteCount: UInt64

    init(
        provider: Provider,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        maximumByteCount: UInt64 = Self.defaultMaximumByteCount
    ) {
        precondition(maximumByteCount > 0 && maximumByteCount < UInt64.max)
        self.provider = provider
        self.temporaryDirectory = temporaryDirectory
        self.maximumByteCount = maximumByteCount
    }

    func load(remotePath: String) async throws -> TerminalPreviewFileResource {
        try await provider.withClient { client in
            let fileManager = FileManager.default
            let directoryURL = temporaryDirectory.appendingPathComponent(
                "RemuxPreview-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false
                )
                let fileURL = directoryURL.appendingPathComponent(
                    Self.localFilename(for: remotePath),
                    isDirectory: false
                )
                let probePlainText = fileURL.pathExtension.isEmpty
                guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }

                let handle = try FileHandle(forWritingTo: fileURL)
                let plainTextProbe: ExtensionlessPlainTextProbe?
                do {
                    let probe = LockedPlainTextProbe(enabled: probePlainText)
                    _ = try await TerminalPreviewRemoteFileReader.stream(
                        client: client,
                        remotePath: remotePath,
                        maximumByteCount: maximumByteCount
                    ) { data in
                        probe.consume(data)
                        try handle.write(contentsOf: data)
                    }
                    plainTextProbe = probe.value
                    try handle.close()
                } catch {
                    do {
                        try handle.close()
                    } catch {
                        NSLog(
                            "Remux preview partial file close failed: %@",
                            String(describing: error)
                        )
                    }
                    throw error
                }

                let previewURL: URL
                if plainTextProbe?.isPlainText == true {
                    previewURL = fileURL.appendingPathExtension("txt")
                    try fileManager.moveItem(at: fileURL, to: previewURL)
                } else {
                    previewURL = fileURL
                }

                return TerminalPreviewFileResource(
                    url: previewURL,
                    directoryURL: directoryURL
                )
            } catch {
                do {
                    try fileManager.removeItem(at: directoryURL)
                } catch let cleanupError as CocoaError
                    where cleanupError.code == .fileNoSuchFile {
                } catch {
                    NSLog(
                        "Remux preview failed-open cleanup failed for %@: %@",
                        directoryURL.path,
                        String(describing: error)
                    )
                }
                throw error
            }
        }
    }

    private static func localFilename(for remotePath: String) -> String {
        let component = URL(fileURLWithPath: remotePath).lastPathComponent
        guard !component.isEmpty, component != ".", component != ".." else {
            return "Preview"
        }
        return component
    }
}

private final class LockedPlainTextProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var probe: ExtensionlessPlainTextProbe?

    init(enabled: Bool) {
        self.probe = enabled ? ExtensionlessPlainTextProbe() : nil
    }

    func consume(_ data: Data) {
        lock.withLock { probe?.consume(data) }
    }

    var value: ExtensionlessPlainTextProbe? {
        lock.withLock { probe }
    }
}

private struct ExtensionlessPlainTextProbe: Sendable {
    private var continuationByteCount = 0
    private var nextContinuationRange: ClosedRange<UInt8> = 0x80...0xBF
    private var valid = true

    var isPlainText: Bool {
        valid && continuationByteCount == 0
    }

    mutating func consume(_ data: Data) {
        guard valid else { return }

        for byte in data {
            if continuationByteCount > 0 {
                guard nextContinuationRange.contains(byte) else {
                    valid = false
                    return
                }
                continuationByteCount -= 1
                nextContinuationRange = 0x80...0xBF
                continue
            }

            switch byte {
            case 0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F:
                valid = false
                return
            case 0x00...0x7F:
                continue
            case 0xC2...0xDF:
                beginSequence(continuationBytes: 1)
            case 0xE0:
                beginSequence(continuationBytes: 2, firstByteRange: 0xA0...0xBF)
            case 0xE1...0xEC, 0xEE...0xEF:
                beginSequence(continuationBytes: 2)
            case 0xED:
                beginSequence(continuationBytes: 2, firstByteRange: 0x80...0x9F)
            case 0xF0:
                beginSequence(continuationBytes: 3, firstByteRange: 0x90...0xBF)
            case 0xF1...0xF3:
                beginSequence(continuationBytes: 3)
            case 0xF4:
                beginSequence(continuationBytes: 3, firstByteRange: 0x80...0x8F)
            default:
                valid = false
                return
            }
        }
    }

    private mutating func beginSequence(
        continuationBytes: Int,
        firstByteRange: ClosedRange<UInt8> = 0x80...0xBF
    ) {
        continuationByteCount = continuationBytes
        nextContinuationRange = firstByteRange
    }
}

struct TerminalPreviewFileClient: Sendable {
    private let loadHandler: @Sendable (String) async throws -> TerminalPreviewFileResource

    init(
        load: @escaping @Sendable (String) async throws -> TerminalPreviewFileResource
    ) {
        self.loadHandler = load
    }

    init<Provider>(provider: Provider) where Provider: RemuxSFTPClientProvider,
            Provider.Client: RemuxSFTPReadOnlyClient {
        let loader = TerminalPreviewFileLoader(provider: provider)
        self.init { remotePath in
            try await loader.load(remotePath: remotePath)
        }
    }

    func load(remotePath: String) async throws -> TerminalPreviewFileResource {
        try await loadHandler(remotePath)
    }
}
