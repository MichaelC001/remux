import Foundation
import GhosttyKit

struct GhosttyRuntimeCallbackLease: Equatable, Sendable {
    let registryID: ObjectIdentifier
    let epoch: UInt64
}

final class GhosttyRuntimeCallbackLeaseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var nextEpoch: UInt64 = 0
    private var activeLease: GhosttyRuntimeCallbackLease?

    func makeLease(registryID: ObjectIdentifier) -> GhosttyRuntimeCallbackLease {
        lock.withLock {
            nextEpoch &+= 1
            let lease = GhosttyRuntimeCallbackLease(
                registryID: registryID,
                epoch: nextEpoch
            )
            activeLease = lease
            return lease
        }
    }

    func accepts(_ lease: GhosttyRuntimeCallbackLease) -> Bool {
        lock.withLock {
            activeLease == lease
        }
    }

    func currentLease() -> GhosttyRuntimeCallbackLease? {
        lock.withLock {
            activeLease
        }
    }

    func invalidate(_ lease: GhosttyRuntimeCallbackLease) {
        lock.withLock {
            guard activeLease == lease else { return }
            activeLease = nil
        }
    }

    func invalidateActiveLease() {
        lock.withLock {
            activeLease = nil
        }
    }
}

enum GhosttyRuntimeSurfaceAction: Equatable {
    case render
    case cellSize
    case scrollbar(GhosttySurfaceScrollState)
    case scrollRoute(GhosttySurfaceScrollRoute)
    case ignored

    init(native action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            self = .render
        case GHOSTTY_ACTION_CELL_SIZE:
            self = .cellSize
        case GHOSTTY_ACTION_SCROLLBAR:
            self = .scrollbar(GhosttySurfaceScrollState(cValue: action.action.scrollbar))
        case GHOSTTY_ACTION_SCROLL_ROUTE:
            self = .scrollRoute(GhosttySurfaceScrollRoute(cValue: action.action.scroll_route))
        default:
            self = .ignored
        }
    }
}

enum GhosttyRuntimeSurfaceActionTarget: Equatable {
    case surface(ghostty_surface_t?)
    case ignored

    init(native target: ghostty_target_s) {
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            self = .surface(target.target.surface)
        default:
            self = .ignored
        }
    }
}

protocol GhosttyKitRuntimeSurfaceDelegate: AnyObject {
    @MainActor
    func makeRuntimeCallbackLease() -> GhosttyRuntimeCallbackLease?

    nonisolated func acceptsRuntimeCallback(_ lease: GhosttyRuntimeCallbackLease) -> Bool

    nonisolated func runtimeCallbackLeaseDidEnd(_ lease: GhosttyRuntimeCallbackLease)

    @MainActor
    func withRuntimeCallbackBatch(
        lease: GhosttyRuntimeCallbackLease,
        _ body: () -> Void
    )

    @MainActor
    func runtimeAction(
        app: ghostty_app_t?,
        target: GhosttyRuntimeSurfaceActionTarget,
        action: GhosttyRuntimeSurfaceAction,
        lease: GhosttyRuntimeCallbackLease
    ) -> Bool
}

extension GhosttyKitRuntimeSurfaceDelegate {
    @MainActor
    func makeRuntimeCallbackLease() -> GhosttyRuntimeCallbackLease? {
        nil
    }

    nonisolated func acceptsRuntimeCallback(_ lease: GhosttyRuntimeCallbackLease) -> Bool {
        false
    }

    nonisolated func runtimeCallbackLeaseDidEnd(_ lease: GhosttyRuntimeCallbackLease) {}

    @MainActor
    func withRuntimeCallbackBatch(
        lease: GhosttyRuntimeCallbackLease,
        _ body: () -> Void
    ) {
        body()
    }
}
