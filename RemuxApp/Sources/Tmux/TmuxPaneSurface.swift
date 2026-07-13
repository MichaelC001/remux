import Foundation
import GhosttyKit
import UIKit

/// A surface projecting one tmux pane through the new session API.
///
/// Lifecycle contract (mirrors libghostty's): the binding is
/// established BEFORE the surface is created (the surface borrows the
/// pane terminal and render mutex at creation, for its whole life),
/// and MUST be released after the surface is freed in `close` order:
/// surface render stops -> surface freed -> binding unbound. The session
/// retains one instance per visited pane and reuses it across presentations.
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
    private let controlSurface: GhosttyKitControlSurface
    private(set) var managedSurface: GhosttyManagedSurface?
    private(set) var hasCompletedInitialLayout = false
    private var presentedWindowID: TmuxWindowID?
    private var closed = false
    private var closeResult: Result<Void, TmuxSessionController.PaneReleaseError>?
    private var closeCompletions: [
        @MainActor @Sendable (Result<Void, TmuxSessionController.PaneReleaseError>) -> Void
    ] = []

    /// Routes the manual backend's input writes to the session controller.
    /// Held with a stable address for the C callback.
    final class InputBox {
        let controller: TmuxSessionController
        let paneID: TmuxPaneID

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
        private var isVisible = false

        func install(surface: ghostty_surface_t) {
            lock.withLock {
                _surface = surface
            }
        }

        func requestRefresh() {
            // The lock is a native-lifetime fence, not only a state lock.
            // `clear()` must not return and let the main actor free the
            // surface while this writer-queue call is still using it.
            lock.withLock {
                guard allowsRefresh, isVisible, let surface = _surface else { return }
                ghostty_surface_refresh(surface)
            }
        }

        func setVisible(_ visible: Bool) {
            lock.withLock {
                isVisible = visible
            }
        }

        func enableRefreshAfterInitialLayout() -> Bool {
            lock.withLock {
                guard !allowsRefresh, _surface != nil else { return false }
                allowsRefresh = true
                return true
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
        // host input callbacks, the pane binding borrowed at creation.
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
        self.controlSurface = GhosttyKitControlSurface(
            surface: surface,
            ownership: .borrowed
        )
    }

    var rawSurface: ghostty_surface_t { surface }

    /// Build the screen-facing wrapper once and retain it beside the native
    /// surface. The borrowed control wrapper intentionally retains no pane
    /// owner: this object owns the wrapper, so a back-reference would cycle.
    func screenSurface(
        windowID: TmuxWindowID?,
        onDisplayUpdate: @escaping @MainActor (GhosttyManagedSurface, CGSize, CGFloat) -> Void
    ) -> GhosttyManagedSurface {
        presentedWindowID = windowID
        if let managedSurface {
            managedSurface.updateScrollState(controlSurface.scrollState())
            managedSurface.updateScrollRoute(controlSurface.scrollRoute())
            managedSurface.onDisplayUpdate = onDisplayUpdate
            return managedSurface
        }

        let paneID = paneID
        let controller = controller
        let managed = GhosttyManagedSurface(
            id: instanceID.rawValue,
            view: view,
            controlSurface: controlSurface,
            scrollState: controlSurface.scrollState(),
            scrollRoute: controlSurface.scrollRoute(),
            visibilityChanged: { [weak wakeTarget = self.wakeTarget] visible in
                wakeTarget?.setVisible(visible)
            },
            tmuxFocus: { [weak controller] in
                controller?.requestSelectPane(paneID: paneID)
                return .queued
            },
            tmuxSplit: { [weak controller] direction in
                let splitDirection: TmuxSessionController.SplitDirection = switch direction {
                case GHOSTTY_SPLIT_DIRECTION_LEFT: .left
                case GHOSTTY_SPLIT_DIRECTION_UP: .up
                case GHOSTTY_SPLIT_DIRECTION_DOWN: .down
                default: .right
                }
                controller?.requestSplit(
                    paneID: paneID,
                    direction: splitDirection,
                    zoom: true
                )
                return .queued
            },
            tmuxClosePane: { [weak controller] in
                controller?.requestClosePane(paneID: paneID)
                return .queued
            },
            tmuxCloseWindow: { [weak self, weak controller] in
                guard let windowID = self?.presentedWindowID else { return .noTarget }
                controller?.requestCloseWindow(windowID: windowID)
                return .queued
            },
            tmuxCopyMode: { [weak controller] in
                controller?.requestCopyMode(paneID: paneID)
                return .queued
            },
            releaseBeforePermanentRemoval: {},
            transferRuntimeSurfaceLifetimeToAppShutdown: {}
        )
        managed.onDisplayUpdate = onDisplayUpdate
        managedSurface = managed
        return managed
    }

    func updateWindowID(_ windowID: TmuxWindowID?) {
        presentedWindowID = windowID
    }

    /// Open writer-queue refresh delivery only after the real host viewport
    /// has sized the borrowed surface. The subsequent visibility transition
    /// queues the first render; submitting another refresh here would be
    /// duplicate renderer work.
    func completeInitialLayout() {
        guard wakeTarget.enableRefreshAfterInitialLayout() else { return }
        hasCompletedInitialLayout = true
    }

    func setPresented(_ presented: Bool) {
        if let managedSurface {
            managedSurface.setFocused(presented)
            managedSurface.setVisible(presented)
        } else {
            ghostty_surface_set_focus(surface, presented)
            ghostty_surface_set_occlusion(surface, presented)
        }
    }

    func applyTerminalTheme(_ theme: TerminalTheme) {
        view.applyTerminalTheme(theme)
    }

    var isClosing: Bool { closed }

    /// Final teardown in contract order: invalidate the stable wrapper, free
    /// the surface (renderer stops and releases the borrowed mutex), then
    /// unbind. Engine retirement remains libghostty/session-owned.
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
        managedSurface?.prepareForPermanentRemoval()
        controlSurface.invalidate()
        wakeTarget.clear()
        ghostty_surface_free(surface)
        let paneID = paneID
        controller.unbind(binding) { [self] releaseResult in
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
