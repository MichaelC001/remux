import CoreGraphics
import XCTest
@testable import Remux

@MainActor
final class TerminalThemePreviewRendererTests: XCTestCase {
    func testPreviewSampleUsesTerminalPaletteForEveryTheme() {
        for theme in TerminalTheme.allCases {
            let output = String(decoding: TerminalThemePreviewSample.output(for: theme), as: UTF8.self)

            XCTAssertNil(output.range(of: #"#[0-9A-Fa-f]{6}"#, options: .regularExpression))
            XCTAssertFalse(output.contains("38;2;"))
            XCTAssertFalse(output.contains("48;2;"))
            XCTAssertTrue(output.contains("\u{1B}[34m#include "))
            XCTAssertTrue(output.contains("\u{1B}[32m<iostream>"))
            XCTAssertTrue(output.contains("\u{1B}[33mint"))
            XCTAssertTrue(output.contains("\u{1B}[44;30m NORMAL "))
            XCTAssertTrue(output.contains("\u{1B}[48;5;8;37m test.cpp "))
            XCTAssertTrue(output.contains("\u{1B}[K"))
            XCTAssertTrue(output.contains("\u{1B}[4;28H"))
            XCTAssertTrue(output.contains("std"))
            XCTAssertTrue(output.contains("cout"))
            XCTAssertTrue(output.contains(#""remux""#))
        }
    }

    func testRenderRequestUsesRoundedPhysicalPixelSize() throws {
        let request = try XCTUnwrap(TerminalThemePreviewRenderRequest(
            settings: TerminalSettings(fontSize: 11, theme: .remuxDark),
            pointSize: CGSize(width: 320.8, height: 132.4),
            scale: 3
        ))

        XCTAssertEqual(request.pointSize, CGSize(width: 320, height: 132))
        XCTAssertEqual(request.pixelWidth, 960)
        XCTAssertEqual(request.pixelHeight, 396)
    }

    func testPreviewContentCreatesRealTerminalSurfaceView() throws {
        let request = try XCTUnwrap(TerminalThemePreviewRenderRequest(
            settings: TerminalSettings(fontSize: 11, theme: .ghosttyDefault),
            pointSize: CGSize(width: 300, height: 120),
            scale: 1
        ))

        let content = try TerminalThemePreviewContent(request: request)

        XCTAssertEqual(content.view.frame.size, request.pointSize)
        XCTAssertEqual(content.view.contentScaleFactor, request.scale)
        XCTAssertEqual(content.view.layer.sublayers?.count, 1)
    }
}
