import Foundation
import GhosttyKit
import UIKit

/// A surface projecting one tmux pane through the new session API.
///
/// Lifecycle contract (mirrors libghostty's): the binding is
/// established BEFORE the surface is created (the surface borrows the
/// pane terminal and render mutex at creation, for its whole life),
/// and MUST be released after the surface is freed in `close` order:
/// surface render stops -> surface freed -> binding unbound. Switching
/// panes means a new TmuxPaneSurface, never a rebind.
@MainActor
final class TmuxPaneSurface {
    let paneID: TmuxPaneID
    let instanceID = TerminalSurfaceInstanceID()
    let view: GhosttyKitSurfaceView

    private let surface: ghostty_surface_t
    private let binding: TmuxSessionController.PaneBinding
    private let controller: TmuxSessionController
    private let inputBox: InputBox
    private let wakeTarget: WakeTarget
    private var closed = false
    private var closeResult: Result<Void, TmuxSessionController.PaneReleaseError>?
    private var closeCompletions: [
        @MainActor @Sendable (Result<Void, TmuxSessionController.PaneReleaseError>) -> Void
    ] = []

    /// Invoked synchronously at the start of `close()`, before the
    /// surface is freed: host-side wrappers borrowing the surface
    /// handle (GhosttyKitControlSurface) invalidate themselves here so
    /// late calls from view teardown become no-ops instead of
    /// use-after-free.
    var onClose: (() -> Void)?

    /// Routes the manual backend's host callbacks (input writes and
    /// resize reports) to the session controller. Held with a stable
    /// address for the C callbacks.
    final class InputBox {
        let controller: TmuxSessionController
        let paneID: TmuxPaneID
        /// Only the visible pane surface reports the client viewport;
        /// in Remux's zoomed presentation that is this surface. Starts
        /// disabled: the view is created at a placeholder frame, and a
        /// report from it would force a server relayout at a bogus
        /// size. The adapter enables reporting on the first real
        /// layout-driven display update.
        var reportsClientSize = false

        init(controller: TmuxSessionController, paneID: TmuxPaneID) {
            self.controller = controller
            self.paneID = paneID
        }
    }

    enum CreateError: Error {
        case bindFailed(TmuxSessionController.BindError)
        case surfaceCreationFailed
    }

    /// C handles/configs crossing into the @Sendable bind completion;
    /// they are only used back on the main actor.
    private struct UncheckedSendable<T>: @unchecked Sendable {
        let value: T
    }

