import Foundation
import GhosttyKit

/// New-architecture tmux session: a thin, thread-disciplined wrapper of
/// the `ghostty_tmux_session_*` C API.
///
/// THREADING CONTRACT (mirrors libghostty's): every call into the C
/// session happens on `queue` — the writer thread. The SSH transport
/// delivers inbound bytes via `pump(_:)` (dispatched onto the queue),
/// outbound wire bytes leave via the `onOutbound` callback (invoked on
/// the queue; the transport forwards them to the SSH channel), and all
/// UI-initiated calls (input, requests, bind/unbind) are queue-hopped
/// here. Events arrive synchronously on the queue and are re-published
/// to the main actor as immutable snapshots — the UI never touches the
/// session handle.
/// @unchecked Sendable: all mutable state is confined to `queue` (the
/// writer thread) per the documented threading contract.
final class TmuxSessionController: @unchecked Sendable {
    // MARK: Public model

    enum SessionState: Equatable, Sendable {
        case detached(DetachReason?)
        case attaching
        case syncing
        case ready
        case closed(CloseReason)
    }

    enum DetachReason: Equatable, Sendable {
        case serverExited(String?)
        case channelAborted
        case outOfMemory
        case baselineFailed
        case reconcileFailed
        case transportClosed
    }

    enum CloseReason: Equatable, Sendable {
        case attachFailed(String)
        case unsupportedVersion(String)
    }

    struct WindowInfo: Equatable, Identifiable, Sendable {
        let id: TmuxWindowID
        let name: String
        let active: Bool
        let zoomed: Bool
        let width: UInt32
        let height: UInt32
        let activePaneID: TmuxPaneID?
    }

    enum PaneState: Equatable, Sendable {
        case discovered
        case bootstrapping
        case live
        case degraded
    }

    struct PaneInfo: Equatable, Identifiable, Sendable {
        let id: TmuxPaneID
        let windowID: TmuxWindowID
        let x: UInt32
        let y: UInt32
        let width: UInt32
        let height: UInt32
        let state: PaneState
    }

    struct TopologySnapshot: Equatable, Sendable {
        let sessionName: String
        let windows: [WindowInfo]
        let panes: [PaneInfo]
        let activeWindowID: TmuxWindowID?
    }

    enum Request: Equatable, Sendable {
        case newWindow
        case splitPane
        case closePane
        case closeWindow
        case selectWindow
        case selectPane
        case zoomPane
        case copyMode
        case setClientSize
        case sendInput
    }

    enum SplitDirection: Sendable {
        case left, right, up, down
    }

    /// Host-visible signals, delivered on the main queue. Snapshots are
    /// immutable copies taken on the writer queue at the event's safe
    /// point, so they are always internally consistent.
    struct Callbacks: Sendable {
        var onState: @Sendable (SessionState) -> Void = { _ in }
        var onTopology: @Sendable (TopologySnapshot) -> Void = { _ in }
        var onPaneRemoved: @Sendable (TmuxPaneID) -> Void = { _ in }
        var onPaneLive: @Sendable (TmuxPaneID) -> Void = { _ in }
        var onPaneDegraded: @Sendable (TmuxPaneID) -> Void = { _ in }
        var onRequestFailed: @Sendable (Request) -> Void = { _ in }
    }

    /// A live pane binding: the surface borrows the pane terminal and
    /// render mutex for its whole lifetime. Release order is strict:
    /// free the surface FIRST (its renderer stops touching the
    /// borrowed mutex), THEN `unbind` — unbind may destroy a
    /// dead-pane's engine and its mutex.
    /// @unchecked Sendable: immutable lets; crosses from the writer
    /// queue (creation) to the main queue (surface ownership).
    final class PaneBinding: @unchecked Sendable {
        let paneID: TmuxPaneID
        fileprivate let handle: ghostty_tmux_binding_t
        fileprivate let wakeBox: WakeBox

        fileprivate init(paneID: TmuxPaneID, handle: ghostty_tmux_binding_t, wakeBox: WakeBox) {
            self.paneID = paneID
            self.handle = handle
            self.wakeBox = wakeBox
        }

