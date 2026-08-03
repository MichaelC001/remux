import Foundation

struct ConnectionLibrarySnapshot: Equatable, Sendable {
    static let empty = ConnectionLibrarySnapshot(servers: [], workspaces: [], identities: [])

    let servers: [SavedServer]
    let workspaces: [SavedWorkspace]
    let identities: [SSHIdentity]

    init(
        servers: [SavedServer],
        workspaces: [SavedWorkspace],
        identities: [SSHIdentity] = []
    ) {
        self.servers = servers
        self.workspaces = workspaces
        self.identities = identities
    }

    var isEmpty: Bool {
        servers.isEmpty && workspaces.isEmpty
    }

    var latestProfile: (SavedServer, SavedWorkspace)? {
        guard let workspace = workspaces.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt }).first else {
            return nil
        }

        guard let server = server(id: workspace.serverID) else {
            return nil
        }

        return (server, workspace)
    }

    func server(id: SavedServer.ID) -> SavedServer? {
        servers.first(where: { $0.id == id })
    }

    func workspace(id: SavedWorkspace.ID) -> SavedWorkspace? {
        workspaces.first(where: { $0.id == id })
    }

    func identity(id: SSHIdentity.ID) -> SSHIdentity? {
        identities.first(where: { $0.id == id })
    }

    func workspaces(for serverID: SavedServer.ID) -> [SavedWorkspace] {
        workspaces
            .filter { $0.serverID == serverID }
            .sorted { lhs, rhs in
                if lhs.lastOpenedAt != rhs.lastOpenedAt {
                    return lhs.lastOpenedAt > rhs.lastOpenedAt
                }

                return lhs.sessionName.localizedStandardCompare(rhs.sessionName) == .orderedAscending
            }
    }
}

protocol ConnectionProfileRepository: Sendable {
    func loadSnapshot() async throws -> ConnectionLibrarySnapshot
    func loadProfile() async throws -> (SavedServer, SavedWorkspace)?
    func saveServer(_ server: SavedServer) async throws
    func saveWorkspace(_ workspace: SavedWorkspace) async throws
    func saveIdentity(_ identity: SSHIdentity) async throws
    func saveIdentityProfile(
        identity: SSHIdentity,
        server: SavedServer,
        workspace: SavedWorkspace
    ) async throws
    func saveProfile(server: SavedServer, workspace: SavedWorkspace) async throws
    func reconcileDiscoveredWorkspaces(
        for serverID: SavedServer.ID,
        sessionNames: [String]
    ) async throws -> ConnectionLibrarySnapshot
    func deleteServer(id: SavedServer.ID) async throws
    func deleteWorkspace(id: SavedWorkspace.ID) async throws
    func deleteIdentity(id: SSHIdentity.ID) async throws
}

enum ConnectionProfileRepositoryError: Error, Equatable {
    case missingServer(SavedServer.ID)
}