    /// Create a pane surface: bind first (writer queue), then build the
    /// surface with the binding in its config. Completion on main.
    static func create(
        app: ghostty_app_t,
        controller: TmuxSessionController,
        paneID: TmuxPaneID,
        baseConfig: ghostty_surface_config_s,
        theme: TerminalTheme,
        completion: @escaping @MainActor (Result<TmuxPaneSurface, CreateError>) -> Void
    ) {
        // The wake target doesn't exist until the surface does; bridge
        // through a box the wake closure reads after creation.
        let wakeTarget = WakeTarget()
        let appBox = UncheckedSendable(value: app)
        let configBox = UncheckedSendable(value: baseConfig)
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "materialization.bind.begin",
            fields: ["pane": "\(paneID)"]
        )
        controller.bind(
            paneID: paneID,
            wake: { [weak wakeTarget] in
                // Writer queue; ghostty_surface_refresh is a renderer
                // mailbox push and is thread-safe.
                wakeTarget?.requestRefresh()
            }
        ) { result in
            // The controller invokes completions on the main queue.
            MainActor.assumeIsolated {
            switch result {
            case .failure(let error):
                GhosttyRuntimeTrace.flowEndIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "materialization.bind.failed",
                    fields: [
                        "error": String(describing: error),
                        "pane": "\(paneID)",
                    ]
                )
                completion(.failure(.bindFailed(error)))
            case .success(let binding):
                GhosttyRuntimeTrace.flowEventIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "materialization.bind.ready",
                    fields: ["pane": "\(paneID)"]
                )
                GhosttyRuntimeTrace.flowEventIfActive(
                    GhosttyRuntimeTrace.paneSwitchFlow,
                    event: "materialization.hostSurface.begin",
                    fields: ["pane": "\(paneID)"]
                )
                if let pane = TmuxPaneSurface(
                    app: appBox.value,
                    controller: controller,
                    paneID: paneID,
                    binding: binding,
                    wakeTarget: wakeTarget,
                    baseConfig: configBox.value,
                    theme: theme
                ) {
                    wakeTarget.install(surface: pane.surface)
                    GhosttyRuntimeTrace.flowEventIfActive(
                        GhosttyRuntimeTrace.paneSwitchFlow,
                        event: "materialization.hostSurface.ready",
                        fields: [
                            "pane": "\(paneID)",
                            "surface": String(describing: pane.surface),
                        ]
                    )
                    completion(.success(pane))
                } else {
                    controller.unbindAndDematerialize(binding) { releaseResult in
                        if case .failure(let error) = releaseResult {
                            GhosttyRuntimeTrace.diagnostics(
                                "tmuxPane.create releaseFailed pane=\(paneID) error=\(error)"
                            )
                        }
                        GhosttyRuntimeTrace.flowEndIfActive(
                            GhosttyRuntimeTrace.paneSwitchFlow,
                            event: "materialization.hostSurface.failed",
                            fields: ["pane": "\(paneID)"]
                        )
                        completion(.failure(.surfaceCreationFailed))
                    }
                }
            }
            }
        }
    }

    /// The wake fires on the writer queue while the surface is set on
    /// the main queue: a real cross-thread handoff, guarded by a lock.
    private final class WakeTarget: @unchecked Sendable {
        private let lock = NSLock()
        private var _surface: ghostty_surface_t?
        private var allowsRefresh = false

        func install(surface: ghostty_surface_t) {
            lock.withLock {
                _surface = surface
            }
        }

        func requestRefresh() {
            let surface = lock.withLock {
                allowsRefresh ? _surface : nil
            }
            guard let surface else { return }
            ghostty_surface_refresh(surface)
        }

        func enableRefreshAfterInitialLayout() -> ghostty_surface_t? {
            lock.withLock {
                guard !allowsRefresh else { return nil }
                allowsRefresh = true
                return _surface
            }
        }

        func clear() {
            lock.withLock {
                _surface = nil
            }
        }
    }

    private init?(
        app: ghostty_app_t,
        controller: TmuxSessionController,
        paneID: TmuxPaneID,
        binding: TmuxSessionController.PaneBinding,
        wakeTarget: WakeTarget,
        baseConfig: ghostty_surface_config_s,
        theme: TerminalTheme
    ) {
        let inputBox = InputBox(controller: controller, paneID: paneID)

        var config = baseConfig
        let scale = max(Double(UIScreen.main.scale), 1)
        config.scale_factor = scale
        config.initial_focused = true

        let view = GhosttyKitSurfaceView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 600)
        )
        view.applyTerminalTheme(theme)
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))

        // The projected-terminal capability: manual backing (no PTY),
        // host input/resize callbacks, the pane binding borrowed at
        // creation.
        config.backing = GHOSTTY_SURFACE_BACKING_MANUAL
        config.tmux_binding = binding.rawHandle
        config.manual_userdata = Unmanaged.passUnretained(inputBox).toOpaque()
        config.manual_write = { userdata, ptr, len, linefeed in
            guard let userdata else { return false }
            let box = Unmanaged<InputBox>.fromOpaque(userdata).takeUnretainedValue()
            var bytes = if let ptr, len > 0 {
                Data(bytes: ptr, count: Int(len))
            } else {
                Data()
            }
            if linefeed { bytes.append(0x0D) }
            guard !bytes.isEmpty else { return true }
            return box.controller.sendInput(paneID: box.paneID, bytes)
        }
        config.manual_resize = { userdata, columns, rows, _, _ in
            guard let userdata else { return false }
            let box = Unmanaged<InputBox>.fromOpaque(userdata).takeUnretainedValue()
            if box.reportsClientSize {
                box.controller.setClientSize(
                    cols: UInt32(columns),
                    rows: UInt32(rows)
                )
            }
            return true
        }
        config.manual_focus = { _, _ in true }

        let nativeSurfaceStartedAt = GhosttyRuntimeTrace.flowTraceEnabled
            ? GhosttyRuntimeTrace.nowNanos() : 0
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "materialization.nativeSurface.begin",
            fields: ["pane": "\(paneID)"],
            at: nativeSurfaceStartedAt == 0 ? nil : nativeSurfaceStartedAt
        )
        guard let surface = ghostty_surface_new(app, &config) else {
            return nil
        }
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "materialization.nativeSurface.ready",
            fields: [
                "elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: nativeSurfaceStartedAt),
                "pane": "\(paneID)",
                "surface": String(describing: surface),
            ]
        )

        self.paneID = paneID
        self.view = view
        self.surface = surface
        self.binding = binding
        self.controller = controller
        self.inputBox = inputBox
        self.wakeTarget = wakeTarget
    }

    var rawSurface: ghostty_surface_t { surface }

    /// Enable viewport reporting after the first real layout and report
    /// the current grid once (the size changes the placeholder gate
    /// swallowed are re-derived from the live surface).
    func enableClientSizeReports() {
        guard !inputBox.reportsClientSize else { return }
        inputBox.reportsClientSize = true
        let size = ghostty_surface_size(surface)
        guard size.columns >= 2, size.rows >= 2 else { return }
        controller.setClientSize(
            cols: UInt32(size.columns),
            rows: UInt32(size.rows)
        )
    }

    /// The first render must happen after the real host viewport has
    /// sized the borrowed surface. Rendering before that uses the
    /// placeholder UIView frame and can flash a stale narrow grid.
    func refreshAfterInitialLayout() {
        guard let surface = wakeTarget.enableRefreshAfterInitialLayout() else { return }
        ghostty_surface_refresh(surface)
        GhosttyRuntimeTrace.flowEndIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "render.refresh.enqueued",
            fields: [
                "pane": "\(paneID)",
                "surface": String(describing: surface),
                "wall_ns": "\(GhosttyRuntimeTrace.wallNanos())",
            ]
        )
    }

    func setVisible(_ visible: Bool) {
        ghostty_surface_set_occlusion(surface, visible)
    }

    /// Teardown in contract order: free the surface (renderer stops and
    /// releases the borrowed mutex), unbind presentation, then discard the
    /// local engine. The remote pane remains alive in tmux. Completion on
    /// main.
    func close(
        completion: @escaping @MainActor @Sendable (Result<Void, TmuxSessionController.PaneReleaseError>) -> Void = { _ in }
    ) {
        if let closeResult {
            completion(closeResult)
            return
        }
        closeCompletions.append(completion)
        guard !closed else { return }
        closed = true
        onClose?()
        onClose = nil
        wakeTarget.clear()
        ghostty_surface_free(surface)
        let paneID = paneID
        controller.unbindAndDematerialize(binding) { [self] releaseResult in
            if case .failure(let error) = releaseResult {
                GhosttyRuntimeTrace.diagnostics(
                    "tmuxPane.close releaseFailed pane=\(paneID) error=\(error)"
                )
            }
            closeResult = releaseResult
            let completions = closeCompletions
            closeCompletions.removeAll()
            for completion in completions {
                completion(releaseResult)
            }
        }
    }

    isolated deinit {
        assert(closed, "TmuxPaneSurface deinit without close()")
    }
}
