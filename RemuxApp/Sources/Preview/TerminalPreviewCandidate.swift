import Foundation

enum TerminalPreviewPath: Equatable, Sendable {
    case absolute(String)
    case relative(String)

    var value: String {
        switch self {
        case .absolute(let value), .relative(let value): value
        }
    }

    func resolved(relativeTo currentDirectory: String) throws -> String {
        switch self {
        case .absolute(let path):
            return path
        case .relative(let path):
            guard currentDirectory.hasPrefix("/"),
                  !currentDirectory.contains("\0"),
                  !currentDirectory.contains("\n"),
                  !currentDirectory.contains("\r")
            else { throw TerminalPreviewPathError.invalidCurrentDirectory }

            let resolved = ((currentDirectory as NSString)
                .appendingPathComponent(path) as NSString)
                .standardizingPath
            guard resolved.hasPrefix("/") else {
                throw TerminalPreviewPathError.invalidCurrentDirectory
            }
            return resolved
        }
    }
}

enum TerminalPreviewPathError: LocalizedError, Equatable, Sendable {
    case invalidCurrentDirectory

    var errorDescription: String? {
        "The terminal's current directory is unavailable."
    }
}

struct TerminalPreviewCandidate: Equatable, Sendable {
    let path: TerminalPreviewPath

    var remotePath: String { path.value }

    init?(
        selection: String,
        explicitTarget: String? = nil
    ) {
        let value = (explicitTarget ?? selection).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty,
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r")
        else { return nil }

        let path: TerminalPreviewPath
        if value.hasPrefix("file:") {
            guard let url = URL(string: value),
                  url.isFileURL,
                  url.host == nil || url.host?.isEmpty == true,
                  url.path.hasPrefix("/")
            else { return nil }
            path = .absolute(url.path)
        } else if value.hasPrefix("/") {
            path = .absolute(value)
        } else {
            guard !value.hasPrefix("~"),
                  value != ".",
                  value != "..",
                  URL(string: value)?.scheme == nil,
                  value.contains("/") || !(value as NSString).pathExtension.isEmpty
            else { return nil }
            path = .relative(value)
        }

        self.path = path
    }

    var filename: String {
        let component = URL(fileURLWithPath: remotePath).lastPathComponent
        return component.isEmpty ? remotePath : component
    }
}

struct TerminalPreviewSelectionContext: Equatable {
    private var automaticVisibleText: String?
    private var automaticExplicitTarget: String?

    mutating func setAutomaticSelection(
        visibleText: String?,
        explicitTarget: String?
    ) {
        automaticVisibleText = visibleText
        automaticExplicitTarget = explicitTarget
    }

    mutating func selectionDidChange() {
        automaticVisibleText = nil
        automaticExplicitTarget = nil
    }

    func candidate(for selection: String) -> TerminalPreviewCandidate? {
        let matchesAutomaticSelection = automaticVisibleText == selection
        let explicitTarget = matchesAutomaticSelection
            ? automaticExplicitTarget
            : nil
        return TerminalPreviewCandidate(
            selection: selection,
            explicitTarget: explicitTarget
        )
    }
}
