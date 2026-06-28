@preconcurrency import Citadel
import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

struct SSHTmuxControlConfiguration: Sendable {
    let host: String
    let port: Int
    let authenticationMethod: @Sendable () throws -> SSHAuthenticationMethod
    let hostKeyValidator: SSHHostKeyValidator
    let connectTimeout: TimeAmount
    let controlNoResponseTimeout: TimeAmount
    let tmuxExecutable: String
    let sessionName: String
    let initialViewport: TmuxControlViewport
    let traceFlowID: String?
    let sshRootKey: RemuxSSHRootKey?

    init(
        host: String,
        port: Int = 22,
        authenticationMethod: @escaping @Sendable () throws -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeout: TimeAmount = .seconds(30),
        controlNoResponseTimeout: TimeAmount = .seconds(15),
        tmuxExecutable: String = "tmux",
        sessionName: String,
        initialViewport: TmuxControlViewport = .default,
        traceFlowID: String? = nil,
        sshRootKey: RemuxSSHRootKey? = nil
    ) {
        self.host = host
        self.port = port
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
        self.connectTimeout = connectTimeout
        self.controlNoResponseTimeout = controlNoResponseTimeout
        self.tmuxExecutable = tmuxExecutable
        self.sessionName = sessionName
        self.initialViewport = initialViewport
        self.traceFlowID = traceFlowID
        self.sshRootKey = sshRootKey
    }

    var sshRootConfiguration: RemuxSSHRootConfiguration {
        RemuxSSHRootConfiguration(
            host: host,
            port: port,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator,
            connectTimeout: connectTimeout
        )
    }
}

struct SSHTmuxControlChannelCompletionState: Equatable, Sendable {
    private var didFinish = false
    private var exitStatus: Int?

    mutating func recordExitStatus(_ status: Int) {
        exitStatus = status
    }

    mutating func finish(
        _ error: Error?,
        diagnostics: SSHTmuxStartupDiagnostics?
    ) -> Result<Void, Error>? {
        guard !didFinish else { return nil }
        didFinish = true

        if let error {
            return .failure(error)
        }

        if let exitStatus, exitStatus != 0 {
            return .failure(
                SSHTmuxControlTransportError.remoteExit(
                    exitStatus,
                    diagnostics: diagnostics
                )
            )
        }

        return .success(())
    }
}

final class SSHTmuxControlFirstOutputGate: @unchecked Sendable {
    private let lock = NIOLock()
    private let promise: EventLoopPromise<Void>
    private var isCompleted = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func succeed() {
        complete {
            promise.succeed(())
        }
    }

    func fail(_ error: Error) {
        complete {
            promise.fail(error)
        }
    }

    private func complete(_ body: () -> Void) {
        let shouldComplete = lock.withLock {
            guard !isCompleted else { return false }
            isCompleted = true
            return true
        }

        guard shouldComplete else { return }
        body()
    }
}

enum SSHTmuxControlTransportError: LocalizedError, Equatable, CustomStringConvertible {
    case remoteExit(Int, diagnostics: SSHTmuxStartupDiagnostics? = nil)
    case channelRequestFailed(SSHTmuxControlChannelRequestKind, diagnostics: SSHTmuxStartupDiagnostics? = nil)
    case unsupportedInboundChannel
    case alreadyStarted
    case closed
    case stalePreparedConnection
    case controlSessionNoResponse(TimeAmount)

    var description: String {
        switch self {
        case .remoteExit(let code, let diagnostics):
            return Self.describe(
                "remoteExit(\(code))",
                diagnostics: diagnostics
            )
        case .channelRequestFailed(let request, let diagnostics):
            return Self.describe(
                "SSH \(request.description) request failed",
                diagnostics: diagnostics
            )
        case .unsupportedInboundChannel:
            return "unsupportedInboundChannel"
        case .alreadyStarted:
            return "alreadyStarted"
        case .closed:
            return "closed"
        case .stalePreparedConnection:
            return "stalePreparedConnection"
        case .controlSessionNoResponse(let timeout):
            return "tmux control session produced no output within \(timeout)"
        }
    }

    var errorDescription: String? {
        switch self {
        case .remoteExit(let code, _):
            return "The remote tmux control session exited with status \(code)."
        case .channelRequestFailed(let request, _):
            return "The SSH server rejected the \(request.description) request."
        case .unsupportedInboundChannel:
            return "Remux received an unexpected SSH channel type."
        case .alreadyStarted:
            return "The tmux control transport has already started."
        case .closed:
            return "The tmux control transport has already been closed."
        case .stalePreparedConnection:
            return "The prepared SSH root reservation is no longer valid."
        case .controlSessionNoResponse(let timeout):
            return "The remote tmux control session produced no output within \(timeout)."
        }
    }

