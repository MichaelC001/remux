import Foundation
import XCTest
@testable import Remux

@MainActor
final class RemuxPreparedTransportCoordinatorTests: XCTestCase {
    func testPrepareCreatesTransportAndSchedulesPrepare() async {
        let factory = PreparedCoordinatorTransportFactory()
        let coordinator = makeCoordinator(factory: factory)
        let target = makePreparedCoordinatorTarget()

        coordinator.prepareTransport(for: target, reason: .activation)

        XCTAssertEqual(factory.createdTargets(), [target])
        let didPrepare = await waitUntil {
            factory.events() == [.created(0), .prepared(0)]
        }
        XCTAssertTrue(didPrepare)
    }

    func testPrepareSkipsCreationWhenReusableTransportExists() async {
        let factory = PreparedCoordinatorTransportFactory()
        let coordinator = makeCoordinator(factory: factory)
        let target = makePreparedCoordinatorTarget()

        coordinator.prepareTransport(for: target, reason: .library)
        let didPrepare = await waitUntil {
            factory.events().contains(.prepared(0))
        }
        XCTAssertTrue(didPrepare)

        coordinator.prepareTransport(for: target, reason: .library)

        XCTAssertEqual(factory.createdTargets(), [target])
        XCTAssertEqual(factory.events(), [.created(0), .prepared(0)])
    }

    func testClaimReturnsCachedReusableTransportAndRemovesIt() async throws {
        let factory = PreparedCoordinatorTransportFactory()
        let coordinator = makeCoordinator(factory: factory)
        let target = makePreparedCoordinatorTarget()

        coordinator.prepareTransport(for: target, reason: .activation)
        let first = try XCTUnwrap(coordinator.claimOrCreateTransport(for: target) as? PreparedCoordinatorTransport)
        let second = try XCTUnwrap(coordinator.claimOrCreateTransport(for: target) as? PreparedCoordinatorTransport)

        XCTAssertEqual(first.index, 0)
        XCTAssertEqual(second.index, 1)
        XCTAssertEqual(factory.createdTargets(), [target, target])
    }

    func testStaleClaimClosesStaleTransportAndReturnsFreshTransport() async throws {
        let factory = PreparedCoordinatorTransportFactory()
        let coordinator = makeCoordinator(factory: factory)
        let target = makePreparedCoordinatorTarget(password: "old")
        let currentTarget = makePreparedCoordinatorTarget(
            serverID: target.server.id,
            workspaceID: target.workspace.id,
            password: "new"
        )

        coordinator.prepareTransport(for: target, reason: .library)
        let fresh = try XCTUnwrap(coordinator.claimOrCreateTransport(for: currentTarget) as? PreparedCoordinatorTransport)

        XCTAssertEqual(fresh.index, 1)
        let didCloseStale = await waitUntil {
            factory.events().contains(.closed(0, .reusable))
        }
        XCTAssertTrue(didCloseStale)
        XCTAssertEqual(factory.createdTargets(), [target, currentTarget])
    }

    func testPrepareReplacementClosesDisplacedTransport() async {
        let factory = PreparedCoordinatorTransportFactory()
        let coordinator = makeCoordinator(factory: factory)
        let target = makePreparedCoordinatorTarget(password: "old")
        let replacementTarget = makePreparedCoordinatorTarget(
            serverID: target.server.id,
            workspaceID: target.workspace.id,
            password: "new"
        )

        coordinator.prepareTransport(for: target, reason: .library)
        coordinator.prepareTransport(for: replacementTarget, reason: .reconnect)

        let didCloseOriginal = await waitUntil {
            factory.events().contains(.closed(0, .reusable))
        }
        XCTAssertTrue(didCloseOriginal)
        XCTAssertEqual(factory.createdTargets(), [target, replacementTarget])
    }

    func testRemoveWorkspaceClosesOnlyThatPreparedTransport() async throws {
        let factory = PreparedCoordinatorTransportFactory()
        let coordinator = makeCoordinator(factory: factory)
        let removedTarget = makePreparedCoordinatorTarget()
        let retainedTarget = makePreparedCoordinatorTarget()

        coordinator.prepareTransport(for: removedTarget, reason: .library)
        coordinator.prepareTransport(for: retainedTarget, reason: .library)
        coordinator.remove(workspaceID: removedTarget.workspace.id)

        let didCloseRemoved = await waitUntil {
            factory.events().contains(.closed(0, .reusable))
        }
        XCTAssertTrue(didCloseRemoved)

        let retained = try XCTUnwrap(coordinator.claimOrCreateTransport(for: retainedTarget) as? PreparedCoordinatorTransport)
        XCTAssertEqual(retained.index, 1)
    }

