import Foundation

enum GhosttyRuntimeTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["REMUX_TRACE_GHOSTTY_IO"] == "1"
    private static let latencyMode = ProcessInfo.processInfo.environment["REMUX_TRACE_LATENCY"]
    static let latencyEnabled = latencyMode == "1" || latencyMode == "minimal"
    private static let verboseLatencyEnabled = latencyMode == "1"
    static let diagnosticsEnabled = isEnabled ||
        ProcessInfo.processInfo.environment["REMUX_TRACE_GHOSTTY_DIAGNOSTICS"] == "1"
    static let perfEnabled = ProcessInfo.processInfo.environment["REMUX_TRACE_PERF"] == "1"
    static let tmuxViewportEnabled = ProcessInfo.processInfo.environment["REMUX_TRACE_TMUX_VIEWPORT"] == "1"
    static let tmuxViewportFullIOEnabled = ProcessInfo.processInfo.environment["REMUX_TRACE_TMUX_VIEWPORT_FULL"] == "1"

    private static let latencyProbeStore = GhosttyLatencyProbeStore()
    private static let latencyMarkerAccumulator = GhosttyLatencyMarkerAccumulator()
    private static let flowTraceStore = GhosttyFlowTraceStore()

    static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func diagnostics(_ message: @autoclosure () -> String) {
        guard diagnosticsEnabled else { return }
        NSLog("Remux diag %@", message())
    }

    /// Lightweight perf signpost. Gated on REMUX_TRACE_PERF=1 so it's a true
    /// no-op (and the message autoclosure is not evaluated) in normal builds.
    /// `thread` is captured because some Ghostty callbacks fire off-main and
    /// we want to see which queue is actually doing the work.
    static func perf(_ message: @autoclosure () -> String) {
        guard perfEnabled else { return }
        let threadLabel = Thread.isMainThread ? "main" : (Thread.current.name ?? "bg")
        NSLog("Remux perf t=%llu thread=%@ %@", nowNanos(), threadLabel, message())
    }

    /// Wraps a block, recording its entry thread and elapsed duration when
    /// REMUX_TRACE_PERF=1. Always cheap when disabled; the only cost is one
    /// `nowNanos()` call before invoking the body.
    static func perfMeasure<T>(_ label: @autoclosure () -> String, _ body: () -> T) -> T {
        guard perfEnabled else { return body() }
        let entryThread = Thread.isMainThread ? "main" : (Thread.current.name ?? "bg")
        let start = nowNanos()
        let result = body()
        NSLog(
            "Remux perf t=%llu thread=%@ %@ elapsed_ms=%@",
            start,
            entryThread,
            label(),
            elapsedMilliseconds(from: start)
        )
        return result
    }

    static func latency(_ message: @autoclosure () -> String) {
        guard latencyEnabled else { return }
        let resolvedMessage = message()
        guard verboseLatencyEnabled || isMinimalLatencyMessage(resolvedMessage) else { return }

        NSLog("Remux latency t=%llu %@", nowNanos(), resolvedMessage)
    }

    static func tmuxViewport(_ message: @autoclosure () -> String) {
        guard tmuxViewportEnabled else { return }
        NSLog("Remux tmuxViewport t=%llu %@", nowNanos(), message())
    }

    static func viewportDescription(_ viewport: TmuxControlViewport) -> String {
        "\(viewport.columns)x\(viewport.rows) px=\(viewport.pixelWidth)x\(viewport.pixelHeight)"
    }

    static func formatTraceFields(_ fields: [String: String]) -> String {
        fields.keys.sorted().map { key in
            "\(key)=\(sanitizeTraceValue(fields[key] ?? ""))"
        }.joined(separator: " ")
    }

    private static func sanitizeTraceValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func flowBegin(
        _ flow: String,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        startedAt: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        let timestamp = startedAt ?? nowNanos()
        flowTraceStore.begin(flow: flow, at: timestamp)
        logFlow(flow, event: event, startedAt: timestamp, at: timestamp, fields: fields())
    }

    static func flowEvent(
        _ flow: String,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        let start = flowTraceStore.start(for: flow) ?? eventTimestamp
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields())
    }

    static func flowEventIfActive(
        _ flow: String,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        guard let start = flowTraceStore.start(for: flow) else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields())
    }

    static func flowEventSince(
        _ flow: String,
        event: String,
        startedAt: UInt64,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        logFlow(flow, event: event, startedAt: startedAt, at: eventTimestamp, fields: fields())
    }

    /// Like `flowEventIfActive`, but logs only the first occurrence of
    /// `event` per flow lifetime — for emission sites that fire
    /// repeatedly (SwiftUI view init, layout passes) where only the
    /// first occurrence is the milestone.
    static func flowEventOnce(
        _ flow: String,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        guard let start = flowTraceStore.markOnce(flow: flow, event: event) else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields())
    }

    static func flowEnd(
        _ flow: String,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        let start = flowTraceStore.end(flow: flow) ?? eventTimestamp
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields())
    }

    static func flowEndIfActive(
        _ flow: String,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        guard let start = flowTraceStore.end(flow: flow) else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields())
    }

    static func isFlowActive(_ flow: String) -> Bool {
        guard flowTraceEnabled else { return false }
        return flowTraceStore.start(for: flow) != nil
    }

    static func flowStartIfActive(_ flow: String) -> UInt64? {
        guard flowTraceEnabled else { return nil }
        return flowTraceStore.start(for: flow)
    }

    static func elapsedMilliseconds(from start: UInt64, to end: UInt64 = nowNanos()) -> String {
        String(format: "%.3f", Double(end &- start) / 1_000_000)
    }

    static func registerLatencyProbe(marker: String, label: String, submittedAt: UInt64? = nil) {
        guard latencyEnabled else { return }
        let timestamp = submittedAt ?? nowNanos()
        latencyProbeStore.register(marker: marker, label: label, submittedAt: timestamp)
        latency("probe_register label=\(label) marker=\(marker)")
    }

    static func registerLatencyMarkers(in text: String, label: String, submittedAt: UInt64? = nil) {
        guard latencyEnabled else { return }
        let timestamp = submittedAt ?? nowNanos()

        for marker in latencyMarkerAccumulator.append(text) {
            registerLatencyProbe(marker: marker, label: label, submittedAt: timestamp)
        }
    }

    static func observeInboundData(_ data: Data, source: String) {
        guard latencyEnabled, !data.isEmpty else { return }

        let now = nowNanos()
        let hits = latencyProbeStore.recordHits(in: data)
        for hit in hits {
            latency(
                "probe_hit label=\(hit.label) marker=\(hit.marker) hit=\(hit.hitCount) source=\(source) bytes=\(data.count) offset=\(hit.offset) delta_ms=\(elapsedMilliseconds(from: hit.submittedAt, to: now)) preview=\(preview(data, limit: 160))"
            )
            flowEventIfActive(
                "terminal.input",
                event: "probe.hit",
                fields: [
                    "label": hit.label,
                    "marker": hit.marker,
                    "source": source,
                    "delta_ms": elapsedMilliseconds(from: hit.submittedAt, to: now),
                ],
                at: now
            )
        }
    }

    static func preview(_ data: Data, limit: Int = 48) -> String {
        data
            .prefix(limit)
            .map { byte in
                if byte >= 0x20, byte <= 0x7E {
                    return String(UnicodeScalar(byte))
                }

                return String(format: "\\x%02X", byte)
            }
            .joined()
    }

    private static func isMinimalLatencyMessage(_ message: String) -> Bool {
        message.hasPrefix("probe_") ||
            message.hasPrefix("debugLatencyProbe")
    }

    static let flowTraceEnabled = perfEnabled || latencyEnabled ||
        ProcessInfo.processInfo.environment["REMUX_TRACE_FLOWS"] == "1"

    private static func logFlow(
        _ flow: String,
        event: String,
        startedAt: UInt64,
        at timestamp: UInt64,
        fields: [String: String]
    ) {
        var parts = [
            "flow=\(flow)",
            "event=\(event)",
            "since_ms=\(elapsedMilliseconds(from: startedAt, to: timestamp))",
        ]
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            parts.append("\(key)=\(normalizeFieldValue(value))")
        }
        NSLog("Remux flow t=%llu %@", timestamp, parts.joined(separator: " "))
    }

    private static func normalizeFieldValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

