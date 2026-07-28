@preconcurrency import AVFoundation
import Accelerate
import Combine
@preconcurrency import Speech

enum GhosttyComposerDictationPhase: Equatable {
    case idle
    case starting
    case recording
    case transcribing

    var isActive: Bool {
        self != .idle
    }
}

enum GhosttyComposerDictationDraft {
    static func merging(snapshot: String, hypothesis: String) -> String {
        guard !hypothesis.isEmpty else { return snapshot }
        guard !snapshot.isEmpty else { return hypothesis }
        guard snapshot.last?.isWhitespace != true else {
            return snapshot + hypothesis
        }
        return snapshot + " " + hypothesis
    }
}

enum GhosttyComposerDictationBackendEvent: Sendable {
    case started
    case audioLevel(CGFloat)
    case hypothesis(String, isFinal: Bool)
    case recognitionFailed
    case failed(String)
}

protocol GhosttyComposerDictationBackendProtocol: Sendable {
    func start(
        id: UInt64,
        locale: Locale,
        handler: @escaping @Sendable (GhosttyComposerDictationBackendEvent) -> Void
    )
    func finish(id: UInt64)
    func cancel(id: UInt64, completion: @escaping @Sendable () -> Void)
    func cancelAll(completion: @escaping @Sendable () -> Void)
}

struct GhosttyComposerDictationAuthorizationClient: Sendable {
    enum Result: Sendable {
        case authorized
        case speechRecognitionDenied
        case microphoneDenied
        case cancelled
    }

    let requestSpeechAuthorization: @Sendable () async -> SFSpeechRecognizerAuthorizationStatus
    let requestMicrophoneAuthorization: @Sendable () async -> Bool

    func resolve() async -> Result {
        let speechAuthorization = await requestSpeechAuthorization()
        guard !Task.isCancelled else { return .cancelled }
        guard speechAuthorization == .authorized else {
            return .speechRecognitionDenied
        }

        let microphoneAuthorized = await requestMicrophoneAuthorization()
        guard !Task.isCancelled else { return .cancelled }
        return microphoneAuthorized ? .authorized : .microphoneDenied
    }

    static let live = Self(
        requestSpeechAuthorization: {
            let current = SFSpeechRecognizer.authorizationStatus()
            guard current == .notDetermined else { return current }

            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        },
        requestMicrophoneAuthorization: {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                return await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            @unknown default:
                return false
            }
        }
    )
}

/// AVAudioSession is process-wide even though each retained terminal has its
/// own composer controller. This lease makes microphone ownership equally
/// process-wide and prevents two terminal sessions from racing audio setup and
/// teardown against each other.
final class GhosttyComposerDictationLease: @unchecked Sendable {
    static let shared = GhosttyComposerDictationLease()

    private let lock = NSLock()
    private var ownerID: UUID?

    func acquire(ownerID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard self.ownerID == nil || self.ownerID == ownerID else { return false }
        self.ownerID = ownerID
        return true
    }

    func release(ownerID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        if self.ownerID == ownerID {
            self.ownerID = nil
        }
    }
}

