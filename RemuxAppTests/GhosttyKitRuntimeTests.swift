import Foundation
import GhosttyKit
import QuartzCore
import UIKit
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
        var config = ghostty_terminal_surface_config_new()

        GhosttyTerminalAppearancePolicy.appearance(
            for: .phone,
            contentSizeCategory: .large
        ).apply(to: &config)

        XCTAssertGreaterThanOrEqual(config.font_size, GhosttyTerminalAppearancePolicy.phoneMinimumFontSize)
        XCTAssertEqual(config.font_size, GhosttyTerminalAppearancePolicy.phoneDefaultFontSize)
    }

    func testPhoneTerminalAppearanceScalesWithAccessibilityTextSize() {
        var regularConfig = ghostty_terminal_surface_config_new()
        var accessibilityConfig = ghostty_terminal_surface_config_new()

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
        var config = ghostty_terminal_surface_config_new()
        config.font_size = 14

        GhosttyTerminalAppearancePolicy.appearance(
            for: .phone,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        ).apply(to: &config)

        XCTAssertEqual(config.font_size, 14)
    }

    func testPadTerminalAppearanceUsesGhosttyDefaultDensity() {
        var config = ghostty_terminal_surface_config_new()

        GhosttyTerminalAppearancePolicy.appearance(for: .pad).apply(to: &config)

        XCTAssertEqual(config.font_size, 0)
    }

    func testTerminalSurfaceReplacementLeavesOneRendererLayerAndDetachesFreedLayers() throws {
        let fixture = try NativeTerminalSurfaceFixture()
        defer { fixture.close() }
        var firstLayer: CALayer?

        for index in 0..<12 {
            let layer = try fixture.createSurface()
            XCTAssertEqual(fixture.view.layer.sublayers?.count, 1)
            if index == 0 {
                firstLayer = layer
            } else {
                XCTAssertFalse(layer === firstLayer)
            }
            try fixture.setVisible()

            let freedLayer = try XCTUnwrap(fixture.freeSurface())
            XCTAssertNil(freedLayer.superlayer)
            XCTAssertEqual(fixture.view.layer.sublayers?.count ?? 0, 0)
            freedLayer.setNeedsDisplay()
            freedLayer.displayIfNeeded()
        }
    }

    func testOwnedIOSurfaceFrameSurvivesRendererReuseAndRelease() async throws {
        let fixture = try NativeTerminalSurfaceFixture()
        defer { fixture.close() }
        let layer = try fixture.createSurface()
        try await awaitPublication(on: layer) {
            try fixture.setVisible()
        }
        let frame = try GhosttyIOSurfaceFrame.read(from: layer)
        let originalBytes = frame.bytes

        for index in 0..<5 {
            try await awaitPublication(on: layer) {
                try fixture.feed("\u{1B}[\(41 + index)mframe-\(index)\u{1B}[0m\r\n")
            }
        }
        _ = fixture.freeSurface()

        let image = try await Task.detached {
            try frame.image(maxWidth: 160, maxHeight: 120)
        }.value
        XCTAssertEqual(frame.bytes, originalBytes)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    private func awaitPublication(
        on layer: CALayer,
        perform: () throws -> Void
    ) async throws {
        let publication = expectation(description: "renderer publishes IOSurface")
        publication.assertForOverFulfill = false
        let observation = layer.observe(\.contents, options: [.new]) { _, _ in
            publication.fulfill()
        }
        defer { observation.invalidate() }
        try perform()
        await fulfillment(of: [publication], timeout: 2)
    }

}

@MainActor
private final class NativeTerminalSurfaceFixture {
    enum FixtureError: Error {
        case producer(ghostty_terminal_producer_result_e)
        case terminal(ghostty_terminal_producer_result_e)
        case surface(ghostty_terminal_surface_result_e)
        case missingRendererLayer
    }

