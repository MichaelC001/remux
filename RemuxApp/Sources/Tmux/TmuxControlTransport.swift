import Foundation

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

protocol TmuxControlTransportSFTPProviding: Sendable {
    var sessionSFTPClientProvider: RemuxSessionCitadelSFTPClientProvider { get }
}

enum TmuxControlTransportCloseDisposition: Equatable, Sendable {
    case reusable
    case invalidated
}

extension TmuxControlTransport {
    func prepare() async {}
}
