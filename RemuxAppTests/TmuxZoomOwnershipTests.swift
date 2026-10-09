import Foundation
import XCTest

@testable import Remux

final class TmuxZoomOwnershipTests: XCTestCase {
    private let owner = TmuxZoomOwner(
        serverID: UUID(uuidString: "0D9F2A6C-5E1B-4C07-9A3D-8B6E2F4C1A75")!
    )

    func testMarkIsSetOnlyWhenTheWindowEndedUpZoomed() {
        XCTAssertEqual(
            owner.markIfZoomedCommand(windowID: 3),
            "set-option -F -w -t @3 @remux-zoom-owner "
                + "'#{?window_zoomed_flag,0D9F2A6C-5E1B-4C07-9A3D-8B6E2F4C1A75,#{@remux-zoom-owner}}'"
        )
    }

    func testMarkIsClearedOnlyWhenItIsThisOwners() {
        XCTAssertEqual(
            owner.clearMarkCommand(windowID: 3),
            "set-option -F -w -t @3 @remux-zoom-owner "
                + "'#{?#{==:#{@remux-zoom-owner},0D9F2A6C-5E1B-4C07-9A3D-8B6E2F4C1A75},,#{@remux-zoom-owner}}'"
        )
    }

    func testMarksReplyDistinguishesOwnOtherAndUnmarkedWindows() {
        let reply = """
        @0 1 \(owner.id)
        @1 1 3C1E7B0A-0000-4000-8000-000000000000
        @2 0 \(owner.id)
        @3 0
        @4 1
        """

        XCTAssertEqual(owner.marks(fromQueryReply: reply), [
            TmuxZoomMark(windowID: 0, zoomed: true, isOwn: true),
            TmuxZoomMark(windowID: 1, zoomed: true, isOwn: false),
            TmuxZoomMark(windowID: 2, zoomed: false, isOwn: true),
            TmuxZoomMark(windowID: 3, zoomed: false, isOwn: false),
            TmuxZoomMark(windowID: 4, zoomed: true, isOwn: false),
        ])
    }

    func testMarksReplySkipsLinesThatAreNotWindowRecords() {
        let reply = "no windows\n@x 1 owner\n@5 2 owner\n@6 1 \(owner.id)\n"

        XCTAssertEqual(owner.marks(fromQueryReply: reply), [
            TmuxZoomMark(windowID: 6, zoomed: true, isOwn: true),
        ])
    }

    func testAdoptionTakesBackOwnZoomsAndForgetsOwnMarksWhoseZoomIsGone() {
        let adoption = TmuxZoomMarkAdoption(
            marks: [
                TmuxZoomMark(windowID: 0, zoomed: true, isOwn: true),
                TmuxZoomMark(windowID: 1, zoomed: true, isOwn: false),
                TmuxZoomMark(windowID: 2, zoomed: false, isOwn: true),
                TmuxZoomMark(windowID: 3, zoomed: false, isOwn: false),
                // The topology, newer than the reply, shows this zoom gone.
                TmuxZoomMark(windowID: 4, zoomed: true, isOwn: true),
                // Zoomed by someone else after the mark was left behind.
                TmuxZoomMark(windowID: 5, zoomed: false, isOwn: true),
            ],
            zoomedWindowIDs: [0, 1, 5],
            zoomingWindowIDs: []
        )

        XCTAssertEqual(adoption.adoptedWindowIDs, [0])
        XCTAssertEqual(adoption.forgottenWindowIDs, [2, 4, 5])
    }

    func testAdoptionKeepsTheMarkOfAZoomThisAttachmentIsMaking() {
        let adoption = TmuxZoomMarkAdoption(
            marks: [TmuxZoomMark(windowID: 7, zoomed: true, isOwn: true)],
            zoomedWindowIDs: [],
            zoomingWindowIDs: [7]
        )

        XCTAssertEqual(adoption.adoptedWindowIDs, [])
        XCTAssertEqual(adoption.forgottenWindowIDs, [])
    }
}