actor FileBackedConnectionProfileRepository: ConnectionProfileRepository {
    private let serverStore: JSONFileStore<SavedServer>
    private let workspaceStore: JSONFileStore<SavedWorkspace>
    private let identityStore: JSONFileStore<SSHIdentity>

    init(rootURL: URL) {
        self.serverStore = JSONFileStore(fileURL: rootURL.appendingPathComponent("servers.json"))
        self.workspaceStore = JSONFileStore(fileURL: rootURL.appendingPathComponent("workspaces.json"))
        self.identityStore = JSONFileStore(fileURL: rootURL.appendingPathComponent("ssh-identities.json"))
    }

    func loadSnapshot() async throws -> ConnectionLibrarySnapshot {
        let servers = try await serverStore.load()
        let workspaces = try await workspaceStore.load()
        let identities = try await identityStore.load()
        let serverIDs = Set(servers.map(\.id))
        let validWorkspaces = workspaces.filter { serverIDs.contains($0.serverID) }

        return ConnectionLibrarySnapshot(
            servers: servers.sorted { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            },
            workspaces: validWorkspaces,
            identities: identities.sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        )
    }

    func loadProfile() async throws -> (SavedServer, SavedWorkspace)? {
        try await loadSnapshot().latestProfile
    }

    func saveServer(_ server: SavedServer) async throws {
        var servers = try await serverStore.load()
        upsert(server, into: &servers)
        try await serverStore.save(servers)
    }

    func saveWorkspace(_ workspace: SavedWorkspace) async throws {
        let servers = try await serverStore.load()
        guard servers.contains(where: { $0.id == workspace.serverID }) else {
            throw ConnectionProfileRepositoryError.missingServer(workspace.serverID)
        }

        var workspaces = try await workspaceStore.load()
        upsert(workspace, into: &workspaces)
        try await workspaceStore.save(workspaces)
    }

    func saveIdentity(_ identity: SSHIdentity) async throws {
        var identities = try await identityStore.load()
        upsert(identity, into: &identities)
        try await identityStore.save(identities)
    }

    func saveIdentityProfile(
        identity: SSHIdentity,
        server: SavedServer,
        workspace: SavedWorkspace
    ) async throws {
        var identities = try await identityStore.load()
        upsert(identity, into: &identities)

        var servers = try await serverStore.load()
        upsert(server, into: &servers)

        var workspaces = try await workspaceStore.load()
        upsert(workspace, into: &workspaces)

        try await identityStore.save(identities)
        try await serverStore.save(servers)
        try await workspaceStore.save(workspaces)
    }

    func saveProfile(server: SavedServer, workspace: SavedWorkspace) async throws {
        var servers = try await serverStore.load()
        upsert(server, into: &servers)

        var workspaces = try await workspaceStore.load()
        upsert(workspace, into: &workspaces)

        try await serverStore.save(servers)
        try await workspaceStore.save(workspaces)
    }

    func reconcileDiscoveredWorkspaces(
        for serverID: SavedServer.ID,
        sessionNames: [String]
    ) async throws -> ConnectionLibrarySnapshot {
        let servers = try await serverStore.load()
        guard servers.contains(where: { $0.id == serverID }) else {
            throw ConnectionProfileRepositoryError.missingServer(serverID)
        }

        var workspaces = try await workspaceStore.load()
        let existingNames = Set(
            workspaces.lazy
                .filter { $0.serverID == serverID }
                .map(\.sessionName)
        )
        var namesToAdd = Set<String>()
        for name in sessionNames where !name.isEmpty {
            guard !existingNames.contains(name), namesToAdd.insert(name).inserted else { continue }
            // Discovery is not an open. Keep it out of recency ordering until
            // the user actually attaches through the normal connect path.
            workspaces.append(
                SavedWorkspace(
                    serverID: serverID,
                    sessionName: name,
                    lastOpenedAt: .distantPast
                )
            )
        }
        if !namesToAdd.isEmpty {
            try await workspaceStore.save(workspaces)
        }
        return try await loadSnapshot()
    }

    func deleteServer(id: SavedServer.ID) async throws {
        let servers = try await serverStore.load()
        let workspaces = try await workspaceStore.load()

        try await serverStore.save(servers.filter { $0.id != id })
        try await workspaceStore.save(workspaces.filter { $0.serverID != id })
    }

    func deleteWorkspace(id: SavedWorkspace.ID) async throws {
        let workspaces = try await workspaceStore.load()
        try await workspaceStore.save(workspaces.filter { $0.id != id })
    }

    func deleteIdentity(id: SSHIdentity.ID) async throws {
        let identities = try await identityStore.load()
        try await identityStore.save(identities.filter { $0.id != id })
    }

    private func upsert<Element: Identifiable>(_ element: Element, into elements: inout [Element]) where Element.ID: Equatable {
        if let index = elements.firstIndex(where: { $0.id == element.id }) {
            elements[index] = element
        } else {
            elements.append(element)
        }
    }
}
