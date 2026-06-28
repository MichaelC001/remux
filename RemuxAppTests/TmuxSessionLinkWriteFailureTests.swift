import Foundation
import GhosttyKit
import XCTest

@testable import Remux

@MainActor
final class TmuxSessionLinkWriteFailureTests: XCTestCase {
    func testSendFailureInvalidatesTransportBeforeDisconnectingController() async throws {
        let runtime = try GhosttyKitRuntime()
        let stateRecorder = SessionStateRecorder()
        let transport = WriteFailingTransport()
        let controller = TmuxSessionController(
            app: runtime.appHandleForTesting,
            callbacks: TmuxSessionController.Callbacks(
                onState: { state in
                    Task { await stateRecorder.append(state) }
                }
            )
        )
        let link = TmuxSessionLink(controller: controller, transport: transport)

        try await link.start(viewport: nil)

        try await waitUntil("transport was not invalidated after send failure") {
            await transport.closeDispositions().first == .invalidated
        }
        try await waitUntil("controller did not publish transportClosed after send failure") {
            await stateRecorder.contains(.detached(.transportClosed))
        }

        await link.stop()
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(failureMessage)
    }
}

private actor SessionStateRecorder {
    private var states: [TmuxSessionController.SessionState] = []

    func append(_ state: TmuxSessionController.SessionState) {
        states.append(state)
    }

    func contains(_ state: TmuxSessionController.SessionState) -> Bool {
        states.contains(state)
    }
}

private actor WriteFailingTransport: TmuxControlTransport {
    enum SendFailure: Error {
        case failed
    }

    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var recordedCloseDispositions: [TmuxControlTransportCloseDisposition] = []

    init() {
        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
    }

    func send(_ data: Data) async throws {
        _ = data
        throw SendFailure.failed
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        recordedCloseDispositions.append(disposition)
        continuation.finish()
    }

    func closeDispositions() -> [TmuxControlTransportCloseDisposition] {
        recordedCloseDispositions
    }
}
