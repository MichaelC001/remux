import CoreGraphics
import XCTest
@testable import Remux

final class GhosttyKeyboardCursorTrackpadTests: XCTestCase {
    private let configuration = GhosttyKeyboardCursorTrackpad.Configuration(
        neutralRadius: 2,
        armingDistance: 8,
        tierPlateauDistance: 4,
        oneXRepeatInterval: 0.2,
        twoXRepeatInterval: 0.1,
        threeXRepeatInterval: 0.05,
        directionSwitchRatio: 1.25,
        tierReleaseHysteresis: 2
    )

    func testRadialZonesSeparateArmingFromStableCommittedTiers() {
        var trackpad = makeTrackpad()

        XCTAssertEqual(trackpad.update(at: .init(x: 1, y: 0)), .active)
        assertFeedback(
            trackpad.update(at: .init(x: 6, y: 0)),
            direction: .right,
            committedTier: .neutral,
            armingTier: .one,
            armingProgress: 0.5
        )
        assertFeedback(
            trackpad.update(at: .init(x: 10, y: 0)),
            direction: .right,
            committedTier: .one
        )
        assertFeedback(
            trackpad.update(at: .init(x: 12, y: 0)),
            direction: .right,
            committedTier: .one
        )
        assertFeedback(
            trackpad.update(at: .init(x: 18, y: 0)),
            direction: .right,
            committedTier: .one,
            armingTier: .two,
            armingProgress: 0.5
        )
        assertFeedback(
            trackpad.update(at: .init(x: 22, y: 0)),
            direction: .right,
            committedTier: .two
        )
        assertFeedback(
            trackpad.update(at: .init(x: 24, y: 0)),
            direction: .right,
            committedTier: .two
        )
        assertFeedback(
            trackpad.update(at: .init(x: 30, y: 0)),
            direction: .right,
            committedTier: .two,
            armingTier: .three,
            armingProgress: 0.5
        )
        assertFeedback(
            trackpad.update(at: .init(x: 34, y: 0)),
            direction: .right,
            committedTier: .three
        )
    }

    func testTierProgressUsesRadiusFromOrigin() {
        var trackpad = makeTrackpad()

        assertFeedback(
            trackpad.update(at: .init(x: 6, y: 8)),
            direction: .down,
            committedTier: .one
        )
    }

    func testMovingInwardPastReleaseHysteresisLowersCommittedTier() {
        var trackpad = makeTrackpad()
        XCTAssertEqual(trackpad.update(at: .init(x: 24, y: 0)).committedTier, .two)

        assertFeedback(
            trackpad.update(at: .init(x: 19, y: 0)),
            direction: .right,
            committedTier: .one,
            armingTier: .two,
            armingProgress: 0.625
        )
    }

    func testCommittedTierDoesNotChatterAtReleaseBoundary() {
        var trackpad = makeTrackpad()
        XCTAssertEqual(trackpad.update(at: .init(x: 22, y: 0)).committedTier, .two)

        assertFeedback(
            trackpad.update(at: .init(x: 21, y: 0)),
            direction: .right,
            committedTier: .two
        )
        assertFeedback(
            trackpad.update(at: .init(x: 19, y: 0)),
            direction: .right,
            committedTier: .one,
            armingTier: .two,
            armingProgress: 0.625
        )
    }

    func testReturningInsideNeutralCircleClearsDirectionAndStopsSteering() {
        var trackpad = makeTrackpad()
        _ = trackpad.update(at: .init(x: 22, y: 0))

        XCTAssertEqual(trackpad.update(at: .init(x: 1, y: 0)), .active)
    }

    func testFixedOriginMapsAllCardinalDirections() {
        let samples: [(CGPoint, GhosttyKeyboardCursorTrackpad.Direction)] = [
            (.init(x: 10, y: 0), .right),
            (.init(x: -10, y: 0), .left),
            (.init(x: 0, y: -10), .up),
            (.init(x: 0, y: 10), .down),
        ]

        for (point, direction) in samples {
            var trackpad = makeTrackpad()
            assertFeedback(
                trackpad.update(at: point),
                direction: direction,
                committedTier: .one
            )
        }
    }

    func testAxisHysteresisPreventsDirectionFlickerNearDiagonal() {
        var trackpad = makeTrackpad()
        XCTAssertEqual(trackpad.update(at: .init(x: 20, y: 10)).direction, .right)

        XCTAssertEqual(trackpad.update(at: .init(x: 20, y: 24)).direction, .right)
        XCTAssertEqual(trackpad.update(at: .init(x: 20, y: 25)).direction, .down)
    }

    func testCrossingOriginReversesImmediatelyOnSameAxis() {
        var trackpad = makeTrackpad()
        XCTAssertEqual(trackpad.update(at: .init(x: 10, y: 0)).direction, .right)

        XCTAssertEqual(trackpad.update(at: .init(x: -10, y: 0)).direction, .left)
    }

    func testStationaryPointKeepsSameCommittedState() {
        var trackpad = makeTrackpad()
        let point = CGPoint(x: 18, y: 0)
        let first = trackpad.update(at: point)

        XCTAssertEqual(trackpad.update(at: point), first)
    }

