import XCTest

@testable import Remux

final class TerminalPreviewCandidateTests: XCTestCase {
    func testAcceptsAbsoluteServerPathsAndFileURLs() {
        XCTAssertEqual(
            TerminalPreviewCandidate(selection: "/srv/app/readme.md")?.remotePath,
            "/srv/app/readme.md"
        )
        XCTAssertEqual(
            TerminalPreviewCandidate(
                selection: "file:///srv/app/a%20file.pdf"
            )?.remotePath,
            "/srv/app/a file.pdf"
        )
    }

    func testRejectsNonFilePreviewTargets() {
        for value in [
            "README.md",
            "~/README.md",
            "https://example.com/readme.pdf",
            "http://localhost:3000",
            "file://server/srv/app/readme.md",
            "/srv/app/bad\0name.txt",
            "/srv/app/index.html",
            "/srv/app/index.HTM",
            "/srv/app/page.xhtml",
        ] {
            XCTAssertNil(TerminalPreviewCandidate(selection: value), value)
        }
    }

    func testUnknownExtensionRemainsEligibleForQuickLookDecision() {
        XCTAssertEqual(
            TerminalPreviewCandidate(selection: "/tmp/artifact.unknown")?.remotePath,
            "/tmp/artifact.unknown"
        )
        XCTAssertEqual(
            TerminalPreviewCandidate(selection: "/tmp/Makefile")?.remotePath,
            "/tmp/Makefile"
        )
    }

    func testTrimsTerminalCellPaddingWithoutRemovingInternalSpaces() {
        XCTAssertEqual(
            TerminalPreviewCandidate(
                selection: "  /tmp/a report.txt   \n"
            )?.remotePath,
            "/tmp/a report.txt"
        )
    }

    func testExplicitTargetOverridesUntouchedAutomaticSelection() {
        var context = TerminalPreviewSelectionContext()
        context.setAutomaticSelection(
            visibleText: "report",
            explicitTarget: "file:///srv/report.pdf"
        )

        XCTAssertEqual(
            context.candidate(for: "report")?.remotePath,
            "/srv/report.pdf"
        )
    }

    func testEditedSelectionCannotReuseExplicitTarget() {
        var context = TerminalPreviewSelectionContext()
        context.setAutomaticSelection(
            visibleText: "report",
            explicitTarget: "file:///srv/report.pdf"
        )

        XCTAssertNil(context.candidate(for: "report edited"))

        context.selectionDidChange()
        XCTAssertNil(context.candidate(for: "report"))
    }
}
