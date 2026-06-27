import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyTerminalDebugLatencyProbeControllerTests: XCTestCase {
    func testDebugLatencyProbeBuildsInputMarkerWithoutEchoingFullMarker() {
        var probe = DebugLatencyProbeCommand(action: .input, probeID: "abc-123")
        let submission = probe.nextSubmission(isInputAvailable: true)

        XCTAssertEqual(submission?.action, .input)
        XCTAssertEqual(submission?.marker, "__REMUX_LATENCY_abc123__")
        XCTAssertEqual(submission?.text, "printf __REMUX_%s__ LATENCY_abc123\r")
        XCTAssertFalse(submission?.text?.contains("__REMUX_LATENCY_abc123__") ?? true)
        XCTAssertNil(probe.nextSubmission(isInputAvailable: true))
    }

    func testDebugLatencyProbeBuildsKeyEchoMarker() {
        var probe = DebugLatencyProbeCommand(action: .keyEcho, probeID: "abc-123")
        let submission = probe.nextSubmission(isInputAvailable: true)

        XCTAssertEqual(submission?.action, .keyEcho)
        XCTAssertEqual(submission?.marker, String(UnicodeScalar(0x00A7)!))
        XCTAssertEqual(submission?.text, String(UnicodeScalar(0x00A7)!))
        XCTAssertNil(probe.nextSubmission(isInputAvailable: true))
    }

    func testDebugLatencyProbeParsesActionAliases() {
        var input = DebugLatencyProbeCommand("1", probeID: "a")
        var keyEcho = DebugLatencyProbeCommand("key-echo", probeID: "a")
        var splitRight = DebugLatencyProbeCommand("split-right", probeID: "a")
        var splitDown = DebugLatencyProbeCommand("down", probeID: "a")
        var newWindow = DebugLatencyProbeCommand("window", probeID: "a")

        XCTAssertEqual(input?.nextSubmission(isInputAvailable: true)?.action, .input)
        XCTAssertEqual(keyEcho?.nextSubmission(isInputAvailable: true)?.action, .keyEcho)
        XCTAssertEqual(splitRight?.nextSubmission(isInputAvailable: true)?.action, .splitRight)
        XCTAssertEqual(splitDown?.nextSubmission(isInputAvailable: true)?.action, .splitDown)
        XCTAssertEqual(newWindow?.nextSubmission(isInputAvailable: true)?.action, .newWindow)
        XCTAssertNil(DebugLatencyProbeCommand("unknown", probeID: "a"))
    }

    func testDebugLatencyProbeReadsDelayFromEnvironment() {
        let probe = DebugLatencyProbeCommand.fromEnvironment([
            "REMUX_DEBUG_LATENCY_PROBE": "input",
            "REMUX_DEBUG_LATENCY_PROBE_DELAY_MS": "2500",
        ])

        XCTAssertEqual(probe?.delayMilliseconds, 2500)
    }

    func testControllerDoesNotSubmitBeforeDelayIsSatisfied() {
        let harness = DelayHarness()
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: .input, probeID: "abc", delayMilliseconds: 100),
            delayScheduler: harness.scheduler
        )
        var inputs: [String] = []

        XCTAssertNil(submit(controller, inputs: &inputs))
        XCTAssertTrue(
            controller.scheduleIfNeeded(
                readiness: Self.readinessSnapshot(phase: .running),
                onDelaySatisfied: {}
            )
        )
        XCTAssertNil(submit(controller, inputs: &inputs))

        harness.fireNext()

        XCTAssertEqual(submit(controller, inputs: &inputs)?.statusMessage, "debug latency input probe sent")
        XCTAssertEqual(inputs, ["printf __REMUX_%s__ LATENCY_abc\r"])
    }

    func testControllerSchedulesDelayOnlyOnce() {
        let harness = DelayHarness()
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: .input, delayMilliseconds: 100),
            delayScheduler: harness.scheduler
        )

        XCTAssertTrue(
            controller.scheduleIfNeeded(
                readiness: Self.readinessSnapshot(phase: .running),
                onDelaySatisfied: {}
            )
        )
        XCTAssertFalse(
            controller.scheduleIfNeeded(
                readiness: Self.readinessSnapshot(phase: .running),
                onDelaySatisfied: {}
            )
        )
        XCTAssertEqual(harness.scheduledDelayMilliseconds, [100])
    }

    func testControllerSchedulesProbeWhenRuntimeIsRunningRegardlessOfFocusTransportOrPanes() {
        let harness = DelayHarness()
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: .input, delayMilliseconds: 100),
            delayScheduler: harness.scheduler
        )

        XCTAssertTrue(
            controller.scheduleIfNeeded(
                readiness: Self.readinessSnapshot(
                    phase: .running,
                    transportWritable: false,
                    topLevelCount: 0,
                    focused: false
                ),
                onDelaySatisfied: {}
            )
        )
        XCTAssertEqual(harness.scheduledDelayMilliseconds, [100])
    }

    func testControllerDoesNotScheduleProbeBeforeRuntimeIsRunningOrAfterFailure() {
        let phases: [GhosttyTerminalRuntimePhase] = [
            .idle,
            .starting,
            .failed(message: "failed", reason: nil),
        ]

        for phase in phases {
            let harness = DelayHarness()
            let controller = GhosttyTerminalDebugLatencyProbeController(
                probe: DebugLatencyProbeCommand(action: .input, delayMilliseconds: 100),
                delayScheduler: harness.scheduler
            )

            XCTAssertFalse(
                controller.scheduleIfNeeded(
                    readiness: Self.readinessSnapshot(phase: phase),
                    onDelaySatisfied: {}
                )
            )
            XCTAssertTrue(harness.scheduledDelayMilliseconds.isEmpty)
        }
    }

    func testControllerCancelInvalidatesPendingDelayCompletion() {
        let harness = DelayHarness()
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: .input, delayMilliseconds: 100),
            delayScheduler: harness.scheduler
        )
        var delaySatisfiedCount = 0
        var inputs: [String] = []

        XCTAssertTrue(
            controller.scheduleIfNeeded(readiness: Self.readinessSnapshot(phase: .running)) {
                delaySatisfiedCount += 1
            }
        )
        controller.cancel()
        harness.fireNext()

        XCTAssertEqual(delaySatisfiedCount, 0)
        XCTAssertNil(submit(controller, inputs: &inputs))
        XCTAssertTrue(inputs.isEmpty)
    }

    func testControllerZeroDelayIsReadyWithoutSchedulingTask() {
        let harness = DelayHarness()
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: .input, probeID: "abc", delayMilliseconds: 0),
            delayScheduler: harness.scheduler
        )
        var inputs: [String] = []

        XCTAssertTrue(
            controller.scheduleIfNeeded(
                readiness: Self.readinessSnapshot(phase: .running),
                onDelaySatisfied: {}
            )
        )
        XCTAssertTrue(harness.scheduledDelayMilliseconds.isEmpty)
        XCTAssertEqual(submit(controller, inputs: &inputs)?.statusMessage, "debug latency input probe sent")
        XCTAssertEqual(inputs, ["printf __REMUX_%s__ LATENCY_abc\r"])
    }

    func testRejectedInputProbeCanRetry() {
        let controller = readyController(action: .input, probeID: "abc")
        var inputs: [String] = []

        _ = submit(controller, inputs: &inputs, inputResult: .surfaceRejected)
        _ = submit(controller, inputs: &inputs)

        XCTAssertEqual(
            inputs,
            [
                "printf __REMUX_%s__ LATENCY_abc\r",
                "printf __REMUX_%s__ LATENCY_abc\r",
            ]
        )
    }

    func testKeyEchoSendsControlUOnlyAfterAcceptedMarkerInput() {
        let acceptedController = readyController(action: .keyEcho, probeID: "abc")
        var acceptedInputs: [String] = []

        XCTAssertEqual(
            submit(acceptedController, inputs: &acceptedInputs)?.statusMessage,
            "debug latency key echo probe sent"
        )
        XCTAssertEqual(acceptedInputs, [String(UnicodeScalar(0x00A7)!), "\u{15}"])

        let rejectedController = readyController(action: .keyEcho, probeID: "abc")
        var rejectedInputs: [String] = []

        XCTAssertNil(
            submit(rejectedController, inputs: &rejectedInputs, inputResult: .surfaceRejected)?.statusMessage
        )
        XCTAssertEqual(rejectedInputs, [String(UnicodeScalar(0x00A7)!)])
    }

    func testSplitAndNewWindowRearmWhenNotQueued() {
        let splitController = readyController(action: .splitRight)
        var splitCount = 0

        _ = splitController.submitIfReady(
            readiness: Self.readinessSnapshot(phase: .running, focused: true),
            sendInput: { _ in .accepted },
            split: { _ in
                splitCount += 1
                return .missingTarget(.focusedPane)
            },
            newWindow: { .queued }
        )
        _ = splitController.submitIfReady(
            readiness: Self.readinessSnapshot(phase: .running, focused: true),
            sendInput: { _ in .accepted },
            split: { _ in
                splitCount += 1
                return .queued
            },
            newWindow: { .queued }
        )

        XCTAssertEqual(splitCount, 2)

        let newWindowController = readyController(action: .newWindow)
        var newWindowCount = 0

        _ = newWindowController.submitIfReady(
            readiness: Self.readinessSnapshot(phase: .running, focused: true),
            sendInput: { _ in .accepted },
            split: { _ in .queued },
            newWindow: {
                newWindowCount += 1
                return .missingTarget(.host)
            }
        )
        _ = newWindowController.submitIfReady(
            readiness: Self.readinessSnapshot(phase: .running, focused: true),
            sendInput: { _ in .accepted },
            split: { _ in .queued },
            newWindow: {
                newWindowCount += 1
                return .queued
            }
        )

        XCTAssertEqual(newWindowCount, 2)
    }

    func testNoSubmissionWhenNotRunningOrNoFocusedSurface() {
        let controller = readyController(action: .input)
        var inputs: [String] = []

        XCTAssertNil(
            submit(
                controller,
                readiness: Self.readinessSnapshot(phase: .starting, focused: true),
                inputs: &inputs
            )
        )
        XCTAssertNil(
            submit(
                controller,
                readiness: Self.readinessSnapshot(phase: .running, focused: false),
                inputs: &inputs
            )
        )
        XCTAssertTrue(inputs.isEmpty)
    }

    func testSubmissionUsesInputAvailabilityWithoutTransportOrPaneCount() {
        let controller = readyController(action: .input, probeID: "abc")
        var inputs: [String] = []

        XCTAssertEqual(
            submit(
                controller,
                readiness: Self.readinessSnapshot(
                    phase: .running,
                    transportWritable: false,
                    topLevelCount: 0,
                    focused: true
                ),
                inputs: &inputs
            )?.statusMessage,
            "debug latency input probe sent"
        )
        XCTAssertEqual(inputs, ["printf __REMUX_%s__ LATENCY_abc\r"])
    }

    private func readyController(
        action: DebugLatencyProbeCommand.Action,
        probeID: String = "abc"
    ) -> GhosttyTerminalDebugLatencyProbeController {
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: action, probeID: probeID)
        )
        _ = controller.scheduleIfNeeded(
            readiness: Self.readinessSnapshot(phase: .running),
            onDelaySatisfied: {}
        )
        return controller
    }

    private func submit(
        _ controller: GhosttyTerminalDebugLatencyProbeController,
        readiness: TerminalReadinessSnapshot? = nil,
        inputs: inout [String],
        inputResult: FocusedTerminalInputSubmissionResult = .accepted
    ) -> GhosttyTerminalDebugLatencyProbeController.SubmissionResult? {
        controller.submitIfReady(
            readiness: readiness ?? Self.readinessSnapshot(phase: .running, focused: true),
            sendInput: { text in
                inputs.append(text)
                return inputResult
            },
            split: { _ in .queued },
            newWindow: { .queued }
        )
    }

    private static func readinessSnapshot(
        phase: GhosttyTerminalRuntimePhase,
        transportWritable: Bool = true,
        topLevelCount: Int = 1,
        focused: Bool = true
    ) -> TerminalReadinessSnapshot {
        TerminalReadinessProjector.snapshot(
            phase: phase,
            transportWritable: transportWritable,
            topLevelCount: topLevelCount,
            selectedActiveLeafID: focused ? UUID() : nil
        )
    }
}

@MainActor
private final class DelayHarness {
    private var completions: [@MainActor () -> Void] = []
    private(set) var scheduledDelayMilliseconds: [Int64] = []

    func scheduler(
        delayMilliseconds: Int64,
        onDelaySatisfied: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        scheduledDelayMilliseconds.append(delayMilliseconds)
        completions.append(onDelaySatisfied)
        return Task {}
    }

    func fireNext() {
        guard !completions.isEmpty else { return }
        completions.removeFirst()()
    }
}
