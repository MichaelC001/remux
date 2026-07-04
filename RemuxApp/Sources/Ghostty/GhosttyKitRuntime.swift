import Foundation
import GhosttyKit
import QuartzCore
import UIKit
import Darwin

enum GhosttyKitRuntimeError: Error, Equatable {
    case initializationFailed(Int32)
    case processDirectoryConfigurationFailed(String)
    case environmentConfigurationFailed(String)
    case runtimeConfigurationFileFailed(String)
    case configCreationFailed
    case appCreationFailed
    case surfaceCreationFailed
}

struct GhosttyTerminalAppearance: Equatable {
    let fontSize: Float32?

    func apply(to config: inout ghostty_surface_config_s) {
        guard let fontSize, config.font_size == 0 else { return }
        config.font_size = fontSize
    }
}

enum GhosttyTerminalDeviceClass {
    case phone
    case pad
}

enum GhosttyTerminalAppearancePolicy {
    static let phoneMinimumFontSize: Float32 = 11
    static let phoneDefaultFontSize: Float32 = 11

    static func appearance(
        for settings: TerminalSettings,
        deviceClass: GhosttyTerminalDeviceClass,
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> GhosttyTerminalAppearance {
        if let fontSize = settings.fontSize {
            return GhosttyTerminalAppearance(fontSize: fontSize)
        }

        return appearance(
            for: deviceClass,
            contentSizeCategory: contentSizeCategory
        )
    }

    static func appearance(
        for deviceClass: GhosttyTerminalDeviceClass,
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> GhosttyTerminalAppearance {
        switch deviceClass {
        case .phone:
            GhosttyTerminalAppearance(
                fontSize: phoneFontSize(contentSizeCategory: contentSizeCategory)
            )
        case .pad:
            GhosttyTerminalAppearance(fontSize: nil)
        }
    }

    @MainActor
    static func currentDeviceAppearance(settings: TerminalSettings = .default) -> GhosttyTerminalAppearance {
        let contentSizeCategory = UIApplication.shared.preferredContentSizeCategory

        return switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            appearance(
                for: settings,
                deviceClass: .phone,
                contentSizeCategory: contentSizeCategory
            )
        case .pad:
            appearance(
                for: settings,
                deviceClass: .pad,
                contentSizeCategory: contentSizeCategory
            )
        default:
            GhosttyTerminalAppearance(fontSize: settings.fontSize)
        }
    }

    private static func phoneFontSize(contentSizeCategory: UIContentSizeCategory) -> Float32 {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        let scaledSize = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: CGFloat(phoneDefaultFontSize),
            compatibleWith: traits
        )

        return Float32(max(scaledSize, CGFloat(phoneMinimumFontSize)))
    }
}

private struct GhosttyTerminalRendererWarmupKey: Hashable {
    let theme: String
    let fontSize: Float32?
    let screenScale: Int
    let contentSizeCategory: String

    init(
        terminalSettings: TerminalSettings,
        screenScale: CGFloat,
        contentSizeCategory: UIContentSizeCategory
    ) {
        self.theme = terminalSettings.theme.rawValue
        self.fontSize = terminalSettings.fontSize
        self.screenScale = Int((screenScale * 1000).rounded())
        self.contentSizeCategory = contentSizeCategory.rawValue
    }
}

