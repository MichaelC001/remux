import Foundation
import QuickLook

@MainActor
final class TerminalPreviewSession: ObservableObject {
    typealias PathResolver = @Sendable () async throws -> String

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
    private var pathResolver: PathResolver?
    private var resolvedRemotePath: String?

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

    func open(
        _ candidate: TerminalPreviewCandidate,
        resolvingPathWith resolver: @escaping PathResolver
    ) {
        guard let client else { return }
        task?.cancel()
        requestGeneration &+= 1
        pathResolver = resolver
        resolvedRemotePath = nil
        startLoading(candidate, resolvingPathWith: resolver, client: client)
    }

    func refresh() {
        guard let client, let currentCandidate, let pathResolver else { return }
        task?.cancel()
        requestGeneration &+= 1
        let resolver = resolvedRemotePath.map { remotePath in
            { @Sendable in remotePath }
        } ?? pathResolver
        startLoading(currentCandidate, resolvingPathWith: resolver, client: client)
    }

    func close() {
        task?.cancel()
        task = nil
        pathResolver = nil
        resolvedRemotePath = nil
        requestGeneration &+= 1
        state = .idle
    }

    private func startLoading(
        _ candidate: TerminalPreviewCandidate,
        resolvingPathWith resolver: @escaping PathResolver,
        client: TerminalPreviewFileClient
    ) {
        let activeGeneration = requestGeneration
        state = .loading(candidate)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var resolvedRemotePath: String?
            let result: Result<TerminalPreviewFileResource, Error>
            do {
                let remotePath = try await resolver()
                resolvedRemotePath = remotePath
                try Task.checkCancellation()
                let resource = try await client.load(remotePath: remotePath)
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
                generation: activeGeneration,
                resolvedRemotePath: resolvedRemotePath
            )
        }
    }

    private func finish(
        _ result: Result<TerminalPreviewFileResource, Error>,
        candidate: TerminalPreviewCandidate,
        generation: UInt,
        resolvedRemotePath: String?
    ) {
        guard requestGeneration == generation else { return }
        task = nil
        if let resolvedRemotePath {
            self.resolvedRemotePath = resolvedRemotePath
        }
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
