import Foundation
import XCTest
@testable import Remux

final class SSHPublicKeyRemoteInstallerTests: XCTestCase {
    func testThrowsMissingResourceWhenBundleDoesNotContainInstaller() throws {
        let fixture = try makeFixtureBundle(resourceContents: nil)
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        XCTAssertThrowsError(
            try SSHPublicKeyRemoteInstaller.command(bundle: fixture.bundle)
        ) { error in
            XCTAssertEqual(error as? SSHPublicKeyRemoteInstallerError, .missingResource)
        }
    }

    func testWrapsFixtureResourceInSingleFixedShellCommand() throws {
        let fixture = try makeFixtureBundle(resourceContents: "printf 'installed'\\n")
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let command = try SSHPublicKeyRemoteInstaller.command(bundle: fixture.bundle)

        XCTAssertTrue(command.hasPrefix("exec sh -c '"))
        XCTAssertTrue(command.hasSuffix("'"))
        XCTAssertTrue(command.contains("'\\''"))
    }

    private func makeFixtureBundle(resourceContents: String?) throws -> (url: URL, bundle: Bundle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHPublicKeyRemoteInstallerTests-\(UUID().uuidString)")
            .appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let info = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleIdentifier": "dev.remux.tests.fixture.\(UUID().uuidString)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Fixture",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: url.appendingPathComponent("Info.plist"))

        if let resourceContents {
            try Data(resourceContents.utf8).write(
                to: url.appendingPathComponent("install_authorized_key.sh")
            )
        }

        return (url, try XCTUnwrap(Bundle(path: url.path)))
    }
}