final class GhosttyKitSurfaceView: UIView {
    override init(frame: CGRect) {
        let initialFrame = frame.isEmpty
            ? CGRect(x: 0, y: 0, width: 1, height: 1)
            : frame
        super.init(frame: initialFrame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        alignGhosttyRendererSublayers()
    }

    func alignGhosttyRendererSublayers() {
        let scale = max(window?.screen.scale ?? contentScaleFactor, 1)
        layer.contentsScale = scale

        guard let sublayers = layer.sublayers else { return }
        for sublayer in sublayers {
            sublayer.frame = bounds
            sublayer.contentsScale = scale
            sublayer.setNeedsDisplay()
        }
    }

    func applyTerminalTheme(_ theme: TerminalTheme) {
        backgroundColor = theme.terminalBackgroundUIColor
    }

    private func configure() {
        applyTerminalTheme(.ghosttyDefault)
        clipsToBounds = true
        isOpaque = true
        contentScaleFactor = max(UIScreen.main.scale, 1)
    }
}

extension TerminalTheme {
    var terminalBackgroundUIColor: UIColor {
        let hex = terminalBackgroundHex
        return UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

@MainActor
final class GhosttyKitRuntime {
    typealias ManualWriteHandler = @Sendable (_ data: Data, _ linefeed: Bool) -> Bool
    typealias ManualResizeHandler = @Sendable (
        _ columns: UInt16,
        _ rows: UInt16,
        _ width: UInt32,
        _ height: UInt32
    ) -> Bool
    typealias ManualFocusHandler = @Sendable (_ focused: Bool) -> Bool

    private static var initialized = false
    @MainActor private static var terminalRendererWarmupKeys = Set<GhosttyTerminalRendererWarmupKey>()

    private let state: GhosttyKitRuntimeState

    init(
        surfaceDelegate: GhosttyKitRuntimeSurfaceDelegate? = nil,
        terminalSettings: TerminalSettings = .default
    ) throws {
        try Self.initializeBackend()
        state = try GhosttyKitRuntimeState(
            surfaceDelegate: surfaceDelegate,
            terminalSettings: terminalSettings
        )
    }

    /// The ghostty app handle for session-level APIs
    /// (ghostty_tmux_session_new); main-actor like the runtime.
    var appHandle: ghostty_app_t {
        state.app
    }

    /// Base surface config for new-architecture tmux pane surfaces:
    /// appearance applied from this runtime's settings; platform,
    /// scale, and the pane binding are set by the pane surface itself.
    func makeTmuxBaseSurfaceConfig() -> ghostty_surface_config_s {
        var config = ghostty_surface_config_new()
        GhosttyTerminalAppearancePolicy
            .currentDeviceAppearance(settings: state.terminalSettings)
            .apply(to: &config)
        return config
    }

    @MainActor
    static func prewarmTerminalRenderer(terminalSettings: TerminalSettings) {
        let key = GhosttyTerminalRendererWarmupKey(
            terminalSettings: terminalSettings,
            screenScale: UIScreen.main.scale,
            contentSizeCategory: UIApplication.shared.preferredContentSizeCategory
        )
        guard !terminalRendererWarmupKeys.contains(key) else { return }

        let start = GhosttyRuntimeTrace.nowNanos()
        do {
            let runtime = try GhosttyKitRuntime(terminalSettings: terminalSettings)
            _ = try runtime.measureTmuxViewport(
                size: CGSize(width: 96, height: 96),
                scale: UIScreen.main.scale
            )
            terminalRendererWarmupKeys.insert(key)
            GhosttyRuntimeTrace.perf(
                "runtime.prewarmTerminalRenderer result=success elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
        } catch {
            GhosttyRuntimeTrace.diagnostics(
                "runtime.prewarmTerminalRenderer failed error=\(String(describing: error))"
            )
        }
    }

    @MainActor
    func measureTmuxViewport(size: CGSize, scale: CGFloat) throws -> TmuxControlViewport? {
        let normalizedSize = GhosttyTerminalViewportCoordinator.normalized(size)
        guard normalizedSize.width > 1, normalizedSize.height > 1 else { return nil }

        let view = GhosttyKitSurfaceView(frame: CGRect(origin: .zero, size: normalizedSize))
        view.contentScaleFactor = max(scale, 1)

        return try withExtendedLifetime(view) {
            let surface = try makeManualHostSurface(
                view: view,
                initialSize: normalizedSize
            )
            return TmuxControlViewport(ghosttySurfaceSize: surface.currentSize())
        }
    }

#if DEBUG
    var appHandleForTesting: ghostty_app_t {
        state.app
    }
#endif

    func makeManualHostSurface(
        view: UIView,
        initialSize: CGSize? = nil,
        onWrite: ManualWriteHandler? = nil,
        onResize: ManualResizeHandler? = nil,
        onFocus: ManualFocusHandler? = nil
    ) throws -> GhosttyKitControlSurface {
        let callbacks = GhosttyKitManualSurfaceCallbacks(
            onWrite: onWrite,
            onResize: onResize,
            onFocus: onFocus
        )

        var surfaceConfig = ghostty_surface_config_new()
        GhosttyTerminalAppearancePolicy
            .currentDeviceAppearance(settings: state.terminalSettings)
            .apply(to: &surfaceConfig)
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))
        surfaceConfig.scale_factor = max(Double(view.contentScaleFactor), 1)
        let metrics = GhosttySurfaceDisplayMetrics(
            size: initialSize ?? view.bounds.size,
            scale: view.contentScaleFactor
        )
        surfaceConfig.initial_width_px = metrics.pixelWidth
        surfaceConfig.initial_height_px = metrics.pixelHeight
        surfaceConfig.initial_focused = false
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surfaceConfig.backing = GHOSTTY_SURFACE_BACKING_MANUAL
        surfaceConfig.manual_userdata = callbacks.userdata
        surfaceConfig.manual_write = callbacks.writeCallback
        surfaceConfig.manual_resize = callbacks.resizeCallback
        surfaceConfig.manual_focus = callbacks.focusCallback

        guard let surface = ghostty_surface_new(state.app, &surfaceConfig) else {
            throw GhosttyKitRuntimeError.surfaceCreationFailed
        }

        return GhosttyKitControlSurface(
            surface: surface,
            ownership: .storageOwned,
            retainedObjects: [state, callbacks]
        )
    }

    func applyTerminalSettings(_ settings: TerminalSettings) throws {
        try state.applyTerminalSettings(settings)
    }

    private static func initializeBackend() throws {
        guard !initialized else { return }

        try configureProcessDirectories()

        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            throw GhosttyKitRuntimeError.initializationFailed(result)
        }

        initialized = true
    }