enum GhosttyTmuxActionTrace {
    enum Action: Equatable, Sendable {
        case newWindow
        case splitPane

        var flow: String {
            switch self {
            case .newWindow:
                "tmux.newWindow"
            case .splitPane:
                "tmux.splitPane"
            }
        }

        var command: String {
            switch self {
            case .newWindow:
                "new-window"
            case .splitPane:
                "split-window"
            }
        }
    }

    enum QueryKind: String, Equatable, Sendable {
        case tmuxVersion = "tmux_version"
        case listWindows = "list_windows"
        case paneState = "pane_state"
        case paneMetadata = "pane_metadata"
        case paneHistory = "pane_history"
        case paneVisible = "pane_visible"
        case panePendingOutput = "pane_pending_output"
    }

    struct CommandQueueEntry: Equatable, Sendable {
        let kind: QueryKind?
        let command: String
    }

    struct FlowContext: Equatable, Sendable {
        let name: String
        let startedAt: UInt64
    }

    struct OutboundQueryReservation: Sendable {
        fileprivate let reservation: GhosttyTmuxCommandTraceStore.OutboundReservation
    }

    enum InboundSignal: String, Equatable, Sendable {
        case windowAdd = "window-add"
        case sessionWindowChanged = "session-window-changed"
        case windowPaneChanged = "window-pane-changed"
        case layoutChange = "layout-change"

