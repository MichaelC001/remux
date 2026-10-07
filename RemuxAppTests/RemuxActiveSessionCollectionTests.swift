import XCTest
@testable import Remux

final class RemuxActiveSessionCollectionTests: XCTestCase {
    func testUpsertActivatedSessionAppendsAndReplacesByWorkspace() {
        let target = makeTarget(sessionName: "main")
        var sessions: [ActiveTerminalSession] = []

        let first = RemuxActiveSessionCollection.upsertActivatedSession(
            target: target,
            in: &sessions
        )
        let replacement = RemuxActiveSessionCollection.upsertActivatedSession(
            target: target,
            in: &sessions
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, target.workspace.id)
        XCTAssertEqual(sessions.first?.target, target)
        XCTAssertEqual(first.id, replacement.id)
        XCTAssertNotEqual(first.instanceID, replacement.instanceID)
        XCTAssertEqual(sessions.first?.runtimeState, .connecting)
    }

    func testReplaceRuntimeUpdatesInstanceAndStateForAutomaticSource() {
        var session = ActiveTerminalSession(
            target: makeTarget(),
            runtimeState: .connected
        )
        let originalInstanceID = session.instanceID
        XCTAssertTrue(session.markAutomaticReconnectAttempted(source: .transportLoss))
        var sessions = [session]

        let replaced = RemuxActiveSessionCollection.replaceRuntime(
            workspaceID: session.id,
            source: .foreground,
            in: &sessions
        )

        XCTAssertEqual(replaced?.runtimeState, .reconnecting(.foreground))
        XCTAssertEqual(sessions.first?.runtimeState, .reconnecting(.foreground))
        XCTAssertNotEqual(sessions.first?.instanceID, originalInstanceID)
        XCTAssertEqual(sessions.first?.automaticReconnectAttemptedSources, [.transportLoss])
    }

    func testReplaceRuntimeClearsAttemptedSourcesForManualSource() {
        var session = ActiveTerminalSession(
            target: makeTarget(),
            runtimeState: .connected
        )
        XCTAssertTrue(session.markAutomaticReconnectAttempted(source: .transportLoss))
        var sessions = [session]

        _ = RemuxActiveSessionCollection.replaceRuntime(
            workspaceID: session.id,
            source: .manualButton,
            in: &sessions
        )

        XCTAssertEqual(sessions.first?.runtimeState, .reconnecting(.manualButton))
        XCTAssertEqual(sessions.first?.automaticReconnectAttemptedSources, [])
    }

    func testRemoveWorkspaceAndServer() {
        let firstServer = makeServer(displayName: "First")
        let secondServer = makeServer(displayName: "Second")
        let firstTarget = makeTarget(server: firstServer, sessionName: "one")
        let secondTarget = makeTarget(server: firstServer, sessionName: "two")
        let thirdTarget = makeTarget(server: secondServer, sessionName: "three")
        var sessions = [
            ActiveTerminalSession(target: firstTarget),
            ActiveTerminalSession(target: secondTarget),
            ActiveTerminalSession(target: thirdTarget),
        ]

        RemuxActiveSessionCollection.removeWorkspace(firstTarget.workspace.id, from: &sessions)

        XCTAssertEqual(sessions.map(\.id), [secondTarget.workspace.id, thirdTarget.workspace.id])

        RemuxActiveSessionCollection.removeServer(firstServer.id, from: &sessions)

        XCTAssertEqual(sessions.map(\.id), [thirdTarget.workspace.id])
    }

    func testRefreshServerUpdatesAuthAndPreservesWorkspaceAndSettings() {
        let server = makeServer(displayName: "Old")
        let target = makeTarget(
            server: server,
            sessionName: "main",
            password: "secret",
            terminalSettings: TerminalSettings(fontSize: 14, theme: .remuxDark)
        )
        let updatedServer = SavedServer(
            id: server.id,
            identityID: server.identityID,
            displayName: "New",
            host: "new.example.test",
            port: 2200,
            username: "new-user"
        )
        let updatedAuth = ResolvedSSHAuth.password(
            username: "new-user",
            password: "new-secret",
            identityID: updatedServer.identityID,
            displayLabel: "New"
        )
        var sessions = [ActiveTerminalSession(target: target)]

        RemuxActiveSessionCollection.refreshServer(
            updatedServer,
            sshAuth: updatedAuth,
            in: &sessions
        )

        XCTAssertEqual(sessions.first?.target.server, updatedServer)
        XCTAssertEqual(sessions.first?.target.workspace, target.workspace)
        XCTAssertEqual(sessions.first?.target.sshAuth, updatedAuth)
        XCTAssertEqual(sessions.first?.target.terminalSettings, target.terminalSettings)
    }

