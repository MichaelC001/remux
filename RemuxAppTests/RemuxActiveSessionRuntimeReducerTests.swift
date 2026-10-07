import XCTest
@testable import Remux

final class RemuxActiveSessionRuntimeReducerTests: XCTestCase {
    func testRootVisibleConnectedProjectionPreservesCurrentRuntimeStateContract() {
        XCTAssertFalse(TerminalRuntimeStateProjection.isRootVisibleConnected(.connecting))
        XCTAssertFalse(TerminalRuntimeStateProjection.isRootVisibleConnected(.reconnecting(.foreground)))
        XCTAssertTrue(TerminalRuntimeStateProjection.isRootVisibleConnected(.connected))
        XCTAssertFalse(
            TerminalRuntimeStateProjection.isRootVisibleConnected(
                .disconnected(transportDisconnectReason())
            )
        )
    }

    func testMissingSessionReportsMissingWithoutMutation() {
        var sessions: [ActiveTerminalSession] = []
        let update = TerminalRuntimeStateUpdate(
            workspaceID: SavedWorkspace.ID(),
            instanceID: UUID(),
            state: .connected,
            source: .readiness
        )

        let outcome = RemuxActiveSessionRuntimeReducer.apply(
            update,
            to: &sessions,
            requestedReconnectSource: nil
        )

        XCTAssertEqual(outcome, .missingSession)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testStaleInstanceReportsCurrentAndStaleIDsWithoutMutation() {
        let session = makeSession()
        let staleInstanceID = UUID()
        var sessions = [session]
        let update = TerminalRuntimeStateUpdate(
            workspaceID: session.id,
            instanceID: staleInstanceID,
            state: .connected,
            source: .readiness
        )

        let outcome = RemuxActiveSessionRuntimeReducer.apply(
            update,
            to: &sessions,
            requestedReconnectSource: nil
        )

        XCTAssertEqual(outcome, .staleInstance(current: session.instanceID, stale: staleInstanceID))
        XCTAssertEqual(sessions, [session])
    }

    func testConnectedStateAppliesAndClearsAutomaticReconnectAttempts() {
        var session = makeSession(runtimeState: .reconnecting(.transportLoss))
        XCTAssertTrue(session.markAutomaticReconnectAttempted(source: .transportLoss))
        var sessions = [session]
        let update = TerminalRuntimeStateUpdate(
            workspaceID: session.id,
            instanceID: session.instanceID,
            state: .connected,
            source: .readiness
        )

        let outcome = RemuxActiveSessionRuntimeReducer.apply(
            update,
            to: &sessions,
            requestedReconnectSource: nil
        )

        XCTAssertEqual(outcome, .applied(.connected))
        XCTAssertEqual(sessions.first?.runtimeState, .connected)
        XCTAssertEqual(sessions.first?.automaticReconnectAttemptedSources, [])
    }

    func testNonConnectedStateDoesNotClearAutomaticReconnectAttempts() {
        var session = makeSession(runtimeState: .reconnecting(.transportLoss))
        XCTAssertTrue(session.markAutomaticReconnectAttempted(source: .transportLoss))

        session.applyRuntimeState(.connecting)
        XCTAssertEqual(session.automaticReconnectAttemptedSources, [.transportLoss])

        session.applyRuntimeState(.disconnected(transportDisconnectReason()))
        XCTAssertEqual(session.automaticReconnectAttemptedSources, [.transportLoss])
    }

    func testConnectingStateDoesNotOverwriteReconnectingState() {
        let session = makeSession(runtimeState: .reconnecting(.manualButton))
        var sessions = [session]
        let update = TerminalRuntimeStateUpdate(
            workspaceID: session.id,
            instanceID: session.instanceID,
            state: .connecting,
            source: .runtime
        )

        let outcome = RemuxActiveSessionRuntimeReducer.apply(
            update,
            to: &sessions,
            requestedReconnectSource: nil
        )

        XCTAssertEqual(outcome, .applied(.reconnecting(.manualButton)))
        XCTAssertEqual(sessions.first?.runtimeState, .reconnecting(.manualButton))
    }

    func testAutomaticReconnectStartsOnceForSource() {
        let session = makeSession()
        var sessions = [session]
        let reason = transportDisconnectReason()
        let update = TerminalRuntimeStateUpdate(
            workspaceID: session.id,
            instanceID: session.instanceID,
            state: .disconnected(reason),
            source: .runtime
        )

        let outcome = RemuxActiveSessionRuntimeReducer.apply(
            update,
            to: &sessions,
            requestedReconnectSource: .transportLoss
        )

        XCTAssertEqual(
            outcome,
            .automaticReconnectStarted(source: .transportLoss, state: .disconnected(reason))
        )
        XCTAssertEqual(sessions.first?.runtimeState, .disconnected(reason))
        XCTAssertEqual(sessions.first?.automaticReconnectAttemptedSources, [.transportLoss])
    }

    func testAutomaticReconnectSkipsRepeatedSource() {
        var session = makeSession()
        XCTAssertTrue(session.markAutomaticReconnectAttempted(source: .transportLoss))
        var sessions = [session]
        let reason = transportDisconnectReason()
        let update = TerminalRuntimeStateUpdate(
            workspaceID: session.id,
            instanceID: session.instanceID,
            state: .disconnected(reason),
            source: .runtime
        )

        let outcome = RemuxActiveSessionRuntimeReducer.apply(
            update,
            to: &sessions,
            requestedReconnectSource: .transportLoss
        )

        XCTAssertEqual(
            outcome,
            .automaticReconnectSkipped(source: .transportLoss, state: .disconnected(reason))
        )
        XCTAssertEqual(sessions.first?.runtimeState, .disconnected(reason))
        XCTAssertEqual(sessions.first?.automaticReconnectAttemptedSources, [.transportLoss])
    }

    func testReadinessDisconnectWithoutReconnectSourceAppliesOnly() {
        let session = makeSession()
        var sessions = [session]
        let reason = transportDisconnectReason()
        let update = TerminalRuntimeStateUpdate(
            workspaceID: session.id,
            instanceID: session.instanceID,
            state: .disconnected(reason),
            source: .readiness
        )

        let outcome = RemuxActiveSessionRuntimeReducer.apply(
            update,
            to: &sessions,
            requestedReconnectSource: nil
        )

        XCTAssertEqual(outcome, .applied(.disconnected(reason)))
        XCTAssertEqual(sessions.first?.runtimeState, .disconnected(reason))
        XCTAssertEqual(sessions.first?.automaticReconnectAttemptedSources, [])
    }

    func testManualReconnectSourceIsNotBoundedAsAutomaticAttempt() {
        var session = makeSession()
        XCTAssertTrue(session.markAutomaticReconnectAttempted(source: .transportLoss))
        var sessions = [session]
        let reason = transportDisconnectReason()
        let update = TerminalRuntimeStateUpdate(
            workspaceID: session.id,
            instanceID: session.instanceID,
            state: .disconnected(reason),
            source: .runtime
        )

        let outcome = RemuxActiveSessionRuntimeReducer.apply(
            update,
            to: &sessions,
            requestedReconnectSource: .manualButton
        )

        XCTAssertEqual(
            outcome,
            .automaticReconnectStarted(source: .manualButton, state: .disconnected(reason))
        )
        XCTAssertEqual(sessions.first?.automaticReconnectAttemptedSources, [.transportLoss])
    }
}

private func makeSession(
    runtimeState: TerminalRuntimeState = .connecting
) -> ActiveTerminalSession {
    let server = SavedServer(
        displayName: "Build Host",
        host: "build.example.test",
        username: "builder"
    )
    let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
    let target = SessionTarget(
        server: server,
        workspace: workspace,
        sshAuth: .password(
            username: server.username,
            password: "secret",
            identityID: server.identityID,
            displayLabel: server.displayName
        )
    )
    return ActiveTerminalSession(target: target, runtimeState: runtimeState)
}

private func transportDisconnectReason() -> TerminalDisconnectReason {
    TerminalDisconnectReason(
        kind: .transportIO,
        message: "tmux transport ended"
    )
}
