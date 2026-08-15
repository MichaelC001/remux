import CoreGraphics
import Foundation

/// Picker-scoped image state plus one sequential asynchronous capture task.
/// Native renderer and terminal lifetime remain owned by the tmux session;
/// this type owns no handles, callbacks, retries, cache, or render queue.
@MainActor
final class GhosttyPanePreviewSession: ObservableObject {
    struct PixelBudget: Equatable, Sendable {
        let width: UInt32
        let height: UInt32
    }

    struct PreviewClient {
        let capture: @MainActor (UUID, PixelBudget) async -> CGImage?
        let cancelCapture: @MainActor (UUID) -> Void

        init(
            capture: @escaping @MainActor (UUID, PixelBudget) async -> CGImage?,
            cancelCapture: @escaping @MainActor (UUID) -> Void = { _ in }
        ) {
            self.capture = capture
            self.cancelCapture = cancelCapture
        }
    }

    enum PreviewState {
        case pending
        case ready(CGImage)
        case failed
    }

    let id = UUID()
    @Published private(set) var imagesByPaneID: [UUID: PreviewState] = [:]

    private let pixelBudget: PixelBudget
    private let client: PreviewClient
    private var trackedLeafIDs: [UUID]
    private var refreshTask: Task<Void, Never>?
    private var didStartRefreshing = false
    private var cancelled = false
    private var generation: UInt64 = 0
    private var activeCaptureLeafID: UUID?

    init(
        leafIDs: [UUID],
        pixelBudget: PixelBudget,
        client: PreviewClient
    ) {
        self.pixelBudget = pixelBudget
        self.client = client
        trackedLeafIDs = Self.unique(leafIDs)
    }

    func startRefreshing() {
        guard !didStartRefreshing, !cancelled else { return }
        didStartRefreshing = true
        restartRefresh()
    }

    func reconcile(leafIDs: [UUID]) {
        let next = Self.unique(leafIDs)
        guard next != trackedLeafIDs else { return }
        let nextSet = Set(next)
        for removed in imagesByPaneID.keys where !nextSet.contains(removed) {
            imagesByPaneID.removeValue(forKey: removed)
        }
        trackedLeafIDs = next
        guard didStartRefreshing, !cancelled else { return }
        restartRefresh()
    }

    func cancelAll() {
        guard !cancelled else { return }
        cancelled = true
        generation &+= 1
        cancelActiveCapture()
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func restartRefresh() {
        generation &+= 1
        let currentGeneration = generation
        let leafIDs = trackedLeafIDs
        let budget = pixelBudget
        cancelActiveCapture()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for leafID in leafIDs {
                guard !Task.isCancelled,
                      !cancelled,
                      generation == currentGeneration,
                      trackedLeafIDs.contains(leafID)
                else { return }

                if Self.isReady(imagesByPaneID[leafID]) { continue }

                imagesByPaneID[leafID] = .pending

                activeCaptureLeafID = leafID
                let image = await client.capture(leafID, budget)
                if activeCaptureLeafID == leafID { activeCaptureLeafID = nil }
                guard !Task.isCancelled,
                      !cancelled,
                      generation == currentGeneration,
                      trackedLeafIDs.contains(leafID)
                else { return }
                if let image {
                    imagesByPaneID[leafID] = .ready(image)
                } else {
                    imagesByPaneID[leafID] = .failed
                }
            }
        }
    }

    private func cancelActiveCapture() {
        guard let leafID = activeCaptureLeafID else { return }
        activeCaptureLeafID = nil
        client.cancelCapture(leafID)
    }

    private static func unique(_ leafIDs: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return leafIDs.filter { seen.insert($0).inserted }
    }

    private static func isReady(_ state: PreviewState?) -> Bool {
        if case .ready? = state { return true }
        return false
    }
}