        var action: Action {
            switch self {
            case .windowAdd, .sessionWindowChanged:
                .newWindow
            case .windowPaneChanged, .layoutChange:
                .splitPane
            }
        }

        var event: String {
            eventName(prefix: "tmux.response")
        }

        func eventName(prefix: String) -> String {
            "\(prefix).\(rawValue)"
        }
    }

    static func outboundAction(for data: Data) -> Action? {
        if containsCommand(Self.newWindowCommand, in: data) {
            return .newWindow
        }
        if containsCommand(Self.splitWindowCommand, in: data) {
            return .splitPane
        }
        return nil
    }

    static func inboundSignals(in data: Data) -> [InboundSignal] {
        var signals: [InboundSignal] = []
        for candidate in Self.inboundSignalPatterns where contains(candidate.pattern, in: data) {
            signals.append(candidate.signal)
        }
        return signals
    }

    static func traceOutboundCommand(
        _ data: Data,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard GhosttyRuntimeTrace.flowTraceEnabled,
              let action = outboundAction(for: data),
              GhosttyRuntimeTrace.isFlowActive(action.flow)
        else {
            return
        }

        var eventFields = fields()
        eventFields["bytes"] = "\(data.count)"
        eventFields["command"] = action.command
        GhosttyRuntimeTrace.flowEventIfActive(
            action.flow,
            event: event,
            fields: eventFields,
            at: timestamp
        )
    }

    @discardableResult
    static func traceOutboundQueryCommands(
        _ data: Data,
        event: String,
        at timestamp: UInt64? = nil
    ) -> OutboundQueryReservation? {
        guard GhosttyRuntimeTrace.flowTraceEnabled else { return nil }

        let commands = commandQueueEntries(in: data)
        guard !commands.isEmpty else { return nil }

        let flows = activeTopologyFlows()
        let eventTimestamp = timestamp ?? GhosttyRuntimeTrace.nowNanos()
        let reservation = commandTraceStore.reserveOutbound(commands, flows: flows)
        for traceEvent in reservation.events {
            logQueryEvent(
                traceEvent,
                phase: "send",
                fields: ["source": event],
                at: eventTimestamp
            )
        }
        return OutboundQueryReservation(reservation: reservation)
    }

    static func cancelOutboundQueryCommands(_ reservation: OutboundQueryReservation?) {
        guard let reservation else { return }
        commandTraceStore.cancelOutboundReservation(reservation.reservation)
    }

    static func traceInboundSignals(
        in data: Data,
        source: String,
        chunkCount: Int,
        eventPrefix: String = "tmux.response",
        at timestamp: UInt64? = nil
    ) {
        guard GhosttyRuntimeTrace.flowTraceEnabled else { return }

        for signal in inboundSignals(in: data) {
            let action = signal.action
            guard GhosttyRuntimeTrace.isFlowActive(action.flow) else { continue }

            GhosttyRuntimeTrace.flowEventIfActive(
                action.flow,
                event: signal.eventName(prefix: eventPrefix),
                fields: [
                    "bytes": "\(data.count)",
                    "chunks": "\(chunkCount)",
                    "signal": signal.rawValue,
                    "source": source,
                ],
                at: timestamp
            )
        }
    }

