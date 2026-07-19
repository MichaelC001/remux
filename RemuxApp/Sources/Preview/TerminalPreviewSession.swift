import Foundation
import QuickLook

@MainActor
final class TerminalPreviewSession: ObservableObject {
    enum State {
        case idle
        case loading(TerminalPreviewCandidate)
        case ready(TerminalPreviewCandidate, TerminalPreviewFileResource)
        case failed(TerminalPreviewCandidate, String)
    }

    @Published private(set) var state: State = .idle

    private let client: TerminalPreviewFileClient?
    let serverDisplayName: String
    private let canPreview: @MainActor @Sendable (URL) -> Bool
    private var requestGeneration: UInt = 0
    private var task: Task<Void, Never>?

    init(
        client: TerminalPreviewFileClient?,
        serverDisplayName: String,
        canPreview: @escaping @MainActor @Sendable (URL) -> Bool = {
            QLPreviewController.canPreview($0 as NSURL)
        }
    ) {
        self.client = client
        self.serverDisplayName = serverDisplayName
        self.canPreview = canPreview
    }

    deinit {
        task?.cancel()
    }

    var isPresented: Bool {
        if case .idle = state { return false }
        return true
    }

    var canOpenPreview: Bool {
        client != nil
    }

    var currentCandidate: TerminalPreviewCandidate? {
        switch state {
        case .idle:
            nil
        case .loading(let candidate),
             .ready(let candidate, _),
             .failed(let candidate, _):
            candidate
        }
    }

    func open(_ candidate: TerminalPreviewCandidate) {
        guard let client else { return }
        task?.cancel()
        requestGeneration &+= 1
        let activeGeneration = requestGeneration
        state = .loading(candidate)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<TerminalPreviewFileResource, Error>
            do {
                let resource = try await client.load(candidate)
                try Task.checkCancellation()
                result = .success(resource)
            } catch is CancellationError {
                return
            } catch {
                result = .failure(error)
            }
            await self?.finish(
                result,
                candidate: candidate,
                generation: activeGeneration
            )
        }
    }

    func refresh() {
        guard let currentCandidate else { return }
        open(currentCandidate)
    }

    func close() {
        task?.cancel()
        task = nil
        requestGeneration &+= 1
        state = .idle
    }

    private func finish(
        _ result: Result<TerminalPreviewFileResource, Error>,
        candidate: TerminalPreviewCandidate,
        generation: UInt
    ) {
        guard requestGeneration == generation else { return }
        task = nil
        switch result {
        case .success(let resource) where canPreview(resource.url):
            state = .ready(candidate, resource)
        case .success:
            state = .failed(
                candidate,
                TerminalPreviewFileError.unsupported.localizedDescription
            )
        case .failure(let error):
            state = .failed(candidate, error.localizedDescription)
        }
    }
}
