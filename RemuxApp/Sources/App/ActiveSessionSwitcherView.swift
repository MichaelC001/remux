import SwiftUI

struct ActiveSessionSwitcherItem: Identifiable, Equatable {
    let id: SavedWorkspace.ID
    let sessionName: String
    let serverName: String
    let runtimeState: TerminalRuntimeState
    let isSelected: Bool
}

enum ActiveSessionSwitcherProjection {
    static func items(
        sessions: [ActiveTerminalSession],
        selectedSessionID: SavedWorkspace.ID?
    ) -> [ActiveSessionSwitcherItem] {
        RemuxActiveSessionCollection.sortedForDisplay(sessions).map { session in
            ActiveSessionSwitcherItem(
                id: session.id,
                sessionName: session.target.workspace.sessionName,
                serverName: session.target.server.displayName,
                runtimeState: session.runtimeState,
                isSelected: session.id == selectedSessionID
            )
        }
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
    let onDisconnectSession: (SavedWorkspace.ID) -> Void
    let onCreateSession: (SavedServer.ID) -> Void

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
            context: "\(sessions.count) active",
            closeAccessibilityIdentifier: "terminal.sessions.close"
        ) {
            List {
                sessionRows
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(.snappy, value: sessions.map(\.id))
            .accessibilityIdentifier("terminal.sessions.list")
        } actions: {
            TerminalSelectionSheetActionButton(
                title: "New Session…",
                systemName: "plus",
                accessibilityIdentifier: "terminal.sessions.new",
                action: newSessionAction
            )
        }
    }

    @ViewBuilder
    private var sessionRows: some View {
        ForEach(sessions) { session in
            sessionRow(session)
        }
    }

    private func sessionRow(_ session: ActiveSessionSwitcherItem) -> some View {
        Button {
            Haptic.selection()
            onSelectSession(session.id)
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

                    TerminalRuntimeStateIndicator(state: session.runtimeState)
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
        let status = TerminalRuntimeStatusPresentation.projection(for: session.runtimeState).label
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
