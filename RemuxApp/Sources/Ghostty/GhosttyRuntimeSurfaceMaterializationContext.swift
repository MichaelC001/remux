import Foundation

@MainActor
struct GhosttyRuntimeSurfaceMaterializationContext {
    private final class EmptySource {}

    private static let emptySource = EmptySource()

    static let empty = GhosttyRuntimeSurfaceMaterializationContext(
        sourceIdentity: ObjectIdentifier(emptySource),
        isAvailable: { false },
        managedSurface: { _ in nil }
    )

    let sourceIdentity: ObjectIdentifier

    private let isAvailableHandler: () -> Bool
    private let managedSurfaceHandler: (UUID) -> GhosttyManagedSurface?

    init(
        sourceIdentity: ObjectIdentifier,
        isAvailable: @escaping () -> Bool,
        managedSurface: @escaping (UUID) -> GhosttyManagedSurface?
    ) {
        self.sourceIdentity = sourceIdentity
        self.isAvailableHandler = isAvailable
        self.managedSurfaceHandler = managedSurface
    }

    var isAvailable: Bool {
        isAvailableHandler()
    }

    func managedSurface(for id: UUID) -> GhosttyManagedSurface? {
        managedSurfaceHandler(id)
    }
}
