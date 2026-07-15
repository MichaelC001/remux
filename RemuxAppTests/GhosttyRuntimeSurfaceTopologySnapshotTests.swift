import XCTest
@testable import Remux

final class GhosttyRuntimeSurfaceTopologySnapshotTests: XCTestCase {
    func testValidSelectionResolvesSelectedWindowAndIndex() {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let thirdPaneID = UUID()
        let firstTopLevel = Self.topLevel(leafID: firstPaneID)
        let secondTopLevel = Self.topLevel(
            leafIDs: [secondPaneID, thirdPaneID],
            focusedLeafID: thirdPaneID
        )
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [firstTopLevel, secondTopLevel],
            selectedTopLevelID: secondTopLevel.id
        )

        XCTAssertEqual(snapshot.selectedTopLevel, secondTopLevel)
        XCTAssertEqual(snapshot.selectedTopLevelIndex, 1)
    }

    func testStaleSelectionDoesNotResolveTopology() {
        let topLevel = Self.topLevel(leafID: UUID())
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [topLevel],
            selectedTopLevelID: UUID()
        )

        XCTAssertNil(snapshot.selectedTopLevel)
        XCTAssertNil(snapshot.selectedTopLevelIndex)
    }

    func testNilSelectionDoesNotResolveTopology() {
        let topLevel = Self.topLevel(leafID: UUID())
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [topLevel],
            selectedTopLevelID: nil
        )

        XCTAssertNil(snapshot.selectedTopLevel)
        XCTAssertNil(snapshot.selectedTopLevelIndex)
    }

    func testDuplicateSelectionPreservesFirstTopLevelMatch() {
        let topLevelID = UUID()
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let firstTopLevel = GhosttyTopLevelSurface(
            id: topLevelID,
            leafIDs: [firstPaneID]
        )
        let secondTopLevel = GhosttyTopLevelSurface(
            id: topLevelID,
            leafIDs: [secondPaneID]
        )
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [firstTopLevel, secondTopLevel],
            selectedTopLevelID: topLevelID
        )

        XCTAssertEqual(snapshot.selectedTopLevel, firstTopLevel)
        XCTAssertEqual(snapshot.selectedTopLevelIndex, 0)
    }

    private static func topLevel(leafID: UUID) -> GhosttyTopLevelSurface {
        GhosttyTopLevelSurface(leafIDs: [leafID])
    }

    private static func topLevel(
        leafIDs: [UUID],
        focusedLeafID: UUID?
    ) -> GhosttyTopLevelSurface {
        return GhosttyTopLevelSurface(
            leafIDs: leafIDs,
            focusedLeafID: focusedLeafID
        )
    }
}