    static func traceInboundQueryResponses(
        in data: Data,
        source: String,
        chunkCount: Int,
        at timestamp: UInt64? = nil
    ) {
        guard GhosttyRuntimeTrace.flowTraceEnabled else { return }

        let eventTimestamp = timestamp ?? GhosttyRuntimeTrace.nowNanos()
        for event in commandTraceStore.recordReceivedResponses(in: data) {
            logQueryEvent(
                event,
                phase: "response.receive",
                fields: [
                    "chunks": "\(chunkCount)",
                    "outcome": event.outcome.rawValue,
                    "source": source,
                ],
                at: eventTimestamp
            )
        }
    }

    static func traceProcessedQueryResponses(
        in data: Data,
        source: String,
        chunkCount: Int,
        accepted: Bool,
        at timestamp: UInt64? = nil
    ) {
        guard GhosttyRuntimeTrace.flowTraceEnabled else { return }

        let eventTimestamp = timestamp ?? GhosttyRuntimeTrace.nowNanos()
        for event in commandTraceStore.recordProcessedResponses(in: data) {
            logQueryEvent(
                event,
                phase: "response.processed",
                fields: [
                    "accepted": "\(accepted)",
                    "chunks": "\(chunkCount)",
                    "outcome": event.outcome.rawValue,
                    "source": source,
                ],
                at: eventTimestamp
            )
        }
    }

    static func traceActiveTopologyFlows(
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard GhosttyRuntimeTrace.flowTraceEnabled else { return }

        var resolvedFields: [String: String]?
        for action in [Action.newWindow, .splitPane] where GhosttyRuntimeTrace.isFlowActive(action.flow) {
            if resolvedFields == nil {
                resolvedFields = fields()
            }
            GhosttyRuntimeTrace.flowEventIfActive(
                action.flow,
                event: event,
                fields: resolvedFields ?? [:],
                at: timestamp
            )
        }
    }

    static func commandQueueEntries(in data: Data) -> [CommandQueueEntry] {
        let text = String(decoding: data, as: UTF8.self)
        var entries: [CommandQueueEntry] = []

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            for rawCommand in splitCommandSequence(String(rawLine)) {
                let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { continue }
                entries.append(
                    CommandQueueEntry(
                        kind: queryKind(for: command),
                        command: commandName(for: command)
                    )
                )
            }
        }

