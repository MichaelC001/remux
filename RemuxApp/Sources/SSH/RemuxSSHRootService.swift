@preconcurrency import Citadel
import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

struct RemuxSSHRootKey: Hashable, Sendable {
    let serverID: SavedServer.ID
    let host: String
    let port: Int
    let username: String
    private let authFingerprint: String

    init(target: TmuxConnectionTarget) {
        self.serverID = target.server.id
        self.host = target.server.host
        self.port = target.server.port
        self.username = target.sshAuth.username
        self.authFingerprint = target.sshAuth.authFingerprint
    }
}

struct RemuxSSHRootConfiguration: Sendable {
    let host: String
    let port: Int
    let authenticationMethod: @Sendable () throws -> SSHAuthenticationMethod
    let hostKeyValidator: SSHHostKeyValidator
    let connectTimeout: TimeAmount

    init(
        host: String,
        port: Int,
        authenticationMethod: @escaping @Sendable () throws -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeout: TimeAmount
    ) {
        self.host = host
        self.port = port
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
        self.connectTimeout = connectTimeout
    }
}

enum RemuxSSHRootReadiness: Equatable, Sendable {
    case connecting
    case ready

    var traceValue: String {
        switch self {
        case .connecting:
            "connecting"
        case .ready:
            "ready"
        }
    }
}

struct RemuxSSHRootServiceSnapshot: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let generation: UUID
        let readiness: RemuxSSHRootReadiness
        let activeLeaseCount: Int
        let reservationCount: Int
        let isIdleCloseScheduled: Bool
    }

    /// Roots evicted from the pool that still have live leases
    /// draining (multi-lease invalidation).
    let retiredCount: Int

    fileprivate let entries: [RemuxSSHRootKey: Entry]

    var entryCount: Int {
        entries.count
    }

    func entry(for key: RemuxSSHRootKey) -> Entry? {
        entries[key]
    }
}

final class SSHTmuxAuthenticatedConnection: @unchecked Sendable {
    let rootChannel: Channel
    let sshHandler: NIOSSHHandler

    init(rootChannel: Channel, sshHandler: NIOSSHHandler) {
        self.rootChannel = rootChannel
        self.sshHandler = sshHandler
    }

    func close() async {
        do {
            try await rootChannel.close()
        } catch {
            NSLog("Remux authenticated SSH root close failed: %@", String(describing: error))
        }
    }
}

enum SSHTmuxAuthenticatedConnectionLeaseDisposition: Equatable, Sendable {
    case reusable
    case invalidated
}

extension TmuxControlTransportCloseDisposition {
    var authenticatedConnectionLeaseDisposition: SSHTmuxAuthenticatedConnectionLeaseDisposition {
        switch self {
        case .reusable:
            return .reusable
        case .invalidated:
            return .invalidated
        }
    }
}

fileprivate final class SSHTmuxAuthenticatedConnectionLease: @unchecked Sendable {
    private let connection: SSHTmuxAuthenticatedConnection

    private let pool: RemuxSSHRootService
    private let key: RemuxSSHRootKey
    private let generation: UUID
    private let lock = NIOLock()
    private var isReleased = false

    init(
        connection: SSHTmuxAuthenticatedConnection,
        pool: RemuxSSHRootService,
        key: RemuxSSHRootKey,
        generation: UUID
    ) {
        self.connection = connection
        self.pool = pool
        self.key = key
        self.generation = generation
    }

    func release(_ disposition: SSHTmuxAuthenticatedConnectionLeaseDisposition) async {
        let shouldRelease = lock.withLock {
            guard !isReleased else { return false }
            isReleased = true
            return true
        }
        guard shouldRelease else { return }

        await pool.releaseConnection(
            connection,
            for: key,
            generation: generation,
            disposition: disposition
        )
    }
}

struct SSHTmuxPreparedConnection {
    let trace: SSHTmuxControlStartupTrace
    private let ownership: SSHTmuxPreparedConnectionOwnership
    private let cancelAuthenticationOnClose: Bool
    private let task: Task<SSHTmuxAuthenticatedConnection, Error>

    fileprivate static func pooled(
        trace: SSHTmuxControlStartupTrace,
        pool: RemuxSSHRootService,
        key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID,
        task: Task<SSHTmuxAuthenticatedConnection, Error>
    ) -> SSHTmuxPreparedConnection {
        SSHTmuxPreparedConnection(
            trace: trace,
            ownership: .pooled(
                pool: pool,
                key: key,
                generation: generation,
                reservationID: reservationID
            ),
            cancelAuthenticationOnClose: false,
            task: task
        )
    }

