import CoreGraphics
import Foundation
import QuartzCore

/// Translates the iOS spacebar long-press / floating-cursor drag into
/// terminal arrow-key emissions. The further the user has pushed past the
/// initial axis lock, the denser the emissions become — distance-based
/// cursor acceleration along the locked axis, modeled as a continuous ramp
/// rather than discrete slow/fast modes, so the gesture reads as continuous
/// analog cursor steering instead of a stepped gear shifter.
struct GhosttyKeyboardCursorTrackpad: Equatable {
    struct Configuration: Equatable {
        var horizontalStep: CGFloat
        var verticalStep: CGFloat
        var lockDeadband: CGFloat
        var lateSwitchRatio: CGFloat
        var rampStartDisplacement: CGFloat
        var rampEndDisplacement: CGFloat
        var maxAccelMultiplier: CGFloat
        var maxStepsPerUpdate: Int

        static let `default` = Configuration(
            horizontalStep: 10,
            verticalStep: 18,
            lockDeadband: 12,
            lateSwitchRatio: 3,
            rampStartDisplacement: 30,
            rampEndDisplacement: 100,
            maxAccelMultiplier: 3,
            maxStepsPerUpdate: 6
        )
    }

    enum Direction: Equatable {
        case left
        case right
        case up
        case down
    }

    enum Axis: Equatable {
        case horizontal
        case vertical
    }

    struct Step: Equatable {
        let direction: Direction
        let intensity: CGFloat
    }

    struct HUDState: Equatable {
        var activeDirection: Direction?
        var intensity: CGFloat
        var isVisible: Bool

        static let hidden = HUDState(activeDirection: nil, intensity: 0, isVisible: false)
    }

    struct UpdateOutcome: Equatable {
        var steps: [Step]
        var hud: HUDState
        var didLockAxis: Bool
    }

    let configuration: Configuration

    private var previousPoint: CGPoint?
    private var lockedAxis: Axis?
    private var preLockAccX: CGFloat = 0
    private var preLockAccY: CGFloat = 0
    private var stepAcc: CGFloat = 0
    private var rawSinceLockLocked: CGFloat = 0
    private var rawSinceLockOrtho: CGFloat = 0
    private var axisDisplacement: CGFloat = 0

    init(configuration: Configuration = .default) {
        precondition(configuration.horizontalStep > 0, "horizontalStep must be positive")
        precondition(configuration.verticalStep > 0, "verticalStep must be positive")
        precondition(configuration.lockDeadband > 0, "lockDeadband must be positive")
        precondition(configuration.lateSwitchRatio > 0, "lateSwitchRatio must be positive")
        precondition(configuration.maxAccelMultiplier >= 1, "maxAccelMultiplier must be >= 1 (1x = no acceleration)")
        precondition(configuration.maxStepsPerUpdate > 0, "maxStepsPerUpdate must be positive")
        precondition(
            configuration.rampStartDisplacement >= 0,
            "rampStartDisplacement must be non-negative"
        )
        precondition(
            configuration.rampEndDisplacement > configuration.rampStartDisplacement,
            "rampEndDisplacement must exceed rampStartDisplacement so the intensity ramp has positive width"
        )
        self.configuration = configuration
    }

    mutating func begin(at point: CGPoint) -> HUDState {
        previousPoint = point
        lockedAxis = nil
        preLockAccX = 0
        preLockAccY = 0
        stepAcc = 0
        rawSinceLockLocked = 0
        rawSinceLockOrtho = 0
        axisDisplacement = 0
        return HUDState(activeDirection: nil, intensity: 0, isVisible: true)
    }

    mutating func end() -> HUDState {
        previousPoint = nil
        lockedAxis = nil
        preLockAccX = 0
        preLockAccY = 0
        stepAcc = 0
        rawSinceLockLocked = 0
        rawSinceLockOrtho = 0
        axisDisplacement = 0
        return .hidden
    }

