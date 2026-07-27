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

private enum GhosttyComposerDictationBackendEvent: Sendable {
    case started
    case audioLevel(CGFloat)
    case hypothesis(String, isFinal: Bool)
    case recognitionFailed
    case failed(String)
}

/// Owns Speech and AVAudioEngine on one serial queue. The UI controller never
/// waits for teardown and never touches audio objects directly.
private final class GhosttyComposerDictationBackend: @unchecked Sendable {
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

    func cancel(id: UInt64) {
        clearDesiredRunID(ifMatching: id)
        queue.async { [self] in
            guard activeRun?.id == id else { return }
            cancelActiveRun()
        }
    }

    func cancelAll() {
        setDesiredRunID(nil)
        queue.async { [self] in
            cancelActiveRun()
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
            let eventHandler = run.handler
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
                onLevel: { level in eventHandler(.audioLevel(level)) }
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
            options: [.duckOthers, .allowBluetoothHFP]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
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
    private static let startDeadline: Duration = .seconds(8)
    private static let finalizationDeadline: Duration = .seconds(3)

    @Published private(set) var phase = GhosttyComposerDictationPhase.idle
    @Published private(set) var audioLevels = Array(
        repeating: CGFloat(0.08),
        count: meterBarCount
    )

    private let backend = GhosttyComposerDictationBackend()
    private var authorizationTask: Task<Void, Never>?
    private var startDeadlineTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var sessionID: UInt64 = 0
    private var draftSnapshot = ""
    private var latestHypothesis = ""
    private var onTranscript: ((String) -> Void)?
    private var onFailure: ((String) -> Void)?
    private var afterTranscription: (() -> Void)?
#if DEBUG
    private var isDebugSession = false
    private var debugTranscript: String?
#endif

    deinit {
        backend.cancelAll()
    }

    func start(
        draft: String,
        onTranscript: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        guard phase == .idle else { return }

        sessionID &+= 1
        let requestedSessionID = sessionID
        draftSnapshot = draft
        latestHypothesis = ""
        audioLevels = Self.emptyAudioLevels
        self.onTranscript = onTranscript
        self.onFailure = onFailure
        phase = .starting
        GhosttyRuntimeTrace.perf("composer.dictation.startRequested id=\(requestedSessionID)")
        scheduleStartDeadline(sessionID: requestedSessionID)

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

        authorizationTask = Task { [weak self] in
            guard let self else { return }
            await authorizeAndStart(sessionID: requestedSessionID)
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

    private func authorizeAndStart(sessionID requestedSessionID: UInt64) async {
        let speechAuthorization = await requestSpeechAuthorizationIfNeeded()
        guard isCurrentStartingSession(requestedSessionID) else { return }
        guard speechAuthorization == .authorized else {
            fail(
                sessionID: requestedSessionID,
                message: "Enable Speech Recognition in Settings to use dictation"
            )
            return
        }

        let microphoneAuthorized = await requestMicrophoneAuthorizationIfNeeded()
        guard isCurrentStartingSession(requestedSessionID) else { return }
        guard microphoneAuthorized else {
            fail(
                sessionID: requestedSessionID,
                message: "Enable Microphone access in Settings to use dictation"
            )
            return
        }

        beginBackend(sessionID: requestedSessionID)
    }

    private func beginBackend(sessionID requestedSessionID: UInt64) {
        backend.start(
            id: requestedSessionID,
            locale: .current,
            handler: { [weak self] event in
                Task { @MainActor [weak self] in
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
        startDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.startDeadline)
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
        finalizationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.finalizationDeadline)
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
        sessionID &+= 1
        authorizationTask?.cancel()
        authorizationTask = nil
        startDeadlineTask?.cancel()
        startDeadlineTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        backend.cancel(id: invalidatedSessionID)

        phase = .idle
        audioLevels = Self.emptyAudioLevels
        onTranscript = nil
        onFailure = nil
        afterTranscription = nil
#if DEBUG
        isDebugSession = false
        debugTranscript = nil
#endif
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
        !Task.isCancelled
            && requestedSessionID == sessionID
            && phase == .starting
    }

    private func requestSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophoneAuthorizationIfNeeded() async -> Bool {
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
