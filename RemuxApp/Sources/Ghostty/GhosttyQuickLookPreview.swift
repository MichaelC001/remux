import QuickLook
import SwiftUI

struct GhosttyQuickLookPreview: UIViewControllerRepresentable {
    enum Source: Equatable {
        case url(URL)
        case securityScopedFile(GhosttySecurityScopedAttachmentFile)
        case terminalPreviewFile(TerminalPreviewFileResource)
    }

    let source: Source

    init(url: URL) {
        self.source = .url(url)
    }

    init(file: GhosttySecurityScopedAttachmentFile) {
        self.source = .securityScopedFile(file)
    }

    init(resource: TerminalPreviewFileResource) {
        self.source = .terminalPreviewFile(resource)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(source: source)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.update(source: source) {
            controller.reloadData()
        }
    }

    static func dismantleUIViewController(
        _ controller: QLPreviewController,
        coordinator: Coordinator
    ) {
        coordinator.stopAccessing()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private var source: Source
        private var previewURL: URL?
        private var accessedURL: URL?

        init(source: Source) {
            self.source = source
            super.init()
            startAccessing(source)
        }

        func update(source: Source) -> Bool {
            guard self.source != source else { return false }
            stopAccessing()
            self.source = source
            startAccessing(source)
            return true
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            previewURL == nil ? 0 : 1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            guard let previewURL else {
                return URL(fileURLWithPath: "/dev/null") as NSURL
            }
            return previewURL as NSURL
        }

        private func startAccessing(_ source: Source) {
            let url: URL
            switch source {
            case .url(let sourceURL):
                url = sourceURL
            case .securityScopedFile(let file):
                do {
                    url = try file.resolvedURL()
                } catch {
                    previewURL = nil
                    return
                }
            case .terminalPreviewFile(let resource):
                url = resource.url
            }

            previewURL = url
            if url.startAccessingSecurityScopedResource() {
                accessedURL = url
            }
        }

        func stopAccessing() {
            accessedURL?.stopAccessingSecurityScopedResource()
            accessedURL = nil
            previewURL = nil
        }
    }
}
