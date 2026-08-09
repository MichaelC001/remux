import SwiftUI

struct ActiveSessionSwitcherItem: Identifiable, Equatable {
    let id: SavedWorkspace.ID
    let sessionName: String
    let serverName: String
    let runtimeState: TerminalRuntimeState
    let isSelected: Bool
}

struct AvailableSessionSwitcherItem: Identifiable, Equatable {
    let id: SavedWorkspace.ID
    let sessionName: String
    let serverName: String
}

struct RecentSessionSwitcherItem: Identifiable, Equatable {
    let id: SavedWorkspace.ID
    let sessionName: String
    let serverName: String
    let lastOpenedAt: Date
    let isAvailable: Bool
}

struct SessionSwitcherProjection: Equatable {
    let activeSessions: [ActiveSessionSwitcherItem]
    let availableSessions: [AvailableSessionSwitcherItem]
    let recentSessions: [RecentSessionSwitcherItem]

    init(
        snapshot: ConnectionLibrarySnapshot,
        activeSessions: [ActiveTerminalSession],
        currentServerID: SavedServer.ID? = nil,
        discoveredSessionNames: [String] = [],
        selectedSessionID: SavedWorkspace.ID?
    ) {
        self.activeSessions = RemuxActiveSessionCollection
            .sortedForDisplay(activeSessions)
            .map { session in
                ActiveSessionSwitcherItem(
                    id: session.id,
                    sessionName: session.target.workspace.sessionName,
                    serverName: session.target.server.displayName,
                    runtimeState: session.runtimeState,
                    isSelected: session.id == selectedSessionID
                )
            }

        let activeWorkspaceIDs = Set(activeSessions.map(\.id))
        let discoveredNames = Set(discoveredSessionNames)
        let activeNamesOnCurrentServer = Set(
            activeSessions.lazy
                .filter { $0.target.server.id == currentServerID }
                .map { $0.target.workspace.sessionName }
        )

        if let currentServerID, let server = snapshot.server(id: currentServerID) {
            var includedNames = activeNamesOnCurrentServer
            self.availableSessions = snapshot
                .workspaces(for: currentServerID)
                .filter { workspace in
                    workspace.lastOpenedAt == .distantPast
                        && discoveredNames.contains(workspace.sessionName)
                        && includedNames.insert(workspace.sessionName).inserted
                }
                .map { workspace in
                    AvailableSessionSwitcherItem(
                        id: workspace.id,
                        sessionName: workspace.sessionName,
                        serverName: server.displayName
                    )
                }
                .sorted {
                    $0.sessionName.localizedStandardCompare($1.sessionName) == .orderedAscending
                }
        } else {
            self.availableSessions = []
        }

        self.recentSessions = snapshot
            .recentWorkspaces(excluding: activeWorkspaceIDs)
            .filter { $0.lastOpenedAt != .distantPast }
            .compactMap { workspace in
                guard let server = snapshot.server(id: workspace.serverID) else {
                    return nil
                }
                return RecentSessionSwitcherItem(
                    id: workspace.id,
                    sessionName: workspace.sessionName,
                    serverName: server.displayName,
                    lastOpenedAt: workspace.lastOpenedAt,
                    isAvailable: workspace.serverID == currentServerID
                        && discoveredNames.contains(workspace.sessionName)
                        && !activeNamesOnCurrentServer.contains(workspace.sessionName)
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

struct SessionSwitcherView: View {
    private enum Route: Hashable {
        case chooseServer
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let projection: SessionSwitcherProjection
    let servers: [SavedServer]
    let currentServerID: SavedServer.ID?
    let onSelectActiveSession: (SavedWorkspace.ID) -> Void
    let onResumeSession: (SavedWorkspace.ID) -> Void
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
                            servers: SessionSwitcherProjection.orderedServers(
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
            context: sessionCountSummary,
            closeAccessibilityIdentifier: "terminal.sessions.close"
        ) {
            List {
                Section {
                    ForEach(projection.activeSessions) { session in
                        activeSessionRow(session)
                    }
                } header: {
                    SessionSwitcherSectionHeader(title: "Active")
                }

                discoverySection

                if !projection.availableSessions.isEmpty {
                    Section {
                        ForEach(projection.availableSessions) { session in
                            availableSessionRow(session)
                        }
                    } header: {
                        SessionSwitcherSectionHeader(title: "Available")
                    }
                }

                if !projection.recentSessions.isEmpty {
                    Section {
                        ForEach(projection.recentSessions) { session in
                            recentSessionRow(session)
                        }
                    } header: {
                        SessionSwitcherSectionHeader(title: "Recent")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(.snappy, value: projection.activeSessions.map(\.id))
            .animation(.snappy, value: projection.availableSessions.map(\.id))
            .animation(.snappy, value: projection.recentSessions.map(\.id))
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

    private var sessionCountSummary: String {
        let count = projection.activeSessions.count
            + projection.availableSessions.count
            + projection.recentSessions.count
        return count == 1 ? "1 session" : "\(count) sessions"
    }

    private func activeSessionRow(_ session: ActiveSessionSwitcherItem) -> some View {
        Button {
            Haptic.selection()
            onSelectActiveSession(session.id)
            dismiss()
        } label: {
            ActiveSessionSwitcherRow(
                session: session,
                chromeStyle: chromeStyle
            )
        }
        .buttonStyle(.plain)
        .sessionSwitcherListRow(accessibilityIdentifier: "terminal.sessions.active-session")
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

    private func availableSessionRow(_ session: AvailableSessionSwitcherItem) -> some View {
        Button {
            Haptic.selection()
            dismiss()
            onResumeSession(session.id)
        } label: {
            AvailableSessionSwitcherRow(session: session)
        }
        .buttonStyle(.plain)
        .sessionSwitcherListRow(accessibilityIdentifier: "terminal.sessions.available-session")
    }

    private func recentSessionRow(_ session: RecentSessionSwitcherItem) -> some View {
        Button {
            Haptic.selection()
            dismiss()
            onResumeSession(session.id)
        } label: {
            RecentSessionSwitcherRow(session: session)
        }
        .buttonStyle(.plain)
        .sessionSwitcherListRow(accessibilityIdentifier: "terminal.sessions.recent-session")
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

    @ViewBuilder
    private var discoverySection: some View {
        switch discoveryState {
        case .loading:
            Section {
                Label("Looking for tmux sessions…", systemImage: "arrow.clockwise")
                    .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                    .listRowBackground(Color.clear)
            } header: {
                SessionSwitcherSectionHeader(title: "Available")
            }

        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                    .listRowBackground(Color.clear)
            } header: {
                SessionSwitcherSectionHeader(title: "Available")
            }

        case .idle, .loaded:
            EmptyView()
        }
    }
}

private struct SessionSwitcherSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(TerminalSelectionSheetPalette.secondary)
            .textCase(nil)
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
                    .truncationMode(.middle)

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

private struct AvailableSessionSwitcherRow: View {
    let session: AvailableSessionSwitcherItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.callout.weight(.semibold))
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .frame(width: 28, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.sessionName)
                    .font(.headline)
                    .foregroundStyle(TerminalSelectionSheetPalette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(session.serverName)
                        .lineLimit(1)

                    Text("·")
                        .accessibilityHidden(true)

                    Text("Available")
                }
                .font(.footnote)
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.sessionName), \(session.serverName)")
        .accessibilityValue("Available")
        .accessibilityHint("Resume this session")
        .accessibilityAddTraits(.isButton)
    }
}

private struct RecentSessionSwitcherRow: View {
    let session: RecentSessionSwitcherItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.callout.weight(.semibold))
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .frame(width: 28, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.sessionName)
                    .font(.headline)
                    .foregroundStyle(TerminalSelectionSheetPalette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(session.serverName)
                        .lineLimit(1)

                    Text("·")
                        .accessibilityHidden(true)

                    if session.isAvailable {
                        Text("Available")
                    } else {
                        Text("opened \(session.lastOpenedAt, style: .relative)")
                    }
                }
                .font(.footnote)
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.sessionName), \(session.serverName)")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Resume this session")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityValue: Text {
        if session.isAvailable {
            return Text("Available")
        }
        return Text("Opened \(session.lastOpenedAt, style: .relative)")
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

private struct SessionSwitcherSheetPresentationModifier: ViewModifier {
    let colorScheme: ColorScheme
    let chromeStyle: GhosttyTerminalChromeStyle

    @State private var selectedDetent: PresentationDetent = .medium

    func body(content: Content) -> some View {
        content
            .presentationDetents(
                [.medium, .large],
                selection: $selectedDetent
            )
            .presentationContentInteraction(.resizes)
            .presentationDragIndicator(.visible)
            .terminalSelectionSheetPresentationBackground()
            .ghosttyTerminalChromePresentation(
                colorScheme,
                chromeStyle: chromeStyle
            )
    }
}

extension View {
    func sessionSwitcherSheetPresentation(
        colorScheme: ColorScheme,
        chromeStyle: GhosttyTerminalChromeStyle
    ) -> some View {
        modifier(
            SessionSwitcherSheetPresentationModifier(
                colorScheme: colorScheme,
                chromeStyle: chromeStyle
            )
        )
    }
}

private extension View {
    func sessionSwitcherListRow(accessibilityIdentifier: String) -> some View {
        self
            .accessibilityIdentifier(accessibilityIdentifier)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.visible)
            .listRowSeparatorTint(TerminalSelectionSheetPalette.stroke)
            .listRowBackground(Color.clear)
    }
}