    static func dedicated(
        configuration: RemuxSSHRootConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) -> SSHTmuxPreparedConnection {
        SSHTmuxPreparedConnection(
            trace: trace,
            ownership: .dedicated,
            cancelAuthenticationOnClose: true,
            task: authenticationTask(configuration: configuration, trace: trace)
        )
    }

    func authenticatedConnection() async throws -> SSHTmuxAuthenticatedConnection {
        try await task.value
    }

    func claim(
        _ authenticatedConnection: SSHTmuxAuthenticatedConnection,
        trace: SSHTmuxControlStartupTrace
    ) async throws -> SSHTmuxClaimedAuthenticatedConnection {
        switch ownership {
        case .dedicated:
            return SSHTmuxClaimedAuthenticatedConnection(
                authenticatedConnection: authenticatedConnection,
                lease: nil
            )

        case .pooled(let pool, let key, let generation, let reservationID):
            let lease = try await trace.stage("sshRoot.pool.lease") {
                try await pool.leaseConnection(
                    authenticatedConnection,
                    for: key,
                    generation: generation,
                    reservationID: reservationID
                )
            }
            return SSHTmuxClaimedAuthenticatedConnection(
                authenticatedConnection: authenticatedConnection,
                lease: lease
            )
        }
    }

    func cancelAndCleanup() async {
        switch ownership {
        case .pooled(let pool, let key, let generation, let reservationID):
            await pool.releaseReservation(
                for: key,
                generation: generation,
                reservationID: reservationID
            )
            return

        case .dedicated:
            break
        }

        guard cancelAuthenticationOnClose else { return }

        task.cancel()
        do {
            let authenticatedConnection = try await task.value
            await authenticatedConnection.close()
        } catch is CancellationError {
            GhosttyRuntimeTrace.latency("transport.prepare.cleanup cancelled")
        } catch {
            NSLog("Remux prepared SSH connection cleanup failed: %@", String(describing: error))
        }
    }
}

private enum SSHTmuxPreparedConnectionOwnership {
    case dedicated
    case pooled(
        pool: RemuxSSHRootService,
        key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    )
}

struct SSHTmuxClaimedAuthenticatedConnection {
    let authenticatedConnection: SSHTmuxAuthenticatedConnection
    private let lease: SSHTmuxAuthenticatedConnectionLease?

    fileprivate init(
        authenticatedConnection: SSHTmuxAuthenticatedConnection,
        lease: SSHTmuxAuthenticatedConnectionLease?
    ) {
        self.authenticatedConnection = authenticatedConnection
        self.lease = lease
    }

    func releaseAfterFailedStart() async {
        await release(.invalidated)
    }

    func release(_ disposition: SSHTmuxAuthenticatedConnectionLeaseDisposition) async {
        if let lease {
            await lease.release(disposition)
        } else {
            await authenticatedConnection.close()
        }
    }
}

