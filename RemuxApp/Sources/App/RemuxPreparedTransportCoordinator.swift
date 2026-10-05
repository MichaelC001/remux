import Foundation

enum RemuxPreparedTransportPrepareReason: String, Sendable {
    case activation
    case library
    case reconnect
}

final class RemuxPreparedTransportCoordinator {
    typealias TransportFactory = (SessionTarget) -> any TmuxControlTransport

    private var cache = RemuxPreparedTransportCache()
    private let transportFactory: TransportFactory

    init(transportFactory: @escaping TransportFactory) {
        self.transportFactory = transportFactory
    }

    deinit {
        closeAll()
    }

    func claimOrCreateTransport(for target: SessionTarget) -> any TmuxControlTransport {
        switch cache.claim(for: target) {
        case .claimed(let prepared):
            GhosttyRuntimeTrace.flowEvent(
                sessionOpenFlowID(target.workspace.id),
                event: "model.transport.prewarm.claimed",
                fields: ["workspaceID": target.workspace.id.uuidString]
            )
            return prepared.transport

        case .discardedStale(let prepared):
            closePreparedTransport(prepared)
            GhosttyRuntimeTrace.flowEvent(
                sessionOpenFlowID(target.workspace.id),
                event: "model.transport.prewarm.discarded",
                fields: [
                    "workspaceID": target.workspace.id.uuidString,
                    "reason": "target_changed",
                ]
            )
            return transportFactory(target)

        case .missing:
            return transportFactory(target)
        }
    }

    func prepareTransport(
        for target: SessionTarget,
        reason: RemuxPreparedTransportPrepareReason
    ) {
        if cache.containsReusableTransport(for: target) {
            GhosttyRuntimeTrace.flowEvent(
                sessionOpenFlowID(target.workspace.id),
                event: "model.transport.prewarm.reused",
                fields: [
                    "reason": reason.rawValue,
                    "workspaceID": target.workspace.id.uuidString,
                ]
            )
            return
        }

        let transport = transportFactory(target)
        if let existing = cache.store(
            PreparedTmuxControlTransport(target: target, transport: transport)
        ) {
            closePreparedTransport(existing)
        }

        GhosttyRuntimeTrace.flowEvent(
            sessionOpenFlowID(target.workspace.id),
            event: "model.transport.prewarm.created",
            fields: [
                "reason": reason.rawValue,
                "workspaceID": target.workspace.id.uuidString,
            ]
        )
        Task.detached(priority: .userInitiated) {
            await transport.prepare()
        }
        GhosttyRuntimeTrace.flowEvent(
            sessionOpenFlowID(target.workspace.id),
            event: "model.transport.prewarm.scheduled",
            fields: [
                "reason": reason.rawValue,
                "workspaceID": target.workspace.id.uuidString,
            ]
        )
    }

    func remove(workspaceID: SavedWorkspace.ID) {
        guard let prepared = cache.remove(workspaceID: workspaceID) else { return }
        closePreparedTransport(prepared)
    }

    func remove(
        serverID: SavedServer.ID,
        excludingWorkspaceID: SavedWorkspace.ID? = nil
    ) {
        closePreparedTransports(
            cache.remove(
                serverID: serverID,
                excludingWorkspaceID: excludingWorkspaceID
            )
        )
    }

    func closeAll() {
        closePreparedTransports(cache.drain())
    }

    private func closePreparedTransport(_ prepared: PreparedTmuxControlTransport) {
        Task { await prepared.transport.close(disposition: .reusable) }
    }

    private func closePreparedTransports(_ preparedTransports: [PreparedTmuxControlTransport]) {
        for prepared in preparedTransports {
            closePreparedTransport(prepared)
        }
    }

    private func sessionOpenFlowID(_ workspaceID: SavedWorkspace.ID) -> String {
        "session.open.\(workspaceID.uuidString)"
    }
}
