import Foundation
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyKitRuntimeTests: XCTestCase {
    func testReleaseBuildModePolicyAcceptsReleaseFastGhosttyKit() {
        XCTAssertNil(
            GhosttyKitBuildModePolicy.releaseValidationFailure(
                for: GHOSTTY_BUILD_MODE_RELEASE_FAST
            )
        )
    }

    func testReleaseBuildModePolicyRejectsDebugGhosttyKitWithActionableFailure() {
        XCTAssertEqual(
            GhosttyKitBuildModePolicy.releaseValidationFailure(
                for: GHOSTTY_BUILD_MODE_DEBUG
            ),
            "Remux Release requires ReleaseFast GhosttyKit; detected Debug. Run scripts/build_release_ghosttykit.sh and rebuild."
        )
    }

    func testRuntimeInitializesGhosttyBackend() throws {
        _ = try GhosttyKitRuntime()
    }

    func testSurfaceViewDoesNotDefaultToDesktopSizedFrame() {
        let view = GhosttyKitSurfaceView(frame: .zero)

        XCTAssertEqual(view.frame.size.width, 1)
        XCTAssertEqual(view.frame.size.height, 1)
    }

    func testPhoneTerminalAppearanceUsesAccessibleMobileDensity() {
        var config = ghostty_surface_config_new()

        GhosttyTerminalAppearancePolicy.appearance(
            for: .phone,
            contentSizeCategory: .large
        ).apply(to: &config)

        XCTAssertGreaterThanOrEqual(config.font_size, GhosttyTerminalAppearancePolicy.phoneMinimumFontSize)
        XCTAssertEqual(config.font_size, GhosttyTerminalAppearancePolicy.phoneDefaultFontSize)
    }

    func testPhoneTerminalAppearanceScalesWithAccessibilityTextSize() {
        var regularConfig = ghostty_surface_config_new()
        var accessibilityConfig = ghostty_surface_config_new()

        GhosttyTerminalAppearancePolicy.appearance(
            for: .phone,
            contentSizeCategory: .large
        ).apply(to: &regularConfig)
        GhosttyTerminalAppearancePolicy.appearance(
            for: .phone,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        ).apply(to: &accessibilityConfig)

        XCTAssertGreaterThan(accessibilityConfig.font_size, regularConfig.font_size)
    }

    func testPhoneTerminalAppearancePreservesExplicitGhosttyFontSize() {
        var config = ghostty_surface_config_new()
        config.font_size = 14

        GhosttyTerminalAppearancePolicy.appearance(
            for: .phone,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        ).apply(to: &config)

        XCTAssertEqual(config.font_size, 14)
    }

    func testPadTerminalAppearanceUsesGhosttyDefaultDensity() {
        var config = ghostty_surface_config_new()

        GhosttyTerminalAppearancePolicy.appearance(for: .pad).apply(to: &config)

        XCTAssertEqual(config.font_size, 0)
    }

    func testRuntimeCreatesManualHostSurfaceThatAcceptsOutput() throws {
        let runtime = try GhosttyKitRuntime()
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let surface = try runtime.makeManualHostSurface(view: view)

        XCTAssertTrue(surface.processOutput(Data("hello from tmux\n".utf8)))
        surface.setBackingExited(true)
    }

    func testManualSurfaceInputRoutesToWriteCallback() async throws {
        let recorder = ManualWriteRecorder()
        let runtime = try GhosttyKitRuntime()
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let surface = try runtime.makeManualHostSurface(
            view: view,
            onWrite: { data, linefeed in
                recorder.record(data: data, linefeed: linefeed)
                return true
            }
        )

        XCTAssertTrue(surface.sendInput("q"))

        let wrote = await waitUntil {
            recorder.writes().contains { $0.data == Data("q".utf8) }
        }

        XCTAssertTrue(wrote)
        surface.setBackingExited(true)
    }


    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private final class ManualWriteRecorder: @unchecked Sendable {
    struct Write: Equatable {
        let data: Data
        let linefeed: Bool
    }

    private let lock = NSLock()
    private var recordedWrites: [Write] = []

    func record(data: Data, linefeed: Bool) {
        lock.withLock {
            recordedWrites.append(Write(data: data, linefeed: linefeed))
        }
    }

    func writes() -> [Write] {
        lock.withLock {
            recordedWrites
        }
    }
}
