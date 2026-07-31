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
    private var stderr = SSHTmuxBoundedStreamPreview()
    private var extendedData = SSHTmuxBoundedStreamPreview()

    mutating func recordStdout(_ data: Data) {
        stdout.append(data)
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
            extendedDataPreview: extendedData.preview
        )
        return diagnostics.isEmpty ? nil : diagnostics
    }
}

enum SSHTmuxControlChannelDataRoute: Equatable, Sendable {
    case stdout(reportFirstOutput: Bool)
    case stderr
    case extendedData
}

final class SSHTmuxControlChannelDataRouter: @unchecked Sendable {
    private let lock = NIOLock()
    private var didReportFirstOutput = false
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
                let reportFirstOutput = !didReportFirstOutput
                didReportFirstOutput = true
                return .stdout(reportFirstOutput: reportFirstOutput)

            case .stdErr:
                startupDiagnostics.recordStderr(data)
                return .stderr

            default:
                startupDiagnostics.recordExtendedData(data)
                return .extendedData
            }
        }
    }
}