    private static func configureProcessDirectories() throws {
        let home = NSHomeDirectory()
        let applicationSupport = "\(home)/Library/Application Support"
        let caches = "\(home)/Library/Caches"

        try createDirectoryIfNeeded(at: applicationSupport)
        try createDirectoryIfNeeded(at: caches)

        try setEnvironment("HOME", to: home)
        try setEnvironment("XDG_CONFIG_HOME", to: applicationSupport)
        try setEnvironment("XDG_CACHE_HOME", to: caches)
        try setEnvironment("XDG_STATE_HOME", to: applicationSupport)
    }

    private static func createDirectoryIfNeeded(at path: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true
            )
        } catch {
            throw GhosttyKitRuntimeError.processDirectoryConfigurationFailed(path)
        }
    }

    private static func setEnvironment(_ name: String, to value: String) throws {
        guard getenv(name) == nil else { return }

        let result = name.withCString { namePointer in
            value.withCString { valuePointer in
                setenv(namePointer, valuePointer, 1)
            }
        }

        guard result == 0 else {
            throw GhosttyKitRuntimeError.environmentConfigurationFailed(name)
        }
    }
}

private final class GhosttyKitRuntimeState {
    let app: ghostty_app_t
    private(set) var terminalSettings: TerminalSettings

    private let config: ghostty_config_t
    private let callbacks: GhosttyKitRuntimeCallbacks

