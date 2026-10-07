import XCTest
@testable import Remux

final class RemuxLibrarySSHPrewarmPlannerTests: XCTestCase {
    func testCandidatesSelectNewestWorkspacePerSSHServer() {
        let firstServer = makePrewarmServer(displayName: "First")
        let secondServer = makePrewarmServer(displayName: "Second")
        let oldFirst = makePrewarmWorkspace(
            serverID: firstServer.id,
            sessionName: "old",
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let newFirst = makePrewarmWorkspace(
            serverID: firstServer.id,
            sessionName: "new",
            lastOpenedAt: Date(timeIntervalSince1970: 30)
        )
        let second = makePrewarmWorkspace(
            serverID: secondServer.id,
            sessionName: "second",
            lastOpenedAt: Date(timeIntervalSince1970: 20)
        )
        let snapshot = ConnectionLibrarySnapshot(
            servers: [firstServer, secondServer],
            workspaces: [oldFirst, newFirst, second]
        )

        let candidates = RemuxLibrarySSHPrewarmPlanner.candidates(
            in: snapshot,
            limit: 3
        )

        XCTAssertEqual(candidates.map(\.workspace.id), [newFirst.id, second.id])
    }

    func testCandidatesApplyActiveServerExclusionBeforeLimit() {
        let activeServer = makePrewarmServer(displayName: "Active")
        let eligibleServer = makePrewarmServer(displayName: "Eligible")
        let secondEligibleServer = makePrewarmServer(displayName: "Second Eligible")
        let activeWorkspace = makePrewarmWorkspace(
            serverID: activeServer.id,
            sessionName: "active",
            lastOpenedAt: Date(timeIntervalSince1970: 40)
        )
        let eligibleWorkspace = makePrewarmWorkspace(
            serverID: eligibleServer.id,
            sessionName: "eligible",
            lastOpenedAt: Date(timeIntervalSince1970: 20)
        )
        let secondEligibleWorkspace = makePrewarmWorkspace(
            serverID: secondEligibleServer.id,
            sessionName: "second",
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let snapshot = ConnectionLibrarySnapshot(
            servers: [activeServer, eligibleServer, secondEligibleServer],
            workspaces: [
                activeWorkspace,
                eligibleWorkspace,
                secondEligibleWorkspace,
            ]
        )

        let candidates = RemuxLibrarySSHPrewarmPlanner.candidates(
            in: snapshot,
            excludingServerIDs: [activeServer.id],
            limit: 2
        )

        XCTAssertEqual(
            candidates.map(\.workspace.id),
            [eligibleWorkspace.id, secondEligibleWorkspace.id]
        )
    }

    func testCandidatesUseSessionNameTieBreakAndLimit() {
        let alphaServer = makePrewarmServer(displayName: "Alpha")
        let betaServer = makePrewarmServer(displayName: "Beta")
        let gammaServer = makePrewarmServer(displayName: "Gamma")
        let date = Date(timeIntervalSince1970: 10)
        let beta = makePrewarmWorkspace(serverID: betaServer.id, sessionName: "beta", lastOpenedAt: date)
        let alpha = makePrewarmWorkspace(serverID: alphaServer.id, sessionName: "alpha", lastOpenedAt: date)
        let gamma = makePrewarmWorkspace(serverID: gammaServer.id, sessionName: "gamma", lastOpenedAt: date)
        let snapshot = ConnectionLibrarySnapshot(
            servers: [alphaServer, betaServer, gammaServer],
            workspaces: [beta, gamma, alpha]
        )

        let candidates = RemuxLibrarySSHPrewarmPlanner.candidates(
            in: snapshot,
            limit: 2
        )

        XCTAssertEqual(candidates.map(\.workspace.id), [alpha.id, beta.id])
    }

    func testCandidatesReturnEmptyForZeroLimit() {
        let server = makePrewarmServer(displayName: "Server")
        let workspace = makePrewarmWorkspace(serverID: server.id, sessionName: "base")
        let snapshot = ConnectionLibrarySnapshot(servers: [server], workspaces: [workspace])

        let candidates = RemuxLibrarySSHPrewarmPlanner.candidates(
            in: snapshot,
            limit: 0
        )

        XCTAssertEqual(candidates, [])
    }

    func testEligibilityRejectsStaleGeneration() {
        let context = makeEligibilityContext()

        XCTAssertEqual(
            context.eligibility(capturedGeneration: 1, currentGeneration: 2),
            .skipped(.staleGeneration)
        )
    }

    func testEligibilityRejectsStaleContext() {
        let context = makeEligibilityContext()

        XCTAssertEqual(
            context.eligibility(isLibraryVisible: false),
            .skipped(.staleContext)
        )
    }

    func testEligibilityRejectsStaleCandidate() {
        let context = makeEligibilityContext()

        XCTAssertEqual(
            context.eligibilityWithCurrent(currentServer: nil, currentWorkspace: context.workspace),
            .skipped(.staleCandidate)
        )
        XCTAssertEqual(
            context.eligibilityWithCurrent(currentServer: context.server, currentWorkspace: nil),
            .skipped(.staleCandidate)
        )
    }

    func testEligibilityRejectsActiveServerAndMissingAuth() {
        let context = makeEligibilityContext()

        XCTAssertEqual(
            context.eligibility(hasActiveSessionOnServer: true),
            .skipped(.activeServer)
        )
        XCTAssertEqual(
            context.eligibility(hasCurrentTarget: false),
            .skipped(.missingAuth)
        )
    }

    func testEligibilityRejectsStaleTargetDrift() {
        let context = makeEligibilityContext()

        XCTAssertEqual(
            context.eligibility(
                currentServer: SavedServer(
                    id: context.server.id,
                    displayName: "Renamed",
                    host: "renamed.example.test",
                    username: context.server.username,
                    identityID: context.server.identityID
                )
            ),
            .skipped(.staleTarget)
        )
        XCTAssertEqual(
            context.eligibility(
                currentWorkspace: SavedWorkspace(
                    id: context.workspace.id,
                    serverID: context.server.id,
                    sessionName: "renamed"
                )
            ),
            .skipped(.staleTarget)
        )
        XCTAssertEqual(
            context.eligibility(
                currentTarget: context.target.replacingAuth(
                    .password(
                        username: context.server.username,
                        password: "changed",
                        identityID: context.server.identityID,
                        displayLabel: "Build"
                    )
                )
            ),
            .skipped(.staleTarget)
        )
        XCTAssertEqual(
            context.eligibility(
                currentTerminalSettings: TerminalSettings(fontSize: 14, theme: .remuxDark)
            ),
            .skipped(.staleTarget)
        )
    }

    func testEligibilityReturnsCapturedTargetWhenReusable() {
        let context = makeEligibilityContext()

        XCTAssertEqual(
            context.eligibility(),
            .eligible(context.target)
        )
    }
}

private struct PrewarmEligibilityContext {
    let server: SavedServer
    let workspace: SavedWorkspace
    let target: SessionTarget
    let candidate: RemuxLibrarySSHPrewarmCandidate

    func eligibility(
        capturedGeneration: UInt64 = 1,
        currentGeneration: UInt64 = 1,
        isLibraryVisible: Bool = true,
        currentServer: SavedServer? = nil,
        currentWorkspace: SavedWorkspace? = nil,
        currentTarget: SessionTarget? = nil,
        hasCurrentTarget: Bool = true,
        currentTerminalSettings: TerminalSettings = .default,
        hasActiveSessionOnServer: Bool = false
    ) -> RemuxLibrarySSHPrewarmEligibility {
        let resolvedServer = currentServer ?? server
        let resolvedWorkspace = currentWorkspace ?? workspace
        let resolvedTarget = currentTarget ?? SessionTarget(
            server: resolvedServer,
            workspace: resolvedWorkspace,
            sshAuth: target.sshAuth,
            terminalSettings: currentTerminalSettings
        )

        return RemuxLibrarySSHPrewarmPlanner.eligibility(
            capturedGeneration: capturedGeneration,
            currentGeneration: currentGeneration,
            isLibraryVisible: isLibraryVisible,
            candidate: candidate,
            capturedTarget: target,
            currentServer: resolvedServer,
            currentWorkspace: resolvedWorkspace,
            currentTarget: hasCurrentTarget ? resolvedTarget : nil,
            currentTerminalSettings: currentTerminalSettings,
            hasActiveSessionOnServer: hasActiveSessionOnServer
        )
    }

    func eligibilityWithCurrent(
        currentServer: SavedServer?,
        currentWorkspace: SavedWorkspace?,
        capturedGeneration: UInt64 = 1,
        currentGeneration: UInt64 = 1,
        isLibraryVisible: Bool = true,
        currentTarget: SessionTarget? = nil,
        hasCurrentTarget: Bool = true,
        currentTerminalSettings: TerminalSettings = .default,
        hasActiveSessionOnServer: Bool = false
    ) -> RemuxLibrarySSHPrewarmEligibility {
        let resolvedTarget = currentTarget ?? {
            guard let currentServer, let currentWorkspace else { return target }
            return SessionTarget(
                server: currentServer,
                workspace: currentWorkspace,
                sshAuth: target.sshAuth,
                terminalSettings: currentTerminalSettings
            )
        }()

        return RemuxLibrarySSHPrewarmPlanner.eligibility(
            capturedGeneration: capturedGeneration,
            currentGeneration: currentGeneration,
            isLibraryVisible: isLibraryVisible,
            candidate: candidate,
            capturedTarget: target,
            currentServer: currentServer,
            currentWorkspace: currentWorkspace,
            currentTarget: hasCurrentTarget ? resolvedTarget : nil,
            currentTerminalSettings: currentTerminalSettings,
            hasActiveSessionOnServer: hasActiveSessionOnServer
        )
    }
}

private func makeEligibilityContext() -> PrewarmEligibilityContext {
    let server = makePrewarmServer(displayName: "Build")
    let workspace = makePrewarmWorkspace(serverID: server.id, sessionName: "base")
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
    let candidate = RemuxLibrarySSHPrewarmCandidate(
        server: server,
        workspace: workspace
    )
    return PrewarmEligibilityContext(
        server: server,
        workspace: workspace,
        target: target,
        candidate: candidate
    )
}

private func makePrewarmServer(
    id: SavedServer.ID = SavedServer.ID(),
    displayName: String
) -> SavedServer {
    SavedServer(
        id: id,
        displayName: displayName,
        host: "\(displayName.lowercased().replacingOccurrences(of: " ", with: "-")).example.test",
        username: "builder",
        identityID: UUID()
    )
}

private extension SessionTarget {
    func replacingAuth(_ auth: ResolvedSSHAuth) -> SessionTarget {
        SessionTarget(
            server: server,
            workspace: workspace,
            sshAuth: auth,
            terminalSettings: terminalSettings
        )
    }
}

private func makePrewarmWorkspace(
    id: SavedWorkspace.ID = SavedWorkspace.ID(),
    serverID: SavedServer.ID,
    sessionName: String,
    lastOpenedAt: Date = Date(timeIntervalSince1970: 10)
) -> SavedWorkspace {
    SavedWorkspace(
        id: id,
        serverID: serverID,
        sessionName: sessionName,
        lastOpenedAt: lastOpenedAt
    )
}