        /// Passed into ghostty_surface_config_s.tmux_binding.
        var rawHandle: ghostty_tmux_binding_t {
            handle
        }
    }

    /// Holds the wake closure with a stable address for the C callback.
    final class WakeBox: @unchecked Sendable {
        let wake: @Sendable () -> Void
        init(_ wake: @escaping @Sendable () -> Void) { self.wake = wake }
    }

    enum BindError: Error {
        case detachedSession
        case paneUnknown
        case alreadyBound
        case outOfMemory
    }

    enum PaneReleaseError: Error {
        case missingSession
        case paneStillBound
        case unexpectedResult
    }

    // MARK: State

    /// The writer thread. Everything that touches `session` runs here.
    let queue: DispatchQueue

    private var session: ghostty_tmux_session_t?
    private var tick: DispatchSourceTimer?
    private let callbacks: Callbacks

    /// Outbound wire bytes sink, invoked on the writer queue after
    /// every entry point that may have produced output. Settable: the
    /// controller outlives connections, and each transport link
    /// re-targets it. Bytes drained while no sink is set belong to a
    /// dead connection and are dropped.
    private var outboundSink: (@Sendable (Data) -> Void)?

    /// Re-target outbound wire bytes (writer queue).
    func setOutboundSink(_ sink: (@Sendable (Data) -> Void)?) {
        queue.async { [self] in
            outboundSink = sink
        }
    }

    init(
        app: ghostty_app_t,
        callbacks: Callbacks,
        queue: DispatchQueue = DispatchQueue(label: "remux.tmux.session.writer")
    ) {
        self.queue = queue
        self.callbacks = callbacks

        var config = ghostty_tmux_session_config_s()
        config.event_cb = { userdata, event in
            guard let userdata else { return }
            let controller = Unmanaged<TmuxSessionController>
                .fromOpaque(userdata).takeUnretainedValue()
            controller.handleEvent(event)
        }
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.handshake_timeout_ms = 0 // library default
        config.command_timeout_ms = 0 // library default
        config.history_line_cap = 0 // library default
        // Mobile presentation projects one pane at a time. Topology remains
        // complete, but a local terminal engine is created only by bind and
        // explicitly released after its surface is gone.
        config.materialization_policy = GHOSTTY_TMUX_MATERIALIZATION_POLICY_MANUAL

        // The session must be created before any callback can fire;
        // the event callback only runs inside pump/tick on our queue.
        self.session = withUnsafePointer(to: &config) { configPtr in
            ghostty_tmux_session_new(app, configPtr)
        }
    }

