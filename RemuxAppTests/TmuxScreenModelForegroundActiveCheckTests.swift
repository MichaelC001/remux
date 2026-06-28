import Foundation
import XCTest

@testable import Remux

@MainActor
final class TmuxScreenModelForegroundActiveCheckTests: XCTestCase {
    func testForegroundInvalidatesInactiveSSHTransportAndReportsForegroundDisconnect() async throws {
        let target = makeTarget()
        let instanceID = UUID()
        let transport = ForegroundInactiveSSHTransport(isActive: false)
        var updates: [TerminalRuntimeStateUpdate] = []
        let model = TmuxScreenModel(
            target: target,
            sessionInstanceID: instanceID,
            transportFactory: { _ in transport },
            onRuntimeStateChange: { updates.append($0) }
        )
        defer {
            Task { @MainActor in
                await model.stop()
            }
        }

        try await waitUntil("transport did not start") {
            await transport.didStart()
        }
        model.session?.handleStateForTesting(.ready)
        updates.removeAll()

        model.handleAppLifecyclePhase(.active)

        try await waitUntil("inactive foreground transport was not invalidated") {
            await transport.closeDispositions().contains(.invalidated)
        }
        try await waitUntil("foreground disconnect was not reported") {
            updates.contains {
                $0.workspaceID == target.workspace.id
                    && $0.instanceID == instanceID
                    && $0.source == .foreground
                    && $0.state.disconnectedReason == GhosttyTerminalDisconnectReasonClassifier
                        .foregroundMissingHost()
            }
        }
    }

    func testForegroundDoesNotProbeSSHTransportWhileSessionIsStillConnecting() async throws {
        let target = makeTarget()
        let transport = ForegroundInactiveSSHTransport(isActive: false)
        var updates: [TerminalRuntimeStateUpdate] = []
        let model = TmuxScreenModel(
            target: target,
            sessionInstanceID: UUID(),
            transportFactory: { _ in transport },
            onRuntimeStateChange: { updates.append($0) }
        )
        defer {
            Task { @MainActor in
                await model.stop()
            }
        }

        try await waitUntil("transport did not start") {
            await transport.didStart()
        }
        updates.removeAll()

        model.handleAppLifecyclePhase(.active)
        try await Task.sleep(for: .milliseconds(80))

        let activeCheckCount = await transport.activeCheckCount()
        let closeDispositions = await transport.closeDispositions()
        XCTAssertEqual(activeCheckCount, 0)
        XCTAssertTrue(closeDispositions.isEmpty)
        XCTAssertTrue(updates.allSatisfy { $0.source != .foreground })
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

    private func makeTarget() -> TmuxConnectionTarget {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        return TmuxConnectionTarget(
            server: server,
            workspace: workspace,
            sshAuth: .password(
                username: server.username,
                password: "secret",
                identityID: server.identityID,
                displayLabel: server.displayName
            )
        )
    }
}

private actor ForegroundInactiveSSHTransport: TmuxControlTransport, SSHTmuxControlChannelActiveChecking {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let isActive: Bool
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var started = false
    private var recordedActiveCheckCount = 0
    private var recordedCloseDispositions: [TmuxControlTransportCloseDisposition] = []

    init(isActive: Bool) {
        self.isActive = isActive

        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
        started = true
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        recordedCloseDispositions.append(disposition)
        continuation.finish()
    }

    func isSSHControlChannelActive() async -> Bool {
        recordedActiveCheckCount += 1
        return isActive
    }

    func didStart() -> Bool {
        started
    }

    func closeDispositions() -> [TmuxControlTransportCloseDisposition] {
        recordedCloseDispositions
    }

    func activeCheckCount() -> Int {
        recordedActiveCheckCount
    }
}
