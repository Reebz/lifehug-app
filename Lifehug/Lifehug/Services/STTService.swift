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

    // MARK: - Clip Capture (U3)

    /// Where the current turn's clip is staged (KTD7). Set by the pipeline before each mic
    /// start; nil disables capture (typed turns, no-context sessions, simulator).
    struct ClipContext: Sendable {
        let stagingDirectory: URL
        let clipFilename: String
    }
    var clipContext: ClipContext?

    /// Result of the last teardown's clip write, read by the pipeline after the stream ends.
    /// `lastCapturedClipFilename` is nil when nothing was captured; `lastCaptureFailed` is
    /// true only when a real capture was attempted but the durability write failed.
    private(set) var lastCapturedClipFilename: String?
    private(set) var lastCaptureFailed: Bool = false

    /// In-flight AAC encodes (off the teardown path). A save awaits these before committing
    /// the staged clips (KTD2). Stateless `StorageService` for the durable writes.
    private var pendingClipTasks: [Task<Void, Never>] = []
    private let clipStorage = StorageService()

    /// Whether to write a clip: a staging context exists and the buffer clears the floor.
    nonisolated static func shouldCaptureClip(hasContext: Bool, sampleCount: Int) -> Bool {
        hasContext && sampleCount >= AudioClipStore.minimumSamples
    }

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
        // Fresh clip-capture state for this recording; the teardown sets it.
        lastCapturedClipFilename = nil
        lastCaptureFailed = false
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

        // Clip capture + authoritative final transcription. Skip entirely if a newer
        // session has already taken over (the shared buffer is no longer ours).
        if sessionID == self.sessionID {
            // Materialize the static buffer ONCE (KTD2). The clip write owns this copy and
            // the empty-streaming final transcription reuses it, rather than re-reading the
            // buffer. This ~11.5MB copy is now paid on every recorded turn, not just the
            // rare empty-streaming path — the accepted cost of durable audio.
            nonisolated(unsafe) let processor = whisperPipe?.audioProcessor
            let samples: [Float] = processor.map { Array($0.audioSamples) } ?? []

            // Persist the clip synchronously (raw dump = the durability point) inside this
            // guarded teardown window, before the purge and before stopAndWait() returns.
            // AAC encoding runs off this path (see persistClipIfNeeded). A persist failure
            // never blocks the purge or transcript yield — the segment is marked audio-failed.
            persistClipIfNeeded(samples: samples)

            // Authoritative final transcription reuses the same materialized buffer: if
            // streaming produced nothing but we captured a non-trivial buffer, transcribe it.
            await runFinalTranscription(using: samples)

            // Purge AFTER the tap has stopped and the final pass + clip write have read the
            // buffer (ordering fix; no lock on the render thread — KTD6).
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
    /// Reuses the buffer already materialized for the clip write (KTD2) — no re-read.
    private func runFinalTranscription(using samples: [Float]) async {
        let partialEmpty = partialTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard let pipe = whisperPipe else { return }
        guard Self.shouldRunFinalTranscription(
            partialIsEmpty: partialEmpty,
            sampleCount: samples.count
        ) else {
            return
        }

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

    /// Persist the just-captured turn as a clip (KTD2/KTD3). Synchronously dumps the raw
    /// samples to the session staging area — the durability point — inside the teardown
    /// window, then kicks off the AAC encode off the teardown path. Sets
    /// `lastCapturedClipFilename` (nil when nothing captured) and `lastCaptureFailed`. Never
    /// throws: a persist failure must not block the purge or the transcript yield.
    private func persistClipIfNeeded(samples: [Float]) {
        guard let ctx = clipContext,
              Self.shouldCaptureClip(hasContext: true, sampleCount: samples.count) else { return }

        let rawURL = ctx.stagingDirectory.appendingPathComponent(ctx.clipFilename + ".raw")
        let finalURL = ctx.stagingDirectory.appendingPathComponent(ctx.clipFilename)
        let excludeBackup = !StorageService.iCloudBackupEnabled
        do {
            try FileManager.default.createDirectory(at: ctx.stagingDirectory, withIntermediateDirectories: true)
            try clipStorage.durableWrite(
                AudioClipStore.rawDumpData(samples),
                to: rawURL,
                protection: .completeUnlessOpen,
                excludeFromBackup: excludeBackup
            )
            lastCapturedClipFilename = ctx.clipFilename
        } catch {
            lastCaptureFailed = true
            logger.error("Clip raw dump failed: \(error.localizedDescription)")
            return
        }

        // Off the teardown path: encode AAC, atomically replace the raw dump with the .m4a.
        // A fresh (stateless) StorageService inside the detached task keeps it Sendable-clean.
        // On encode failure the raw dump is intentionally LEFT in staging; `commitClips`
        // recovers it by re-encoding at save time, so the recording survives (KTD2).
        let task = Task.detached(priority: .utility) {
            let storage = StorageService()
            let encodeTemp = ctx.stagingDirectory.appendingPathComponent(".encode-\(ctx.clipFilename).tmp")
            do {
                try AudioClipStore.encode(samples: samples, to: encodeTemp)
                try storage.durablePlace(
                    tempFile: encodeTemp,
                    at: finalURL,
                    protection: .completeUnlessOpen,
                    excludeFromBackup: excludeBackup
                )
                try? AudioClipStore.deleteClip(at: rawURL)
            } catch {
                try? FileManager.default.removeItem(at: encodeTemp)
            }
        }
        pendingClipTasks.append(task)
    }

    /// Re-transcribe a clip from disk for empty-transcript recovery (U5/KTD10). Decodes the
    /// clip and runs the SAME `transcribe(audioArray:)` overload and sanitize/join as the
    /// live final-transcription path, so recovered text is indistinguishable from live text.
    /// Device-only (WhisperKit); returns nil on the simulator or when the model isn't loaded.
    func transcribeClip(atPath path: String) async -> String? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let pipe = whisperPipe else { return nil }
        let samples = (try? AudioClipStore.decodeSamples(from: URL(fileURLWithPath: path))) ?? []
        guard samples.count >= Self.finalTranscriptionMinSamples else { return nil }
        nonisolated(unsafe) let p = pipe
        let results: [TranscriptionResult]? = try? await p.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(language: "en", skipSpecialTokens: true, withoutTimestamps: true)
        )
        guard let results else { return nil }
        return Self.sanitizeTranscript(Self.joinTranscriptionText(results.map(\.text)))
        #endif
    }

    /// Await all in-flight AAC encodes so a save can safely commit the staged clips (KTD2).
    /// Off the hot path — called at save time, not during recording.
    func awaitPendingClipWrites() async {
        let tasks = pendingClipTasks
        pendingClipTasks.removeAll()
        for t in tasks { await t.value }
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
        s = Self.replacingMatches(in: s, of: Self.specialTokenRegex)
        s = Self.replacingMatches(in: s, of: Self.annotationRegex)
        s = Self.replacingMatches(in: s, of: Self.whitespaceRegex)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Precompiled sanitize patterns. sanitizeTranscript runs on EVERY transcriber
    /// state change while recording, and `replacingOccurrences(options: .regularExpression)`
    /// recompiles its pattern on each call — three compiles per callback on the MainActor.
    /// NSRegularExpression is immutable and documented thread-safe; `nonisolated(unsafe)`
    /// is the project's standard crossing for such types.
    nonisolated(unsafe) private static let specialTokenRegex =
        try! NSRegularExpression(pattern: #"<\|[^|]*\|>"#)
    nonisolated(unsafe) private static let annotationRegex =
        try! NSRegularExpression(pattern: #"[\(\[][^\)\]]*[\)\]]"#)
    nonisolated(unsafe) private static let whitespaceRegex =
        try! NSRegularExpression(pattern: #"\s+"#)

    nonisolated private static func replacingMatches(in s: String, of regex: NSRegularExpression) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
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
