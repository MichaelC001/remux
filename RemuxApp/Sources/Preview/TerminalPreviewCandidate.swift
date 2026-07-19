import Foundation

struct TerminalPreviewCandidate: Equatable, Sendable {
    let remotePath: String

    init?(selection: String, explicitTarget: String? = nil) {
        let value = (explicitTarget ?? selection).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty,
              !value.contains("\0")
        else { return nil }

        let path: String
        if value.hasPrefix("file:") {
            guard let url = URL(string: value),
                  url.isFileURL,
                  url.host == nil || url.host?.isEmpty == true,
                  url.path.hasPrefix("/")
            else { return nil }
            path = url.path
        } else {
            guard value.hasPrefix("/") else { return nil }
            path = value
        }

        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "htm", "html", "xhtml": return nil
        default: break
        }

        self.remotePath = path
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
        let explicitTarget = automaticVisibleText == selection
            ? automaticExplicitTarget
            : nil
        return TerminalPreviewCandidate(
            selection: selection,
            explicitTarget: explicitTarget
        )
    }
}