    let runtime: GhosttyKitRuntime
    let view = GhosttyKitSurfaceView(
        frame: CGRect(x: 0, y: 0, width: 320, height: 180)
    )
    private let window = UIWindow(
        frame: CGRect(x: 0, y: 0, width: 320, height: 180)
    )

    private let producer: ghostty_terminal_producer_t
    private let terminal: ghostty_terminal_t
    private var surface: ghostty_terminal_surface_t?

    init() throws {
        runtime = try GhosttyKitRuntime()
        var producerConfig = ghostty_terminal_producer_config_new()
        producerConfig.columns = 80
        producerConfig.rows = 24
        producerConfig.max_scrollback = 100

        var createdProducer: ghostty_terminal_producer_t?
        let producerResult = ghostty_terminal_producer_new(
            &producerConfig,
            &createdProducer
        )
        guard producerResult == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK,
              let createdProducer
        else { throw FixtureError.producer(producerResult) }

        var createdTerminal: ghostty_terminal_t?
        let terminalResult = ghostty_terminal_producer_retain_terminal(
            createdProducer,
            &createdTerminal
        )
        guard terminalResult == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK,
              let createdTerminal
        else {
            ghostty_terminal_producer_free(createdProducer)
            throw FixtureError.terminal(terminalResult)
        }
        producer = createdProducer
        terminal = createdTerminal

        let rootViewController = UIViewController()
        window.rootViewController = rootViewController
        rootViewController.view.addSubview(view)
        window.isHidden = false
    }

    func createSurface() throws -> CALayer {
        precondition(surface == nil)
        let scale = max(window.screen.scale, 1)
        var config = runtime.makeTmuxBaseSurfaceConfig()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))
        config.scale_factor = scale
        config.width_px = UInt32((view.bounds.width * scale).rounded())
        config.height_px = UInt32((view.bounds.height * scale).rounded())
        config.visible = false
        config.focused = true

        var createdSurface: ghostty_terminal_surface_t?
        let result = ghostty_terminal_surface_new(
            runtime.appHandleForTesting,
            terminal,
            &config,
            &createdSurface
        )
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK,
              let createdSurface
        else { throw FixtureError.surface(result) }
        surface = createdSurface
        view.alignGhosttyRendererSublayers()
        guard let layer = view.layer.sublayers?.first else {
            ghostty_terminal_surface_free(createdSurface)
            surface = nil
            throw FixtureError.missingRendererLayer
        }
        return layer
    }

    func setVisible() throws {
        guard let surface else { throw FixtureError.missingRendererLayer }
        let result = ghostty_terminal_surface_set_visible(surface, true)
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            throw FixtureError.surface(result)
        }
        ghostty_app_tick(runtime.appHandleForTesting)
    }

    func feed(_ text: String) throws {
        let producerResult = text.utf8.withContiguousStorageIfAvailable { bytes in
            ghostty_terminal_producer_feed(producer, bytes.baseAddress, bytes.count)
        } ?? Array(text.utf8).withUnsafeBufferPointer { bytes in
            ghostty_terminal_producer_feed(producer, bytes.baseAddress, bytes.count)
        }
        guard producerResult == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
            throw FixtureError.producer(producerResult)
        }
        guard let surface else { throw FixtureError.missingRendererLayer }
        let result = ghostty_terminal_surface_terminal_changed(surface)
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            throw FixtureError.surface(result)
        }
        ghostty_app_tick(runtime.appHandleForTesting)
    }

    func freeSurface() -> CALayer? {
        guard let surface else { return nil }
        let layer = view.layer.sublayers?.first
        ghostty_terminal_surface_free(surface)
        self.surface = nil
        return layer
    }

    func close() {
        window.isHidden = true
        if let surface { ghostty_terminal_surface_free(surface) }
        surface = nil
        ghostty_terminal_release(terminal)
        ghostty_terminal_producer_free(producer)
        _ = runtime
    }
}