    /// Tear down the session: cancel the tick and free the C session on
    /// the writer queue (the only thread allowed to touch it). All
    /// bindings must have been released first — the C side asserts this
    /// in debug builds. Call before releasing the last reference.
    func shutdown(completion: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in
            tick?.cancel()
            tick = nil
            if let session {
                ghostty_tmux_session_free(session)
            }
            session = nil
            DispatchQueue.main.async(execute: completion)
        }
    }

    deinit {
        // shutdown() must have run: freeing here would touch the
        // session from an arbitrary thread.
        assert(session == nil, "TmuxSessionController deinit without shutdown()")
    }

    // MARK: Clock

    /// Monotonic milliseconds for the session's deadline clock.
    private static func nowMS() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private func preconditionOnWriterQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    // MARK: Transport plumbing (writer queue)

    /// Start (or restart, after a detach) a connection attempt. The
    /// caller is responsible for having a control-mode channel running
    /// `tmux -C new-session -A` whose bytes flow through `pump`.
    func connect() {
        queue.async { [self] in
            guard let session else { return }
            guard ghostty_tmux_session_connect(session, Self.nowMS()) else {
                let state = readState()
                DispatchQueue.main.async { self.callbacks.onState(state) }
                return
            }
            startTick()
            drainOutbound()
        }
    }

    /// Prompt detach on transport loss (SSH EOF/error). Session state
    /// is retained for the next connect; idempotent.
    func disconnect() {
        queue.async { [self] in
            guard let session else { return }
            ghostty_tmux_session_disconnect(session)
            tick?.cancel()
            tick = nil
        }
    }

    /// Inbound SSH bytes.
    func pump(_ data: Data) {
        let enqueuedAt = GhosttyRuntimeTrace.perfEnabled ? GhosttyRuntimeTrace.nowNanos() : 0
        queue.async { [self] in
            guard let session else { return }
            let applyStart = GhosttyRuntimeTrace.perfEnabled ? GhosttyRuntimeTrace.nowNanos() : 0
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                ghostty_tmux_session_pump(
                    session,
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    UInt(raw.count),
                    Self.nowMS()
                )
            }
            // The pump applies %output to pane terminals while holding the
            // render mutex; its duration is the renderer-blocking hazard.
            GhosttyRuntimeTrace.perf(
                "tmuxPump bytes=\(data.count) wait_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: enqueuedAt, to: applyStart)) apply_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: applyStart))"
            )
            drainOutbound()
        }
    }

    private func startTick() {
        preconditionOnWriterQueue()
        tick?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let session = self.session else { return }
            ghostty_tmux_session_tick(session, Self.nowMS())
            self.drainOutbound()
        }
        timer.resume()
        tick = timer
    }

    /// Drain pending wire bytes to the transport. Called on the writer
    /// queue after every entry point that can produce output.
    @discardableResult
    private func drainOutbound() -> Int {
        preconditionOnWriterQueue()
        guard let session else { return 0 }
        var len: UInt = 0
        guard let ptr = ghostty_tmux_session_outbound(session, &len), len > 0 else {
            return 0
        }
        let data = Data(bytes: ptr, count: Int(len))
        ghostty_tmux_session_outbound_consume(session, len)
        outboundSink?(data)
        return data.count
    }

    // MARK: Events (writer queue) -> main snapshots

    private func handleEvent(_ event: ghostty_tmux_event_s) {
        preconditionOnWriterQueue()
        switch event.tag {
        case GHOSTTY_TMUX_EVENT_STATE_CHANGED:
            let state = readState()
            DispatchQueue.main.async { self.callbacks.onState(state) }
        case GHOSTTY_TMUX_EVENT_TOPOLOGY_CHANGED:
            let snapshot = readTopology()
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "tmux.topology.changed",
                fields: {
                    let window = snapshot.activeWindowID.flatMap { id in
                        snapshot.windows.first { $0.id == id }
                    }
                    let pane = window?.activePaneID.flatMap { id in
                        snapshot.panes.first { $0.id == id }
                    }
                    let siblingCount = pane.map { active in
                        snapshot.panes.count { $0.windowID == active.windowID && $0.id != active.id }
                    }
                    return [
                        "active_pane": pane.map { "\($0.id)" } ?? "none",
                        "active_window": snapshot.activeWindowID.map { "\($0)" } ?? "none",
                        "pane_height": pane.map { "\($0.height)" } ?? "none",
                        "pane_width": pane.map { "\($0.width)" } ?? "none",
                        "pane_x": pane.map { "\($0.x)" } ?? "none",
                        "pane_y": pane.map { "\($0.y)" } ?? "none",
                        "sibling_count": siblingCount.map(String.init) ?? "none",
                        "window_height": window.map { "\($0.height)" } ?? "none",
                        "window_width": window.map { "\($0.width)" } ?? "none",
                        "window_zoomed": window.map { "\($0.zoomed)" } ?? "none",
                    ]
                }()
            )
            DispatchQueue.main.async { self.callbacks.onTopology(snapshot) }
        case GHOSTTY_TMUX_EVENT_PANE_REMOVED:
            let id = TmuxPaneID(event.pane_id)
            DispatchQueue.main.async { self.callbacks.onPaneRemoved(id) }
        case GHOSTTY_TMUX_EVENT_PANE_LIVE:
            let id = TmuxPaneID(event.pane_id)
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "tmux.pane.live",
                fields: ["pane": "\(id)"]
            )
            DispatchQueue.main.async { self.callbacks.onPaneLive(id) }
        case GHOSTTY_TMUX_EVENT_PANE_DEGRADED:
            let id = TmuxPaneID(event.pane_id)
            DispatchQueue.main.async { self.callbacks.onPaneDegraded(id) }
        case GHOSTTY_TMUX_EVENT_REQUEST_FAILED:
            let request = Request(event.request)
            if request == .selectPane {
                GhosttyRuntimeTrace.flowEndIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "tmux.request.failed",
                    fields: ["request": "selectPane"]
                )
            }
            DispatchQueue.main.async { self.callbacks.onRequestFailed(request) }
        default:
            break
        }
    }

    private func readState() -> SessionState {
        preconditionOnWriterQueue()
        guard let session else { return .detached(nil) }
        switch ghostty_tmux_session_state(session) {
        case GHOSTTY_TMUX_SESSION_STATE_ATTACHING: return .attaching
        case GHOSTTY_TMUX_SESSION_STATE_SYNCING: return .syncing
        case GHOSTTY_TMUX_SESSION_STATE_READY: return .ready
        case GHOSTTY_TMUX_SESSION_STATE_CLOSED:
            let detail = readReasonString() ?? ""
            switch ghostty_tmux_session_close_reason(session) {
            case GHOSTTY_TMUX_CLOSE_REASON_UNSUPPORTED_VERSION:
                return .closed(.unsupportedVersion(detail))
            default:
                return .closed(.attachFailed(detail))
            }
        default:
            switch ghostty_tmux_session_detach_reason(session) {
            case GHOSTTY_TMUX_DETACH_REASON_SERVER_EXITED:
                return .detached(.serverExited(readReasonString()))
            case GHOSTTY_TMUX_DETACH_REASON_CHANNEL_ABORTED:
                return .detached(.channelAborted)
            case GHOSTTY_TMUX_DETACH_REASON_OUT_OF_MEMORY:
                return .detached(.outOfMemory)
            case GHOSTTY_TMUX_DETACH_REASON_BASELINE_FAILED:
                return .detached(.baselineFailed)
            case GHOSTTY_TMUX_DETACH_REASON_RECONCILE_FAILED:
                return .detached(.reconcileFailed)
            case GHOSTTY_TMUX_DETACH_REASON_TRANSPORT_CLOSED:
                return .detached(.transportClosed)
            default:
                return .detached(nil)
            }
        }
    }

    private func readReasonString() -> String? {
        preconditionOnWriterQueue()
        guard let session else { return nil }
        var len: UInt = 0
        guard let ptr = ghostty_tmux_session_reason_string(session, &len), len > 0 else {
            return nil
        }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: Int(len)), as: UTF8.self)
    }

    private func readTopology() -> TopologySnapshot {
        preconditionOnWriterQueue()
        guard let session else {
            return TopologySnapshot(sessionName: "", windows: [], panes: [], activeWindowID: nil)
        }

        var nameLen: UInt = 0
        let namePtr = ghostty_tmux_session_name(session, &nameLen)
        let sessionName: String = if let namePtr, nameLen > 0 {
            String(decoding: UnsafeBufferPointer(start: namePtr, count: Int(nameLen)), as: UTF8.self)
        } else {
            ""
        }

        var windows: [WindowInfo] = []
        let windowCount = ghostty_tmux_session_window_count(session)
        windows.reserveCapacity(Int(windowCount))
        for index in 0..<windowCount {
            var raw = ghostty_tmux_window_s()
            guard ghostty_tmux_session_window_at(session, index, &raw) else { continue }
            let name: String = if let ptr = raw.name, raw.name_len > 0 {
                String(decoding: UnsafeBufferPointer(start: ptr, count: Int(raw.name_len)), as: UTF8.self)
            } else {
                ""
            }
            windows.append(WindowInfo(
                id: TmuxWindowID(raw.id),
                name: name,
                active: raw.active,
                zoomed: raw.zoomed,
                width: raw.width,
                height: raw.height,
                activePaneID: raw.has_active_pane ? TmuxPaneID(raw.active_pane_id) : nil
            ))
        }

        var panes: [PaneInfo] = []
        let paneCount = ghostty_tmux_session_pane_count(session)
        panes.reserveCapacity(Int(paneCount))
        for index in 0..<paneCount {
            var raw = ghostty_tmux_pane_s()
            guard ghostty_tmux_session_pane_at(session, index, &raw) else { continue }
            panes.append(PaneInfo(
                id: TmuxPaneID(raw.id),
                windowID: TmuxWindowID(raw.window_id),
                x: raw.x,
                y: raw.y,
                width: raw.width,
                height: raw.height,
                state: PaneState(raw.state)
            ))
        }

        var activeWindow: UInt64 = 0
        let hasActive = ghostty_tmux_session_active_window(session, &activeWindow)

        return TopologySnapshot(
            sessionName: sessionName,
            windows: windows,
            panes: panes,
            activeWindowID: hasActive ? TmuxWindowID(activeWindow) : nil
        )
    }

    // MARK: Bindings (writer queue)

    /// Bind a pane for a surface about to be created. `wake` fires on
    /// the writer queue whenever the pane's content changed; forward it
    /// to the surface's render request (which is thread-safe).
    func bind(
        paneID: TmuxPaneID,
        wake: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (Result<PaneBinding, BindError>) -> Void
    ) {
        queue.async { [self] in
            guard let session else {
                DispatchQueue.main.async { completion(.failure(.detachedSession)) }
                return
            }
            let box = WakeBox(wake)
            var handle: ghostty_tmux_binding_t?
            let result = ghostty_tmux_session_bind_pane(
                session,
                paneID.rawValue,
                { ctx in
                    guard let ctx else { return }
                    Unmanaged<WakeBox>.fromOpaque(ctx).takeUnretainedValue().wake()
                },
                Unmanaged.passUnretained(box).toOpaque(),
                &handle
            )
            drainOutbound()
            switch result {
            case GHOSTTY_TMUX_RESULT_OK:
                let binding = PaneBinding(paneID: paneID, handle: handle!, wakeBox: box)
                DispatchQueue.main.async { completion(.success(binding)) }
            case GHOSTTY_TMUX_RESULT_PANE_UNKNOWN:
                DispatchQueue.main.async { completion(.failure(.paneUnknown)) }
            case GHOSTTY_TMUX_RESULT_ALREADY_BOUND:
                DispatchQueue.main.async { completion(.failure(.alreadyBound)) }
            case GHOSTTY_TMUX_RESULT_DETACHED:
                DispatchQueue.main.async { completion(.failure(.detachedSession)) }
            default:
                DispatchQueue.main.async { completion(.failure(.outOfMemory)) }
            }
        }
    }

    /// REQUIRED for every binding, AFTER the bound surface has been freed.
    /// Unbind presentation first, then discard this consumer's local engine;
    /// the remote tmux pane and topology are untouched. Keeping both C calls
    /// in one writer-queue turn prevents another bind from racing between
    /// them. `completion` fires on the main queue once release finishes.
    func unbindAndDematerialize(
        _ binding: PaneBinding,
        completion: @escaping @MainActor @Sendable (Result<Void, PaneReleaseError>) -> Void = { _ in }
    ) {
        queue.async { [self] in
            guard let session else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion(.failure(.missingSession)) }
                }
                return
            }
            let startedAt = GhosttyRuntimeTrace.perfEnabled ? GhosttyRuntimeTrace.nowNanos() : 0
            ghostty_tmux_session_unbind_pane(session, binding.handle)
            // Keep the wake box alive until after unbind: no wake can
            // fire past this point.
            _ = binding.wakeBox
            let result = ghostty_tmux_session_dematerialize_pane(session, binding.paneID.rawValue)
            GhosttyRuntimeTrace.perf(
                "tmuxPane.dematerialize pane=\(binding.paneID) result=\(result) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
            )

            let completionResult: Result<Void, PaneReleaseError> = switch result {
            case GHOSTTY_TMUX_RESULT_OK, GHOSTTY_TMUX_RESULT_PANE_UNKNOWN:
                // Unknown is expected when tmux removed the pane while its
                // bound surface was displaying the frozen zombie engine;
                // unbind already destroyed that local engine.
                .success(())
            case GHOSTTY_TMUX_RESULT_PANE_BOUND:
                .failure(.paneStillBound)
            default:
                .failure(.unexpectedResult)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(completionResult) }
            }
        }
    }

    // MARK: Input, size, requests (writer queue)

    /// Copies input onto the writer queue without blocking the caller. `true`
    /// means this controller accepted the bytes for ordered submission, not
    /// that tmux has already accepted them. A later libghostty rejection is
    /// published through `onRequestFailed(.sendInput)` on the main queue.
    func sendInput(paneID: TmuxPaneID, _ bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return true }

        let enqueuedAt = GhosttyRuntimeTrace.perfEnabled
            ? GhosttyRuntimeTrace.nowNanos() : 0
        queue.async { [self, bytes] in
            let applyStartedAt = GhosttyRuntimeTrace.perfEnabled
                ? GhosttyRuntimeTrace.nowNanos() : 0
            guard let session else {
                GhosttyRuntimeTrace.perf(
                    "tmuxInput.writer pane=\(paneID) bytes=\(bytes.count) wait_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: enqueuedAt, to: applyStartedAt)) result=detached"
                )
                reportImmediateRequestFailureIfNeeded(
                    GHOSTTY_TMUX_RESULT_DETACHED,
                    request: .sendInput
                )
                return
            }
            let result = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                ghostty_tmux_session_send_input(
                    session,
                    paneID.rawValue,
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    UInt(raw.count)
                )
            }
            drainOutbound()
            GhosttyRuntimeTrace.perf(
                "tmuxInput.writer pane=\(paneID) bytes=\(bytes.count) wait_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: enqueuedAt, to: applyStartedAt)) apply_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: applyStartedAt)) result=\(result)"
            )
            reportImmediateRequestFailureIfNeeded(result, request: .sendInput)
        }
        return true
    }

    /// Honest viewport reporting. Callable any time, including before
    /// connect: the size is flushed into the attach's sync batch so
    /// layouts arrive already sized for this client.
    /// Host-side record of the last reported viewport, carried across
    /// model replacement so a reconnect attaches already sized (the
    /// engine pipelines it before the baseline; captures land at this
    /// client's width with no relayout churn).
    struct ClientSize: Sendable, Equatable {
        let cols: UInt32
        let rows: UInt32
    }

    private var writerLastClientSize: ClientSize?

    var lastClientSize: ClientSize? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { writerLastClientSize }
    }

    /// The last size reported while the host viewport was in its
    /// settled shape (no transient overlay such as the software
    /// keyboard). Reconnects carry this one: a size captured
    /// mid-transient would make the next attach first-paint at the
    /// wrong shape for ~a round trip.
    private var writerLastStableClientSize: ClientSize?
    private var writerViewportIsStable = true

    var lastStableClientSize: ClientSize? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { writerLastStableClientSize }
    }

    /// The viewport to carry into a replacement session.
    var carriedClientSize: ClientSize? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        let startedAt = GhosttyRuntimeTrace.perfEnabled
            ? GhosttyRuntimeTrace.nowNanos() : 0
        let size = queue.sync {
            writerLastStableClientSize ?? writerLastClientSize
        }
        GhosttyRuntimeTrace.perf(
            "tmuxViewport.carriedSnapshot wait_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
        )
        return size
    }

    /// Host hint that the viewport is (not) in its settled shape.
    /// Ordering makes this race-free without coordination: the host
    /// flips to unstable before the overlay changes layout, so the
    /// shrunken report that follows is never recorded as stable; it
    /// flips back to stable before the restored layout reports, and
    /// the stable record keeps its previous settled value until that
    /// report arrives.
    func setViewportStability(_ stable: Bool) {
        queue.async { [self] in
            writerViewportIsStable = stable
        }
    }

    func setClientSize(cols: UInt32, rows: UInt32) {
        GhosttyRuntimeTrace.tmuxViewport(
            "client_size.local_submit cols=\(cols) rows=\(rows)"
        )
        queue.async { [self] in
            writerLastClientSize = ClientSize(cols: cols, rows: rows)
            if writerViewportIsStable {
                writerLastStableClientSize = writerLastClientSize
            }
            guard let session else { return }
            let result = ghostty_tmux_session_set_client_size(session, cols, rows)
            let outboundBytes = drainOutbound()
            GhosttyRuntimeTrace.tmuxViewport(
                "client_size.writer_result cols=\(cols) rows=\(rows) result=\(result) outbound_bytes=\(outboundBytes)"
            )
            reportImmediateRequestFailureIfNeeded(result, request: .setClientSize)
        }
    }

    func requestNewWindow() {
        submit(request: .newWindow) { ghostty_tmux_session_request_new_window($0) }
    }

    func requestSplit(paneID: TmuxPaneID, direction: SplitDirection, zoom: Bool) {
        let cDirection: ghostty_tmux_split_direction_e = switch direction {
        case .left: GHOSTTY_TMUX_SPLIT_DIRECTION_LEFT
        case .right: GHOSTTY_TMUX_SPLIT_DIRECTION_RIGHT
        case .up: GHOSTTY_TMUX_SPLIT_DIRECTION_UP
        case .down: GHOSTTY_TMUX_SPLIT_DIRECTION_DOWN
        }
        submit(request: .splitPane) {
            ghostty_tmux_session_request_split($0, paneID.rawValue, cDirection, zoom)
        }
    }

    func requestClosePane(paneID: TmuxPaneID) {
        submit(request: .closePane) { ghostty_tmux_session_request_close_pane($0, paneID.rawValue) }
    }

    func requestCloseWindow(windowID: TmuxWindowID) {
        submit(request: .closeWindow) { ghostty_tmux_session_request_close_window($0, windowID.rawValue) }
    }

    func requestSelectWindow(windowID: TmuxWindowID) {
        submit(request: .selectWindow) { ghostty_tmux_session_request_select_window($0, windowID.rawValue) }
    }

    func requestSelectPane(paneID: TmuxPaneID) {
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "tmux.request.enqueued",
            fields: [
                "pane": "\(paneID)",
                "request": "selectPane",
            ]
        )
        submit(request: .selectPane, tracePaneID: paneID) {
            ghostty_tmux_session_request_select_pane($0, paneID.rawValue)
        }
    }

    func requestZoomPane(paneID: TmuxPaneID) {
        submit(request: .zoomPane) { ghostty_tmux_session_request_zoom_pane($0, paneID.rawValue) }
    }

    func requestCopyMode(paneID: TmuxPaneID) {
        submit(request: .copyMode) { ghostty_tmux_session_request_copy_mode($0, paneID.rawValue) }
    }

    func renderPanePreviewImageAsync(
        paneID: TmuxPaneID,
        styleSurface: GhosttyKitControlSurface,
        options: ghostty_surface_preview_image_options_s,
        previewGrid: ClientSize,
        userdata: UnsafeMutableRawPointer?,
        callback: ghostty_surface_preview_image_callback_f,
        completion: @escaping @MainActor @Sendable (
            ghostty_surface_preview_request_t?
        ) -> Void
    ) {
        let submission = TmuxPanePreviewSubmission(
            paneID: paneID,
            styleSurface: styleSurface,
            options: options,
            previewGrid: previewGrid,
            userdata: userdata,
            callback: callback
        )
        queue.async { [self, submission] in
            guard let session else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            let tmuxOptions = ghostty_tmux_pane_preview_image_options_s(
                image: submission.options,
                preview_cols: submission.previewGrid.cols,
                preview_rows: submission.previewGrid.rows
            )
            // This lock-scoped borrow intentionally covers the synchronous C
            // call. It fences the external owner's invalidate-then-free path
            // while libghostty copies the style, font, colors, and preview
            // subsystem identity. The C call invokes no synchronous callback
            // and retains no Surface pointer after it returns.
            let requestResult = submission.styleSurface
                .withSynchronousBorrowedSurface { styleSurface in
                    TmuxPanePreviewRequestResult(
                        request: ghostty_tmux_session_render_pane_preview_image_async(
                            session,
                            styleSurface,
                            submission.paneID.rawValue,
                            tmuxOptions,
                            submission.userdata,
                            submission.callback
                        )
                    )
                }
            guard let requestResult else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            // Publish acceptance before the capture-pane command can leave
            // the writer queue. The callback therefore cannot overtake the
            // handle/source installation on MainActor.
            DispatchQueue.main.async {
                completion(requestResult.request)
            }
            drainOutbound()
        }
    }

    private func submit(
        request: Request,
        tracePaneID: TmuxPaneID? = nil,
        _ body: @escaping @Sendable (ghostty_tmux_session_t) -> ghostty_tmux_result_e
    ) {
        queue.async { [self] in
            guard let session else {
                if tracePaneID != nil {
                    GhosttyRuntimeTrace.flowEndIfActive(
                        GhosttyRuntimeTrace.paneSwitchFlow,
                        event: "tmux.request.rejected",
                        fields: ["reason": "missing_session"]
                    )
                }
                return
            }
            if let tracePaneID {
                GhosttyRuntimeTrace.flowEventIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "tmux.request.writer.begin",
                    fields: ["pane": "\(tracePaneID)"]
                )
            }
            let result = body(session)
            let outboundBytes = drainOutbound()
            if let tracePaneID {
                GhosttyRuntimeTrace.flowEventIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "tmux.request.outbound.drained",
                    fields: [
                        "bytes": "\(outboundBytes)",
                        "pane": "\(tracePaneID)",
                        "result": "\(result)",
                    ]
                )
                if result != GHOSTTY_TMUX_RESULT_OK {
                    GhosttyRuntimeTrace.flowEndIfActive(
                        GhosttyRuntimeTrace.paneSwitchFlow,
                        event: "tmux.request.rejected",
                        fields: [
                            "pane": "\(tracePaneID)",
                            "result": "\(result)",
                        ]
                    )
                }
            }
            reportImmediateRequestFailureIfNeeded(result, request: request)
        }
    }

    private func reportImmediateRequestFailureIfNeeded(
        _ result: ghostty_tmux_result_e,
        request: Request
    ) {
        preconditionOnWriterQueue()
        guard result != GHOSTTY_TMUX_RESULT_OK else { return }
        DispatchQueue.main.async { self.callbacks.onRequestFailed(request) }
    }
}