    private static func describe(
        _ base: String,
        diagnostics: SSHTmuxStartupDiagnostics?
    ) -> String {
        guard let diagnostics else { return base }
        return "\(base) \(diagnostics)"
    }
}

actor SSHTmuxControlTransport: TmuxControlTransport, SSHTmuxControlChannelActiveChecking {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let configuration: SSHTmuxControlConfiguration
    private let inboundStream: SSHTmuxControlInboundStream
    private let sshRootService: RemuxSSHRootService?

    private var resizeState: TmuxViewportResizeState
    private var pendingWrites: [Data] = []
    private var preparedRoot: RemuxSSHPreparedRoot?
    private var connection: SSHTmuxControlConnection?
    private var hasStarted = false
    private var isClosed = false

    init(
        configuration: SSHTmuxControlConfiguration,
        sshRootService: RemuxSSHRootService? = nil
    ) {
        self.configuration = configuration
        self.sshRootService = sshRootService
        self.resizeState = TmuxViewportResizeState(initialViewport: configuration.initialViewport)
        let inboundStream = SSHTmuxControlInboundStream()
        self.inboundStream = inboundStream
        self.receivedBytes = inboundStream.receivedBytes
    }

    func prepare() async {
        guard !isClosed, preparedRoot == nil, connection == nil, !hasStarted else { return }

        preparedRoot = await makePreparedRoot()
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        guard !isClosed else { throw SSHTmuxControlTransportError.closed }
        guard !hasStarted else { throw SSHTmuxControlTransportError.alreadyStarted }
        hasStarted = true
        if let initialViewport {
            resizeState.request(initialViewport)
        }

        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "transport.start begin host=\(configuration.host):\(configuration.port) session=\(configuration.sessionName)"
        )
        let preparedRoot: RemuxSSHPreparedRoot
        if let existingPreparedRoot = self.preparedRoot {
            preparedRoot = existingPreparedRoot
        } else {
            preparedRoot = await makePreparedRoot()
        }
        self.preparedRoot = preparedRoot
        let startupTrace = preparedRoot.trace
        var startedConnection: SSHTmuxControlConnection?
        let establishedConnection: SSHTmuxControlConnection
        do {
            let sshRoot = try await startupTrace.stage("sshRoot.ready") {
                try await preparedRoot.sshRoot()
            }
            self.preparedRoot = nil
            guard !isClosed else { throw SSHTmuxControlTransportError.closed }
            let startupViewport = resizeState.latestViewport
            GhosttyRuntimeTrace.tmuxViewport(
                "startup.attach session=\(configuration.sessionName) viewport=\(GhosttyRuntimeTrace.viewportDescription(startupViewport)) initialProvided=\(initialViewport != nil)"
            )
            let claimedConnection = try await preparedRoot.claim(
                sshRoot,
                trace: startupTrace
            )
            guard !isClosed else {
                await claimedConnection.release(.reusable)
                throw SSHTmuxControlTransportError.closed
            }
            establishedConnection = try await SSHTmuxControlBootstrap.openControlSession(
                using: claimedConnection,
                viewport: startupViewport,
                command: tmuxAttachCommand(viewport: startupViewport),
                controlNoResponseTimeout: configuration.controlNoResponseTimeout,
                trace: startupTrace,
                onOutput: { [inboundStream] data in
                    inboundStream.yield(data)
                },
                onFinish: { [inboundStream] error in
                    inboundStream.finish(error)
                }
            )
            startedConnection = establishedConnection
            guard !isClosed else { throw SSHTmuxControlTransportError.closed }
            connection = establishedConnection
            resizeState.markApplied(startupViewport)
            try await drainResizeQueueIfNeeded(using: establishedConnection)
            startedConnection = nil
        } catch {
            self.preparedRoot = nil
            self.connection = nil
            await startedConnection?.close(disposition: closeDispositionAfterStartFailure(error))
            throw error
        }

        let queuedWrites = pendingWrites
        pendingWrites.removeAll(keepingCapacity: true)
        startupTrace.event(
            "queuedWrites.begin",
            fields: ["count": "\(queuedWrites.count)"]
        )
        for data in queuedWrites {
            try await establishedConnection.write(data)
        }
        startupTrace.event(
            "queuedWrites.end",
            fields: ["count": "\(queuedWrites.count)"]
        )
        startupTrace.event(
            "end",
            fields: ["queuedWrites": "\(queuedWrites.count)"]
        )
        GhosttyRuntimeTrace.latency(
            "transport.start end queuedWrites=\(queuedWrites.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        guard !isClosed else { throw SSHTmuxControlTransportError.closed }

        let start = GhosttyRuntimeTrace.nowNanos()
        guard let connection else {
            pendingWrites.append(data)
            GhosttyRuntimeTrace.latency(
                "transport.send queued-before-start bytes=\(data.count) pending=\(pendingWrites.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start)) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
            )
            return
        }

        GhosttyRuntimeTrace.latency(
            "transport.send begin bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        try await connection.write(data)
        GhosttyRuntimeTrace.latency(
            "transport.send end bytes=\(data.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func isSSHControlChannelActive() async -> Bool {
        guard !isClosed, let connection else { return false }
        return connection.isSSHControlChannelActive
    }

    func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) async throws {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "transport.resize request columns=\(columns) rows=\(rows) px=\(width)x\(height)"
        )
        resizeState.request(
            TmuxControlViewport(
                columns: columns,
                rows: rows,
                pixelWidth: width,
                pixelHeight: height
            )
        )

        guard let connection else {
            GhosttyRuntimeTrace.latency(
                "transport.resize queued-before-start elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return
        }
        try await drainResizeQueueIfNeeded(using: connection)
        GhosttyRuntimeTrace.latency(
            "transport.resize drained elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        let activeConnection = connection
        let pendingPreparedRoot = preparedRoot
        connection = nil
        preparedRoot = nil
        isClosed = true
        await activeConnection?.close(disposition: disposition)
        if let pendingPreparedRoot {
            Task {
                await pendingPreparedRoot.cancelAndCleanup()
            }
        }
        inboundStream.finish(nil)
    }

    private func closeDispositionAfterStartFailure(_ error: any Error) -> TmuxControlTransportCloseDisposition {
        if let transportError = error as? SSHTmuxControlTransportError,
           transportError == .closed {
            return .reusable
        }

        return .invalidated
    }

    private func makePreparedRoot() async -> RemuxSSHPreparedRoot {
        let configuration = self.configuration
        let startupTrace = SSHTmuxControlStartupTrace(flowID: configuration.traceFlowID)
        startupTrace.event(
            "begin",
            fields: [
                "host": configuration.host,
                "port": "\(configuration.port)",
                "session": configuration.sessionName,
            ]
        )

        if let sshRootService,
           let rootKey = configuration.sshRootKey {
            return await sshRootService.preparedRoot(
                for: rootKey,
                configuration: configuration.sshRootConfiguration,
                trace: startupTrace
            )
        }

        return RemuxSSHPreparedRoot.dedicated(
            configuration: configuration.sshRootConfiguration,
            trace: startupTrace
        )
    }

    private func drainResizeQueueIfNeeded(
        using connection: SSHTmuxControlConnection
    ) async throws {
        guard var viewport = resizeState.beginApplyingIfNeeded() else { return }

        do {
            while true {
                let start = GhosttyRuntimeTrace.nowNanos()
                GhosttyRuntimeTrace.latency(
                    "transport.resize.apply begin columns=\(viewport.columns) rows=\(viewport.rows) px=\(viewport.pixelWidth)x\(viewport.pixelHeight)"
                )
                try await connection.resize(viewport)
                GhosttyRuntimeTrace.latency(
                    "transport.resize.apply end elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
                )
                guard let nextViewport = resizeState.completeApplied(viewport) else {
                    return
                }
                viewport = nextViewport
            }
        } catch {
            resizeState.failApplying()
            throw error
        }
    }

    private func tmuxAttachCommand(viewport: TmuxControlViewport) -> String {
        SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: configuration.tmuxExecutable,
            sessionName: configuration.sessionName,
            initialViewport: viewport
        )
    }
}

private final class SSHTmuxControlViewportTraceState: @unchecked Sendable {
    private let lock = NIOLock()
    private var viewport: TmuxControlViewport

    init(viewport: TmuxControlViewport) {
        self.viewport = viewport
    }

    func update(_ viewport: TmuxControlViewport) {
        lock.withLock {
            self.viewport = viewport
        }
    }

    func description() -> String {
        lock.withLock {
            GhosttyRuntimeTrace.viewportDescription(viewport)
        }
    }
}

private func traceControlByteChunk(
    _ data: Data,
    direction: ControlByteTraceDirection,
    source: String,
    viewportDescription: String,
    accumulator: inout ControlByteLineTraceAccumulator
) {
    guard GhosttyRuntimeTrace.tmuxViewportEnabled, !data.isEmpty else { return }

    let previewLimit = GhosttyRuntimeTrace.tmuxViewportFullIOEnabled ? 4096 : 220
    let records = accumulator.append(
        data,
        previewLimit: previewLimit
    )
    GhosttyRuntimeTrace.tmuxViewport(
        "io.chunk dir=\(direction.rawValue) source=\(source) chunkBytes=\(data.count) lines=\(records.count) pendingLineBytes=\(accumulator.pendingByteCount) viewport=\(viewportDescription)"
    )
    for record in records {
        GhosttyRuntimeTrace.tmuxViewport(
            "io.line dir=\(direction.rawValue) source=\(source) seq=\(record.sequence) lineBytes=\(record.lineByteCount) viewport=\(viewportDescription) preview=\(record.preview)"
        )
    }
}

private final class SSHTmuxControlConnection: @unchecked Sendable {
    private let claimedConnection: RemuxSSHClaimedRoot
    private let sessionChannel: Channel
    private let viewportTraceState: SSHTmuxControlViewportTraceState
    private let allocator = ByteBufferAllocator()
    private let closeLock = NIOLock()
    private var outboundByteTrace = ControlByteLineTraceAccumulator()
    private var didClose = false

    init(
        claimedConnection: RemuxSSHClaimedRoot,
        sessionChannel: Channel,
        viewportTraceState: SSHTmuxControlViewportTraceState
    ) {
        self.claimedConnection = claimedConnection
        self.sessionChannel = sessionChannel
        self.viewportTraceState = viewportTraceState
    }

    var isSSHControlChannelActive: Bool {
        claimedConnection.sshRoot.rootChannel.isActive && sessionChannel.isActive
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }

        traceControlByteChunk(
            data,
            direction: .outbound,
            source: "ssh.writeAndFlush",
            viewportDescription: viewportTraceState.description(),
            accumulator: &outboundByteTrace
        )
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "ssh.writeAndFlush begin bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        try await sessionChannel.writeAndFlush(
            SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        )
        GhosttyRuntimeTrace.latency(
            "ssh.writeAndFlush end bytes=\(data.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func resize(_ viewport: TmuxControlViewport) async throws {
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "ssh.resize begin columns=\(viewport.columns) rows=\(viewport.rows) px=\(viewport.pixelWidth)x\(viewport.pixelHeight)"
        )
        GhosttyRuntimeTrace.tmuxViewport(
            "ssh.resize begin viewport=\(GhosttyRuntimeTrace.viewportDescription(viewport)) previous=\(viewportTraceState.description())"
        )
        // Only report PTY geometry at the SSH layer here. tmux control commands
        // must be emitted by Ghostty so its command-response FIFO stays owned.
        try await sessionChannel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: Int(viewport.columns),
                terminalRowHeight: Int(viewport.rows),
                terminalPixelWidth: Int(viewport.pixelWidth),
                terminalPixelHeight: Int(viewport.pixelHeight)
            )
        )
        viewportTraceState.update(viewport)
        GhosttyRuntimeTrace.tmuxViewport(
            "ssh.resize end viewport=\(GhosttyRuntimeTrace.viewportDescription(viewport))"
        )
        GhosttyRuntimeTrace.latency(
            "ssh.resize end elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        let shouldClose = closeLock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldClose else { return }

        try? await sessionChannel.close()
        await claimedConnection.release(disposition.sshRootLeaseDisposition)
    }
}

