import Foundation
import XCTest
@testable import Remux

final class TmuxSessionDiscoveryTests: XCTestCase {
    func testListCommandKeepsConfiguredExecutableOutOfLoginShellSyntax() {
        let executable = "/home/owner's tools/tmux; touch pwned"

        let command = SSHTmuxControlCommandBuilder.listSessionsCommand(
            tmuxExecutable: executable
        )

        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertTrue(command.contains("exec \"$resolved\" list-sessions -F \"#{session_name}\""))
        XCTAssertFalse(command.contains(executable))
        XCTAssertFalse(command.contains("touch pwned"))
    }

    func testParserPreservesWhitespaceDeduplicatesAndAcceptsCRLF() throws {
        let names = try TmuxSessionDiscovery.parseSessionNames(
            Data("main\r\n  spaced  \nmain\n\nops\r\n".utf8)
        )

        XCTAssertEqual(names, ["main", "  spaced  ", "ops"])
    }

    func testParserRejectsInvalidUTF8() {
        XCTAssertThrowsError(
            try TmuxSessionDiscovery.parseSessionNames(Data([0xFF]))
        ) {
            XCTAssertEqual($0 as? TmuxSessionDiscoveryError, .invalidUTF8)
        }
    }
}
