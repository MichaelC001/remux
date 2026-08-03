import SwiftUI

struct ActiveSessionSwitcherItem: Identifiable, Equatable {
    let id: SavedWorkspace.ID
    let sessionName: String
    let serverName: String
    let runtimeState: TerminalRuntimeState?
    let isActive: Bool
    let isSelected: Bool

    var isDisconnectable: Bool {
        isActive && runtimeState.map(TerminalRuntimeStateProjection.isRootVisibleConnected) == true
    }
}

enum ActiveSessionSwitcherProjection {
    static func items(
        sessions: [ActiveTerminalSession],
        snapshot: ConnectionLibrarySnapshot,
        serverID: SavedServer.ID?,
        discoveredSessionNames: [String],
        selectedSessionID: SavedWorkspace.ID?
    ) -> [ActiveSessionSwitcherItem] {
        guard let serverID, let server = snapshot.server(id: serverID) else { return [] }
        let activeSessions = RemuxActiveSessionCollection.sortedForDisplay(sessions)
            .filter { $0.target.server.id == serverID }
        var includedNames = Set<String>()
        var items = activeSessions.compactMap { session -> ActiveSessionSwitcherItem? in
            guard includedNames.insert(session.target.workspace.sessionName).inserted else { return nil }
            return ActiveSessionSwitcherItem(
                id: session.id,
                sessionName: session.target.workspace.sessionName,
                serverName: session.target.server.displayName,
                runtimeState: session.runtimeState,
                isActive: true,
                isSelected: session.id == selectedSessionID
            )
        }

        let workspacesByName = Dictionary(
            snapshot.workspaces(for: serverID).map { ($0.sessionName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let unopened = Set(discoveredSessionNames)
            .subtracting(includedNames)
            .compactMap { workspacesByName[$0] }
            .sorted {
                $0.sessionName.localizedStandardCompare($1.sessionName) == .orderedAscending
            }
            .map { workspace in
                ActiveSessionSwitcherItem(
                    id: workspace.id,
                    sessionName: workspace.sessionName,
                    serverName: server.displayName,
                    runtimeState: nil,
                    isActive: false,
                    isSelected: false
                )
            }
        items.append(contentsOf: unopened)
        return items
    }

    static func orderedServers(
        _ servers: [SavedServer],
        currentServerID: SavedServer.ID?
    ) -> [SavedServer] {
        servers.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.id == currentServerID
            let rhsIsCurrent = rhs.id == currentServerID
            if lhsIsCurrent != rhsIsCurrent {
                return lhsIsCurrent
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
}

struct ActiveSessionSwitcherView: View {
    private enum Route: Hashable {
        case chooseServer
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let sessions: [ActiveSessionSwitcherItem]
    let servers: [SavedServer]
    let currentServerID: SavedServer.ID?
    let onSelectSession: (SavedWorkspace.ID) -> Void
    let onOpenSession: (SavedWorkspace.ID) -> Void
    let onDisconnectSession: (SavedWorkspace.ID) -> Void
    let onCreateSession: (SavedServer.ID) -> Void
    let onRefresh: () -> Void
    let discoveryState: TmuxSessionDiscoveryState

    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            sessionList
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .chooseServer:
                        NewSessionServerPickerView(
                            servers: ActiveSessionSwitcherProjection.orderedServers(
                                servers,
                                currentServerID: currentServerID
                            ),
                            currentServerID: currentServerID,
                            onSelect: beginNewSession
                        )
                    }
                }
        }
        .accessibilityIdentifier("terminal.sessions.sheet")
    }

    private var sessionList: some View {
        TerminalSelectionSheetScaffold(
            title: "Sessions",
            context: context,
            closeAccessibilityIdentifier: "terminal.sessions.close"
        ) {
            List {
                discoveryPresentation
                sessionRows
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(.snappy, value: sessions.map(\.id))
            .accessibilityIdentifier("terminal.sessions.list")
        } actions: {
            HStack(spacing: 10) {
                TerminalSelectionSheetActionButton(
                    title: discoveryState.isLoading ? "Refreshing…" : "Refresh",
                    systemName: "arrow.clockwise",
                    accessibilityIdentifier: "terminal.sessions.refresh",
                    action: discoveryState.isLoading ? nil : onRefresh
                )
                TerminalSelectionSheetActionButton(
                    title: "New Session…",
                    systemName: "plus",
                    accessibilityIdentifier: "terminal.sessions.new",
                    action: newSessionAction
                )
            }
        }
    }

    @ViewBuilder
    private var sessionRows: some View {
        ForEach(sessions) { session in
            sessionRow(session)
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: ActiveSessionSwitcherItem) -> some View {
        if session.isDisconnectable {
            sessionRowButton(session)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Haptic.warning()
                        onDisconnectSession(session.id)
                    } label: {
                        Label("Disconnect", systemImage: "bolt.slash")
                    }
                    .accessibilityIdentifier("terminal.sessions.disconnect")
                }
                .accessibilityAction(named: Text("Disconnect from Remux")) {
                    onDisconnectSession(session.id)
                }
        } else {
            sessionRowButton(session)
        }
    }

    private func sessionRowButton(_ session: ActiveSessionSwitcherItem) -> some View {
        Button {
            Haptic.selection()
            if session.isActive {
                onSelectSession(session.id)
            } else {
                onOpenSession(session.id)
            }
            dismiss()
        } label: {
            ActiveSessionSwitcherRow(
                session: session,
                chromeStyle: chromeStyle
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("terminal.sessions.session")
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.visible)
        .listRowSeparatorTint(TerminalSelectionSheetPalette.stroke)
        .listRowBackground(Color.clear)
    }

    private var newSessionAction: (() -> Void)? {
        guard !servers.isEmpty else { return nil }
        return showNewSessionFlow
    }

    private func showNewSessionFlow() {
        if servers.count == 1, let server = servers.first {
            beginNewSession(server.id)
            return
        }

        path.append(.chooseServer)
    }

    private func beginNewSession(_ serverID: SavedServer.ID) {
        dismiss()
        onCreateSession(serverID)
    }

    private var context: String {
        switch discoveryState {
        case .idle:
            "Loading sessions…"
        case .loading:
            "Refreshing sessions…"
        case .loaded:
            "\(sessions.count) \(sessions.count == 1 ? "session" : "sessions")"
        case .failed:
            "Showing connected sessions"
        }
    }

    @ViewBuilder
    private var discoveryPresentation: some View {
        switch discoveryState {
        case .loading:
            Label("Looking for tmux sessions…", systemImage: "arrow.clockwise")
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .listRowBackground(Color.clear)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .listRowBackground(Color.clear)

        case .loaded where sessions.isEmpty:
            ContentUnavailableView(
                "No tmux sessions",
                systemImage: "terminal",
                description: Text("Create a session or refresh to check again.")
            )
            .listRowBackground(Color.clear)

        case .idle, .loaded:
            EmptyView()
        }
    }
}

private struct ActiveSessionSwitcherRow: View {
    let session: ActiveSessionSwitcherItem
    let chromeStyle: GhosttyTerminalChromeStyle

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.callout.weight(.semibold))
                .foregroundStyle(
                    session.isSelected
                        ? chromeStyle.accent
                        : TerminalSelectionSheetPalette.secondary
                )
                .frame(width: 28, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.sessionName)
                    .font(.headline)
                    .foregroundStyle(TerminalSelectionSheetPalette.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(session.serverName)
                        .lineLimit(1)

                    Text("·")
                        .accessibilityHidden(true)

                    if let runtimeState = session.runtimeState {
                        TerminalRuntimeStateIndicator(state: runtimeState)
                    } else {
                        Text("Available")
                    }
                }
                .font(.footnote)
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if session.isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(chromeStyle.accent)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(session.isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityLabel: String {
        let status = session.runtimeState.map {
            TerminalRuntimeStatusPresentation.projection(for: $0).label
        } ?? "available"
        let current = session.isSelected ? ", current session" : ""
        return "\(session.sessionName), \(session.serverName), \(status)\(current)"
    }
}

private struct NewSessionServerPickerView: View {
    let servers: [SavedServer]
    let currentServerID: SavedServer.ID?
    let onSelect: (SavedServer.ID) -> Void

    var body: some View {
        List(servers) { server in
            Button {
                Haptic.selection()
                onSelect(server.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(server.displayName)
                                .font(.headline)
                                .foregroundStyle(TerminalSelectionSheetPalette.primary)
                                .lineLimit(1)

                            if server.id == currentServerID {
                                Text("Current")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                            }
                        }

                        Text(server.displayAddress)
                            .font(.footnote.monospaced())
                            .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TerminalSelectionSheetPalette.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(TerminalSelectionSheetPalette.stroke)
            .accessibilityIdentifier("terminal.sessions.server")
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Choose Server")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("terminal.sessions.server-picker")
    }
}