private final class SSHTmuxPreparedControlSession: @unchecked Sendable {
    let claimedConnection: RemuxSSHClaimedRoot
    let sessionChannel: Channel

    private let closeLock = NIOLock()
    private var didClose = false

    init(
        claimedConnection: RemuxSSHClaimedRoot,
        sessionChannel: Channel
    ) {
        self.claimedConnection = claimedConnection
        self.sessionChannel = sessionChannel
    }

    func close(disposition: RemuxSSHRootLeaseDisposition) async {
        let shouldClose = closeLock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldClose else { return }

        try? await sessionChannel.close()
        await claimedConnection.release(disposition)
    }
}

private enum SSHTmuxControlBootstrap {
    static func openSessionChannel(
        using sshRoot: RemuxSSHRoot,
        trace: SSHTmuxControlStartupTrace
    ) async throws -> Channel {
        let channel = sshRoot.rootChannel
        let sshHandler = sshRoot.sshHandler

        return try await trace.stage("sessionChannel.open") {
            try await channel.eventLoop.flatSubmit { [eventLoop = channel.eventLoop] in
                let promise = eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise) { channel, channelType in
                    guard case .session = channelType else {
                        return channel.eventLoop.makeFailedFuture(
                            SSHTmuxControlTransportError.unsupportedInboundChannel
                        )
                    }

                    return channel.eventLoop.makeSucceededFuture(())
                }
                return promise.futureResult.always { _ in
                    // Recorded on the event loop the instant the open
                    // completes: the gap to sessionChannel.open.end is
                    // Swift-concurrency resume lag, not wire time.
                    trace.event("sessionChannel.open.wireComplete")
                }
            }.get()
        }
    }

    static func activateControlSession(
        using preparedSession: SSHTmuxPreparedControlSession,
        viewport: TmuxControlViewport,
        command: String,
        controlNoResponseTimeout: TimeAmount,
        trace: SSHTmuxControlStartupTrace,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> SSHTmuxControlConnection {
        let childChannel = preparedSession.sessionChannel
        let viewportTraceState = SSHTmuxControlViewportTraceState(viewport: viewport)
        let firstOutputPromise = childChannel.eventLoop.makePromise(of: Void.self)
        let firstOutputGate = SSHTmuxControlFirstOutputGate(promise: firstOutputPromise)
        let firstOutputTimeout = childChannel.eventLoop.scheduleTask(
            deadline: .now() + controlNoResponseTimeout
        ) { [firstOutputGate] in
            firstOutputGate.fail(
                SSHTmuxControlTransportError.controlSessionNoResponse(controlNoResponseTimeout)
            )
        }
        let handler = SSHTmuxControlChannelHandler(
            viewportTraceState: viewportTraceState,
            onFirstOutput: { [firstOutputGate] data in
                firstOutputGate.succeed()
                trace.event(
                    "firstOutput",
                    fields: [
                        "bytes": "\(data.count)",
                        "preview": GhosttyRuntimeTrace.preview(data, limit: 80),
                    ]
                )
            },
            onOutput: onOutput,
            onFinish: { [firstOutputGate] error in
                firstOutputGate.fail(
                    error ?? SSHTmuxControlTransportError.controlSessionNoResponse(
                        controlNoResponseTimeout
                    )
                )
                onFinish(error)
            }
        )

        try await trace.stage("sessionChannel.handler.add") {
            try await childChannel.pipeline.addHandler(handler).get()
        }

        // Deliberately NO pseudo-terminal: the control-mode protocol is a
        // plain byte stream pumped straight into the session parser. A PTY
        // would force `tmux -CC` (which demands a tty and wraps the stream
        // in a DCS 1000p envelope the parser must not see) and adds echo and
        // CRLF line-discipline hazards. `tmux -C` over a bare exec channel
        // emits exactly the verified wire contract; TERM is exported by the
        // remote command line and the client size is owned by the session's
        // refresh-client reporting.
        try await trace.stage(
            "exec.request",
            fields: ["commandBytes": "\(command.lengthOfBytes(using: .utf8))"]
        ) {
            GhosttyRuntimeTrace.tmuxViewport(
                "startup.exec.request viewport=\(GhosttyRuntimeTrace.viewportDescription(viewport)) commandBytes=\(command.lengthOfBytes(using: .utf8)) preview=\(GhosttyRuntimeTrace.preview(Data(command.utf8), limit: 220))"
            )
            handler.expectReply(for: .exec)
            try await childChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            )
        }
        do {
            try await trace.stage(
                "controlSession.firstOutput",
                fields: ["timeout": "\(controlNoResponseTimeout)"]
            ) {
                try await firstOutputPromise.futureResult.get()
            }
            firstOutputTimeout.cancel()
        } catch {
            firstOutputTimeout.cancel()
            throw error
        }
        trace.event("bootstrap.connected")

        return SSHTmuxControlConnection(
            claimedConnection: preparedSession.claimedConnection,
            sessionChannel: childChannel,
            viewportTraceState: viewportTraceState
        )
    }

    static func openControlSession(
        using claimedConnection: RemuxSSHClaimedRoot,
        viewport: TmuxControlViewport,
        command: String,
        controlNoResponseTimeout: TimeAmount,
        trace: SSHTmuxControlStartupTrace,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> SSHTmuxControlConnection {
        var preparedSession: SSHTmuxPreparedControlSession?
        do {
            let childChannel = try await openSessionChannel(
                using: claimedConnection.sshRoot,
                trace: trace
            )
            let session = SSHTmuxPreparedControlSession(
                claimedConnection: claimedConnection,
                sessionChannel: childChannel
            )
            preparedSession = session

            return try await activateControlSession(
                using: session,
                viewport: viewport,
                command: command,
                controlNoResponseTimeout: controlNoResponseTimeout,
                trace: trace,
                onOutput: onOutput,
                onFinish: onFinish
            )
        } catch {
            if let preparedSession {
                await preparedSession.close(disposition: .invalidated)
            } else {
                await claimedConnection.releaseAfterFailedStart()
            }
            throw error
        }
    }
}

