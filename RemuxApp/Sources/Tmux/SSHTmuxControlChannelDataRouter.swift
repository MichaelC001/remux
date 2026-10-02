import Foundation
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

private struct SSHTmuxBoundedStreamPreview: Equatable, Sendable {
    private static let limit = 240

    private(set) var byteCount = 0
    private var bytes = Data()

    var preview: String? {
        guard !bytes.isEmpty else { return nil }
        return GhosttyRuntimeTrace.preview(bytes, limit: Self.limit)
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }

        byteCount += data.count

        if data.count >= Self.limit {
            bytes = Data(data.suffix(Self.limit))
            return
        }

        let retainedPrefixCount = max(0, Self.limit - data.count)
        if bytes.count > retainedPrefixCount {
            bytes = Data(bytes.suffix(retainedPrefixCount))
        }
        bytes.append(data)
    }
}

struct SSHTmuxStartupDiagnostics: Equatable, Sendable, CustomStringConvertible {
    let stdoutByteCount: Int
    let stderrByteCount: Int
    let extendedDataByteCount: Int
    let stderrPreview: String?
    let extendedDataPreview: String?
    /// Output before tmux's first protocol line: login-shell output and, on a
    /// pseudo-terminal, the launch script's stderr.
    let startupOutputPreview: String?

    /// Every message the launch could have written, wherever it arrived.
    var messages: String {
        [startupOutputPreview, stderrPreview].compactMap { $0 }.joined(separator: "\n")
    }

    var isEmpty: Bool {
        stdoutByteCount == 0 &&
            stderrByteCount == 0 &&
            extendedDataByteCount == 0
    }

    var description: String {
        var fields = [
            "stdout_bytes=\(stdoutByteCount)",
            "stderr_bytes=\(stderrByteCount)",
            "extended_bytes=\(extendedDataByteCount)",
        ]
        if let startupOutputPreview {
            fields.append("startup_preview=\"\(startupOutputPreview)\"")
        }
        if let stderrPreview {
            fields.append("stderr_preview=\"\(stderrPreview)\"")
        }
        if let extendedDataPreview {
            fields.append("extended_preview=\"\(extendedDataPreview)\"")
        }
        return fields.joined(separator: " ")
    }
}

private struct SSHTmuxStartupDiagnosticsAccumulator: Equatable, Sendable {
    private var stdout = SSHTmuxBoundedStreamPreview()
    private var startupOutput = SSHTmuxBoundedStreamPreview()
    private var stderr = SSHTmuxBoundedStreamPreview()
    private var extendedData = SSHTmuxBoundedStreamPreview()

    mutating func recordStdout(_ data: Data) {
        stdout.append(data)
    }

    mutating func recordStartupOutput(_ data: Data) {
        startupOutput.append(data)
    }

    mutating func recordStderr(_ data: Data) {
        stderr.append(data)
    }

    mutating func recordExtendedData(_ data: Data) {
        extendedData.append(data)
    }

    func snapshot() -> SSHTmuxStartupDiagnostics? {
        let diagnostics = SSHTmuxStartupDiagnostics(
            stdoutByteCount: stdout.byteCount,
            stderrByteCount: stderr.byteCount,
            extendedDataByteCount: extendedData.byteCount,
            stderrPreview: stderr.preview,
            extendedDataPreview: extendedData.preview,
            startupOutputPreview: startupOutput.preview
        )
        return diagnostics.isEmpty ? nil : diagnostics
    }
}

enum SSHTmuxControlChannelDataRoute: Equatable, Sendable {
    /// tmux control-mode bytes. `isFirst` marks the start of the protocol.
    case controlOutput(Data, isFirst: Bool)
    /// Stdout before tmux's first protocol line, kept only as diagnostics.
    case startupOutput
    case stderr
    case extendedData
}

/// Splits the channel into tmux's control protocol and everything else. The
/// protocol starts at the first line beginning with `%`; anything earlier on
/// stdout came from the login shell or the launch script.
final class SSHTmuxControlChannelDataRouter: @unchecked Sendable {
    private let lock = NIOLock()
    private var protocolStarted = false
    private var atLineStart = true
    private var startupDiagnostics = SSHTmuxStartupDiagnosticsAccumulator()

    var diagnostics: SSHTmuxStartupDiagnostics? {
        lock.withLock {
            startupDiagnostics.snapshot()
        }
    }

    func route(
        type: SSHChannelData.DataType,
        data: Data
    ) -> SSHTmuxControlChannelDataRoute {
        lock.withLock {
            switch type {
            case .channel:
                startupDiagnostics.recordStdout(data)
                if protocolStarted {
                    return .controlOutput(data, isFirst: false)
                }
                guard let start = protocolStart(in: data) else {
                    startupDiagnostics.recordStartupOutput(data)
                    return .startupOutput
                }
                protocolStarted = true
                startupDiagnostics.recordStartupOutput(data[..<start])
                return .controlOutput(Data(data[start...]), isFirst: true)

            case .stdErr:
                startupDiagnostics.recordStderr(data)
                return .stderr

            default:
                startupDiagnostics.recordExtendedData(data)
                return .extendedData
            }
        }
    }

    private func protocolStart(in data: Data) -> Data.Index? {
        for index in data.indices {
            let byte = data[index]
            if atLineStart, byte == UInt8(ascii: "%") {
                return index
            }
            atLineStart = byte == UInt8(ascii: "\n")
        }
        return nil
    }
}
