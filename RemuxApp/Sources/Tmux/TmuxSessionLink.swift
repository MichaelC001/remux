import Foundation
import GhosttyKit

/// Connects an `SSHTmuxControlTransport` to a `TmuxSessionController`:
/// inbound SSH bytes pump the session on its writer queue, outbound
/// wire bytes are written to the SSH channel strictly in order (a
/// single consumer task drains an ordered stream fed from the writer
/// queue), and transport loss detaches the session promptly via
/// `disconnect` instead of waiting for command deadlines.
///
/// Viewport ownership stays in the screen model. The link only passes the
/// already-known viewport to the SSH attach command's initial `-x -y`.
actor TmuxSessionLink {
    let controller: TmuxSessionController

    private let transport: any TmuxControlTransport
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private let outbound: AsyncStream<Data>
    private let outboundContinuation: AsyncStream<Data>.Continuation
    private var transportClosed = false
    private var transportCloseDisposition = TmuxControlTransportCloseDisposition.reusable

    /// The controller outlives links: reconnecting builds a new link
    /// (new transport) around the same controller, whose session state
    /// is retained across the detach.
    init(
        controller: TmuxSessionController,
        transport: any TmuxControlTransport
    ) {
        self.controller = controller
        self.transport = transport

        var continuation: AsyncStream<Data>.Continuation!
        self.outbound = AsyncStream { continuation = $0 }
        self.outboundContinuation = continuation
    }

    /// Establish the SSH control channel and attach the session.
    /// `viewport` (when already known) shapes the attach command's `-x -y`.
    /// The screen model has already submitted the same grid to the controller
    /// before starting this link, so the session sync batch applies it before
    /// the baseline. When unknown, pass nil; never fabricate one.
    func start(viewport: TmuxControlViewport?) async throws {
        // Idempotent transport prewarm (auth/root channel) before the
        // session channel opens.
        await transport.prepare()

        // Re-target the controller's wire bytes at this link. `yield`
        // is synchronous on the writer queue, preserving order into
        // the single consumer below.
        controller.setOutboundSink { [outboundContinuation] data in
            outboundContinuation.yield(data)
        }

        // Single ordered writer for the session's wire bytes.
        writeTask = Task { [weak self, transport, outbound] in
            for await data in outbound {
                do {
                    try await transport.send(data)
                } catch {
                    await self?.invalidateTransportAfterWriteFailure()
                    break
                }
            }
        }

        try await transport.start(initialViewport: viewport)

        controller.connect()

        readTask = Task { [transport, controller] in
            do {
                for try await data in transport.receivedBytes {
                    controller.pump(data)
                }
            } catch {
                // Fall through: any stream end is a transport loss.
            }
            controller.disconnect()
        }
    }

    func controlChannelIsActive() async -> Bool? {
        guard let transport = transport as? any TmuxControlTransportLivenessChecking else {
            return nil
        }
        return await transport.isControlChannelActive()
    }

    func invalidateTransport() async {
        await closeTransport(disposition: .invalidated)
        controller.disconnect()
    }

    /// Tear the link down. The controller survives (its session state
    /// is retained for a future link); bindings stay valid per the
    /// session contract.
    func stop() async {
        controller.setOutboundSink(nil)
        readTask?.cancel()
        readTask = nil
        outboundContinuation.finish()
        writeTask = nil
        controller.disconnect()
        await closeTransport(disposition: .reusable)
    }

    private func invalidateTransportAfterWriteFailure() async {
        await closeTransport(disposition: .invalidated)
        controller.disconnect()
    }

    private func closeTransport(disposition: TmuxControlTransportCloseDisposition) async {
        if disposition == .invalidated {
            transportCloseDisposition = .invalidated
        }
        guard !transportClosed else { return }

        transportClosed = true
        await transport.close(disposition: transportCloseDisposition)
    }
}