actor RemuxSSHRootService {
    private struct Entry {
        let generation: UUID
        let task: Task<SSHTmuxAuthenticatedConnection, Error>
        var activeLeaseCount: Int
        var reservationIDs: Set<UUID>
        var idleCloseTask: Task<Void, Never>?
        var readiness: RemuxSSHRootReadiness
    }

    /// A root removed from the pool while sessions still lease it: no
    /// new leases, and the underlying connection closes only when the
    /// last lease releases. Closing immediately on invalidation would
    /// let one session's channel-level failure kill healthy sibling
    /// sessions sharing the root; a genuinely dead root drains fast
    /// because every sibling errors out and releases.
    private struct RetiredEntry {
        let task: Task<SSHTmuxAuthenticatedConnection, Error>
        var activeLeaseCount: Int
    }

    private struct EntrySnapshot: Sendable {
        let generation: UUID
        let task: Task<SSHTmuxAuthenticatedConnection, Error>
        let didReuse: Bool
        let readiness: RemuxSSHRootReadiness
        let reservationID: UUID?
    }

    private enum LeaseEntryResult {
        case leased
        case busy
        case stale
    }

    private enum ReleaseEntryResult {
        /// Lease returned; the connection stays pooled.
        case retained
        /// Caller owns closing the connection (last lease of a retired
        /// root, or a root the pool no longer tracks).
        case close
    }

    /// SSH multiplexes channels over one authenticated connection;
    /// each session needs exactly one exec channel. Bounding the
    /// share keeps the blast radius of a dying root modest.
    static let maxConcurrentLeases = 4

    private let idleTimeout: Duration
    private var entries: [RemuxSSHRootKey: Entry] = [:]
    private var retiredEntries: [UUID: RetiredEntry] = [:]

    init(idleTimeout: Duration = .seconds(120)) {
        self.idleTimeout = idleTimeout
    }

    func snapshot() -> RemuxSSHRootServiceSnapshot {
        RemuxSSHRootServiceSnapshot(
            retiredCount: retiredEntries.count,
            entries: entries.mapValues { entry in
                RemuxSSHRootServiceSnapshot.Entry(
                    generation: entry.generation,
                    readiness: entry.readiness,
                    activeLeaseCount: entry.activeLeaseCount,
                    reservationCount: entry.reservationIDs.count,
                    isIdleCloseScheduled: entry.idleCloseTask != nil
                )
            }
        )
    }

    func prewarmConnection(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: SSHTmuxControlStartupTrace,
        reason: String
    ) {
        let snapshot = entrySnapshot(
            for: key,
            configuration: configuration,
            trace: trace
        )
        let eventPrefix = snapshot.didReuse ? "sshRoot.prewarm.hit" : "sshRoot.prewarm.miss"
        trace.event(
            eventPrefix,
            fields: poolTraceFields(key: key, reason: reason, readiness: snapshot.readiness)
        )

        guard snapshot.readiness == .connecting else { return }

        Task {
            do {
                _ = try await snapshot.task.value
                trace.event(
                    "sshRoot.prewarm.ready",
                    fields: poolTraceFields(key: key, reason: reason, readiness: .ready)
                )
            } catch is CancellationError {
                trace.event(
                    "sshRoot.prewarm.cancelled",
                    fields: poolTraceFields(key: key, reason: reason, readiness: .connecting)
                )
            } catch {
                var fields = poolTraceFields(key: key, reason: reason, readiness: .connecting)
                fields["error"] = String(describing: error)
                trace.event("sshRoot.prewarm.failed", fields: fields)
                NSLog(
                    "Remux SSH root prewarm failed for %@@%@:%d (%@): %@",
                    key.username,
                    key.host,
                    key.port,
                    reason,
                    String(describing: error)
                )
            }
        }
    }

    func preparedConnection(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) -> SSHTmuxPreparedConnection {
        guard let snapshot = reserveEntry(
            for: key,
            configuration: configuration,
            trace: trace
        ) else {
            trace.event(
                "sshRoot.pool.busy",
                fields: poolTraceFields(key: key, readiness: entries[key]?.readiness ?? .connecting)
            )
            return dedicatedPreparedConnection(
                configuration: configuration,
                trace: trace
            )
        }
        trace.event(
            snapshot.didReuse ? "sshRoot.pool.hit" : "sshRoot.pool.miss",
            fields: poolTraceFields(key: key, readiness: snapshot.readiness)
        )
        guard let reservationID = snapshot.reservationID else {
            return dedicatedPreparedConnection(
                configuration: configuration,
                trace: trace
            )
        }

        return SSHTmuxPreparedConnection.pooled(
            trace: trace,
            pool: self,
            key: key,
            generation: snapshot.generation,
            reservationID: reservationID,
            task: snapshot.task
        )
    }

    fileprivate func leaseConnection(
        _ connection: SSHTmuxAuthenticatedConnection,
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    ) async throws -> SSHTmuxAuthenticatedConnectionLease {
        switch leaseEntry(for: key, generation: generation, reservationID: reservationID) {
        case .leased:
            break
        case .stale:
            await connection.close()
            throw SSHTmuxControlTransportError.stalePreparedConnection
        case .busy:
            throw SSHTmuxControlTransportError.closed
        }

        return SSHTmuxAuthenticatedConnectionLease(
            connection: connection,
            pool: self,
            key: key,
            generation: generation
        )
    }

    fileprivate func releaseConnection(
        _ connection: SSHTmuxAuthenticatedConnection,
        for key: RemuxSSHRootKey,
        generation: UUID,
        disposition: SSHTmuxAuthenticatedConnectionLeaseDisposition
    ) async {
        switch releaseEntry(for: key, generation: generation, disposition: disposition) {
        case .retained:
            break
        case .close:
            await connection.close()
        }
    }

    @discardableResult
    private func leaseEntry(
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    ) -> LeaseEntryResult {
        guard var entry = entries[key], entry.generation == generation else {
            return .stale
        }
        guard entry.reservationIDs.contains(reservationID) else {
            return .busy
        }

        entry.idleCloseTask?.cancel()
        entry.idleCloseTask = nil
        entry.reservationIDs.remove(reservationID)
        entry.activeLeaseCount += 1
        entries[key] = entry
        return .leased
    }

    @discardableResult
    private func releaseEntry(
        for key: RemuxSSHRootKey,
        generation: UUID,
        disposition: SSHTmuxAuthenticatedConnectionLeaseDisposition
    ) -> ReleaseEntryResult {
        guard var entry = entries[key], entry.generation == generation else {
            // A retired root: drain, close with the last lease.
            if var retired = retiredEntries[generation] {
                retired.activeLeaseCount = max(0, retired.activeLeaseCount - 1)
                if retired.activeLeaseCount == 0 {
                    retiredEntries.removeValue(forKey: generation)
                    return .close
                }
                retiredEntries[generation] = retired
                return .retained
            }
            // Unknown to the pool (dedicated or already evicted):
            // the caller owns the close.
            return .close
        }

        switch disposition {
        case .reusable:
            entry.activeLeaseCount = max(0, entry.activeLeaseCount - 1)
            entries[key] = entry
            scheduleIdleCloseIfNeeded(for: key, generation: generation)
            return .retained

        case .invalidated:
            entry.idleCloseTask?.cancel()
            entries.removeValue(forKey: key)
            let remaining = max(0, entry.activeLeaseCount - 1)
            guard remaining > 0 else {
                return .close
            }
            retiredEntries[generation] = RetiredEntry(
                task: entry.task,
                activeLeaseCount: remaining
            )
            return .retained
        }
    }

    func releaseReservation(
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    ) {
        guard var entry = entries[key],
              entry.generation == generation,
              entry.reservationIDs.contains(reservationID) else {
            return
        }

        entry.reservationIDs.remove(reservationID)
        entries[key] = entry
        scheduleIdleCloseIfNeeded(for: key, generation: generation)
    }

    func closeIdleConnections(forServerID serverID: SavedServer.ID) {
        let closing = entries
            .filter { key, entry in
                key.serverID == serverID
                    && entry.activeLeaseCount == 0
                    && entry.reservationIDs.isEmpty
            }

        for (key, entry) in closing {
            entry.idleCloseTask?.cancel()
            entries.removeValue(forKey: key)
            closeEntryTask(entry.task, reason: "server_profile_changed")
        }
    }

    func closeAllConnections() {
        let closing = Array(entries.values)
        entries.removeAll()

        for entry in closing {
            entry.idleCloseTask?.cancel()
            closeEntryTask(entry.task, reason: "pool_closed")
        }

        let retired = Array(retiredEntries.values)
        retiredEntries.removeAll()
        for entry in retired {
            closeEntryTask(entry.task, reason: "pool_closed")
        }
    }

    private func entrySnapshot(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) -> EntrySnapshot {
        if let existing = entries[key] {
            return EntrySnapshot(
                generation: existing.generation,
                task: existing.task,
                didReuse: true,
                readiness: existing.readiness,
                reservationID: nil
            )
        }

        let generation = UUID()
        let task = makeAuthenticationTask(configuration: configuration, trace: trace)
        entries[key] = Entry(
            generation: generation,
            task: task,
            activeLeaseCount: 0,
            reservationIDs: [],
            idleCloseTask: nil,
            readiness: .connecting
        )

        observeAuthenticationResult(task, for: key, generation: generation)

        return EntrySnapshot(
            generation: generation,
            task: task,
            didReuse: false,
            readiness: .connecting,
            reservationID: nil
        )
    }

    private func reserveEntry(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) -> EntrySnapshot? {
        let reservationID = UUID()
        if entries[key] != nil {
            return reserveExistingEntry(
                for: key,
                reservationID: reservationID
            )
        }

        let generation = UUID()
        let task = makeAuthenticationTask(configuration: configuration, trace: trace)
        entries[key] = Entry(
            generation: generation,
            task: task,
            activeLeaseCount: 0,
            reservationIDs: [reservationID],
            idleCloseTask: nil,
            readiness: .connecting
        )

        observeAuthenticationResult(task, for: key, generation: generation)

        return EntrySnapshot(
            generation: generation,
            task: task,
            didReuse: false,
            readiness: .connecting,
            reservationID: reservationID
        )
    }

    private func reserveExistingEntry(
        for key: RemuxSSHRootKey,
        reservationID: UUID
    ) -> EntrySnapshot? {
        guard var existing = entries[key],
              existing.activeLeaseCount + existing.reservationIDs.count
                  < Self.maxConcurrentLeases
        else {
            return nil
        }

        existing.idleCloseTask?.cancel()
        existing.idleCloseTask = nil
        existing.reservationIDs.insert(reservationID)
        entries[key] = existing
        return EntrySnapshot(
            generation: existing.generation,
            task: existing.task,
            didReuse: true,
            readiness: existing.readiness,
            reservationID: reservationID
        )
    }

    private func dedicatedPreparedConnection(
        configuration: RemuxSSHRootConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) -> SSHTmuxPreparedConnection {
        SSHTmuxPreparedConnection.dedicated(configuration: configuration, trace: trace)
    }

    private nonisolated func makeAuthenticationTask(
        configuration: RemuxSSHRootConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) -> Task<SSHTmuxAuthenticatedConnection, Error> {
        SSHTmuxPreparedConnection.authenticationTask(configuration: configuration, trace: trace)
    }

    private func observeAuthenticationResult(
        _ task: Task<SSHTmuxAuthenticatedConnection, Error>,
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        Task {
            do {
                _ = try await task.value
                self.authenticationSucceeded(for: key, generation: generation)
            } catch {
                self.authenticationFailed(for: key, generation: generation)
            }
        }
    }

    private func authenticationSucceeded(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard var entry = entries[key], entry.generation == generation else { return }
        entry.readiness = .ready
        entries[key] = entry
        scheduleIdleCloseIfNeeded(for: key, generation: generation)
    }

    private func authenticationFailed(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard let entry = entries[key], entry.generation == generation else { return }
        entry.idleCloseTask?.cancel()
        entries.removeValue(forKey: key)
    }

    private func scheduleIdleCloseIfNeeded(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard var entry = entries[key], entry.generation == generation else { return }
        guard entry.activeLeaseCount == 0, entry.reservationIDs.isEmpty else { return }

        entry.idleCloseTask?.cancel()
        entry.idleCloseTask = Task {
            do {
                try await Task.sleep(for: idleTimeout)
                self.closeIdleEntry(for: key, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                NSLog("Remux SSH root idle close timer failed: %@", String(describing: error))
            }
        }
        entries[key] = entry
    }

    private func closeIdleEntry(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard let entry = entries[key], entry.generation == generation else { return }
        guard entry.activeLeaseCount == 0, entry.reservationIDs.isEmpty else { return }

        entry.idleCloseTask?.cancel()
        entries.removeValue(forKey: key)
        closeEntryTask(entry.task, reason: "idle_timeout")
    }

#if DEBUG
    @discardableResult
    func insertEntryForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID = UUID(),
        readiness: RemuxSSHRootReadiness = .ready,
        activeLeaseCount: Int = 0,
        reservationID: UUID? = nil,
        idleCloseScheduled: Bool = false
    ) -> UUID {
        entries[key]?.idleCloseTask?.cancel()
        entries[key] = Entry(
            generation: generation,
            task: Task<SSHTmuxAuthenticatedConnection, Error> {
                throw CancellationError()
            },
            activeLeaseCount: activeLeaseCount,
            reservationIDs: reservationID.map { [$0] } ?? [],
            idleCloseTask: idleCloseScheduled ? Self.testingIdleCloseTask() : nil,
            readiness: readiness
        )
        return generation
    }

    func leaseEntryForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    ) throws {
        guard leaseEntry(for: key, generation: generation, reservationID: reservationID) == .leased else {
            throw SSHTmuxControlTransportError.closed
        }
    }

    func reserveEntryForTesting(
        for key: RemuxSSHRootKey
    ) -> UUID? {
        reserveExistingEntry(
            for: key,
            reservationID: UUID()
        )?.reservationID
    }

    func releaseReservationForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    ) {
        releaseReservation(
            for: key,
            generation: generation,
            reservationID: reservationID
        )
    }

    func releaseEntryForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID,
        disposition: TmuxControlTransportCloseDisposition
    ) {
        releaseEntry(
            for: key,
            generation: generation,
            disposition: disposition.authenticatedConnectionLeaseDisposition
        )
    }

    func markAuthenticationSucceededForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        authenticationSucceeded(for: key, generation: generation)
    }

    func markAuthenticationFailedForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        authenticationFailed(for: key, generation: generation)
    }

    private static func testingIdleCloseTask() -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
        }
    }