/// Owns Speech and AVAudioEngine on one serial queue. The UI controller never
/// waits for teardown and never touches audio objects directly.
final class GhosttyComposerDictationBackend: GhosttyComposerDictationBackendProtocol,
    @unchecked Sendable
{
    typealias EventHandler = @Sendable (GhosttyComposerDictationBackendEvent) -> Void

    private enum RunPhase {
        case starting
        case recording
        case finishing
    }

    private final class Run {
        let id: UInt64
        let handler: EventHandler
        var phase = RunPhase.starting
        var recognizer: SFSpeechRecognizer?
        var request: SFSpeechAudioBufferRecognitionRequest?
        var recognitionTask: SFSpeechRecognitionTask?
        var audioEngine: AVAudioEngine?
        var tapProcessor: GhosttyComposerAudioTapProcessor?
        var hasInstalledTap = false

        init(id: UInt64, handler: @escaping EventHandler) {
            self.id = id
            self.handler = handler
        }
    }

    private let queue = DispatchQueue(
        label: "dev.remux.composer-dictation",
        qos: .userInitiated
    )
    private let desiredRunLock = NSLock()
    private var desiredRunID: UInt64?
    private var activeRun: Run?

    func start(
        id: UInt64,
        locale: Locale,
        handler: @escaping EventHandler
    ) {
        setDesiredRunID(id)
        queue.async { [self] in
            GhosttyRuntimeTrace.perf("composer.dictation.backend.startQueued id=\(id)")
            cancelActiveRun()
            guard isDesiredRun(id) else { return }

            let run = Run(id: id, handler: handler)
            activeRun = run
            start(run, locale: locale)
        }
    }

    func finish(id: UInt64) {
        queue.async { [self] in
            guard let run = activeRun,
                  run.id == id,
                  run.phase == .recording else {
                return
            }

            run.phase = .finishing
            stopCapture(run)
            run.request?.endAudio()
            run.recognitionTask?.finish()
            deactivateAudioSession()
        }
    }

    func cancel(id: UInt64, completion: @escaping @Sendable () -> Void) {
        clearDesiredRunID(ifMatching: id)
        queue.async { [self] in
            if activeRun?.id == id {
                cancelActiveRun()
            }
            completion()
        }
    }

    func cancelAll(completion: @escaping @Sendable () -> Void) {
        setDesiredRunID(nil)
        queue.async { [self] in
            cancelActiveRun()
            completion()
        }
    }

    private func start(_ run: Run, locale: Locale) {
        do {
            GhosttyRuntimeTrace.perf(
                "composer.dictation.backend.audioSessionActivate.begin id=\(run.id)"
            )
            try activateAudioSession()
            guard isActive(run), isDesiredRun(run.id) else {
                cancelActiveRun()
                return
            }
            GhosttyRuntimeTrace.perf(
                "composer.dictation.backend.audioSessionActivate.end id=\(run.id)"
            )

            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                throw GhosttyComposerDictationError.unsupportedLocale
            }
            guard recognizer.supportsOnDeviceRecognition else {
                throw GhosttyComposerDictationError.unsupportedOnDeviceLocale
            }
            guard recognizer.isAvailable else {
                throw GhosttyComposerDictationError.recognizerUnavailable
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            request.taskHint = .dictation

            run.recognizer = recognizer
            run.request = request
            let runID = run.id
            run.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let hypothesis = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                let errorDescription = error.map { String(describing: $0) }
                self?.queue.async { [weak self] in
                    self?.handleRecognitionUpdate(
                        runID: runID,
                        hypothesis: hypothesis,
                        isFinal: isFinal,
                        errorDescription: errorDescription
                    )
                }
            }

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            // The input node delivers captured microphone audio on its output bus.
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            guard recordingFormat.sampleRate > 0,
                  recordingFormat.channelCount > 0 else {
                throw GhosttyComposerDictationError.unavailableAudioInput
            }

            let tapProcessor = GhosttyComposerAudioTapProcessor(
                request: request,
                onLevel: { [weak self] level in
                    self?.publishAudioLevel(level, runID: runID)
                }
            )
            inputNode.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: recordingFormat
            ) { buffer, _ in
                tapProcessor.process(buffer)
            }
            run.audioEngine = engine
            run.tapProcessor = tapProcessor
            run.hasInstalledTap = true

            engine.prepare()
            GhosttyRuntimeTrace.perf(
                "composer.dictation.backend.engineStart.begin id=\(run.id)"
            )
            try engine.start()
            guard isActive(run), isDesiredRun(run.id) else {
                cancelActiveRun()
                return
            }

            GhosttyRuntimeTrace.perf(
                "composer.dictation.backend.engineStart.end id=\(run.id)"
            )
            run.phase = .recording
            run.handler(.started)
        } catch {
            let message = userMessage(for: error)
            GhosttyRuntimeTrace.perf(
                "composer.dictation.backend.startFailed id=\(run.id) "
                    + "error=\(String(describing: error))"
            )
            clearDesiredRunID(ifMatching: run.id)
            cancelActiveRun()
            run.handler(.failed(message))
        }
    }

    private func handleRecognitionUpdate(
        runID: UInt64,
        hypothesis: String?,
        isFinal: Bool,
        errorDescription: String?
    ) {
        guard let run = activeRun, run.id == runID else { return }

        if let hypothesis, !hypothesis.isEmpty {
            run.handler(.hypothesis(hypothesis, isFinal: isFinal))
        }

        if isFinal {
            clearDesiredRunID(ifMatching: run.id)
            releaseCompletedRun(run)
            return
        }

        guard let errorDescription else { return }
        GhosttyRuntimeTrace.perf(
            "composer.dictation.backend.recognitionFailed id=\(run.id) "
                + "error=\(errorDescription)"
        )
        clearDesiredRunID(ifMatching: run.id)
        run.handler(.recognitionFailed)
        cancelActiveRun()
    }

    private func publishAudioLevel(_ level: CGFloat, runID: UInt64) {
        queue.async { [weak self] in
            guard let self,
                  let run = activeRun,
                  run.id == runID,
                  run.phase == .recording else {
                return
            }
            run.handler(.audioLevel(level))
        }
    }

    private func releaseCompletedRun(_ run: Run) {
        guard activeRun === run else { return }
        stopCapture(run)
        deactivateAudioSession()
        activeRun = nil
    }

    private func cancelActiveRun() {
        guard let run = activeRun else { return }
        activeRun = nil
        run.recognitionTask?.cancel()
        stopCapture(run)
        run.request?.endAudio()
        run.recognitionTask = nil
        run.request = nil
        run.recognizer = nil
        deactivateAudioSession()
    }

    private func stopCapture(_ run: Run) {
        guard let engine = run.audioEngine else { return }
        engine.stop()
        if run.hasInstalledTap {
            engine.inputNode.removeTap(onBus: 0)
            run.hasInstalledTap = false
        }
        engine.reset()
        run.tapProcessor = nil
        run.audioEngine = nil
    }

    private func activateAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .record,
            mode: .measurement,
            options: [.allowBluetoothHFP]
        )
        try audioSession.setActive(true)
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            GhosttyRuntimeTrace.perf(
                "composer.dictation.backend.audioSessionDeactivateFailed "
                    + "error=\(String(describing: error))"
            )
        }
    }

    private func isActive(_ run: Run) -> Bool {
        activeRun === run
    }

    private func setDesiredRunID(_ id: UInt64?) {
        desiredRunLock.lock()
        desiredRunID = id
        desiredRunLock.unlock()
    }

    private func clearDesiredRunID(ifMatching id: UInt64) {
        desiredRunLock.lock()
        if desiredRunID == id {
            desiredRunID = nil
        }
        desiredRunLock.unlock()
    }

    private func isDesiredRun(_ id: UInt64) -> Bool {
        desiredRunLock.lock()
        defer { desiredRunLock.unlock() }
        return desiredRunID == id
    }

    private func userMessage(for error: Error) -> String {
        switch error {
        case GhosttyComposerDictationError.unsupportedLocale:
            "Dictation isn’t available for this language"
        case GhosttyComposerDictationError.unsupportedOnDeviceLocale:
            "On-device dictation isn’t available for this language"
        case GhosttyComposerDictationError.recognizerUnavailable:
            "Dictation is temporarily unavailable"
        default:
            "Microphone couldn’t start — try again"
        }
    }
}

