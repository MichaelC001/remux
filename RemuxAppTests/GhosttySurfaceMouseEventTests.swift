import XCTest
import CoreGraphics
import GhosttyKit
@testable import Remux

final class GhosttySurfaceMouseEventTests: XCTestCase {
    func testMouseButtonEventPreservesCValues() {
        let event = GhosttySurfaceMouseButtonEvent(
            state: .press,
            button: .right,
            mods: [.alt, .ctrl]
        )

        event.withCValues { state, button, mods in
            XCTAssertEqual(state, GHOSTTY_MOUSE_PRESS)
            XCTAssertEqual(button, GHOSTTY_MOUSE_RIGHT)
            XCTAssertEqual(mods.rawValue, GhosttySurfaceKeyEvent.Mods([.alt, .ctrl]).rawValue)
        }
    }

    func testMouseScrollModsEncodePrecisionAndMomentum() {
        let mods = GhosttySurfaceMouseScrollMods(
            precision: true,
            momentum: .changed
        )

        XCTAssertTrue(mods.precision)
        XCTAssertEqual(mods.momentum, .changed)
        XCTAssertEqual(mods.rawValue, 0b0000_0111)
    }

    func testMouseScrollModsRoundTripRawValue() {
        let mods = GhosttySurfaceMouseScrollMods(rawValue: 0b0000_1001)

        XCTAssertTrue(mods.precision)
        XCTAssertEqual(mods.momentum, .ended)
    }

    func testTapGestureActivatesInputOnlyWhenMouseIsNotCaptured() {
        XCTAssertEqual(
            GhosttySurfaceTapGesture.actions(
                forLocalPoint: CGPoint(x: 10, y: 20),
                mouseCaptured: false
            ),
            [.activateInput]
        )
    }

    func testTapGestureActivatesInputAndEmitsMouseClickWhenMouseIsCaptured() {
        let point = CGPoint(x: 10, y: 20)

        XCTAssertEqual(
            GhosttySurfaceTapGesture.actions(
                forLocalPoint: point,
                mouseCaptured: true
            ),
            [
                .activateInput,
                .mousePosition(point),
                .mouseButton(.init(state: .press, button: .left)),
                .mouseButton(.init(state: .release, button: .left)),
            ]
        )
    }

}