    mutating func update(at point: CGPoint) -> UpdateOutcome {
        guard let previous = previousPoint else {
            previousPoint = point
            return UpdateOutcome(
                steps: [],
                hud: HUDState(activeDirection: nil, intensity: 0, isVisible: true),
                didLockAxis: false
            )
        }

        let dx = point.x - previous.x
        let dy = point.y - previous.y
        previousPoint = point

        if lockedAxis == nil {
            preLockAccX += dx
            preLockAccY += dy
            guard max(abs(preLockAccX), abs(preLockAccY)) > configuration.lockDeadband else {
                return UpdateOutcome(
                    steps: [],
                    hud: HUDState(activeDirection: nil, intensity: 0, isVisible: true),
                    didLockAxis: false
                )
            }

            lockedAxis = abs(preLockAccX) >= abs(preLockAccY) ? .horizontal : .vertical
            stepAcc = 0
            rawSinceLockLocked = 0
            rawSinceLockOrtho = 0
            axisDisplacement = 0
            preLockAccX = 0
            preLockAccY = 0
            return UpdateOutcome(
                steps: [],
                hud: HUDState(activeDirection: nil, intensity: 0, isVisible: true),
                didLockAxis: true
            )
        }

        var axis = lockedAxis ?? .horizontal
        var lockedDelta = (axis == .horizontal) ? dx : dy
        var orthDelta = (axis == .horizontal) ? dy : dx
        rawSinceLockLocked += lockedDelta
        rawSinceLockOrtho += orthDelta

        var didLockAxis = false
        // Require *both* a meaningful absolute orthogonal commitment (at least
        // the lock deadband, same threshold the user crossed to lock the axis
        // in the first place) AND the ratio dominance check. Without the
        // absolute floor a 1pt orthogonal wobble immediately after lock satisfies
        // the ratio against an effectively-zero locked travel and flips axes
        // on a single pixel of jitter.
        let orthogonalCommitted = abs(rawSinceLockOrtho) >= configuration.lockDeadband
        let orthogonalDominant = abs(rawSinceLockOrtho) > configuration.lateSwitchRatio * abs(rawSinceLockLocked)
        if orthogonalCommitted && orthogonalDominant {
            axis = (axis == .horizontal) ? .vertical : .horizontal
            lockedAxis = axis
            stepAcc = 0
            axisDisplacement = 0
            rawSinceLockLocked = orthDelta
            rawSinceLockOrtho = lockedDelta
            lockedDelta = (axis == .horizontal) ? dx : dy
            orthDelta = (axis == .horizontal) ? dy : dx
            didLockAxis = true
        }

        axisDisplacement += lockedDelta
        stepAcc += lockedDelta

        let intensity = computeIntensity(displacement: axisDisplacement)
        let multiplier = 1.0 + intensity * (configuration.maxAccelMultiplier - 1.0)
        let baseStep = (axis == .horizontal) ? configuration.horizontalStep : configuration.verticalStep
        let effectiveStep = baseStep / multiplier
        let heldDirection = abs(axisDisplacement) >= baseStep
            ? directionFor(axis: axis, signedAccumulator: axisDisplacement)
            : nil

        var steps: [Step] = []
        let count = Int(abs(stepAcc) / effectiveStep)
        if count > 0 {
            let direction: Direction = directionFor(axis: axis, signedAccumulator: stepAcc)
            let bounded = min(count, configuration.maxStepsPerUpdate)
            for _ in 0..<bounded {
                steps.append(Step(direction: direction, intensity: intensity))
            }
            // Consume only what we emitted. Any backlog from a coalesced UIKit
            // update rolls into the next callback rather than being silently
            // dropped; cursor density per pt of finger travel stays consistent
            // regardless of how UIKit chunks the floating-cursor stream.
            let consumed = CGFloat(bounded) * effectiveStep
            stepAcc = stepAcc > 0 ? stepAcc - consumed : stepAcc + consumed
        }

        return UpdateOutcome(
            steps: steps,
            hud: HUDState(
                activeDirection: heldDirection,
                intensity: intensity,
                isVisible: true
            ),
            didLockAxis: didLockAxis
        )
    }

    private func computeIntensity(displacement: CGFloat) -> CGFloat {
        let span = configuration.rampEndDisplacement - configuration.rampStartDisplacement
        let raw = (abs(displacement) - configuration.rampStartDisplacement) / span
        return max(0, min(1, raw))
    }

    private func directionFor(axis: Axis, signedAccumulator: CGFloat) -> Direction {
        switch axis {
        case .horizontal:
            return signedAccumulator >= 0 ? .right : .left
        case .vertical:
            return signedAccumulator >= 0 ? .down : .up
        }
    }
}

/// Owns the one clock used by held cursor-steering gestures. Movement remains
/// synchronous: the trackpad's immediate steps are sent from `update`. The
/// repeating timer exists only while a direction is held, and adds one repeated
/// arrow at a time after the initial delay.
@MainActor
final class GhosttyKeyboardCursorTrackpadDriver {
    static let initialRepeatDelay: TimeInterval = 0.30
    static let slowRepeatInterval: TimeInterval = 0.18
    static let mediumRepeatInterval: TimeInterval = 0.10
    static let fastRepeatInterval: TimeInterval = 0.06

    private struct RepeatState {
        var direction: GhosttyKeyboardCursorTrackpad.Direction
        var interval: TimeInterval
        var nextFireAt: TimeInterval
    }

    private weak var owner: AnyObject?
    private var trackpad: GhosttyKeyboardCursorTrackpad?
    private var sendKeyEvent: ((GhosttySurfaceKeyEvent) -> Bool)?
    private var publishHUD: ((GhosttyKeyboardCursorTrackpad.HUDState) -> Void)?
    private var repeatState: RepeatState?
    private var repeatTimer: Timer?
    private var didSteer = false

    var isRepeatScheduled: Bool { repeatTimer != nil }