private final class GhosttyComposerAudioTapProcessor: @unchecked Sendable {
    private static let levelPublishInterval = 0.075

    private let request: SFSpeechAudioBufferRecognitionRequest
    private let onLevel: @Sendable (CGFloat) -> Void
    private var lastLevelPublishTime: CFTimeInterval = 0

    init(
        request: SFSpeechAudioBufferRecognitionRequest,
        onLevel: @escaping @Sendable (CGFloat) -> Void
    ) {
        self.request = request
        self.onLevel = onLevel
    }

    /// AVAudioEngine invokes one tap serially, so this state stays confined to
    /// the engine's render callback and never needs to enter the main actor.
    func process(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)

        let now = CACurrentMediaTime()
        guard now - lastLevelPublishTime >= Self.levelPublishInterval else { return }
        lastLevelPublishTime = now
        onLevel(GhosttyComposerAudioLevelMeter.normalizedPeak(for: buffer))
    }
}

@MainActor
final class GhosttyComposerDictationController: ObservableObject {
    static let meterBarCount = 28

    @Published private(set) var phase = GhosttyComposerDictationPhase.idle
    @Published private(set) var audioLevels = Array(
        repeating: CGFloat(0.08),
        count: meterBarCount
    )

    private let backend: any GhosttyComposerDictationBackendProtocol
    private let authorizationClient: GhosttyComposerDictationAuthorizationClient
    private let lease: GhosttyComposerDictationLease
    private let leaseOwnerID: UUID
    private let startDeadline: Duration
    private let finalizationDeadline: Duration
    private var authorizationTask: Task<Void, Never>?
    private var startDeadlineTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var sessionID: UInt64 = 0
    private var leaseGeneration: UInt64 = 0
    private var backendRunRequested = false
    private var draftSnapshot = ""
    private var latestHypothesis = ""
    private var onTranscript: ((String) -> Void)?
    private var onFailure: ((String) -> Void)?
    private var afterTranscription: (() -> Void)?
#if DEBUG
    private var isDebugSession = false
    private var debugTranscript: String?
#endif