    func testRemoveServerPreservesExcludedWorkspace() async throws {
        let factory = PreparedCoordinatorTransportFactory()
        let coordinator = makeCoordinator(factory: factory)
        let serverID = SavedServer.ID()
        let removedTarget = makePreparedCoordinatorTarget(serverID: serverID)
        let excludedTarget = makePreparedCoordinatorTarget(serverID: serverID)
        let otherServerTarget = makePreparedCoordinatorTarget()

        coordinator.prepareTransport(for: removedTarget, reason: .library)
        coordinator.prepareTransport(for: excludedTarget, reason: .library)
        coordinator.prepareTransport(for: otherServerTarget, reason: .library)
        coordinator.remove(
            serverID: serverID,
            excludingWorkspaceID: excludedTarget.workspace.id
        )

        let didCloseRemoved = await waitUntil {
            factory.events().contains(.closed(0, .reusable))
        }
        XCTAssertTrue(didCloseRemoved)

        let excluded = try XCTUnwrap(coordinator.claimOrCreateTransport(for: excludedTarget) as? PreparedCoordinatorTransport)
        let otherServer = try XCTUnwrap(coordinator.claimOrCreateTransport(for: otherServerTarget) as? PreparedCoordinatorTransport)
        XCTAssertEqual(excluded.index, 1)
        XCTAssertEqual(otherServer.index, 2)
    }

    func testCloseAllClosesAllRetainedPreparedTransports() async {
        let factory = PreparedCoordinatorTransportFactory()
        let coordinator = makeCoordinator(factory: factory)
        let firstTarget = makePreparedCoordinatorTarget()
        let secondTarget = makePreparedCoordinatorTarget()

        coordinator.prepareTransport(for: firstTarget, reason: .library)
        coordinator.prepareTransport(for: secondTarget, reason: .library)
        coordinator.closeAll()

        let didCloseBoth = await waitUntil {
            let events = factory.events()
            return events.contains(.closed(0, .reusable)) &&
                events.contains(.closed(1, .reusable))
        }
        XCTAssertTrue(didCloseBoth)
    }

}

private func makeCoordinator(
    factory: PreparedCoordinatorTransportFactory
) -> RemuxPreparedTransportCoordinator {
    RemuxPreparedTransportCoordinator { target in
        factory.makeTransport(for: target)
    }
}

private func makePreparedCoordinatorTarget(
    serverID: SavedServer.ID = SavedServer.ID(),
    workspaceID: SavedWorkspace.ID = SavedWorkspace.ID(),
    password: String = "secret"
) -> TmuxConnectionTarget {
    let server = SavedServer(
        id: serverID,
        displayName: "Build Host",
        host: "build.example.test",
        username: "builder"
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
        sshAuth: .password(
            username: server.username,
            password: password,
            identityID: server.identityID,
            displayLabel: server.displayName
        )
    )
}

private func waitUntil(
    timeout: TimeInterval = 1,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private final class PreparedCoordinatorTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIndex = 0
    private var recordedEvents: [PreparedCoordinatorTransportEvent] = []
    private var recordedTargets: [TmuxConnectionTarget] = []

    func makeTransport(for target: TmuxConnectionTarget) -> PreparedCoordinatorTransport {
        lock.lock()
        let index = nextIndex
        nextIndex += 1
        recordedTargets.append(target)
        recordedEvents.append(.created(index))
        lock.unlock()

        return PreparedCoordinatorTransport(index: index, factory: self)
    }

    func recordPrepared(index: Int) {
        lock.lock()
        recordedEvents.append(.prepared(index))
        lock.unlock()
    }

    func recordClosed(index: Int, disposition: TmuxControlTransportCloseDisposition) {
        lock.lock()
        recordedEvents.append(.closed(index, disposition))
        lock.unlock()
    }

    func events() -> [PreparedCoordinatorTransportEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func createdTargets() -> [TmuxConnectionTarget] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTargets
    }
}

private final class PreparedCoordinatorTransport: @unchecked Sendable, TmuxControlTransport {
    let index: Int
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let factory: PreparedCoordinatorTransportFactory

    init(
        index: Int,
        factory: PreparedCoordinatorTransportFactory
    ) {
        self.index = index
        self.factory = factory

        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func prepare() async {
        factory.recordPrepared(index: index)
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        factory.recordClosed(index: index, disposition: disposition)
        continuation.finish()
    }
}

private enum PreparedCoordinatorTransportEvent: Equatable {
    case created(Int)
    case prepared(Int)
    case closed(Int, TmuxControlTransportCloseDisposition)
}