#endif

    private nonisolated func closeEntryTask(
        _ task: Task<SSHTmuxAuthenticatedConnection, Error>,
        reason: String
    ) {
        task.cancel()
        Task {
            do {
                let connection = try await task.value
                GhosttyRuntimeTrace.latency("sshRoot.pool.close reason=\(reason)")
                await connection.close()
            } catch is CancellationError {
                GhosttyRuntimeTrace.latency("sshRoot.pool.close cancelled reason=\(reason)")
            } catch {
                NSLog("Remux SSH root pool close failed (%@): %@", reason, String(describing: error))
            }
        }
    }

    private func poolTraceFields(
        key: RemuxSSHRootKey,
        reason: String? = nil,
        readiness: RemuxSSHRootReadiness
    ) -> [String: String] {
        var fields = [
            "host": "\(key.host):\(key.port)",
            "readiness": readiness.traceValue,
            "serverID": key.serverID.uuidString,
            "username": key.username,
        ]
        if let reason {
            fields["reason"] = reason
        }
        return fields
    }
}

private extension SSHTmuxPreparedConnection {
    static func authenticationTask(
        configuration: RemuxSSHRootConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) -> Task<SSHTmuxAuthenticatedConnection, Error> {
        Task.detached(priority: .userInitiated) {
            try await SSHTmuxAuthenticatedConnectionBootstrap.authenticate(
                using: configuration,
                trace: trace
            )
        }
    }
}