    @MainActor
    init(
        surfaceDelegate: GhosttyKitRuntimeSurfaceDelegate?,
        terminalSettings: TerminalSettings
    ) throws {
        guard let config = ghostty_config_new() else {
            throw GhosttyKitRuntimeError.configCreationFailed
        }
        let appearance = GhosttyTerminalAppearancePolicy.currentDeviceAppearance(settings: terminalSettings)
        try Self.loadSettings(
            terminalSettings,
            into: config,
            effectiveFontSize: appearance.fontSize
        )
        ghostty_config_finalize(config)

        let callbackLease = surfaceDelegate?.makeRuntimeCallbackLease()
        let callbacks = GhosttyKitRuntimeCallbacks(callbackLease: callbackLease)
        callbacks.surfaceDelegate = surfaceDelegate
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: callbacks.userdata,
            supports_selection_clipboard: false,
            wakeup_cb: GhosttyKitRuntimeCallbacks.wakeupCallback,
            action_cb: GhosttyKitRuntimeCallbacks.actionCallback,
            read_clipboard_cb: nil,
            confirm_read_clipboard_cb: nil,
            write_clipboard_cb: nil,
            close_surface_cb: nil,
            select_surface_cb: GhosttyKitRuntimeCallbacks.selectSurfaceCallback,
            create_surface_cb: GhosttyKitRuntimeCallbacks.createSurfaceCallback,
            create_surface_tree_cb: GhosttyKitRuntimeCallbacks.createSurfaceTreeCallback
        )

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            callbacks.invalidateCallbackLease()
            ghostty_config_free(config)
            throw GhosttyKitRuntimeError.appCreationFailed
        }

        self.app = app
        self.config = config
        self.callbacks = callbacks
        self.terminalSettings = terminalSettings
        callbacks.app = app
    }

    deinit {
        // A wakeup callback may have queued a MainActor tick. Clear the pointer
        // before freeing so the queued task cannot tick a destroyed app.
        callbacks.app = nil
        callbacks.invalidateCallbackLease()
        ghostty_app_free(app)
        ghostty_config_free(config)
        _ = callbacks
    }

    @MainActor
    func applyTerminalSettings(_ settings: TerminalSettings) throws {
        guard settings != terminalSettings else { return }

        guard let config = ghostty_config_new() else {
            throw GhosttyKitRuntimeError.configCreationFailed
        }
        defer { ghostty_config_free(config) }

        let appearance = GhosttyTerminalAppearancePolicy.currentDeviceAppearance(settings: settings)
        try Self.loadSettings(
            settings,
            into: config,
            effectiveFontSize: appearance.fontSize
        )
        ghostty_config_finalize(config)

        GhosttyRuntimeTrace.diagnostics(
            "runtime.applyTerminalSettings theme=\(settings.theme.rawValue) fontSize=\(appearance.fontSize.map(String.init(describing:)) ?? "nil")"
        )
        ghostty_app_update_config(app, config)
        terminalSettings = settings
    }

    private static func loadSettings(
        _ settings: TerminalSettings,
        into config: ghostty_config_t,
        effectiveFontSize: Float32?
    ) throws {
        guard let contents = settings.ghosttyConfigContents(effectiveFontSize: effectiveFontSize) else {
            return
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-ghostty-\(UUID().uuidString).conf")

        do {
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw GhosttyKitRuntimeError.runtimeConfigurationFileFailed(fileURL.path)
        }
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        fileURL.path.withCString { path in
            ghostty_config_load_file(config, path)
        }
    }
}

private final class GhosttyKitRuntimeCallbacks: @unchecked Sendable {
    var app: ghostty_app_t?
    weak var surfaceDelegate: GhosttyKitRuntimeSurfaceDelegate?
    let callbackLease: GhosttyRuntimeCallbackLease?

    init(callbackLease: GhosttyRuntimeCallbackLease?) {
        self.callbackLease = callbackLease
    }

    var userdata: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    func acceptsRuntimeCallback() -> Bool {
        guard let callbackLease else { return false }
        return surfaceDelegate?.acceptsRuntimeCallback(callbackLease) ?? false
    }

    func acceptsWakeupCallback() -> Bool {
        guard callbackLease != nil else { return true }
        return acceptsRuntimeCallback()
    }

    func invalidateCallbackLease() {
        guard let callbackLease else { return }
        surfaceDelegate?.runtimeCallbackLeaseDidEnd(callbackLease)
    }

    private static func traceTopologyCallback(
        _ event: String,
        fields: @autoclosure () -> [String: String] = [:]
    ) {
        GhosttyTmuxActionTrace.traceActiveTopologyFlows(event: event, fields: fields())
    }

    private static func callbackThreadField() -> String {
        Thread.isMainThread ? "main" : "background"
    }

    private static func createSurfaceTraceFields(
        request: GhosttyRuntimeSurfaceCreationRequest,
        route: String
    ) -> [String: String] {
        [
            "context": request.context.map { String(describing: $0) } ?? "nil",
            "route": route,
            "thread": callbackThreadField(),
        ]
    }

    private static func createSurfaceTreeTraceFields(
        request: GhosttyRuntimeSurfaceTreeCreationRequest,
        route: String
    ) -> [String: String] {
        [
            "focusedIndex": "\(request.focusedLeafIndex)",
            "focusedValid": "\(request.focusedLeafIndexIsValid)",
            "leaves": "\(request.leafSurfaceCount)",
            "nodes": "\(request.nodeCount)",
            "route": route,
            "thread": callbackThreadField(),
        ]
    }

    private static func wakeupTraceFields(
        route: String,
        entryThread: String
    ) -> [String: String] {
        [
            "entryThread": entryThread,
            "route": route,
        ]
    }

    static var wakeupCallback: ghostty_runtime_wakeup_cb {
        { userdata in
            GhosttyKitRuntimeCallbacks.wakeup(userdata)
        }
    }

    static var actionCallback: ghostty_runtime_action_cb {
        { app, target, action in
            GhosttyKitRuntimeCallbacks.action(app, target: target, action: action)
        }
    }