        return entries
    }

    private static func activeTopologyFlows() -> [FlowContext] {
        [Action.newWindow.flow, Action.splitPane.flow].compactMap { flow in
            guard let startedAt = GhosttyRuntimeTrace.flowStartIfActive(flow) else { return nil }
            return FlowContext(name: flow, startedAt: startedAt)
        }
    }

    private static func logQueryEvent(
        _ event: GhosttyTmuxCommandTraceStore.TraceEvent,
        phase: String,
        fields: [String: String] = [:],
        at timestamp: UInt64
    ) {
        guard let kind = event.kind else { return }

        var eventFields = fields
        eventFields["command"] = event.command
        eventFields["kind"] = kind.rawValue
        eventFields["sequence"] = "\(event.sequence)"

        for flow in event.flows {
            GhosttyRuntimeTrace.flowEventSince(
                flow.name,
                event: "tmux.query.\(kind.rawValue).\(phase)",
                startedAt: flow.startedAt,
                fields: eventFields,
                at: timestamp
            )
        }
    }

    private static func splitCommandSequence(_ line: String) -> [String] {
        line.components(separatedBy: " ; ")
    }

    private static func queryKind(for command: String) -> QueryKind? {
        if command.hasPrefix("display-message -p '#{version}'") {
            return .tmuxVersion
        }
        if command.hasPrefix("list-windows ") {
            return .listWindows
        }
        if command.hasPrefix("list-panes ") {
            return .paneState
        }
        if command.hasPrefix("display-message "),
           command.contains("#{history_size}") {
            return .paneMetadata
        }
        if command.hasPrefix("capture-pane ") {
            if command.contains(" -P ") {
                return .panePendingOutput
            }
            if command.contains(" -S -") {
                return .paneHistory
            }
            return .paneVisible
        }

        return nil
    }

    private static func commandName(for command: String) -> String {
        if let kind = queryKind(for: command) {
            return kind.rawValue
        }

        guard let firstToken = command.split(separator: " ").first else {
            return "unknown"
        }
        return String(firstToken)
    }

    private static let newWindowCommand = Array("new-window".utf8)
    private static let splitWindowCommand = Array("split-window".utf8)
    private static let commandTraceStore = GhosttyTmuxCommandTraceStore()
    private static let inboundSignalPatterns: [(signal: InboundSignal, pattern: Data)] = [
        (.windowAdd, Data("%window-add".utf8)),
        (.sessionWindowChanged, Data("%session-window-changed".utf8)),
        (.windowPaneChanged, Data("%window-pane-changed".utf8)),
        (.layoutChange, Data("%layout-change".utf8)),
    ]

    private static func containsCommand(_ command: [UInt8], in data: Data) -> Bool {
        let bytes = Array(data)
        var lineStart = 0

        while lineStart < bytes.count {
            var index = lineStart
            while index < bytes.count, bytes[index] == Self.space || bytes[index] == Self.tab {
                index += 1
            }

            if matchesCommand(command, in: bytes, at: index) {
                return true
            }

            while lineStart < bytes.count,
                  bytes[lineStart] != Self.lineFeed,
                  bytes[lineStart] != Self.carriageReturn {
                lineStart += 1
            }
            while lineStart < bytes.count,
                  bytes[lineStart] == Self.lineFeed || bytes[lineStart] == Self.carriageReturn {
                lineStart += 1
            }
        }

        return false
    }

    private static func matchesCommand(_ command: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        guard index + command.count <= bytes.count else { return false }
        guard bytes[index..<index + command.count].elementsEqual(command) else { return false }

        let boundaryIndex = index + command.count
        guard boundaryIndex < bytes.count else { return true }
        return isCommandTokenBoundary(bytes[boundaryIndex])
    }

    private static func isCommandTokenBoundary(_ byte: UInt8) -> Bool {
        byte == Self.space || byte == Self.tab || byte == Self.lineFeed || byte == Self.carriageReturn
    }

    private static func contains(_ needle: Data, in haystack: Data) -> Bool {
        haystack.range(of: needle) != nil
    }

    private static let space: UInt8 = 0x20
    private static let tab: UInt8 = 0x09
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
}

final class GhosttyTmuxCommandTraceStore: @unchecked Sendable {
    enum ResponseOutcome: String, Sendable {
        case end
        case error
    }

    struct OutboundReservation: Sendable {
        let firstSequence: UInt64?
        let count: Int
        let events: [TraceEvent]
    }

    struct TraceEvent: Sendable {
        let kind: GhosttyTmuxActionTrace.QueryKind?
        let command: String
        let flows: [GhosttyTmuxActionTrace.FlowContext]
        let sequence: UInt64
        let outcome: ResponseOutcome
    }

    private struct PendingCommand {
        let kind: GhosttyTmuxActionTrace.QueryKind?
        let command: String
        let flows: [GhosttyTmuxActionTrace.FlowContext]
        let sequence: UInt64
    }

    private let lock = NSLock()
    private let maxPendingCommands = 2048
    private var nextSequence: UInt64 = 0
    private var receivePending: [PendingCommand] = []
    private var processPending: [PendingCommand] = []
    private var receiveParser = GhosttyTmuxControlResponseParser()
    private var processParser = GhosttyTmuxControlResponseParser()

    func reserveOutbound(
        _ commands: [GhosttyTmuxActionTrace.CommandQueueEntry],
        flows: [GhosttyTmuxActionTrace.FlowContext]
    ) -> OutboundReservation {
        return lock.withLock {
            var events: [TraceEvent] = []
            var firstSequence: UInt64?
            var count = 0
            for command in commands {
                nextSequence &+= 1
                if firstSequence == nil {
                    firstSequence = nextSequence
                }
                count += 1
                let pending = PendingCommand(
                    kind: command.kind,
                    command: command.command,
                    flows: flows,
                    sequence: nextSequence
                )
                receivePending.append(pending)
                trimPendingIfNeeded(&receivePending)
                if command.kind != nil, !flows.isEmpty {
                    events.append(traceEvent(for: pending, outcome: .end))
                }
            }
            return OutboundReservation(
                firstSequence: firstSequence,
                count: count,
                events: events
            )
        }
    }