/// Preview arguments cross onto the tmux writer queue and are consumed there
/// exactly once. The strong style wrapper owns the borrowed-handle fence; no
/// raw surface pointer crosses the queue. The queue remains the sole owner of
/// the C session.
private struct TmuxPanePreviewSubmission: @unchecked Sendable {
    let paneID: TmuxPaneID
    let styleSurface: GhosttyKitControlSurface
    let options: ghostty_surface_preview_image_options_s
    let previewGrid: TmuxSessionController.ClientSize
    let userdata: UnsafeMutableRawPointer?
    let callback: ghostty_surface_preview_image_callback_f
}

/// The opaque request handle is transferred from the writer queue to
/// MainActor, where the preview lease becomes its sole owner.
private struct TmuxPanePreviewRequestResult: @unchecked Sendable {
    let request: ghostty_surface_preview_request_t?
}

// MARK: - C enum bridging

extension TmuxSessionController.Request {
    init(_ raw: ghostty_tmux_request_e) {
        switch raw {
        case GHOSTTY_TMUX_REQUEST_SPLIT_PANE: self = .splitPane
        case GHOSTTY_TMUX_REQUEST_CLOSE_PANE: self = .closePane
        case GHOSTTY_TMUX_REQUEST_CLOSE_WINDOW: self = .closeWindow
        case GHOSTTY_TMUX_REQUEST_SELECT_WINDOW: self = .selectWindow
        case GHOSTTY_TMUX_REQUEST_SELECT_PANE: self = .selectPane
        case GHOSTTY_TMUX_REQUEST_ZOOM_PANE: self = .zoomPane
        case GHOSTTY_TMUX_REQUEST_COPY_MODE: self = .copyMode
        case GHOSTTY_TMUX_REQUEST_SET_CLIENT_SIZE: self = .setClientSize
        default: self = .newWindow
        }
    }
}

extension TmuxSessionController.PaneState {
    init(_ raw: ghostty_tmux_pane_state_e) {
        switch raw {
        case GHOSTTY_TMUX_PANE_STATE_BOOTSTRAPPING: self = .bootstrapping
        case GHOSTTY_TMUX_PANE_STATE_LIVE: self = .live
        case GHOSTTY_TMUX_PANE_STATE_DEGRADED: self = .degraded
        default: self = .discovered
        }
    }
}