private final class SSHTmuxControlChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let viewportTraceState: SSHTmuxControlViewportTraceState
    private let onFirstOutput: @Sendable (Data) -> Void
    private let onOutput: @Sendable (Data) -> Void
    private let onFinish: @Sendable (Error?) -> Void
    private let lock = NIOLock()
    private var inboundByteTrace = ControlByteLineTraceAccumulator()
    private var channelDataRouter = SSHTmuxControlChannelDataRouter()
    private var completionState = SSHTmuxControlChannelCompletionState()
    private var requestReplyTracker = SSHTmuxControlChannelRequestReplyTracker()

    init(
        viewportTraceState: SSHTmuxControlViewportTraceState,
        onFirstOutput: @escaping @Sendable (Data) -> Void,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) {
        self.viewportTraceState = viewportTraceState
        self.onFirstOutput = onFirstOutput
        self.onOutput = onOutput
        self.onFinish = onFinish
    }

    func expectReply(for request: SSHTmuxControlChannelRequestKind) {
        lock.withLock {
            requestReplyTracker.expectReply(for: request)
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { [weak self] error in
            self?.finish(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            lock.withLock {
                completionState.recordExitStatus(Int(status.exitStatus))
            }
        case is ChannelSuccessEvent:
            lock.withLock {
                _ = requestReplyTracker.acknowledgeSuccess()
            }
        case is NIOSSH.ChannelFailureEvent:
            let failure = lock.withLock {
                (
                    request: requestReplyTracker.acknowledgeFailure(),
                    diagnostics: channelDataRouter.diagnostics
                )
            }
            finish(
                SSHTmuxControlTransportError.channelRequestFailed(
                    failure.request,
                    diagnostics: failure.diagnostics
                )
            )
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        guard case .byteBuffer(var buffer) = channelData.data else {
            return
        }

        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }

        let data = Data(bytes)
        let route = lock.withLock {
            channelDataRouter.route(type: channelData.type, data: data)
        }
        switch route {
        case .stdout(let reportFirstOutput):
            handleStdout(data, reportFirstOutput: reportFirstOutput)
        case .stderr:
            handleStderr(data)
        case .extendedData(let typeDescription):
            handleExtendedData(data, typeDescription: typeDescription)
        }
    }

    private func handleStdout(_ data: Data, reportFirstOutput: Bool) {
        traceControlByteChunk(
            data,
            direction: .inbound,
            source: "ssh.channelRead",
            viewportDescription: viewportTraceState.description(),
            accumulator: &inboundByteTrace
        )
        GhosttyRuntimeTrace.latency(
            "ssh.channelRead bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        GhosttyTmuxActionTrace.traceInboundSignals(
            in: data,
            source: "ssh.channelRead",
            chunkCount: 1,
            eventPrefix: "tmux.signal.ssh.channelRead"
        )
        if reportFirstOutput {
            onFirstOutput(data)
        }
        onOutput(data)
    }

    private func handleStderr(_ data: Data) {
        GhosttyRuntimeTrace.latency(
            "ssh.channelRead.stderr bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
    }

    private func handleExtendedData(_ data: Data, typeDescription: String) {
        GhosttyRuntimeTrace.latency(
            "ssh.channelRead.extended type=\(typeDescription) bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(nil)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish(nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(error)
        context.close(promise: nil)
    }

    private func finish(_ error: Error?) {
        let completion = lock.withLock { () -> Result<Void, Error>? in
            completionState.finish(error, diagnostics: channelDataRouter.diagnostics)
        }

        guard let completion else { return }

        switch completion {
        case .success:
            onFinish(nil)
        case .failure(let error):
            onFinish(error)
        }
    }
}