    func cancelOutboundReservation(_ reservation: OutboundReservation) {
        guard let firstSequence = reservation.firstSequence, reservation.count > 0 else { return }
        let lastSequence = firstSequence + UInt64(reservation.count - 1)

        lock.withLock {
            receivePending.removeAll { pending in
                pending.sequence >= firstSequence && pending.sequence <= lastSequence
            }
            processPending.removeAll { pending in
                pending.sequence >= firstSequence && pending.sequence <= lastSequence
            }
        }
    }

    func recordReceivedResponses(in data: Data) -> [TraceEvent] {
        lock.withLock {
            let responses = receiveParser.responses(in: data)
            guard !responses.isEmpty else { return [] }

            var events: [TraceEvent] = []
            for response in responses {
                guard !receivePending.isEmpty else { continue }
                let pending = receivePending.removeFirst()
                processPending.append(pending)
                trimPendingIfNeeded(&processPending)
                if pending.kind != nil, !pending.flows.isEmpty {
                    events.append(traceEvent(for: pending, outcome: response))
                }
            }
            return events
        }
    }

    func recordProcessedResponses(in data: Data) -> [TraceEvent] {
        lock.withLock {
            let responses = processParser.responses(in: data)
            guard !responses.isEmpty else { return [] }

            var events: [TraceEvent] = []
            for response in responses {
                guard !processPending.isEmpty else { continue }
                let pending = processPending.removeFirst()
                if pending.kind != nil, !pending.flows.isEmpty {
                    events.append(traceEvent(for: pending, outcome: response))
                }
            }
            return events
        }
    }

    private func traceEvent(for pending: PendingCommand, outcome: ResponseOutcome) -> TraceEvent {
        TraceEvent(
            kind: pending.kind,
            command: pending.command,
            flows: pending.flows,
            sequence: pending.sequence,
            outcome: outcome
        )
    }

    private func trimPendingIfNeeded(_ pending: inout [PendingCommand]) {
        guard pending.count > maxPendingCommands else { return }
        pending.removeFirst(pending.count - maxPendingCommands)
    }
}

struct GhosttyTmuxControlResponseParser {
    private var partialLine: [UInt8] = []
    private var previousByteWasCarriageReturn = false
    private let maxPartialLineLength = 4096

    mutating func responses(in data: Data) -> [GhosttyTmuxCommandTraceStore.ResponseOutcome] {
        guard !data.isEmpty else { return [] }

        var responses: [GhosttyTmuxCommandTraceStore.ResponseOutcome] = []
        for byte in data {
            if previousByteWasCarriageReturn {
                previousByteWasCarriageReturn = false
                if byte == Self.lineFeed {
                    continue
                }
            }

            if byte == Self.carriageReturn || byte == Self.lineFeed {
                appendResponseIfNeeded(from: partialLine, to: &responses)
                partialLine.removeAll(keepingCapacity: true)
                previousByteWasCarriageReturn = byte == Self.carriageReturn
                continue
            }

            partialLine.append(byte)
            if partialLine.count > maxPartialLineLength {
                partialLine.removeFirst(partialLine.count - maxPartialLineLength)
            }
        }

        return responses
    }

    private func appendResponseIfNeeded(
        from line: [UInt8],
        to responses: inout [GhosttyTmuxCommandTraceStore.ResponseOutcome]
    ) {
        if line.starts(with: Self.endPrefix) {
            responses.append(.end)
        } else if line.starts(with: Self.errorPrefix) {
            responses.append(.error)
        }
    }

    private static let endPrefix = Array("%end ".utf8)
    private static let errorPrefix = Array("%error ".utf8)
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
}

