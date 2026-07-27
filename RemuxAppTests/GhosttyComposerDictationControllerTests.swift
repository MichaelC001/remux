import XCTest
@testable import Remux

final class GhosttyComposerDictationControllerTests: XCTestCase {
    func testHypothesisBecomesDraftWhenSnapshotIsEmpty() {
        XCTAssertEqual(
            GhosttyComposerDictationDraft.merging(
                snapshot: "",
                hypothesis: "Check the build"
            ),
            "Check the build"
        )
    }

    func testHypothesisIsSeparatedFromExistingDraft() {
        XCTAssertEqual(
            GhosttyComposerDictationDraft.merging(
                snapshot: "Open the project",
                hypothesis: "then run the tests"
            ),
            "Open the project then run the tests"
        )
    }

    func testExistingWhitespaceIsNotDuplicated() {
        XCTAssertEqual(
            GhosttyComposerDictationDraft.merging(
                snapshot: "Open the project\n",
                hypothesis: "Then run the tests"
            ),
            "Open the project\nThen run the tests"
        )
    }

    func testEmptyPartialPreservesSnapshot() {
        XCTAssertEqual(
            GhosttyComposerDictationDraft.merging(
                snapshot: "Keep this draft",
                hypothesis: ""
            ),
            "Keep this draft"
        )
    }

    func testNewPartialReplacesPreviousPartialInsteadOfAppending() {
        let snapshot = "Please"

        XCTAssertEqual(
            GhosttyComposerDictationDraft.merging(
                snapshot: snapshot,
                hypothesis: "review"
            ),
            "Please review"
        )
        XCTAssertEqual(
            GhosttyComposerDictationDraft.merging(
                snapshot: snapshot,
                hypothesis: "review this change"
            ),
            "Please review this change"
        )
    }
}