    func begin(
        owner: AnyObject,
        at point: CGPoint,
        sendKeyEvent: @escaping (GhosttySurfaceKeyEvent) -> Bool,
        onHUDStateChange: @escaping (GhosttyKeyboardCursorTrackpad.HUDState) -> Void
    ) {
        cancelCurrentGesture()

        var trackpad = GhosttyKeyboardCursorTrackpad()
        let hud = trackpad.begin(at: point)
        self.owner = owner
        self.trackpad = trackpad
        self.sendKeyEvent = sendKeyEvent
        publishHUD = onHUDStateChange
        didSteer = false
        onHUDStateChange(hud)
        Haptic.tap(.soft)
    }

    func update(
        owner: AnyObject,
        at point: CGPoint,
        now: TimeInterval = CACurrentMediaTime()
    ) -> GhosttyKeyboardCursorTrackpad.UpdateOutcome? {
        guard self.owner === owner, var trackpad else { return nil }

        let outcome = trackpad.update(at: point)
        self.trackpad = trackpad

        for step in outcome.steps {
            didSteer = true
            guard send(direction: step.direction) else {
                rejectCurrentGesture()
                return outcome
            }
        }

        if outcome.didLockAxis {
            Haptic.selection()
        }
        publishHUD?(outcome.hud)
        updateRepeat(for: outcome.hud, now: now)
        return outcome
    }

    /// Returns whether this gesture sent or attempted any steering key. A
    /// non-owner gets `nil`, allowing another gesture entry point to decide
    /// whether a stationary release should begin text selection.
    @discardableResult
    func end(owner: AnyObject) -> Bool? {
        guard self.owner === owner else { return nil }
        let result = didSteer
        cancelCurrentGesture()
        return result
    }

    @discardableResult
    func cancel(owner: AnyObject) -> Bool {
        guard self.owner === owner else { return false }
        cancelCurrentGesture()
        return true
    }

    /// Internal time injection keeps repeat timing deterministic in tests.
    func repeatTick(at now: TimeInterval) {
        guard let nextFireAt = repeatState?.nextFireAt, now >= nextFireAt else { return }
        emitRepeat(at: now)
    }

    private func emitRepeat(at now: TimeInterval) {
        guard owner != nil else {
            cancelCurrentGesture()
            return
        }
        guard var state = repeatState else { return }

        didSteer = true
        guard send(direction: state.direction) else {
            rejectCurrentGesture()
            return
        }

        // Never catch up after a delayed frame. One tick sends at most one key
        // and the next deadline is measured from the actual send time.
        state.nextFireAt = now + state.interval
        repeatState = state
    }

    private func updateRepeat(
        for hud: GhosttyKeyboardCursorTrackpad.HUDState,
        now: TimeInterval
    ) {
        guard let direction = hud.activeDirection else {
            stopRepeating()
            return
        }

        let interval = repeatInterval(for: hud.intensity)
        if var state = repeatState, state.direction == direction {
            if state.interval != interval {
                state.interval = interval
                state.nextFireAt = now + interval
                repeatState = state
                scheduleRepeat(every: interval, firstFireAfter: interval)
            }
        } else {
            repeatState = RepeatState(
                direction: direction,
                interval: interval,
                nextFireAt: now + Self.initialRepeatDelay
            )
            scheduleRepeat(every: interval, firstFireAfter: Self.initialRepeatDelay)
        }
    }

    private func send(direction: GhosttyKeyboardCursorTrackpad.Direction) -> Bool {
        sendKeyEvent?(GhosttySurfaceKeyEvent(keyCode: direction.keyCode)) == true
    }

    private func rejectCurrentGesture() {
        trackpad = nil
        stopRepeating()
        publishHUD?(.hidden)
    }

    private func cancelCurrentGesture() {
        trackpad = nil
        stopRepeating()
        if owner != nil {
            publishHUD?(.hidden)
        }
        owner = nil
        sendKeyEvent = nil
        publishHUD = nil
        didSteer = false
    }

    private func repeatInterval(for intensity: CGFloat) -> TimeInterval {
        if intensity >= 1 { return Self.fastRepeatInterval }
        if intensity > 0 { return Self.mediumRepeatInterval }
        return Self.slowRepeatInterval
    }

    private func scheduleRepeat(every interval: TimeInterval, firstFireAfter delay: TimeInterval) {
        repeatTimer?.invalidate()
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(repeatTimerFired),
            userInfo: nil,
            repeats: true
        )
        timer.fireDate = Date(timeIntervalSinceNow: delay)
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopRepeating() {
        repeatState = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    @objc private func repeatTimerFired() {
        emitRepeat(at: CACurrentMediaTime())
        if let interval = repeatState?.interval {
            repeatTimer?.fireDate = Date(timeIntervalSinceNow: interval)
        }
    }
}

private extension GhosttyKeyboardCursorTrackpad.Direction {
    var keyCode: GhosttySurfaceKeyEvent.KeyCode {
        switch self {
        case .up: .arrowUp
        case .down: .arrowDown
        case .left: .arrowLeft
        case .right: .arrowRight
        }
    }
}
