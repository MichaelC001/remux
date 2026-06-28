import Foundation
import GhosttyKit

/// Connects an `SSHTmuxControlTransport` to a `TmuxSessionController`:
/// inbound SSH bytes pump the session on its writer queue, outbound
/// wire bytes are written to the SSH channel strictly in order (a
/// single consumer task drains an ordered stream fed from the writer
/// queue), and transport loss detaches the session promptly via
/// `disconnect` instead of waiting for command deadlines.
///
/// The transport's own viewport machinery is deliberately unused: the
/// session model owns `refresh-client -C` reporting, and any command
/// the transport injected itself would corrupt the channel's response
/// correlation. The only viewport the transport sees is the `-x -y`
/// on the attach command line (used by tmux only when creating a new
/// session).
actor TmuxSessionLink {
    let controller: TmuxSessionController

    private let transport: any TmuxControlTransport
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private let outbound: AsyncStream<Data>
    private let outboundContinuation: AsyncStream<Data>.Continuation

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
    /// `viewport` (when already known) shapes the attach command's
    /// `-x -y` for brand-new sessions AND is reported through the
    /// session's sync batch so existing sessions re-layout before the
    /// baseline. When unknown, pass nil and report the size later —
    /// never fabricate one.
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
        writeTask = Task { [transport, outbound, controller] in
            for await data in outbound {
                do {
                    try await transport.send(data)
                } catch {
                    await transport.close(disposition: .invalidated)
                    controller.disconnect()
                    break
                }
            }
        }

        try await transport.start(initialViewport: viewport)

        if let viewport {
            controller.setClientSize(
                cols: UInt32(viewport.columns),
                rows: UInt32(viewport.rows)
            )
        }
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
        await transport.close(disposition: .reusable)
    }
}
