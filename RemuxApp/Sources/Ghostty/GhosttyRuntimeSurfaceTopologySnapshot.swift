import Foundation

struct GhosttyRuntimeSurfaceTopologySnapshot: Equatable {
    static var empty: GhosttyRuntimeSurfaceTopologySnapshot {
        GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [],
            selectedTopLevelID: nil,
            pendingPhonePresentationSurfaceID: nil
        )
    }

    let topLevels: [GhosttyTopLevelSurface]
    let selectedTopLevelID: UUID?
    let pendingPhonePresentationSurfaceID: UUID?
    let selectedTopLevel: GhosttyTopLevelSurface?
    let selectedTopLevelIndex: Int?
    let selectedActiveLeafID: UUID?

    init(
        topLevels: [GhosttyTopLevelSurface],
        selectedTopLevelID: UUID?,
        pendingPhonePresentationSurfaceID: UUID?
    ) {
        self.topLevels = topLevels
        self.selectedTopLevelID = selectedTopLevelID
        self.pendingPhonePresentationSurfaceID = pendingPhonePresentationSurfaceID

        guard let selectedTopLevelID,
              let selectedTopLevelIndex = topLevels.firstIndex(where: { $0.id == selectedTopLevelID })
        else {
            self.selectedTopLevel = nil
            self.selectedTopLevelIndex = nil
            self.selectedActiveLeafID = nil
            return
        }

        let selectedTopLevel = topLevels[selectedTopLevelIndex]
        let selectedActiveLeafID = selectedTopLevel.resolvedFocusedLeafID

        self.selectedTopLevel = selectedTopLevel
        self.selectedTopLevelIndex = selectedTopLevelIndex
        self.selectedActiveLeafID = selectedActiveLeafID
    }
}