    static var selectSurfaceCallback: ghostty_runtime_select_surface_cb {
        { app, surface in
            GhosttyKitRuntimeCallbacks.selectSurface(app, surface: surface)
        }
    }

    static var createSurfaceCallback: ghostty_runtime_create_surface_cb {
        { app, request in
            GhosttyKitRuntimeCallbacks.createSurface(app, request: request)
        }
    }

    static var createSurfaceTreeCallback: ghostty_runtime_create_surface_tree_cb {
        { app, request in
            GhosttyKitRuntimeCallbacks.createSurfaceTree(app, request: request)
        }
    }


    static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let callbacks = from(userdata: userdata) else { return }
        guard callbacks.acceptsWakeupCallback() else { return }
        let entryThread = GhosttyRuntimeTrace.flowTraceEnabled ? callbackThreadField() : ""
        traceTopologyCallback(
            "runtime.wakeup.entry",
            fields: wakeupTraceFields(route: "async", entryThread: entryThread)
        )
        traceTopologyCallback(
            "runtime.wakeup.mainActor.schedule",
            fields: wakeupTraceFields(route: "async", entryThread: entryThread)
        )
        Task { @MainActor in
            guard callbacks.acceptsWakeupCallback() else { return }
            guard let app = callbacks.app else { return }
            traceTopologyCallback(
                "runtime.wakeup.mainActor.begin",
                fields: wakeupTraceFields(route: "async", entryThread: entryThread)
            )
            traceTopologyCallback(
                "runtime.wakeup.appTick.begin",
                fields: wakeupTraceFields(route: "async", entryThread: entryThread)
            )
            if let lease = callbacks.callbackLease {
                callbacks.surfaceDelegate?.withRuntimeCallbackBatch(lease: lease) {
                    ghostty_app_tick(app)
                }
            } else {
                ghostty_app_tick(app)
            }
            traceTopologyCallback(
                "runtime.wakeup.appTick.end",
                fields: wakeupTraceFields(route: "async", entryThread: entryThread)
            )
        }
    }

    static func action(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let callbacks = from(app: app) else { return true }
        guard let lease = callbacks.callbackLease,
              callbacks.acceptsRuntimeCallback()
        else {
            return true
        }
        let appBox = UnsafeSendable(app)
        let targetBox = UnsafeSendable(GhosttyRuntimeSurfaceActionTarget(native: target))
        let actionBox = UnsafeSendable(GhosttyRuntimeSurfaceAction(native: action))
        let leaseBox = UnsafeSendable(lease)
        if Thread.isMainThread {
            GhosttyRuntimeTrace.perf("runtime.action route=main")
            return MainActor.assumeIsolated {
                callbacks.surfaceDelegate?.runtimeAction(
                    app: appBox.value,
                    target: targetBox.value,
                    action: actionBox.value,
                    lease: leaseBox.value
                ) ?? true
            }
        } else {
            return GhosttyRuntimeTrace.perfMeasure("runtime.action route=sync") {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        callbacks.surfaceDelegate?.runtimeAction(
                            app: appBox.value,
                            target: targetBox.value,
                            action: actionBox.value,
                            lease: leaseBox.value
                        ) ?? true
                    }
                }
            }
        }
    }


    static func createSurface(
        _ app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s
    ) -> ghostty_surface_t? {
        guard let callbacks = from(app: app) else { return nil }
        guard let lease = callbacks.callbackLease,
              callbacks.acceptsRuntimeCallback()
        else {
            return nil
        }
        let appBox = UnsafeSendable(app)
        let requestBox = UnsafeSendable(GhosttyRuntimeSurfaceCreationRequest(native: request))
        let leaseBox = UnsafeSendable(lease)
        if Thread.isMainThread {
            GhosttyRuntimeTrace.perf("runtime.createSurface route=main")
            traceTopologyCallback(
                "runtime.callback.createSurface.entry",
                fields: createSurfaceTraceFields(request: requestBox.value, route: "direct")
            )
            traceTopologyCallback(
                "runtime.callback.createSurface.mainActor.begin",
                fields: createSurfaceTraceFields(request: requestBox.value, route: "direct")
            )
            return MainActor.assumeIsolated {
                UnsafeSendable(callbacks.surfaceDelegate?.runtimeCreateSurface(
                    app: appBox.value,
                    request: requestBox.value,
                    lease: leaseBox.value
                ))
            }.value
        } else {
            traceTopologyCallback(
                "runtime.callback.createSurface.entry",
                fields: createSurfaceTraceFields(request: requestBox.value, route: "sync")
            )
            traceTopologyCallback(
                "runtime.callback.createSurface.mainActor.schedule",
                fields: createSurfaceTraceFields(request: requestBox.value, route: "sync")
            )
            return GhosttyRuntimeTrace.perfMeasure("runtime.createSurface route=sync") {
                let result: UnsafeSendable<ghostty_surface_t?> = DispatchQueue.main.sync {
                    traceTopologyCallback(
                        "runtime.callback.createSurface.mainActor.begin",
                        fields: createSurfaceTraceFields(request: requestBox.value, route: "sync")
                    )
                    return MainActor.assumeIsolated {
                        UnsafeSendable(callbacks.surfaceDelegate?.runtimeCreateSurface(
                            app: appBox.value,
                            request: requestBox.value,
                            lease: leaseBox.value
                        ))
                    }
                }
                return result
            }.value
        }
    }

    static func createSurfaceTree(
        _ app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_tree_s
    ) -> Bool {
        guard let callbacks = from(app: app) else { return false }
        guard let lease = callbacks.callbackLease,
              callbacks.acceptsRuntimeCallback()
        else {
            return false
        }
        let appBox = UnsafeSendable(app)
        let requestBox = UnsafeSendable(
            GhosttyRuntimeTrace.perfMeasure("runtime.createSurfaceTree.decode") {
                GhosttyRuntimeSurfaceTreeCreationRequest(native: request)
            }
        )
        let leaseBox = UnsafeSendable(lease)
        if Thread.isMainThread {
            GhosttyRuntimeTrace.perf("runtime.createSurfaceTree route=main")
            traceTopologyCallback(
                "runtime.callback.createSurfaceTree.entry",
                fields: createSurfaceTreeTraceFields(request: requestBox.value, route: "direct")
            )
            traceTopologyCallback(
                "runtime.callback.createSurfaceTree.mainActor.begin",
                fields: createSurfaceTreeTraceFields(request: requestBox.value, route: "direct")
            )
            return MainActor.assumeIsolated {
                callbacks.surfaceDelegate?.runtimeCreateSurfaceTree(
                    app: appBox.value,
                    request: requestBox.value,
                    lease: leaseBox.value
                ) ?? false
            }
        } else {
            traceTopologyCallback(
                "runtime.callback.createSurfaceTree.entry",
                fields: createSurfaceTreeTraceFields(request: requestBox.value, route: "sync")
            )
            traceTopologyCallback(
                "runtime.callback.createSurfaceTree.mainActor.schedule",
                fields: createSurfaceTreeTraceFields(request: requestBox.value, route: "sync")
            )
            return GhosttyRuntimeTrace.perfMeasure("runtime.createSurfaceTree route=sync") {
                let result: Bool = DispatchQueue.main.sync {
                    traceTopologyCallback(
                        "runtime.callback.createSurfaceTree.mainActor.begin",
                        fields: createSurfaceTreeTraceFields(request: requestBox.value, route: "sync")
                    )
                    return MainActor.assumeIsolated {
                        callbacks.surfaceDelegate?.runtimeCreateSurfaceTree(
                            app: appBox.value,
                            request: requestBox.value,
                            lease: leaseBox.value
                        ) ?? false
                    }
                }
                return result
            }
        }
    }

    static func selectSurface(
        _ app: ghostty_app_t?,
        surface: ghostty_surface_t?
    ) {
        guard let callbacks = from(app: app) else { return }
        guard let lease = callbacks.callbackLease,
              callbacks.acceptsRuntimeCallback()
        else {
            return
        }
        let appBox = UnsafeSendable(app)
        let surfaceBox = UnsafeSendable(surface)
        let leaseBox = UnsafeSendable(lease)
        if Thread.isMainThread {
            GhosttyRuntimeTrace.perf("runtime.selectSurface route=main")
            MainActor.assumeIsolated {
                callbacks.surfaceDelegate?.runtimeSelectSurface(
                    app: appBox.value,
                    surface: surfaceBox.value,
                    lease: leaseBox.value
                )
            }
        } else {
            GhosttyRuntimeTrace.perfMeasure("runtime.selectSurface route=sync") {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        callbacks.surfaceDelegate?.runtimeSelectSurface(
                            app: appBox.value,
                            surface: surfaceBox.value,
                            lease: leaseBox.value
                        )
                    }
                }
            }
        }
    }


    private static func from(app: ghostty_app_t?) -> GhosttyKitRuntimeCallbacks? {
        guard let app else { return nil }
        guard let userdata = ghostty_app_userdata(app) else { return nil }
        return Unmanaged<GhosttyKitRuntimeCallbacks>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func from(userdata: UnsafeMutableRawPointer?) -> GhosttyKitRuntimeCallbacks? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyKitRuntimeCallbacks>.fromOpaque(userdata).takeUnretainedValue()
    }
}