    init(
        backend: any GhosttyComposerDictationBackendProtocol = GhosttyComposerDictationBackend(),
        authorizationClient: GhosttyComposerDictationAuthorizationClient = .live,
        lease: GhosttyComposerDictationLease = .shared,
        startDeadline: Duration = .seconds(8),
        finalizationDeadline: Duration = .seconds(3)
    ) {
        self.backend = backend
        self.authorizationClient = authorizationClient
        self.lease = lease
        leaseOwnerID = UUID()
        self.startDeadline = startDeadline
        self.finalizationDeadline = finalizationDeadline
    }

    deinit {
        let lease = lease
        let leaseOwnerID = leaseOwnerID
        backend.cancelAll {
            lease.release(ownerID: leaseOwnerID)
        }
    }

    func start(
        draft: String,
        onTranscript: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        guard phase == .idle else { return }
        guard lease.acquire(ownerID: leaseOwnerID) else {
            onFailure("Microphone is already in use by another terminal")
            return
        }
        leaseGeneration &+= 1

        sessionID &+= 1
        let requestedSessionID = sessionID
        draftSnapshot = draft
        latestHypothesis = ""
        audioLevels = Self.emptyAudioLevels
        self.onTranscript = onTranscript
        self.onFailure = onFailure
        phase = .starting
        GhosttyRuntimeTrace.perf("composer.dictation.startRequested id=\(requestedSessionID)")

#if DEBUG
        if ProcessInfo.processInfo.environment[
            "REMUX_DEBUG_DICTATION_NO_SPEECH"
        ] == "1" {
            startDebugSession(transcript: nil, sessionID: requestedSessionID)
            return
        }

        if let transcript = ProcessInfo.processInfo.environment[
            "REMUX_DEBUG_DICTATION_TRANSCRIPT"
        ], !transcript.isEmpty {
            startDebugSession(transcript: transcript, sessionID: requestedSessionID)
            return
        }
#endif

        let authorizationClient = authorizationClient
        authorizationTask = Task { [weak self, authorizationClient] in
            let result = await authorizationClient.resolve()
            guard let self else { return }
            handleAuthorizationResult(result, sessionID: requestedSessionID)
        }
    }

