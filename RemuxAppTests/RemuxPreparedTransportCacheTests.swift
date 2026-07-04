import Foundation
import XCTest
@testable import Remux

final class RemuxPreparedTransportCacheTests: XCTestCase {
    func testClaimReusableTransportReturnsAndRemovesPreparedTransport() throws {
        var cache = RemuxPreparedTransportCache()
        let target = makeTarget()
        let transport = CacheTransport()

        XCTAssertNil(cache.store(PreparedTmuxControlTransport(target: target, transport: transport)))

        guard case .claimed(let prepared) = cache.claim(for: target) else {
            XCTFail("expected reusable prepared transport")
            return
        }
        XCTAssertEqual((prepared.transport as? CacheTransport)?.id, transport.id)
        guard case .missing = cache.claim(for: target) else {
            XCTFail("expected cache miss after claim")
            return
        }
    }

    func testClaimStaleTransportReturnsDiscardAndRemovesPreparedTransport() throws {
        var cache = RemuxPreparedTransportCache()
        let target = makeTarget(password: "old")
        let currentTarget = makeTarget(
            serverID: target.server.id,
            workspaceID: target.workspace.id,
            password: "new"
        )
        let transport = CacheTransport()

        XCTAssertNil(cache.store(PreparedTmuxControlTransport(target: target, transport: transport)))

        guard case .discardedStale(let prepared) = cache.claim(for: currentTarget) else {
            XCTFail("expected stale prepared transport discard")
            return
        }
        XCTAssertEqual((prepared.transport as? CacheTransport)?.id, transport.id)
        guard case .missing = cache.claim(for: currentTarget) else {
            XCTFail("expected cache miss after stale discard")
            return
        }
    }

    func testClaimAllowsSavedUsernameDriftWhenResolvedAuthMatches() throws {
        var cache = RemuxPreparedTransportCache()
        let target = makeTarget()
        let currentTarget = makeTarget(
            serverID: target.server.id,
            workspaceID: target.workspace.id,
            serverUsername: "renamed-user",
            sshAuth: target.sshAuth
        )
        let transport = CacheTransport()

        XCTAssertNil(cache.store(PreparedTmuxControlTransport(target: target, transport: transport)))

        guard case .claimed(let prepared) = cache.claim(for: currentTarget) else {
            XCTFail("expected reusable prepared transport")
            return
        }
        XCTAssertEqual((prepared.transport as? CacheTransport)?.id, transport.id)
    }

    func testClaimRejectsResolvedAuthUsernameDrift() throws {
        var cache = RemuxPreparedTransportCache()
        let target = makeTarget()
        let currentTarget = makeTarget(
            serverID: target.server.id,
            workspaceID: target.workspace.id,
            sshAuth: .password(
                username: "other-user",
                password: "secret",
                identityID: target.server.identityID,
                displayLabel: target.server.displayName
            )
        )
        let transport = CacheTransport()

        XCTAssertNil(cache.store(PreparedTmuxControlTransport(target: target, transport: transport)))

        guard case .discardedStale(let prepared) = cache.claim(for: currentTarget) else {
            XCTFail("expected stale prepared transport discard")
            return
        }
        XCTAssertEqual((prepared.transport as? CacheTransport)?.id, transport.id)
    }

    func testStoreReplacementReturnsPreviousTransport() throws {
        var cache = RemuxPreparedTransportCache()
        let target = makeTarget()
        let firstTransport = CacheTransport()
        let secondTransport = CacheTransport()

        XCTAssertNil(cache.store(PreparedTmuxControlTransport(target: target, transport: firstTransport)))
        let replaced = try XCTUnwrap(
            cache.store(PreparedTmuxControlTransport(target: target, transport: secondTransport))
        )
        XCTAssertEqual((replaced.transport as? CacheTransport)?.id, firstTransport.id)

        guard case .claimed(let prepared) = cache.claim(for: target) else {
            XCTFail("expected replacement transport")
            return
        }
        XCTAssertEqual((prepared.transport as? CacheTransport)?.id, secondTransport.id)
    }

