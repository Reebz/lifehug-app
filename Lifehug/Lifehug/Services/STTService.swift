import Foundation
import AVFoundation
import WhisperKit
import os

/// On-device speech-to-text using WhisperKit's AudioStreamTranscriber.
/// Creates a new AudioStreamTranscriber per recording session (actor handles
/// recording, VAD, real-time transcription, and segment confirmation internally).
/// Audio session is configured once by VoicePipeline at conversation start.
@Observable
@MainActor
final class STTService {
    var isAuthorized: Bool = false
    var isRecording: Bool = false
    var partialTranscript: String = ""
    var error: String?

    /// Explicit, observable ASR-readiness state (replaces the fire-once boolean).
    /// Mic controls stay disabled until `.ready`; `.failed` is retriable.
    private(set) var asrState: ASRState = .idle

    /// First-run model download progress (0...1), driven by `WhisperKit.download`.
    private(set) var downloadProgress: Double = 0

    /// Voice recognition is usable only when the model is fully loaded.
    var isASRReady: Bool { asrState == .ready }

    /// Shared status label while ASR is downloading/loading/failed; nil when
    /// idle/ready so each view supplies its own resting label. Single source for
    /// the copy both ConversationView and DailyQuestionView render.
    var preparingStatusLabel: String? {
        switch asrState {
        case .downloading:
            let pct = Int((downloadProgress * 100).rounded())
            return "Preparing voice… \(pct)%"
        case .loading:
            return "Preparing voice…"
        case .failed(let message):
            return message
        case .idle, .ready:
            return nil
        }
    }

    private let logger = Logger(subsystem: "com.lifehug.app", category: "STT")

    /// WhisperKit pipeline — created once at launch, persists across sessions.
    private var whisperPipe: WhisperKit?

    /// Test seam. When set (simulator/tests only), replaces the real download+load
    /// so the readiness state machine can be exercised without a CoreML model.
    /// Throwing from the closure drives the `.failed` branch; returning drives `.ready`.
    var loadOverrideForTesting: (@MainActor () async throws -> Void)?

    private var continuation: AsyncStream<String>.Continuation?
    private var transcriber: AudioStreamTranscriber?
    private var transcriptionTask: Task<Void, Never>?

    /// Maximum recording duration as wall-clock time (3 minutes). Enforced without
    /// reading the live sample buffer from the MainActor during recording (KTD6).
    private let maxRecordingSeconds: TimeInterval = 180

    /// When the current recording began; nil when not recording.
    private var recordingStart: Date?

    /// Minimum captured samples (~0.5s at 16kHz) to attempt a final full-buffer
    /// transcription when the streaming pass produced nothing. `nonisolated` so the
    /// `nonisolated` pure helper `shouldRunFinalTranscription` can read this constant
    /// under Swift 6.2 strict concurrency (it is an immutable compile-time value).
    nonisolated static let finalTranscriptionMinSamples = 8000

    /// Monotonic session token. A stale session's teardown only touches the shared
    /// continuation/transcriber state when its captured id still matches the current
    /// one, so it cannot finish or nil a newer session's stream (P2-5).
    private var sessionID = 0

    // MARK: - Model Loading

    /// Download (with progress) and load the WhisperKit model, driving `asrState`.
    /// Idempotent for the terminal/ready and in-flight states; retriable from
    /// `.idle`/`.failed` (call again on the next voice-mode entry or `.active`).
    func loadASRModel() async {
        switch asrState {
        case .ready, .downloading, .loading:
            return  // already usable or a load is already in flight
        case .idle, .failed:
            break   // resting or previously failed — (re)attempt
        }

        do {
            try await performASRLoad()
            asrState = .ready
            logger.info("WhisperKit small.en ready")
        } catch is CancellationError {
            asrState = .idle
        } catch is TimeoutError {
            logger.error("WhisperKit download timed out")
            asrState = .failed("Voice recognition timed out. Tap to retry.")
        } catch {
            logger.error("WhisperKit load failed: \(error)")
            asrState = .failed("Voice recognition failed to load. Tap to retry.")
        }
    }