    func finish(afterTranscription: (() -> Void)? = nil) {
        guard phase == .recording else { return }

        self.afterTranscription = afterTranscription
        phase = .transcribing
        startDeadlineTask?.cancel()
        startDeadlineTask = nil
        GhosttyRuntimeTrace.perf("composer.dictation.finishRequested id=\(sessionID)")

#if DEBUG
        if isDebugSession {
            let completionDelay: Duration = debugTranscript == nil
                ? .milliseconds(250)
                : .milliseconds(1_250)
            finalizationTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: completionDelay)
                } catch {
                    return
                }
                guard let self, phase == .transcribing else { return }
                if latestHypothesis.isEmpty {
                    fail(
                        sessionID: sessionID,
                        message: "No speech detected — try again"
                    )
                } else {
                    complete(sessionID: sessionID)
                }
            }
            return
        }
#endif

        backend.finish(id: sessionID)
        scheduleFinalizationDeadline(sessionID: sessionID)
    }

    func cancel() {
        guard phase.isActive else { return }
        let snapshot = draftSnapshot
        let transcript = onTranscript
        invalidateSession()
        transcript?(snapshot)
    }

    func stopImmediately() {
        guard phase.isActive else { return }
        invalidateSession()
    }

    func interrupt(message: String) {
        guard phase.isActive else { return }
        let failure = onFailure
        invalidateSession()
        failure?(message)
    }

    private func handleAuthorizationResult(
        _ result: GhosttyComposerDictationAuthorizationClient.Result,
        sessionID requestedSessionID: UInt64
    ) {
        guard isCurrentStartingSession(requestedSessionID) else { return }
        authorizationTask = nil

        switch result {
        case .authorized:
            beginBackend(sessionID: requestedSessionID)

        case .speechRecognitionDenied:
            fail(
                sessionID: requestedSessionID,
                message: "Enable Speech Recognition in Settings to use dictation"
            )

        case .microphoneDenied:
            fail(
                sessionID: requestedSessionID,
                message: "Enable Microphone access in Settings to use dictation"
            )

        case .cancelled:
            invalidateSession()
        }
    }

    private func beginBackend(sessionID requestedSessionID: UInt64) {
        backendRunRequested = true
        scheduleStartDeadline(sessionID: requestedSessionID)
        backend.start(
            id: requestedSessionID,
            locale: .current,
            handler: { [weak self] event in
                DispatchQueue.main.async { [weak self] in
                    self?.handleBackendEvent(event, sessionID: requestedSessionID)
                }
            }
        )
    }

    private func handleBackendEvent(
        _ event: GhosttyComposerDictationBackendEvent,
        sessionID requestedSessionID: UInt64
    ) {
        guard requestedSessionID == sessionID, phase.isActive else { return }

        switch event {
        case .started:
            guard phase == .starting else { return }
            startDeadlineTask?.cancel()
            startDeadlineTask = nil
            phase = .recording

        case .audioLevel(let level):
            guard phase == .recording else { return }
            audioLevels.removeFirst()
            audioLevels.append(level)

        case .hypothesis(let hypothesis, let isFinal):
            latestHypothesis = hypothesis
            onTranscript?(
                GhosttyComposerDictationDraft.merging(
                    snapshot: draftSnapshot,
                    hypothesis: hypothesis
                )
            )
            if isFinal {
                complete(sessionID: requestedSessionID)
            }

        case .recognitionFailed:
            if phase == .transcribing, !latestHypothesis.isEmpty {
                complete(sessionID: requestedSessionID)
            } else {
                fail(
                    sessionID: requestedSessionID,
                    message: "Dictation stopped — try again"
                )
            }

        case .failed(let message):
            fail(sessionID: requestedSessionID, message: message)
        }
    }

    private func scheduleStartDeadline(sessionID requestedSessionID: UInt64) {
        startDeadlineTask?.cancel()
        let startDeadline = startDeadline
        startDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: startDeadline)
            } catch {
                return
            }
            guard let self,
                  requestedSessionID == sessionID,
                  phase == .starting else {
                return
            }

            GhosttyRuntimeTrace.perf(
                "composer.dictation.startTimedOut id=\(requestedSessionID)"
            )
            fail(
                sessionID: requestedSessionID,
                message: "Dictation couldn’t start — try again"
            )
        }
    }

    private func scheduleFinalizationDeadline(sessionID requestedSessionID: UInt64) {
        finalizationTask?.cancel()
        let finalizationDeadline = finalizationDeadline
        finalizationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: finalizationDeadline)
            } catch {
                return
            }
            guard let self,
                  requestedSessionID == sessionID,
                  phase == .transcribing else {
                return
            }

            if latestHypothesis.isEmpty {
                fail(
                    sessionID: requestedSessionID,
                    message: "No speech detected — try again"
                )
            } else {
                complete(sessionID: requestedSessionID)
            }
        }
    }

    private func complete(sessionID requestedSessionID: UInt64) {
        guard requestedSessionID == sessionID else { return }
        let completion = afterTranscription
        invalidateSession()
        completion?()
    }

    private func fail(sessionID requestedSessionID: UInt64, message: String) {
        guard requestedSessionID == sessionID else { return }
        let failure = onFailure
        invalidateSession()
        failure?(message)
    }

    private func invalidateSession() {
        let invalidatedSessionID = sessionID
        let invalidatedLeaseGeneration = leaseGeneration
        let shouldCancelBackend = backendRunRequested
        sessionID &+= 1
        backendRunRequested = false
        authorizationTask?.cancel()
        authorizationTask = nil
        startDeadlineTask?.cancel()
        startDeadlineTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil

        phase = .idle
        audioLevels = Self.emptyAudioLevels
        onTranscript = nil
        onFailure = nil
        afterTranscription = nil
#if DEBUG
        isDebugSession = false
        debugTranscript = nil
#endif

        guard shouldCancelBackend else {
            lease.release(ownerID: leaseOwnerID)
            return
        }

        let lease = lease
        let leaseOwnerID = leaseOwnerID
        backend.cancel(id: invalidatedSessionID) { [weak self] in
            DispatchQueue.main.async { [weak self, lease] in
                guard let self else {
                    lease.release(ownerID: leaseOwnerID)
                    return
                }
                guard leaseGeneration == invalidatedLeaseGeneration else { return }
                lease.release(ownerID: leaseOwnerID)
            }
        }
    }