    func testRefreshWorkspacePreservesServerPasswordAndSettings() {
        let server = makeServer(displayName: "Server")
        let target = makeTarget(
            server: server,
            sessionName: "old",
            password: "secret",
            terminalSettings: TerminalSettings(fontSize: 13, theme: .remuxLight)
        )
        let updatedWorkspace = SavedWorkspace(
            id: target.workspace.id,
            serverID: server.id,
            sessionName: "new",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        var sessions = [ActiveTerminalSession(target: target)]

        RemuxActiveSessionCollection.refreshWorkspace(updatedWorkspace, in: &sessions)

        XCTAssertEqual(sessions.first?.target.server, server)
        XCTAssertEqual(sessions.first?.target.workspace, updatedWorkspace)
        XCTAssertEqual(sessions.first?.target.sshAuth.credential, .password("secret"))
        XCTAssertEqual(sessions.first?.target.terminalSettings, target.terminalSettings)
    }

    func testRefreshTerminalSettingsPreservesRuntimeIdentityAndState() {
        let target = makeTarget(
            password: "secret",
            terminalSettings: TerminalSettings(fontSize: 13, theme: .remuxDark)
        )
        var session = ActiveTerminalSession(
            target: target,
            runtimeState: .connected
        )
        let instanceID = session.instanceID
        XCTAssertTrue(session.markAutomaticReconnectAttempted(source: .transportLoss))
        var sessions = [session]
        let updated = TerminalSettings(fontSize: nil, theme: .remuxLight)

        RemuxActiveSessionCollection.refreshTerminalSettings(updated, in: &sessions)

        XCTAssertEqual(sessions.first?.instanceID, instanceID)
        XCTAssertEqual(sessions.first?.runtimeState, .connected)
        XCTAssertEqual(sessions.first?.automaticReconnectAttemptedSources, [.transportLoss])
        XCTAssertEqual(sessions.first?.target.server, target.server)
        XCTAssertEqual(sessions.first?.target.workspace, target.workspace)
        XCTAssertEqual(sessions.first?.target.sshAuth.credential, .password("secret"))
        XCTAssertEqual(sessions.first?.target.terminalSettings, updated)
    }

    func testActiveServerQueries() {
        let firstServer = makeServer(displayName: "First")
        let secondServer = makeServer(displayName: "Second")
        let target = makeTarget(server: firstServer)
        let sessions = [ActiveTerminalSession(target: target)]

        XCTAssertEqual(
            RemuxActiveSessionCollection.activeServerIDs(in: sessions),
            [firstServer.id]
        )
        XCTAssertTrue(
            RemuxActiveSessionCollection.hasActiveSession(
                onServer: firstServer.id,
                in: sessions
            )
        )
        XCTAssertFalse(
            RemuxActiveSessionCollection.hasActiveSession(
                onServer: secondServer.id,
                in: sessions
            )
        )
        XCTAssertTrue(
            RemuxActiveSessionCollection.containsWorkspace(
                target.workspace.id,
                in: sessions
            )
        )
    }

    func testRuntimeStateUpdateDelegatesToReducer() {
        let session = ActiveTerminalSession(target: makeTarget())
        var sessions = [session]
        let update = TerminalRuntimeStateUpdate(
            workspaceID: session.id,
            instanceID: session.instanceID,
            state: .connected,
            source: .readiness
        )

        let outcome = RemuxActiveSessionCollection.applyRuntimeStateUpdate(
            update,
            to: &sessions,
            requestedReconnectSource: nil
        )

        XCTAssertEqual(outcome, .applied(.connected))
        XCTAssertEqual(sessions.first?.runtimeState, .connected)
    }
}

private func makeServer(displayName: String = "Build Host") -> SavedServer {
    SavedServer(
        displayName: displayName,
        host: "\(displayName.lowercased().replacingOccurrences(of: " ", with: "-")).example.test",
        username: "builder"
    )
}

private func makeTarget(
    server: SavedServer = makeServer(),
    sessionName: String = "base",
    password: String = "secret",
    terminalSettings: TerminalSettings = .default
) -> SessionTarget {
    let workspace = SavedWorkspace(serverID: server.id, sessionName: sessionName)
    return SessionTarget(
        server: server,
        workspace: workspace,
        sshAuth: .password(
            username: server.username,
            password: password,
            identityID: server.identityID,
            displayLabel: server.displayName
        ),
        terminalSettings: terminalSettings
    )
}
