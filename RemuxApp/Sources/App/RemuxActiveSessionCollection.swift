import Foundation

enum RemuxActiveSessionCollection {
    static func sortedForDisplay(
        _ activeSessions: [ActiveTerminalSession]
    ) -> [ActiveTerminalSession] {
        activeSessions.sorted { lhs, rhs in
            if lhs.target.workspace.lastOpenedAt != rhs.target.workspace.lastOpenedAt {
                return lhs.target.workspace.lastOpenedAt > rhs.target.workspace.lastOpenedAt
            }

            let sessionComparison = lhs.target.workspace.sessionName.localizedStandardCompare(
                rhs.target.workspace.sessionName
            )
            if sessionComparison != .orderedSame {
                return sessionComparison == .orderedAscending
            }

            return lhs.target.server.displayName.localizedStandardCompare(
                rhs.target.server.displayName
            ) == .orderedAscending
        }
    }

    static func containsWorkspace(
        _ workspaceID: SavedWorkspace.ID,
        in activeSessions: [ActiveTerminalSession]
    ) -> Bool {
        activeSessions.contains { $0.id == workspaceID }
    }

    static func session(
        _ workspaceID: SavedWorkspace.ID,
        in activeSessions: [ActiveTerminalSession]
    ) -> ActiveTerminalSession? {
        activeSessions.first { $0.id == workspaceID }
    }

    static func activeServerIDs(
        in activeSessions: [ActiveTerminalSession]
    ) -> Set<SavedServer.ID> {
        Set(activeSessions.map(\.target.server.id))
    }

    static func hasActiveSession(
        onServer serverID: SavedServer.ID,
        in activeSessions: [ActiveTerminalSession]
    ) -> Bool {
        activeSessions.contains { $0.target.server.id == serverID }
    }

    @discardableResult
    static func upsertActivatedSession(
        target: TmuxConnectionTarget,
        in activeSessions: inout [ActiveTerminalSession]
    ) -> ActiveTerminalSession {
        upsertActivatedSession(
            ActiveTerminalSession(target: target),
            in: &activeSessions
        )
    }

    @discardableResult
    static func upsertActivatedSession(
        _ activeSession: ActiveTerminalSession,
        in activeSessions: inout [ActiveTerminalSession]
    ) -> ActiveTerminalSession {
        if let index = activeSessions.firstIndex(where: { $0.id == activeSession.id }) {
            activeSessions[index] = activeSession
        } else {
            activeSessions.append(activeSession)
        }
        return activeSession
    }

    @discardableResult
    static func replaceRuntime(
        workspaceID: SavedWorkspace.ID,
        source: TerminalReconnectSource,
        in activeSessions: inout [ActiveTerminalSession]
    ) -> ActiveTerminalSession? {
        guard let replacement = runtimeReplacementSession(
            workspaceID: workspaceID,
            source: source,
            in: activeSessions
        ) else {
            return nil
        }

        replaceRuntime(with: replacement, in: &activeSessions)
        return replacement
    }

    static func runtimeReplacementSession(
        workspaceID: SavedWorkspace.ID,
        source: TerminalReconnectSource,
        in activeSessions: [ActiveTerminalSession]
    ) -> ActiveTerminalSession? {
        guard var session = activeSessions.first(where: { $0.id == workspaceID }) else {
            return nil
        }

        session.replaceRuntime(source: source)
        return session
    }

    static func replaceRuntime(
        with replacement: ActiveTerminalSession,
        in activeSessions: inout [ActiveTerminalSession]
    ) {
        guard let index = activeSessions.firstIndex(where: { $0.id == replacement.id }) else {
            return
        }

        activeSessions[index] = replacement
    }

    static func applyRuntimeStateUpdate(
        _ update: TerminalRuntimeStateUpdate,
        to activeSessions: inout [ActiveTerminalSession],
        requestedReconnectSource: TerminalReconnectSource?
    ) -> ActiveSessionRuntimeTransitionOutcome {
        RemuxActiveSessionRuntimeReducer.apply(
            update,
            to: &activeSessions,
            requestedReconnectSource: requestedReconnectSource
        )
    }

    static func removeWorkspace(
        _ workspaceID: SavedWorkspace.ID,
        from activeSessions: inout [ActiveTerminalSession]
    ) {
        activeSessions.removeAll { $0.id == workspaceID }
    }

    static func removeServer(
        _ serverID: SavedServer.ID,
        from activeSessions: inout [ActiveTerminalSession]
    ) {
        activeSessions.removeAll { $0.target.server.id == serverID }
    }

    static func refreshServer(
        _ server: SavedServer,
        sshAuth: ResolvedSSHAuth,
        in activeSessions: inout [ActiveTerminalSession]
    ) {
        for index in activeSessions.indices where activeSessions[index].target.server.id == server.id {
            let target = activeSessions[index].target
            activeSessions[index].target = TmuxConnectionTarget(
                server: server,
                workspace: target.workspace,
                sshAuth: sshAuth,
                terminalSettings: target.terminalSettings
            )
        }
    }

    static func refreshWorkspace(
        _ workspace: SavedWorkspace,
        in activeSessions: inout [ActiveTerminalSession]
    ) {
        guard let index = activeSessions.firstIndex(where: { $0.id == workspace.id }) else {
            return
        }

        let target = activeSessions[index].target
        activeSessions[index].target = TmuxConnectionTarget(
            server: target.server,
            workspace: workspace,
            sshAuth: target.sshAuth,
            terminalSettings: target.terminalSettings
        )
    }

    static func refreshTerminalSettings(
        _ terminalSettings: TerminalSettings,
        in activeSessions: inout [ActiveTerminalSession]
    ) {
        for index in activeSessions.indices {
            let target = activeSessions[index].target
            activeSessions[index].target = TmuxConnectionTarget(
                server: target.server,
                workspace: target.workspace,
                sshAuth: target.sshAuth,
                terminalSettings: terminalSettings
            )
        }
    }
}