final class GhosttyFlowTraceStore: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [String: UInt64] = [:]
    private var onceEvents: Set<String> = []

    func begin(flow: String, at timestamp: UInt64) {
        lock.withLock {
            starts[flow] = timestamp
            clearOnceEventsLocked(flow: flow)
        }
    }

    func start(for flow: String) -> UInt64? {
        lock.withLock {
            starts[flow]
        }
    }

    func end(flow: String) -> UInt64? {
        lock.withLock {
            clearOnceEventsLocked(flow: flow)
            return starts.removeValue(forKey: flow)
        }
    }

    /// First occurrence of `event` for an active flow: returns the
    /// flow's start time exactly once per flow lifetime, nil after
    /// (and always nil for inactive flows). A new `begin` re-arms.
    func markOnce(flow: String, event: String) -> UInt64? {
        lock.withLock {
            guard let start = starts[flow] else { return nil }
            guard onceEvents.insert("\(flow)#\(event)").inserted else { return nil }
            return start
        }
    }

    private func clearOnceEventsLocked(flow: String) {
        let prefix = "\(flow)#"
        onceEvents = onceEvents.filter { !$0.hasPrefix(prefix) }
    }
}

final class GhosttyLatencyMarkerAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix = "__REMUX_LATENCY_"
    private let maxBufferedCharacters: Int
    private var buffer = ""

    init(maxBufferedCharacters: Int = 256) {
        self.maxBufferedCharacters = max(32, maxBufferedCharacters)
    }

    func append(_ text: String) -> [String] {
        lock.withLock {
            appendLocked(text)
        }
    }

    private func appendLocked(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        buffer.append(text)
        var markers: [String] = []

        while true {
            guard let prefixRange = buffer.range(of: prefix) else {
                preservePossiblePrefixSuffix()
                return markers
            }

            if prefixRange.lowerBound > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<prefixRange.lowerBound)
            }

            let markerBodyStart = buffer.index(buffer.startIndex, offsetBy: prefix.count)
            guard let markerEnd = buffer[markerBodyStart...].range(of: "__")?.upperBound else {
                trimUnclosedMarkerIfNeeded()
                return markers
            }

            markers.append(String(buffer[buffer.startIndex..<markerEnd]))
            buffer.removeSubrange(buffer.startIndex..<markerEnd)
        }
    }

    private func preservePossiblePrefixSuffix() {
        let suffixLength = min(buffer.count, prefix.count - 1)
        buffer = String(buffer.suffix(suffixLength))
    }

    private func trimUnclosedMarkerIfNeeded() {
        guard buffer.count > maxBufferedCharacters else { return }
        buffer = String(buffer.suffix(maxBufferedCharacters))
    }
}

final class GhosttyLatencyProbeStore: @unchecked Sendable {
    struct Hit {
        let marker: String
        let label: String
        let submittedAt: UInt64
        let hitCount: Int
        let offset: Int
    }

    private struct Probe {
        let marker: String
        let markerData: Data
        let label: String
        let submittedAt: UInt64
        var hitCount: Int
    }

    private let lock = NSLock()
    private var probes: [String: Probe] = [:]
    private var recentData = Data()

    func register(marker: String, label: String, submittedAt: UInt64) {
        lock.withLock {
            probes[marker] = Probe(
                marker: marker,
                markerData: Data(marker.utf8),
                label: label,
                submittedAt: submittedAt,
                hitCount: 0
            )
        }
    }

    func recordHits(in data: Data) -> [Hit] {
        lock.withLock {
            var hits: [Hit] = []
            var searchableData = recentData
            let previousByteCount = searchableData.count
            searchableData.append(data)

            for marker in probes.keys.sorted() {
                guard var probe = probes[marker] else { continue }
                guard let range = searchableData.range(of: probe.markerData) else { continue }
                guard range.upperBound > previousByteCount else { continue }

                probe.hitCount += 1
                probes[marker] = probe
                hits.append(
                    Hit(
                        marker: probe.marker,
                        label: probe.label,
                        submittedAt: probe.submittedAt,
                        hitCount: probe.hitCount,
                        offset: max(0, range.lowerBound - previousByteCount)
                    )
                )
            }

            if let maxMarkerLength = probes.values.map(\.markerData.count).max(), maxMarkerLength > 1 {
                recentData = searchableData.suffix(maxMarkerLength - 1)
            } else {
                recentData.removeAll(keepingCapacity: true)
            }

            return hits
        }
    }
}