    /// Performs the actual download + load. Split into two observable phases per
    /// KTD3: `WhisperKit.download` (with progress) then `WhisperKit(config)` load.
    private func performASRLoad() async throws {
        #if targetEnvironment(simulator)
        // No CoreML on the simulator. Honor an injected test loader if present so
        // the state machine is unit-testable; otherwise treat as ready immediately.
        asrState = .loading
        if let override = loadOverrideForTesting {
            try await override()
        }
        #else
        // 1. Download (surfaces progress, distinct from the compile/load phase).
        asrState = .downloading
        downloadProgress = 0
        // Time-bound the download: the underlying URLSession's resource timeout is
        // ~7 days, so a trickle-stalled socket would otherwise pin `.downloading`
        // forever with the mic disabled and no in-session retry (loadASRModel
        // early-returns while a load is in flight). Mirrors KokoroManager.loadEngine.
        let modelFolder = try await withTimeout(seconds: 180) {
            try await WhisperKit.download(
                variant: "small.en",
                from: "argmaxinc/whisperkit-coreml",
                // `@Sendable` so this non-MainActor closure can be handed to WhisperKit's
                // nonisolated `download` without "sending main-actor-isolated value" —
                // mirrors the `stateChangeCallback` closure below. It only reads a Sendable
                // Double and hops back to the MainActor via a Task.
                progressCallback: { @Sendable [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = fraction
                    }
                }
            )
        }

        // 2. Load + prewarm from the downloaded folder (no re-download). The init
        //    returning without throwing IS the authoritative "ready" signal.
        asrState = .loading
        let pipe = try await WhisperKit(WhisperKitConfig(
            model: "small.en",
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        ))
        self.whisperPipe = pipe
        print("[STT] DIAG: WhisperKit loaded — tokenizer=\(pipe.tokenizer != nil), audioProcessor=\(type(of: pipe.audioProcessor))")
        #endif
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        #if targetEnvironment(simulator)
        isAuthorized = true
        return
        #else
        let micGranted: Bool
        if #available(iOS 17, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await Self.requestMicPermission()
        }
        isAuthorized = micGranted
        if !micGranted {
            error = "Microphone access not authorized. Please enable in Settings."
        }
        #endif
    }

    private nonisolated static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Start Listening

    func startListening() -> AsyncStream<String> {
        // Readiness gate (device + simulator): never start a recording before ASR is
        // ready. Surface a distinct message so an unready mic is not mistaken for an
        // empty transcript. Views also `.disabled` the mic until `.ready`.
        guard asrState == .ready else {
            self.error = "Preparing voice recognition…"
            logger.warning("startListening called while ASR not ready (state: \(String(describing: self.asrState)))")
            return AsyncStream<String> { $0.finish() }
        }
        #if targetEnvironment(simulator)
        return AsyncStream<String> { continuation in
            Task { @MainActor in
                self.isRecording = true
                try? await Task.sleep(for: .seconds(1.5))
                let mockText = "This is a simulated voice answer for testing on the simulator."
                self.partialTranscript = mockText
                continuation.yield(mockText)
                continuation.finish()
                self.isRecording = false
            }
        }
        #else
        self.error = nil
        self.partialTranscript = ""

        // Ensure WhisperKit is loaded
        guard let pipe = whisperPipe else {
            print("[STT] ❌ DIAG: whisperPipe is nil — model not loaded")
            self.error = "Voice recognition not available. Please restart."
            return AsyncStream<String> { $0.finish() }
        }
        guard let tokenizer = pipe.tokenizer else {
            print("[STT] ❌ DIAG: tokenizer is nil — pipe exists but tokenizer missing")
            self.error = "Voice recognition not available. Please restart."
            return AsyncStream<String> { $0.finish() }
        }
        print("[STT] DIAG: whisperPipe=OK, tokenizer=OK, creating AudioStreamTranscriber")

        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.continuation = continuation
        sessionID += 1
        let mySessionID = sessionID

        // Create a fresh AudioStreamTranscriber for each session.
        // State (confirmedSegments, etc.) does not reset between cycles,
        // so a new instance gives us a clean slate. This is cheap — it wraps
        // existing model references, no CoreML reload.
        //
        // WhisperKit's protocol types (AudioEncoding, etc.) are not Sendable.
        // We use nonisolated(unsafe) to cross the @MainActor → actor boundary.
        // This is safe because the WhisperKit pipeline is created once and
        // shared — we never mutate these references from multiple threads.
        nonisolated(unsafe) let encoder = pipe.audioEncoder
        nonisolated(unsafe) let extractor = pipe.featureExtractor
        nonisolated(unsafe) let seeker = pipe.segmentSeeker
        nonisolated(unsafe) let decoder = pipe.textDecoder
        nonisolated(unsafe) let tok = tokenizer
        nonisolated(unsafe) let processor = pipe.audioProcessor

        let ast = AudioStreamTranscriber(
            audioEncoder: encoder,
            featureExtractor: extractor,
            segmentSeeker: seeker,
            textDecoder: decoder,
            tokenizer: tok,
            audioProcessor: processor,
            // skipSpecialTokens strips <|startoftranscript|> and the <|x.xx|> timestamp
            // tokens from the decoded text (WhisperKit defaults it to false, which leaked
            // raw tokens into saved answers). Timestamp EMISSION stays on so the VAD
            // segment-confirmation logic still works; only the text output is cleaned.
            decodingOptions: DecodingOptions(language: "en", skipSpecialTokens: true),
            requiredSegmentsForConfirmation: 2,
            silenceThreshold: 0.3,
            useVAD: true,
            stateChangeCallback: { @Sendable [weak self] _, newState in
                // Extract Sendable values before crossing to MainActor.
                // State is structurally Sendable but not annotated as such.
                let confirmed = newState.confirmedSegments.map(\.text)
                let unconfirmed = newState.unconfirmedSegments.map(\.text)
                let currentText = newState.currentText
                let sampleCount = newState.lastBufferSize
                Task { @MainActor [weak self] in
                    self?.handleStateChange(
                        confirmedTexts: confirmed,
                        unconfirmedTexts: unconfirmed,
                        currentText: currentText,
                        sampleCount: sampleCount
                    )
                }
            }
        )
        self.transcriber = ast
        self.recordingStart = Date()

        // startStreamTranscription() suspends for the entire recording —
        // handles mic permission, recording start, and realtime transcription
        // loop internally. This eliminates the stream-before-recording race.
        transcriptionTask = Task {
            self.isRecording = true
            print("[STT] DIAG: Task started, isRecording=true, calling startStreamTranscription...")
            do {
                try await ast.startStreamTranscription()
                print("[STT] DIAG: startStreamTranscription returned normally")
            } catch {
                print("[STT] ❌ DIAG: startStreamTranscription threw: \(error)")
            }
            // Recording ended (either stopped or error). Run the single ordered teardown
            // against THIS session's captured continuation/transcriber/id (P2-5).
            await self.finishRecording(sessionID: mySessionID, continuation: continuation, transcriber: ast)
        }

        return stream
        #endif
    }

    // MARK: - Stop Listening

    func stopListening() {
        guard isRecording || transcriptionTask != nil else { return }
        logger.info("stopListening")

        // Stop the transcriber: stopStreamTranscription() halts the tap and ends the
        // realtime loop, so startStreamTranscription() returns and the teardown in the
        // transcriptionTask runs. Cancellation alone is NOT sufficient — the loop only
        // checks isRecording between decodes, so we must stop it authoritatively.
        // The buffer purge is deferred to finishRecording() (after the tap stops) to
        // fix the purge-before-teardown race (P1-3); no purge here.
        let t = transcriber
        transcriptionTask?.cancel()
        Task { await t?.stopStreamTranscription() }
    }

    /// Awaitable teardown: trigger the stop, then await the transcription task (which
    /// runs the ordered `finishRecording()` teardown) to completion. Lets callers
    /// sequence `stop → await engine teardown → deactivate session` so deactivation
    /// never races a live recording engine (U9 / P2-3).
    func stopAndWait() async {
        guard isRecording || transcriptionTask != nil else { return }
        let task = transcriptionTask
        stopListening()
        await task?.value
    }

    /// Single, ordered teardown for a recording session. Called once per session from
    /// its own transcription task, after the realtime loop has exited: stop the tap so
    /// the captured buffer is static, run the authoritative final transcription (P1-1),
    /// purge the buffer (P1-3, after stop), then finish the stream. Operates on the
    /// session's OWN captured continuation/transcriber so it never disturbs a newer
    /// session, and only clears shared refs when this session is still current (P2-5).
    private func finishRecording(
        sessionID: Int,
        continuation: AsyncStream<String>.Continuation,
        transcriber ast: AudioStreamTranscriber
    ) async {
        print("[STT] DIAG: finishRecording — partialTranscript='\(partialTranscript.prefix(40))'")

        // Ensure the tap is stopped even on the error-return path, so `audioSamples`
        // stops growing before we read or purge it (idempotent).
        await ast.stopStreamTranscription()

        // Authoritative final transcription: if streaming produced nothing but we
        // captured a non-trivial buffer, transcribe the whole buffer once. Skip if a
        // newer session has already taken over (the shared buffer is no longer ours).
        if sessionID == self.sessionID {
            await runFinalTranscriptionIfNeeded()

            // Purge AFTER the tap has stopped and the final pass has read the buffer
            // (ordering fix; no lock on the render thread — KTD6).
            nonisolated(unsafe) let processor = whisperPipe?.audioProcessor
            processor?.purgeAudioSamples(keepingLast: 0)
        }

        // Yield the final transcript to THIS session's stream, then finish it.
        if !partialTranscript.isEmpty {
            continuation.yield(partialTranscript)
        }
        continuation.finish()

        // Only clear shared state if this is still the current session — a stale
        // teardown must not nil a newer session's continuation/transcriber (P2-5).
        if sessionID == self.sessionID {
            isRecording = false
            recordingStart = nil
            self.continuation = nil
            self.transcriber = nil
            self.transcriptionTask = nil
        }
        print("[STT] DIAG: Recording session ended (id=\(sessionID))")
    }

    /// If the streaming pass yielded no text but enough audio was captured, run a
    /// final full-buffer transcription and adopt its text. This is the safety net
    /// that makes VAD gating non-fatal for short/soft/pause-leading answers (P1-1).
    private func runFinalTranscriptionIfNeeded() async {
        let partialEmpty = partialTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard let pipe = whisperPipe else { return }
        nonisolated(unsafe) let readProcessor = pipe.audioProcessor
        // Gate on the O(1) count first — materializing the buffer (~11.5 MB for a
        // full 3-minute recording) is deferred to the rare empty-streaming path.
        // The tap is already stopped, so the buffer is static between these reads.
        guard Self.shouldRunFinalTranscription(
            partialIsEmpty: partialEmpty,
            sampleCount: readProcessor.audioSamples.count
        ) else {
            return
        }
        let samples = Array(readProcessor.audioSamples)

        // WhisperKit is not Sendable; mirror the existing nonisolated(unsafe) crossing.
        // Bind the [TranscriptionResult] overload explicitly (KTD3) via the annotation.
        nonisolated(unsafe) let p = pipe
        let results: [TranscriptionResult]? = try? await p.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(language: "en", skipSpecialTokens: true, withoutTimestamps: true)
        )
        guard let results else { return }
        let text = Self.sanitizeTranscript(Self.joinTranscriptionText(results.map(\.text)))
        if !text.isEmpty {
            partialTranscript = text
            print("[STT] DIAG: Final full-buffer transcription recovered '\(text.prefix(40))'")
        }
    }

    /// Whether a final full-buffer transcription should run: only when streaming
    /// produced nothing and at least `finalTranscriptionMinSamples` were captured.
    nonisolated static func shouldRunFinalTranscription(partialIsEmpty: Bool, sampleCount: Int) -> Bool {
        partialIsEmpty && sampleCount >= finalTranscriptionMinSamples
    }

    /// Join per-segment transcription texts into one trimmed transcript.
    nonisolated static func joinTranscriptionText(_ texts: [String]) -> String {
        texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip any residual WhisperKit special/timestamp tokens (`<|...|>`) and non-speech
    /// annotations (`(typing)`, `[music]`, …) the decoder emits as ordinary words, then
    /// collapse whitespace. `skipSpecialTokens` handles the `<|...|>` tokens at the source;
    /// this is the belt-and-suspenders pass that also removes the parenthesized/bracketed
    /// annotations, which are real word tokens and survive `skipSpecialTokens`.
    nonisolated static func sanitizeTranscript(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the recording has exceeded the wall-clock cap (no live-buffer read).
    nonisolated static func recordingExceededCap(start: Date?, now: Date, cap: TimeInterval) -> Bool {
        guard let start else { return false }
        return now.timeIntervalSince(start) > cap
    }

    // MARK: - State Change Handling

    /// Called on every AudioStreamTranscriber state mutation.
    /// Combines confirmed + unconfirmed + current text for live partial results.
    private func handleStateChange(
        confirmedTexts: [String],
        unconfirmedTexts: [String],
        currentText: String,
        sampleCount: Int
    ) {
        // Filter "Waiting for speech..." placeholder
        let current = currentText == "Waiting for speech..." ? "" : currentText

        // Build transcript: confirmed (stable) + unconfirmed (fluctuating) + current (live)
        var parts: [String] = []
        let confirmed = confirmedTexts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !confirmed.isEmpty { parts.append(confirmed) }
        let unconfirmed = unconfirmedTexts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !unconfirmed.isEmpty { parts.append(unconfirmed) }
        if !current.isEmpty { parts.append(current) }

        // Sanitize here (the single chokepoint) so BOTH the live partial shown while
        // listening and the final saved transcript are clean — sanitizing only at
        // finalization would still flash tokens/annotations on screen mid-recording.
        let transcript = Self.sanitizeTranscript(parts.joined(separator: " "))

        if !transcript.isEmpty {
            partialTranscript = transcript
            continuation?.yield(transcript)
        }

        // Three-minute recording guard — wall-clock based, so we never read the live
        // `audioSamples` buffer from the MainActor during recording (KTD6 / P1-3).
        if Self.recordingExceededCap(start: recordingStart, now: Date(), cap: maxRecordingSeconds) {
            logger.warning("Recording exceeded 3-minute cap — auto-stopping")
            stopListening()
        }
    }
}

// MARK: - ASR Readiness State

/// Observable readiness of the on-device speech recognizer (U2 state machine).
/// `.failed` carries a user-facing, retriable message.
enum ASRState: Equatable {
    case idle
    case downloading
    case loading
    case ready
    case failed(String)
}

// MARK: - Errors

enum STTError: Error, LocalizedError {
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "Microphone is not available. Please check permissions in Settings."
        }
    }
}