    func testRepeatIntervalsAreExplicitForEachTier() {
        let trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)

        XCTAssertNil(trackpad.repeatInterval(for: .neutral))
        XCTAssertEqual(trackpad.repeatInterval(for: .one)!, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(trackpad.repeatInterval(for: .two)!, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(trackpad.repeatInterval(for: .three)!, 0.05, accuracy: 0.000_001)
    }

    func testDefaultCadencesMatchPrecisionAndTraversalRoles() {
        let trackpad = GhosttyKeyboardCursorTrackpad()

        XCTAssertEqual(trackpad.repeatInterval(for: .one)!, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(trackpad.repeatInterval(for: .two)!, 0.225, accuracy: 0.000_001)
        XCTAssertEqual(trackpad.repeatInterval(for: .three)!, 0.12, accuracy: 0.000_001)
    }

    func testDefaultGeometryKeepsAllTiersWithinOneHundredTwentyPoints() {
        var trackpad = GhosttyKeyboardCursorTrackpad()
        _ = trackpad.begin(at: .zero)

        XCTAssertEqual(trackpad.update(at: .init(x: 7, y: 0)), .active)
        assertFeedback(
            trackpad.update(at: .init(x: 22, y: 0)),
            direction: .right,
            committedTier: .neutral,
            armingTier: .one,
            armingProgress: 0.5
        )
        XCTAssertEqual(trackpad.update(at: .init(x: 36, y: 0)).committedTier, .one)
        XCTAssertEqual(trackpad.update(at: .init(x: 78, y: 0)).committedTier, .two)
        XCTAssertEqual(trackpad.update(at: .init(x: 120, y: 0)).committedTier, .three)
    }

    @MainActor
    func testDriverDoesNotEmitDuringInitialArming() {
        let harness = DriverHarness(configuration: configuration)
        defer { harness.driver.cancel(owner: harness.owner) }

        let feedback = harness.driver.update(owner: harness.owner, at: .init(x: 6, y: 0), now: 0)

        XCTAssertTrue(harness.keyCodes.isEmpty)
        assertFeedback(
            feedback!,
            direction: .right,
            committedTier: .neutral,
            armingTier: .one,
            armingProgress: 0.5
        )
    }

    @MainActor
    func testDriverRepeatsCommittedDirectionWhileFingerIsStill() {
        let harness = DriverHarness(configuration: configuration)
        defer { harness.driver.cancel(owner: harness.owner) }
        _ = harness.driver.update(owner: harness.owner, at: .init(x: 10, y: 0), now: 0)

        XCTAssertEqual(harness.keyCodes, [.arrowRight])
        harness.driver.repeatTick(at: 0.19)
        XCTAssertEqual(harness.keyCodes, [.arrowRight])
        harness.driver.repeatTick(at: 0.20)
        harness.driver.repeatTick(at: 0.39)
        harness.driver.repeatTick(at: 0.40)

        XCTAssertEqual(harness.keyCodes, [.arrowRight, .arrowRight, .arrowRight])
        XCTAssertEqual(harness.driver.end(owner: harness.owner), true)
    }

    @MainActor
    func testDriverKeepsCurrentRateWhileNextTierIsArming() {
        let harness = DriverHarness(configuration: configuration)
        defer { harness.driver.cancel(owner: harness.owner) }
        _ = harness.driver.update(owner: harness.owner, at: .init(x: 10, y: 0), now: 0)

        let feedback = harness.driver.update(owner: harness.owner, at: .init(x: 18, y: 0), now: 0.1)
        harness.driver.repeatTick(at: 0.20)

        assertFeedback(
            feedback!,
            direction: .right,
            committedTier: .one,
            armingTier: .two,
            armingProgress: 0.5
        )
        XCTAssertEqual(harness.keyCodes, [.arrowRight, .arrowRight])
    }

    @MainActor
    func testDriverUsesFasterCadenceOnlyAfterTierCommits() {
        let harness = DriverHarness(configuration: configuration)
        defer { harness.driver.cancel(owner: harness.owner) }
        _ = harness.driver.update(owner: harness.owner, at: .init(x: 10, y: 0), now: 0)

        _ = harness.driver.update(owner: harness.owner, at: .init(x: 22, y: 0), now: 0.1)
        harness.driver.repeatTick(at: 0.19)
        XCTAssertEqual(harness.keyCodes, [.arrowRight, .arrowRight])
        harness.driver.repeatTick(at: 0.20)

        XCTAssertEqual(harness.keyCodes, [.arrowRight, .arrowRight, .arrowRight])
        XCTAssertEqual(harness.hapticCues, [.tierChanged, .tierChanged])
    }

    @MainActor
    func testDriverDoesNotEmitExtraCommandWhenMovingToSlowerTier() {
        let harness = DriverHarness(configuration: configuration)
        defer { harness.driver.cancel(owner: harness.owner) }
        _ = harness.driver.update(owner: harness.owner, at: .init(x: 22, y: 0), now: 0)
        XCTAssertEqual(harness.keyCodes, [.arrowRight])

        _ = harness.driver.update(owner: harness.owner, at: .init(x: 19, y: 0), now: 0.1)

        XCTAssertEqual(harness.keyCodes, [.arrowRight])
        XCTAssertEqual(harness.hapticCues, [.tierChanged, .tierChanged])
    }

    @MainActor
    func testDriverStopsImmediatelyInsideNeutralZone() {
        let harness = DriverHarness(configuration: configuration)
        defer { harness.driver.cancel(owner: harness.owner) }
        _ = harness.driver.update(owner: harness.owner, at: .init(x: 10, y: 0), now: 0)

        _ = harness.driver.update(owner: harness.owner, at: .init(x: 1, y: 0), now: 0.1)
        harness.driver.repeatTick(at: 1)

        XCTAssertEqual(harness.keyCodes, [.arrowRight])
        XCTAssertEqual(harness.hapticCues, [.tierChanged, .neutralEntered])
    }

    @MainActor
    func testDriverDirectionChangeEmitsNewDirectionAndCancelsOldRepeat() {
        let harness = DriverHarness(configuration: configuration)
        defer { harness.driver.cancel(owner: harness.owner) }
        _ = harness.driver.update(owner: harness.owner, at: .init(x: 10, y: 0), now: 0)

        _ = harness.driver.update(owner: harness.owner, at: .init(x: -10, y: 0), now: 0.1)
        harness.driver.repeatTick(at: 0.299)
        harness.driver.repeatTick(at: 0.301)

        XCTAssertEqual(harness.keyCodes, [.arrowRight, .arrowLeft, .arrowLeft])
    }

    @MainActor
    func testDriverRejectsUpdatesFromAnotherOwner() {
        let harness = DriverHarness(configuration: configuration)
        let otherOwner = NSObject()
        defer { harness.driver.cancel(owner: harness.owner) }

        XCTAssertNil(harness.driver.update(owner: otherOwner, at: .init(x: 10, y: 0)))
        XCTAssertNil(harness.driver.end(owner: otherOwner))
        XCTAssertEqual(harness.driver.end(owner: harness.owner), false)
    }

    @MainActor
    func testDriverCancelsGestureWhenKeyPathRejectsInput() {
        let driver = GhosttyKeyboardCursorTrackpadDriver(configuration: configuration)
        let owner = NSObject()
        var feedback: [GhosttyKeyboardCursorTrackpad.FeedbackState] = []
        var attempts = 0
        driver.begin(
            owner: owner,
            at: .zero,
            sendKeyEvent: { _ in
                attempts += 1
                return false
            },
            onFeedbackChange: { feedback.append($0) }
        )

        _ = driver.update(owner: owner, at: .init(x: 10, y: 0), now: 0)

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(feedback, [.active, .hidden])
        XCTAssertNil(driver.update(owner: owner, at: .init(x: 22, y: 0)))
        XCTAssertNil(driver.end(owner: owner))
    }

    private func makeTrackpad() -> GhosttyKeyboardCursorTrackpad {
        var trackpad = GhosttyKeyboardCursorTrackpad(configuration: configuration)
        trackpad.begin(at: .zero)
        return trackpad
    }

    private func assertFeedback(
        _ feedback: GhosttyKeyboardCursorTrackpad.FeedbackState,
        direction: GhosttyKeyboardCursorTrackpad.Direction,
        committedTier: GhosttyKeyboardCursorTrackpad.SpeedTier,
        armingTier: GhosttyKeyboardCursorTrackpad.SpeedTier? = nil,
        armingProgress: CGFloat = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(feedback.isVisible, file: file, line: line)
        XCTAssertEqual(feedback.direction, direction, file: file, line: line)
        XCTAssertEqual(feedback.committedTier, committedTier, file: file, line: line)
        XCTAssertEqual(feedback.armingTier, armingTier, file: file, line: line)
        XCTAssertEqual(feedback.armingProgress, armingProgress, accuracy: 0.000_001, file: file, line: line)
    }
}

@MainActor
private final class DriverHarness {
    let driver: GhosttyKeyboardCursorTrackpadDriver
    let owner = NSObject()
    let hapticRecorder: HapticRecorder
    private(set) var keyCodes: [GhosttySurfaceKeyEvent.KeyCode] = []

    var hapticCues: [GhosttyKeyboardCursorTrackpadDriver.HapticCue] {
        hapticRecorder.cues
    }

    init(configuration: GhosttyKeyboardCursorTrackpad.Configuration) {
        let hapticRecorder = HapticRecorder()
        self.hapticRecorder = hapticRecorder
        driver = GhosttyKeyboardCursorTrackpadDriver(
            configuration: configuration,
            playHaptic: { [hapticRecorder] cue in
                hapticRecorder.cues.append(cue)
            }
        )
        driver.begin(
            owner: owner,
            at: .zero,
            sendKeyEvent: { [weak self] event in
                self?.keyCodes.append(event.keyCode)
                return true
            },
            onFeedbackChange: { _ in }
        )
    }
}

@MainActor
private final class HapticRecorder {
    var cues: [GhosttyKeyboardCursorTrackpadDriver.HapticCue] = []
}