#if DEBUG
    private func startDebugSession(transcript: String?, sessionID requestedSessionID: UInt64) {
        isDebugSession = true
        debugTranscript = transcript
        authorizationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }

            guard let self, isCurrentStartingSession(requestedSessionID) else { return }
            startDeadlineTask?.cancel()
            startDeadlineTask = nil
            phase = .recording
            audioLevels = (0..<Self.meterBarCount).map { index in
                0.14 + (CGFloat(index % 7) * 0.1)
            }

            guard let transcript else { return }

            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }

            guard requestedSessionID == sessionID, phase == .recording else { return }
            latestHypothesis = transcript
            onTranscript?(
                GhosttyComposerDictationDraft.merging(
                    snapshot: draftSnapshot,
                    hypothesis: transcript
                )
            )
        }
    }
#endif

    private func isCurrentStartingSession(_ requestedSessionID: UInt64) -> Bool {
        requestedSessionID == sessionID
            && phase == .starting
    }

    private static var emptyAudioLevels: [CGFloat] {
        Array(repeating: 0.08, count: meterBarCount)
    }
}

private enum GhosttyComposerAudioLevelMeter {
    static func normalizedPeak(for buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?.pointee,
              buffer.frameLength > 0 else {
            return 0.08
        }

        var peak: Float = 0
        vDSP_maxmgv(
            samples,
            1,
            &peak,
            vDSP_Length(buffer.frameLength)
        )
        let decibels = 20 * log10(max(peak, 0.000_001))
        return CGFloat(min(max((decibels + 50) / 50, 0.08), 1))
    }
}

private enum GhosttyComposerDictationError: Error {
    case unavailableAudioInput
    case unsupportedLocale
    case unsupportedOnDeviceLocale
    case recognizerUnavailable
}