    func testRemoveByServerExcludesSelectedWorkspace() throws {
        var cache = RemuxPreparedTransportCache()
        let serverID = SavedServer.ID()
        let removedTarget = makeTarget(serverID: serverID, workspaceID: SavedWorkspace.ID())
        let retainedTarget = makeTarget(serverID: serverID, workspaceID: SavedWorkspace.ID())
        let otherServerTarget = makeTarget()
        let removedTransport = CacheTransport()
        let retainedTransport = CacheTransport()
        let otherServerTransport = CacheTransport()

        XCTAssertNil(cache.store(PreparedTmuxControlTransport(target: removedTarget, transport: removedTransport)))
        XCTAssertNil(cache.store(PreparedTmuxControlTransport(target: retainedTarget, transport: retainedTransport)))
        XCTAssertNil(cache.store(PreparedTmuxControlTransport(target: otherServerTarget, transport: otherServerTransport)))

        let removed = cache.remove(
            serverID: serverID,
            excludingWorkspaceID: retainedTarget.workspace.id
        )
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual((removed.first?.transport as? CacheTransport)?.id, removedTransport.id)

        guard case .claimed(let retained) = cache.claim(for: retainedTarget) else {
            XCTFail("expected excluded workspace to remain cached")
            return
        }
        XCTAssertEqual((retained.transport as? CacheTransport)?.id, retainedTransport.id)
        guard case .claimed(let otherServer) = cache.claim(for: otherServerTarget) else {
            XCTFail("expected other server workspace to remain cached")
            return
        }
        XCTAssertEqual((otherServer.transport as? CacheTransport)?.id, otherServerTransport.id)
    }

    func testDrainReturnsAllPreparedTransportsAndEmptiesCache() throws {
        var cache = RemuxPreparedTransportCache()
        let firstTarget = makeTarget()
        let secondTarget = makeTarget()
        let firstTransport = CacheTransport()
        let secondTransport = CacheTransport()

        XCTAssertNil(cache.store(PreparedTmuxControlTransport(target: firstTarget, transport: firstTransport)))
        XCTAssertNil(cache.store(PreparedTmuxControlTransport(target: secondTarget, transport: secondTransport)))

        let drainedIDs = Set(cache.drain().compactMap { ($0.transport as? CacheTransport)?.id })
        XCTAssertEqual(drainedIDs, Set([firstTransport.id, secondTransport.id]))
        guard case .missing = cache.claim(for: firstTarget) else {
            XCTFail("expected cache miss after drain")
            return
        }
        guard case .missing = cache.claim(for: secondTarget) else {
            XCTFail("expected cache miss after drain")
            return
        }
    }
}

private func makeTarget(
    serverID: SavedServer.ID = SavedServer.ID(),
    workspaceID: SavedWorkspace.ID = SavedWorkspace.ID(),
    serverUsername: String = "builder",
    password: String = "secret",
    sshAuth: ResolvedSSHAuth? = nil,
    terminalSettings: TerminalSettings = .default
) -> TmuxConnectionTarget {
    let server = SavedServer(
        id: serverID,
        displayName: "Build Host",
        host: "build.example.test",
        username: serverUsername
    )
    let workspace = SavedWorkspace(
        id: workspaceID,
        serverID: serverID,
        sessionName: "base",
        lastOpenedAt: Date(timeIntervalSince1970: 0)
    )
    return TmuxConnectionTarget(
        server: server,
        workspace: workspace,
        sshAuth: sshAuth ?? .password(
            username: server.username,
            password: password,
            identityID: server.identityID,
            displayLabel: server.displayName
        ),
        terminalSettings: terminalSettings
    )
}

private final class CacheTransport: @unchecked Sendable, TmuxControlTransport {
    let id = UUID()
    let receivedBytes: AsyncThrowingStream<Data, Error> = AsyncThrowingStream { continuation in
        continuation.finish()
    }

    func prepare() async {}

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        _ = disposition
    }
}
