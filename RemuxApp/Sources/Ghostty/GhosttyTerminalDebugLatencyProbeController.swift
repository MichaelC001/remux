import Foundation
import GhosttyKit

@MainActor
final class GhosttyTerminalDebugLatencyProbeController {
    struct SubmissionResult: Equatable {
        let statusMessage: String?
        let didSubmit: Bool
        let shouldRetry: Bool
    }

    typealias DelayScheduler = @MainActor (
        _ delayMilliseconds: Int64,
        _ onDelaySatisfied: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>

    private var probe: DebugLatencyProbeCommand?
    private var delaySatisfied = false
    private var delayTask: Task<Void, Never>?
    private var delayGeneration: UInt64 = 0
    private let delayScheduler: DelayScheduler

    init(
        probe: DebugLatencyProbeCommand?,
        delayScheduler: @escaping DelayScheduler = GhosttyTerminalDebugLatencyProbeController.defaultDelayScheduler
    ) {
        self.probe = probe
        self.delayScheduler = delayScheduler
    }

    @discardableResult
    func update(
        readiness: TerminalReadinessSnapshot,
        onDelaySatisfied: @escaping @MainActor () -> Void,
        sendInput: @MainActor (String) -> FocusedTerminalInputSubmissionResult,
        split: @MainActor (ghostty_action_split_direction_e) -> GhosttyTmuxModelActionOutcome,
        newWindow: @MainActor () -> GhosttyTmuxModelActionOutcome,
        showWindows: @MainActor () -> Bool,
        showPanes: @MainActor () -> Bool,
        showWindowsThenDismiss: @MainActor () -> Bool,
        showPanesThenDismiss: @MainActor () -> Bool,
        selectWindow: @MainActor () -> Bool = { false },
        selectPane: @MainActor () -> Bool = { false },
        closeWindow: @MainActor () -> Bool = { false },
        closePane: @MainActor () -> Bool = { false }
    ) -> SubmissionResult? {
        _ = scheduleIfNeeded(
            readiness: readiness,
            onDelaySatisfied: onDelaySatisfied
        )
        return submitIfReady(
            readiness: readiness,
            sendInput: sendInput,
            split: split,
            newWindow: newWindow,
            showWindows: showWindows,
            showPanes: showPanes,
            showWindowsThenDismiss: showWindowsThenDismiss,
            showPanesThenDismiss: showPanesThenDismiss,
            selectWindow: selectWindow,
            selectPane: selectPane,
            closeWindow: closeWindow,
            closePane: closePane
        )
    }

    @discardableResult
    func scheduleIfNeeded(
        readiness: TerminalReadinessSnapshot,
        onDelaySatisfied: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let probe else { return false }
        guard readiness.phase == .running else { return false }
        guard !delaySatisfied else { return false }
        guard delayTask == nil else { return false }

        let delay = probe.delayMilliseconds
        guard delay > 0 else {
            delaySatisfied = true
            return true
        }

        delayGeneration &+= 1
        let generation = delayGeneration
        delayTask = delayScheduler(delay) { [weak self] in
            self?.completeDelay(generation: generation, onDelaySatisfied: onDelaySatisfied)
        }
        return true
    }

    func submitIfReady(
        readiness: TerminalReadinessSnapshot,
        sendInput: @MainActor (String) -> FocusedTerminalInputSubmissionResult,
        split: @MainActor (ghostty_action_split_direction_e) -> GhosttyTmuxModelActionOutcome,
        newWindow: @MainActor () -> GhosttyTmuxModelActionOutcome,
        showWindows: @MainActor () -> Bool,
        showPanes: @MainActor () -> Bool,
        showWindowsThenDismiss: @MainActor () -> Bool,
        showPanesThenDismiss: @MainActor () -> Bool,
        selectWindow: @MainActor () -> Bool = { false },
        selectPane: @MainActor () -> Bool = { false },
        closeWindow: @MainActor () -> Bool = { false },
        closePane: @MainActor () -> Bool = { false }
    ) -> SubmissionResult? {
        guard var probe else { return nil }
        guard delaySatisfied else { return nil }
        guard let submission = probe.nextSubmission(
            isInputAvailable: TerminalReadinessProjector.isInputAvailable(readiness)
        ) else {
            self.probe = probe
            return nil
        }

        let statusMessage: String?
        var shouldRetry = false
        switch submission.action {
        case .input:
            guard let marker = submission.marker, let text = submission.text else {
                self.probe = probe
                return nil
            }
            let submittedAt = GhosttyRuntimeTrace.nowNanos()
            GhosttyRuntimeTrace.registerLatencyProbe(
                marker: marker,
                label: "debug-input",
                submittedAt: submittedAt
            )
            GhosttyRuntimeTrace.latency(
                "debugLatencyProbe.input submit marker=\(marker) bytes=\(text.lengthOfBytes(using: .utf8))"
            )
            let result = sendInput(text)
            if result.isAccepted {
                statusMessage = "debug latency input probe sent"
            } else {
                probe.markRejected()
                shouldRetry = true
                statusMessage = nil
            }

        case .keyEcho:
            guard let marker = submission.marker, let text = submission.text else {
                self.probe = probe
                return nil
            }
            let submittedAt = GhosttyRuntimeTrace.nowNanos()
            GhosttyRuntimeTrace.registerLatencyProbe(
                marker: marker,
                label: "debug-key-echo",
                submittedAt: submittedAt
            )
            GhosttyRuntimeTrace.latency(
                "debugLatencyProbe.keyEcho submit marker=\(marker) characters=\(text.count) bytes=\(text.lengthOfBytes(using: .utf8))"
            )
            let result = sendInput(text)
            if result.isAccepted {
                _ = sendInput("\u{15}")
                statusMessage = "debug latency key echo probe sent"
            } else {
                probe.markRejected()
                shouldRetry = true
                statusMessage = nil
            }

        case .splitRight:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.splitRight submit")
            if !split(GHOSTTY_SPLIT_DIRECTION_RIGHT).isQueued {
                probe.markRejected()
                shouldRetry = true
            }
            statusMessage = nil

        case .splitDown:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.splitDown submit")
            if !split(GHOSTTY_SPLIT_DIRECTION_DOWN).isQueued {
                probe.markRejected()
                shouldRetry = true
            }
            statusMessage = nil

        case .newWindow:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.newWindow submit")
            if !newWindow().isQueued {
                probe.markRejected()
                shouldRetry = true
            }
            statusMessage = nil

        case .showWindows:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.showWindows submit")
            if !showWindows() {
                probe.markRejected()
                shouldRetry = true
            }
            statusMessage = nil

        case .showPanes:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.showPanes submit")
            if !showPanes() {
                probe.markRejected()
                shouldRetry = true
            }
            statusMessage = nil

        case .showWindowsDismiss:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.showWindowsDismiss submit")
            if !showWindowsThenDismiss() {
                probe.markRejected()
                shouldRetry = true
            }
            statusMessage = nil

        case .showPanesDismiss:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.showPanesDismiss submit")
            if !showPanesThenDismiss() {
                probe.markRejected()
                shouldRetry = true
            }
            statusMessage = nil

        case .selectWindow:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.selectWindow submit")
            if !selectWindow() {
                probe.markRejected()
                shouldRetry = true
            }
            statusMessage = nil

        case .selectPane:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.selectPane submit")
            if !selectPane() {
                probe.markRejected()
                shouldRetry = true
            }
            statusMessage = nil

        case .closeWindow:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.closeWindow submit")
            if !closeWindow() {
                probe.markRejected()
                shouldRetry = true
            }
            statusMessage = nil

        case .closePane:
            GhosttyRuntimeTrace.latency("debugLatencyProbe.closePane submit")
            if !closePane() {
                probe.markRejected()
                shouldRetry = true
            }
            statusMessage = nil
        }

        self.probe = probe
        return SubmissionResult(
            statusMessage: statusMessage,
            didSubmit: true,
            shouldRetry: shouldRetry
        )
    }

    func cancel() {
        delayGeneration &+= 1
        delayTask?.cancel()
        delayTask = nil
        delaySatisfied = false
    }

    private func completeDelay(
        generation: UInt64,
        onDelaySatisfied: @escaping @MainActor () -> Void
    ) {
        guard generation == delayGeneration else { return }
        delaySatisfied = true
        delayTask = nil
        onDelaySatisfied()
    }

    private static func defaultDelayScheduler(
        delayMilliseconds: Int64,
        onDelaySatisfied: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }
            onDelaySatisfied()
        }
    }
}

