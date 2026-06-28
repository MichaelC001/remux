import Foundation
import GhosttyKit
import XCTest

@testable import Remux

@MainActor
final class TmuxScreenModelForegroundActiveCheckTests: XCTestCase {
    func testForegroundInvalidatesInactiveTransportAndReportsForegroundDisconnect() async throws {
        let target = makeTarget()
        let instanceID = UUID()
        let transport = ForegroundInactiveTransport(isActive: false)
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

    func testForegroundDoesNotProbeTransportWhileSessionIsStillConnecting() async throws {
        let target = makeTarget()
        let transport = ForegroundInactiveTransport(isActive: false)
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

    func testStaleForegroundProbeDoesNotInvalidateReplacementLink() async throws {
        let runtime = try GhosttyKitRuntime()
        let firstTransport = ForegroundSuspendingTransport(isActiveAfterResume: false)
        let secondTransport = ForegroundInactiveTransport(isActive: true)
        var transports: [any TmuxControlTransport] = [firstTransport, secondTransport]
        let session = TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            makeTransport: {
                transports.removeFirst()
            },
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark },
            createPaneSurface: { _, _, _, _, _, completion in
                completion(.failure(.surfaceCreationFailed))
            }
        )
        defer {
            Task { @MainActor in
                await session.shutdown()
            }
        }

        session.connect(viewport: nil)
        try await waitUntil("first transport did not start") {
            await firstTransport.didStart()
        }
        session.handleStateForTesting(.ready)

        var invalidatedReasons: [TerminalDisconnectReason] = []
        let probe = Task { @MainActor in
            await session.invalidateInactiveTransportOnForeground { reason in
                invalidatedReasons.append(reason)
            }
        }
        try await waitUntil("first transport was not probed") {
            await firstTransport.activeCheckCount() == 1
        }

        await session.disconnect()
        session.connect(viewport: nil)
        try await waitUntil("second transport did not start") {
            await secondTransport.didStart()
        }
        session.handleStateForTesting(.ready)

        await firstTransport.resumeActiveCheck()
        let reason = await probe.value

        XCTAssertNil(reason)
        XCTAssertTrue(invalidatedReasons.isEmpty)
        XCTAssertEqual(await firstTransport.closeDispositions(), [.reusable])
        XCTAssertTrue(await secondTransport.closeDispositions().isEmpty)
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

private actor ForegroundInactiveTransport: TmuxControlTransport, TmuxControlTransportLivenessChecking {
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

    func isControlChannelActive() async -> Bool {
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

private actor ForegroundSuspendingTransport: TmuxControlTransport, TmuxControlTransportLivenessChecking {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let isActiveAfterResume: Bool
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var activeCheckContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var recordedActiveCheckCount = 0
    private var recordedCloseDispositions: [TmuxControlTransportCloseDisposition] = []

    init(isActiveAfterResume: Bool) {
        self.isActiveAfterResume = isActiveAfterResume

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

    func isControlChannelActive() async -> Bool {
        recordedActiveCheckCount += 1
        await withCheckedContinuation { continuation in
            activeCheckContinuation = continuation
        }
        return isActiveAfterResume
    }

    func resumeActiveCheck() {
        activeCheckContinuation?.resume()
        activeCheckContinuation = nil
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
