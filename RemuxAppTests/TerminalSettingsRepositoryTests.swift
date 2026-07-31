import XCTest
@testable import Remux

final class TerminalSettingsRepositoryTests: XCTestCase {
    func testFileBackedRepositoryLoadsDefaultWhenNoFileExists() async throws {
        let repository = FileBackedTerminalSettingsRepository(rootURL: temporaryRoot())

        let settings = try await repository.loadSettings()

        XCTAssertEqual(settings, .default)
    }

    func testFileBackedRepositoryPersistsSettings() async throws {
        let root = temporaryRoot()
        let repository = FileBackedTerminalSettingsRepository(rootURL: root)
        let saved = TerminalSettings(
            fontSize: 16,
            theme: .remuxLight,
            allowInsecureRSAHostKeys: true
        )

        try await repository.saveSettings(saved)

        let reloaded = try await FileBackedTerminalSettingsRepository(rootURL: root).loadSettings()
        XCTAssertEqual(reloaded, saved)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