private struct UnsafeSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class GhosttyKitManualSurfaceCallbacks: @unchecked Sendable {
    private let onWrite: GhosttyKitRuntime.ManualWriteHandler?
    private let onResize: GhosttyKitRuntime.ManualResizeHandler?
    private let onFocus: GhosttyKitRuntime.ManualFocusHandler?

    init(
        onWrite: GhosttyKitRuntime.ManualWriteHandler?,
        onResize: GhosttyKitRuntime.ManualResizeHandler?,
        onFocus: GhosttyKitRuntime.ManualFocusHandler?
    ) {
        self.onWrite = onWrite
        self.onResize = onResize
        self.onFocus = onFocus
    }

    var userdata: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    var writeCallback: ghostty_surface_manual_write_cb? {
        guard onWrite != nil else { return nil }
        return { userdata, data, count, linefeed in
            GhosttyKitManualSurfaceCallbacks.writeThunk(userdata, data, count, linefeed)
        }
    }

    var resizeCallback: ghostty_surface_manual_resize_cb? {
        guard onResize != nil else { return nil }
        return { userdata, columns, rows, width, height in
            GhosttyKitManualSurfaceCallbacks.resizeThunk(userdata, columns, rows, width, height)
        }
    }

    var focusCallback: ghostty_surface_manual_focus_cb? {
        guard onFocus != nil else { return nil }
        return { userdata, focused in
            GhosttyKitManualSurfaceCallbacks.focusThunk(userdata, focused)
        }
    }

