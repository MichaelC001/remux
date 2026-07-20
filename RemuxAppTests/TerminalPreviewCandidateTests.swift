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
            "README",
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

    func testAcceptsRelativePathsFromAutomaticAndWordSelections() throws {
        var context = TerminalPreviewSelectionContext()
        context.setAutomaticSelection(
            visibleText: "../docs/README.md",
            explicitTarget: nil
        )

        let candidate = try XCTUnwrap(context.candidate(for: "../docs/README.md"))
        XCTAssertEqual(candidate.path, .relative("../docs/README.md"))
        XCTAssertEqual(candidate.remotePath, "../docs/README.md")

        context.selectionDidChange()
        XCTAssertEqual(
            context.candidate(for: "README.md")?.path,
            .relative("README.md")
        )
        XCTAssertEqual(
            context.candidate(for: "docs/README.md")?.path,
            .relative("docs/README.md")
        )
        XCTAssertNil(context.candidate(for: "README"))
    }

    func testResolvesRelativePathsLexicallyAgainstPaneDirectory() throws {
        let candidate = try XCTUnwrap(TerminalPreviewCandidate(
            selection: "../docs/./README.md"
        ))

        XCTAssertEqual(
            try candidate.path.resolved(relativeTo: "/srv/app/src"),
            "/srv/app/docs/README.md"
        )
    }

    func testRejectsInvalidRelativePathInputsAndCurrentDirectories() throws {
        for value in ["~/README.md", ".", "..", "https://example.com/file.txt"] {
            XCTAssertNil(
                TerminalPreviewCandidate(selection: value),
                value
            )
        }

        let candidate = try XCTUnwrap(TerminalPreviewCandidate(
            selection: "README.md"
        ))
        XCTAssertThrowsError(try candidate.path.resolved(relativeTo: "relative/cwd")) {
            XCTAssertEqual($0 as? TerminalPreviewPathError, .invalidCurrentDirectory)
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