struct DebugLatencyProbeCommand: Equatable {
    enum Action: String, Equatable {
        case input
        case keyEcho
        case splitRight
        case splitDown
        case newWindow
        case showWindows
        case showPanes
        case showWindowsDismiss
        case showPanesDismiss
        case selectWindow
        case selectPane
        case closeWindow
        case closePane
    }

    struct Submission: Equatable {
        let action: Action
        let marker: String?
        let text: String?
    }

    private static let environmentKey = "REMUX_DEBUG_LATENCY_PROBE"
    private static let delayEnvironmentKey = "REMUX_DEBUG_LATENCY_PROBE_DELAY_MS"

    private let action: Action
    private let probeID: String
    let delayMilliseconds: Int64
    private var didSubmit = false

    init(
        action: Action = .input,
        probeID: String = UUID().uuidString,
        delayMilliseconds: Int64 = 0
    ) {
        self.action = action
        self.probeID = Self.normalizedProbeID(probeID)
        self.delayMilliseconds = max(delayMilliseconds, 0)
    }

    init?(
        _ rawValue: String?,
        probeID: String = UUID().uuidString,
        delayMilliseconds: Int64 = 0
    ) {
        guard let rawValue, !rawValue.isEmpty else { return nil }

        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "1", "true", "input":
            self.init(action: .input, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "key-echo", "key_echo", "key", "echo":
            self.init(action: .keyEcho, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "split-right", "split_right", "right":
            self.init(action: .splitRight, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "split-down", "split_down", "down":
            self.init(action: .splitDown, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "new-window", "new_window", "window":
            self.init(action: .newWindow, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "show-windows", "show_windows", "showwindows", "windows":
            self.init(action: .showWindows, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "show-panes", "show_panes", "showpanes", "panes":
            self.init(action: .showPanes, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "show-windows-dismiss", "show_windows_dismiss", "windows-dismiss", "windows_dismiss":
            self.init(action: .showWindowsDismiss, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "show-panes-dismiss", "show_panes_dismiss", "panes-dismiss", "panes_dismiss":
            self.init(action: .showPanesDismiss, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "select-window", "select_window", "selectwindow":
            self.init(action: .selectWindow, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "select-pane", "select_pane", "selectpane":
            self.init(action: .selectPane, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "close-window", "close_window", "closewindow":
            self.init(action: .closeWindow, probeID: probeID, delayMilliseconds: delayMilliseconds)
        case "close-pane", "close_pane", "closepane":
            self.init(action: .closePane, probeID: probeID, delayMilliseconds: delayMilliseconds)
        default:
            return nil
        }
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DebugLatencyProbeCommand? {
#if DEBUG
        DebugLatencyProbeCommand(
            environment[environmentKey],
            delayMilliseconds: Self.delayMilliseconds(from: environment)
        )
#else
        _ = environment
        return nil
#endif
    }

    mutating func nextSubmission(
        isInputAvailable: Bool
    ) -> Submission? {
        guard !didSubmit, isInputAvailable else { return nil }

        didSubmit = true
        switch action {
        case .input:
            return Submission(
                action: action,
                marker: outputMarker,
                text: inputText
            )
        case .keyEcho:
            return Submission(
                action: action,
                marker: keyEchoMarker,
                text: keyEchoMarker
            )
        case .splitRight,
             .splitDown,
             .newWindow,
             .showWindows,
             .showPanes,
             .showWindowsDismiss,
             .showPanesDismiss,
             .selectWindow,
             .selectPane,
             .closeWindow,
             .closePane:
            return Submission(
                action: action,
                marker: nil,
                text: nil
            )
        }
    }

    mutating func markRejected() {
        didSubmit = false
    }

    var outputMarker: String {
        "__REMUX_LATENCY_\(probeID)__"
    }

    var keyEchoMarker: String {
        String(UnicodeScalar(0x00A7)!)
    }

    var inputText: String {
        "printf __REMUX_%s__ LATENCY_\(probeID)\r"
    }

    private static func normalizedProbeID(_ value: String) -> String {
        let allowed = value.filter { character in
            character.isLetter || character.isNumber
        }
        return String(allowed.prefix(16)).isEmpty ? "probe" : String(allowed.prefix(16))
    }

    private static func delayMilliseconds(from environment: [String: String]) -> Int64 {
        guard let rawValue = environment[delayEnvironmentKey] else { return 0 }
        return Int64(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
