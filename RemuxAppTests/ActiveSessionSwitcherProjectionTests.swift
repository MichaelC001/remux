import Foundation
import XCTest
@testable import Remux

final class ActiveSessionSwitcherProjectionTests: XCTestCase {
    func testItemsUseRecentOpenOrderAndMarkOnlySelectedSession() {
        let older = makeSession(
            serverName: "Production",
            sessionName: "api",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        let selected = makeSession(
            serverName: "Mac Mini",
            sessionName: "codex",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )

        let items = ActiveSessionSwitcherProjection.items(
            sessions: [older, selected],
            selectedSessionID: selected.id
        )

        XCTAssertEqual(items.map(\.id), [selected.id, older.id])
        XCTAssertEqual(items.map(\.sessionName), ["codex", "api"])
        XCTAssertEqual(items.map(\.serverName), ["Mac Mini", "Production"])
        XCTAssertEqual(items.map(\.isSelected), [true, false])
    }

    func testOrderedServersPlacesCurrentServerFirstThenSortsByName() {
        let production = makeServer(name: "Production")
        let macMini = makeServer(name: "Mac Mini")
        let staging = makeServer(name: "Staging")

        let ordered = ActiveSessionSwitcherProjection.orderedServers(
            [production, staging, macMini],
            currentServerID: staging.id
        )

        XCTAssertEqual(ordered.map(\.id), [staging.id, macMini.id, production.id])
    }

    private func makeSession(
        serverName: String,
        sessionName: String,
        lastOpenedAt: Date
    ) -> ActiveTerminalSession {
        let server = makeServer(name: serverName)
        let workspace = SavedWorkspace(
            serverID: server.id,
            sessionName: sessionName,
            lastOpenedAt: lastOpenedAt
        )
        let auth = ResolvedSSHAuth.password(
            username: server.username,
            password: "test-password",
            identityID: server.identityID,
            displayLabel: server.displayName
        )
        return ActiveTerminalSession(
            target: TmuxConnectionTarget(
                server: server,
                workspace: workspace,
                sshAuth: auth
            ),
            runtimeState: .connected
        )
    }

    private func makeServer(name: String) -> SavedServer {
        SavedServer(
            displayName: name,
            host: "\(name.lowercased().replacingOccurrences(of: " ", with: "-")).example.test",
            username: "tester",
            identityID: UUID()
        )
    }
}