    private static func writeThunk(
        _ userdata: UnsafeMutableRawPointer?,
        _ data: UnsafePointer<CChar>?,
        _ count: Int,
        _ linefeed: Bool
    ) -> Bool {
        write(userdata, data: data, count: count, linefeed: linefeed)
    }

    private static func resizeThunk(
        _ userdata: UnsafeMutableRawPointer?,
        _ columns: UInt16,
        _ rows: UInt16,
        _ width: UInt32,
        _ height: UInt32
    ) -> Bool {
        resize(userdata, columns: columns, rows: rows, width: width, height: height)
    }

    private static func focusThunk(
        _ userdata: UnsafeMutableRawPointer?,
        _ focused: Bool
    ) -> Bool {
        focus(userdata, focused: focused)
    }

    private static func write(
        _ userdata: UnsafeMutableRawPointer?,
        data: UnsafePointer<CChar>?,
        count: Int,
        linefeed: Bool
    ) -> Bool {
        guard let callbacks = from(userdata: userdata) else { return false }
        guard let onWrite = callbacks.onWrite else { return true }
        guard count >= 0 else { return false }

        if count == 0 {
            return onWrite(Data(), linefeed)
        }

        guard let data else { return false }
        return onWrite(Data(bytes: data, count: count), linefeed)
    }

    private static func resize(
        _ userdata: UnsafeMutableRawPointer?,
        columns: UInt16,
        rows: UInt16,
        width: UInt32,
        height: UInt32
    ) -> Bool {
        guard let callbacks = from(userdata: userdata) else { return false }
        guard let onResize = callbacks.onResize else { return true }
        return onResize(columns, rows, width, height)
    }

    private static func focus(
        _ userdata: UnsafeMutableRawPointer?,
        focused: Bool
    ) -> Bool {
        guard let callbacks = from(userdata: userdata) else { return false }
        guard let onFocus = callbacks.onFocus else { return true }
        return onFocus(focused)
    }

    private static func from(userdata: UnsafeMutableRawPointer?) -> GhosttyKitManualSurfaceCallbacks? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyKitManualSurfaceCallbacks>.fromOpaque(userdata).takeUnretainedValue()
    }
}
