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
        var showWindows = DebugLatencyProbeCommand("show-windows", probeID: "a")
        var showPanes = DebugLatencyProbeCommand("panes", probeID: "a")
        var showWindowsDismiss = DebugLatencyProbeCommand("windows-dismiss", probeID: "a")
        var showPanesDismiss = DebugLatencyProbeCommand("show-panes-dismiss", probeID: "a")
        var selectWindow = DebugLatencyProbeCommand("select-window", probeID: "a")
        var selectPane = DebugLatencyProbeCommand("select-pane", probeID: "a")
        var closeWindow = DebugLatencyProbeCommand("close-window", probeID: "a")
        var closePane = DebugLatencyProbeCommand("close-pane", probeID: "a")

        XCTAssertEqual(input?.nextSubmission(isInputAvailable: true)?.action, .input)
        XCTAssertEqual(keyEcho?.nextSubmission(isInputAvailable: true)?.action, .keyEcho)
        XCTAssertEqual(splitRight?.nextSubmission(isInputAvailable: true)?.action, .splitRight)
        XCTAssertEqual(splitDown?.nextSubmission(isInputAvailable: true)?.action, .splitDown)
        XCTAssertEqual(newWindow?.nextSubmission(isInputAvailable: true)?.action, .newWindow)
        XCTAssertEqual(showWindows?.nextSubmission(isInputAvailable: true)?.action, .showWindows)
        XCTAssertEqual(showPanes?.nextSubmission(isInputAvailable: true)?.action, .showPanes)
        XCTAssertEqual(showWindowsDismiss?.nextSubmission(isInputAvailable: true)?.action, .showWindowsDismiss)
        XCTAssertEqual(showPanesDismiss?.nextSubmission(isInputAvailable: true)?.action, .showPanesDismiss)
        XCTAssertEqual(selectWindow?.nextSubmission(isInputAvailable: true)?.action, .selectWindow)
        XCTAssertEqual(selectPane?.nextSubmission(isInputAvailable: true)?.action, .selectPane)
        XCTAssertEqual(closeWindow?.nextSubmission(isInputAvailable: true)?.action, .closeWindow)
        XCTAssertEqual(closePane?.nextSubmission(isInputAvailable: true)?.action, .closePane)
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

    func testUpdateSubmitsImmediatelyWhenDelayIsZero() {
        let harness = DelayHarness()
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: .input, probeID: "abc", delayMilliseconds: 0),
            delayScheduler: harness.scheduler
        )
        var inputs: [String] = []

        XCTAssertEqual(
            update(controller, inputs: &inputs)?.statusMessage,
            "debug latency input probe sent"
        )
        XCTAssertTrue(harness.scheduledDelayMilliseconds.isEmpty)
        XCTAssertEqual(inputs, ["printf __REMUX_%s__ LATENCY_abc\r"])
    }

    func testUpdateSchedulesThenSubmitsAfterDelayCallback() {
        let harness = DelayHarness()
        let controller = GhosttyTerminalDebugLatencyProbeController(
            probe: DebugLatencyProbeCommand(action: .input, probeID: "abc", delayMilliseconds: 100),
            delayScheduler: harness.scheduler
        )
        var delayCallbackCount = 0
        var inputs: [String] = []

        XCTAssertNil(
            update(controller, inputs: &inputs) {
                delayCallbackCount += 1
            }
        )
        XCTAssertEqual(harness.scheduledDelayMilliseconds, [100])
        XCTAssertTrue(inputs.isEmpty)

        harness.fireNext()

        XCTAssertEqual(delayCallbackCount, 1)
        XCTAssertEqual(
            update(controller, inputs: &inputs)?.statusMessage,
            "debug latency input probe sent"
        )
        XCTAssertEqual(inputs, ["printf __REMUX_%s__ LATENCY_abc\r"])
    }

    func testRejectedInputProbeCanRetry() {
        let controller = readyController(action: .input, probeID: "abc")
        var inputs: [String] = []

        let rejected = submit(controller, inputs: &inputs, inputResult: .surfaceRejected)
        let accepted = submit(controller, inputs: &inputs)

        XCTAssertTrue(rejected?.shouldRetry == true)
        XCTAssertTrue(accepted?.shouldRetry == false)
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

        let rejected = submit(rejectedController, inputs: &rejectedInputs, inputResult: .surfaceRejected)
        XCTAssertNil(rejected?.statusMessage)
        XCTAssertTrue(rejected?.shouldRetry == true)
        XCTAssertEqual(rejectedInputs, [String(UnicodeScalar(0x00A7)!)])
    }

    func testRejectedTopologyAndSheetActionsCanRetry() {
        let cases: [(String, DebugLatencyProbeCommand.Action, (Bool, @escaping () -> Void) -> ProbeSubmitOverrides)] = [
            ("splitRight", .splitRight, { accepted, recordAttempt in
                ProbeSubmitOverrides(split: { _ in
                    recordAttempt()
                    return accepted ? .queued : .missingTarget(.focusedPane)
                })
            }),
            ("splitDown", .splitDown, { accepted, recordAttempt in
                ProbeSubmitOverrides(split: { _ in
                    recordAttempt()
                    return accepted ? .queued : .missingTarget(.focusedPane)
                })
            }),
            ("newWindow", .newWindow, { accepted, recordAttempt in
                ProbeSubmitOverrides(newWindow: {
                    recordAttempt()
                    return accepted ? .queued : .missingTarget(.host)
                })
            }),
            ("showWindows", .showWindows, { accepted, recordAttempt in
                ProbeSubmitOverrides(showWindows: {
                    recordAttempt()
                    return accepted
                })
            }),
            ("showPanes", .showPanes, { accepted, recordAttempt in
                ProbeSubmitOverrides(showPanes: {
                    recordAttempt()
                    return accepted
                })
            }),
            ("showWindowsDismiss", .showWindowsDismiss, { accepted, recordAttempt in
                ProbeSubmitOverrides(showWindowsThenDismiss: {
                    recordAttempt()
                    return accepted
                })
            }),
            ("showPanesDismiss", .showPanesDismiss, { accepted, recordAttempt in
                ProbeSubmitOverrides(showPanesThenDismiss: {
                    recordAttempt()
                    return accepted
                })
            }),
            ("selectWindow", .selectWindow, { accepted, recordAttempt in
                ProbeSubmitOverrides(selectWindow: {
                    recordAttempt()
                    return accepted
                })
            }),
            ("selectPane", .selectPane, { accepted, recordAttempt in
                ProbeSubmitOverrides(selectPane: {
                    recordAttempt()
                    return accepted
                })
            }),
            ("closeWindow", .closeWindow, { accepted, recordAttempt in
                ProbeSubmitOverrides(closeWindow: {
                    recordAttempt()
                    return accepted
                })
            }),
            ("closePane", .closePane, { accepted, recordAttempt in
                ProbeSubmitOverrides(closePane: {
                    recordAttempt()
                    return accepted
                })
            }),
        ]

        for (name, action, overrides) in cases {
            let controller = readyController(action: action)
            var attempts = 0

            _ = submitAction(
                controller,
                overrides: overrides(false) {
                    attempts += 1
                }
            )
            _ = submitAction(
                controller,
                overrides: overrides(true) {
                    attempts += 1
                }
            )

            XCTAssertEqual(attempts, 2, name)
        }
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
            newWindow: { .queued },
            showWindows: { true },
            showPanes: { true },
            showWindowsThenDismiss: { true },
            showPanesThenDismiss: { true }
        )
    }

    private func update(
        _ controller: GhosttyTerminalDebugLatencyProbeController,
        readiness: TerminalReadinessSnapshot? = nil,
        inputs: inout [String],
        inputResult: FocusedTerminalInputSubmissionResult = .accepted,
        onDelaySatisfied: @escaping @MainActor () -> Void = {}
    ) -> GhosttyTerminalDebugLatencyProbeController.SubmissionResult? {
        controller.update(
            readiness: readiness ?? Self.readinessSnapshot(phase: .running, focused: true),
            onDelaySatisfied: onDelaySatisfied,
            sendInput: { text in
                inputs.append(text)
                return inputResult
            },
            split: { _ in .queued },
            newWindow: { .queued },
            showWindows: { true },
            showPanes: { true },
            showWindowsThenDismiss: { true },
            showPanesThenDismiss: { true }
        )
    }

    private func submitAction(
        _ controller: GhosttyTerminalDebugLatencyProbeController,
        overrides: ProbeSubmitOverrides
    ) -> GhosttyTerminalDebugLatencyProbeController.SubmissionResult? {
        controller.submitIfReady(
            readiness: Self.readinessSnapshot(phase: .running, focused: true),
            sendInput: { _ in .accepted },
            split: overrides.split ?? { _ in .queued },
            newWindow: overrides.newWindow ?? { .queued },
            showWindows: overrides.showWindows ?? { true },
            showPanes: overrides.showPanes ?? { true },
            showWindowsThenDismiss: overrides.showWindowsThenDismiss ?? { true },
            showPanesThenDismiss: overrides.showPanesThenDismiss ?? { true },
            selectWindow: overrides.selectWindow ?? { true },
            selectPane: overrides.selectPane ?? { true },
            closeWindow: overrides.closeWindow ?? { true },
            closePane: overrides.closePane ?? { true }
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

private struct ProbeSubmitOverrides {
    var split: (@MainActor (ghostty_action_split_direction_e) -> GhosttyTmuxModelActionOutcome)?
    var newWindow: (@MainActor () -> GhosttyTmuxModelActionOutcome)?
    var showWindows: (@MainActor () -> Bool)?
    var showPanes: (@MainActor () -> Bool)?
    var showWindowsThenDismiss: (@MainActor () -> Bool)?
    var showPanesThenDismiss: (@MainActor () -> Bool)?
    var selectWindow: (@MainActor () -> Bool)?
    var selectPane: (@MainActor () -> Bool)?
    var closeWindow: (@MainActor () -> Bool)?
    var closePane: (@MainActor () -> Bool)?
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
