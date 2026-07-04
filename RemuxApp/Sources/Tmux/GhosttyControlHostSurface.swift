import Foundation
import GhosttyKit

enum TmuxActionSubmissionResult: Equatable, Sendable, CustomStringConvertible {
    case queued
    case notTmuxBound
    case noTarget
    case queueFailed


    var isQueued: Bool {
        self == .queued
    }

    var description: String {
        switch self {
        case .queued:
            "queued"
        case .notTmuxBound:
            "not tmux backed"
        case .noTarget:
            "no target"
        case .queueFailed:
            "queue failed"
        }
    }
}

protocol TmuxControlTransport: Sendable {
    var receivedBytes: AsyncThrowingStream<Data, Error> { get }

    /// Starts authentication/root transport work that does not allocate the
    /// terminal session channel and does not depend on the terminal viewport.
    /// Implementations must keep this idempotent; `start()` remains the point
    /// where the transport becomes usable and queued writes may flush.
    func prepare() async
    func start(initialViewport: TmuxControlViewport?) async throws
    func send(_ data: Data) async throws
    func close(disposition: TmuxControlTransportCloseDisposition) async
}

protocol TmuxControlTransportLivenessChecking: Sendable {
    func isControlChannelActive() async -> Bool
}

enum TmuxControlTransportCloseDisposition: Equatable, Sendable {
    case reusable
    case invalidated
}

extension TmuxControlTransport {
    func prepare() async {}
}

protocol GhosttyControlSurface: AnyObject {
    /// Feed bytes into Ghostty's surface ingress. The concrete Ghostty-backed
    /// implementation is expected to call ghostty_surface_process_output.
    @MainActor
    func processOutput(_ data: Data) -> Bool

    /// Notify Ghostty that the manual backing ended. The concrete Ghostty-backed
    /// implementation is expected to call ghostty_surface_set_backing_exited.
    @MainActor
    func setBackingExited(_ exited: Bool)
}
