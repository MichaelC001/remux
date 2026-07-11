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


    func testRuntimeSurfaceCreationRequestCopiesNativeConfig() {
        let parent = UnsafeMutableRawPointer(bitPattern: 0x7001)!
        let manualUserdata = UnsafeMutableRawPointer(bitPattern: 0x7002)!
        var config = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            manualUserdata: manualUserdata
        )

        let request = withUnsafePointer(to: &config) { configPtr in
            GhosttyRuntimeSurfaceCreationRequest(
                native: ghostty_runtime_create_surface_s(
                    parent: parent,
                    split_direction: GHOSTTY_SPLIT_DIRECTION_DOWN,
                    config: configPtr
                )
            )
        }
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        XCTAssertEqual(request.parentHandle, parent)
        XCTAssertEqual(request.splitDirection, GHOSTTY_SPLIT_DIRECTION_DOWN)
        XCTAssertEqual(request.context, GHOSTTY_SURFACE_CONTEXT_WINDOW)
        XCTAssertEqual(request.baseConfig?.manual_userdata, manualUserdata)
    }

    func testRuntimeSurfaceCreationRequestPreservesMissingConfig() {
        let request = GhosttyRuntimeSurfaceCreationRequest(
            native: ghostty_runtime_create_surface_s(
                parent: nil,
                split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                config: nil
            )
        )

        XCTAssertNil(request.baseConfig)
        XCTAssertNil(request.context)
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

    private static let runtimeTreeManualWrite: ghostty_surface_manual_write_cb = { _, _, _, _ in
        true
    }


    private static func manualRuntimeTreeConfig(
        context: ghostty_surface_context_e,
        manualUserdata: UnsafeMutableRawPointer? = nil
    ) -> ghostty_surface_config_s {
        var config = ghostty_surface_config_new()
        config.context = context
        config.backing = GHOSTTY_SURFACE_BACKING_MANUAL
        config.manual_write = runtimeTreeManualWrite
        config.manual_userdata = manualUserdata
        return config
    }

    private func withRuntimeTreeRequest<T>(
        firstConfig: inout ghostty_surface_config_s,
        secondConfig: inout ghostty_surface_config_s,
        leafSurfaces: inout [ghostty_surface_t?],
        focusedLeafIndex: Int,
        body: (ghostty_runtime_create_surface_tree_s) throws -> T
    ) throws -> T {
        try withUnsafePointer(to: &firstConfig) { firstConfigPtr in
            try withUnsafePointer(to: &secondConfig) { secondConfigPtr in
                var nodes = [
                    ghostty_runtime_surface_tree_node_s(
                        key: GHOSTTY_SURFACE_TREE_NODE_SPLIT,
                        split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                        split_ratio: 0.5,
                        left_index: 1,
                        right_index: 2,
                        config: nil
                    ),
                    ghostty_runtime_surface_tree_node_s(
                        key: GHOSTTY_SURFACE_TREE_NODE_LEAF,
                        split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                        split_ratio: 0.5,
                        left_index: 0,
                        right_index: 0,
                        config: firstConfigPtr
                    ),
                    ghostty_runtime_surface_tree_node_s(
                        key: GHOSTTY_SURFACE_TREE_NODE_LEAF,
                        split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                        split_ratio: 0.5,
                        left_index: 0,
                        right_index: 0,
                        config: secondConfigPtr
                    )
                ]

                return try nodes.withUnsafeBufferPointer { nodeBuffer in
                    try leafSurfaces.withUnsafeMutableBufferPointer { leafBuffer in
                        let request = ghostty_runtime_create_surface_tree_s(
                            parent: nil,
                            nodes: nodeBuffer.baseAddress,
                            nodes_len: nodeBuffer.count,
                            root_index: 0,
                            leaf_surfaces: leafBuffer.baseAddress,
                            leaf_surfaces_len: leafBuffer.count,
                            focused_leaf_index: focusedLeafIndex,
                            focused_leaf_index_valid: true
                        )
                        return try body(request)
                    }
                }
            }
        }
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