private enum SSHTmuxAuthenticatedConnectionBootstrap {
    static func authenticate(
        using configuration: RemuxSSHRootConfiguration,
        trace: SSHTmuxControlStartupTrace
    ) async throws -> SSHTmuxAuthenticatedConnection {
        var rootChannel: Channel?

        do {
            trace.event("bootstrap.configure.begin")
            let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { channel in
                    let handshake = SSHTmuxControlHandshakeHandler(
                        eventLoop: channel.eventLoop,
                        timeout: configuration.connectTimeout
                    )
                    let authenticationMethod: SSHAuthenticationMethod
                    do {
                        authenticationMethod = try configuration.authenticationMethod()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }

                    let sshConfiguration = SSHClientConfiguration(
                        userAuthDelegate: authenticationMethod,
                        serverAuthDelegate: configuration.hostKeyValidator
                    )
                    let sshHandler = NIOSSHHandler(
                        role: .client(sshConfiguration),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { channel, _ in
                            channel.eventLoop.makeFailedFuture(
                                SSHTmuxControlTransportError.unsupportedInboundChannel
                            )
                        }
                    )

                    return channel.pipeline.addHandlers([
                        sshHandler,
                        handshake,
                    ])
                }
                .connectTimeout(configuration.connectTimeout)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            trace.event("bootstrap.configure.end")

            let channel = try await trace.stage(
                "tcpConnect",
                fields: [
                    "host": configuration.host,
                    "port": "\(configuration.port)",
                ]
            ) {
                try await bootstrap.connect(
                    host: configuration.host,
                    port: configuration.port
                ).get()
            }
            rootChannel = channel

            let handshake = try await trace.stage("handshakeHandler.lookup") {
                try await channel.pipeline.handler(type: SSHTmuxControlHandshakeHandler.self).get()
            }
            try await trace.stage("sshAuthentication") {
                try await handshake.authenticated.get()
            }

            let sshHandler = try await trace.stage("sshHandler.lookup") {
                try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
            }

            return SSHTmuxAuthenticatedConnection(
                rootChannel: channel,
                sshHandler: sshHandler
            )
        } catch {
            if let rootChannel {
                try? await rootChannel.close()
            }
            throw error
        }
    }
}

private final class SSHTmuxControlHandshakeHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    private struct Disconnected: Error {}

    private let promise: EventLoopPromise<Void>

    var authenticated: EventLoopFuture<Void> {
        promise.futureResult
    }

    init(eventLoop: EventLoop, timeout: TimeAmount) {
        self.promise = eventLoop.makePromise(of: Void.self)

        eventLoop.scheduleTask(deadline: .now() + timeout) { [promise] in
            promise.fail(ChannelError.connectTimeout(timeout))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            promise.succeed(())
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.fireErrorCaught(error)
    }

    deinit {
        promise.fail(Disconnected())
    }
}
