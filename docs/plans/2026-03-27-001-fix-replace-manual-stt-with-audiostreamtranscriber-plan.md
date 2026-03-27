---
title: "Replace manual STT recording with WhisperKit AudioStreamTranscriber"
type: fix
status: active
date: 2026-03-27
deepened: 2026-03-27
---

# Replace Manual STT Recording with WhisperKit AudioStreamTranscriber

## Enhancement Summary

**Deepened on:** 2026-03-27

### Key Corrections from Deepening

1. **Architecture contradiction resolved.** The original plan proposed both "new AST per session" (Task 1) and "use `setInputSuppressed` to avoid engine teardown" (Task 2). These are mutually exclusive — `setInputSuppressed` requires keeping the same AST alive across turns, but state accumulates and corrupts subsequent transcripts. **Resolution: Drop `setInputSuppressed` for initial implementation. Use new AST per turn, accept ~200ms engine rebuild latency.** Reserve `setInputSuppressed` as a future optimization once the basic flow is stable.
2. **Memory guard required.** `audioSamples` grows unboundedly (~3.8 MB per minute). Combined with LLM (~500 MB) and Kokoro TTS (~80 MB), a five-minute recording hits ~38 MB peak audio + copies. Add a three-minute cap and purge after stopping.
3. **Audio session conflict path remains.** Removing STTService's session setup eliminates one conflict, but KokoroManager still sets `[.allowBluetoothA2DP]` while AudioProcessor sets `[.allowBluetooth]` only. **Fix: Configure session once at conversation start, not per-component.**
4. **Concrete Swift 6 integration pattern verified.** All agent findings confirm: no deadlock risk, State struct is Sendable, `Task { @MainActor in }` dispatch is correct, new AST per session is cheap (no model reload).
5. **Short utterance handling.** Single-word answers may stay in `unconfirmedSegments` only (segment confirmation requires two passes). Must combine confirmed + unconfirmed text for final result.

---

## Overview

Recording has been broken across builds 5–8 despite multiple fix attempts. The root cause is a combination of: (1) double audio session configuration between our code and WhisperKit's internal setup, (2) race conditions where the stream is returned before recording starts, and (3) missing `AVAudioEngineConfigurationChange` observer. Replace the entire manual recording + periodic transcription approach with WhisperKit's built-in `AudioStreamTranscriber`.

## Problem Statement

The current STTService manually:
1. Configures the audio session (`.playAndRecord`) — then WhisperKit's `startRecordingLive()` reconfigures with different options, triggering an engine configuration change that can cause `inputNode` to report 0 Hz / 0 channels
2. Runs a periodic transcription loop every three seconds — no VAD, re-transcribes the entire growing buffer each pass
3. Returns an AsyncStream before recording actually starts (race condition) — if anything triggers `stopListening()` before `startRecordingLive()` completes, zero audio is captured
4. Has no `AVAudioEngineConfigurationChange` observer — engine can silently stop after route changes or session reconfigurations
5. The `onTermination` handler on the stream calls `stopListening()` whenever the consuming task is cancelled — this can kill a newly started session (race condition #3 from investigation)

## Proposed Solution

Replace `STTService`'s manual `AudioProcessor` + periodic transcription with `AudioStreamTranscriber`.

### What AudioStreamTranscriber gives us

- **Recording**: Uses `AudioProcessor.startRecordingLive()` internally — one owner of the audio session, no double config
- **VAD**: Energy-based voice activity detection — skips transcription during silence
- **Real-time transcription loop**: Automatic ~1s polling with VAD gating
- **Segment confirmation**: Confirmed vs unconfirmed segments — stable partial results
- **Clean start/stop**: Actor isolation serializes all method calls — no race between start and stop
- **Permission handling**: `startStreamTranscription()` requests mic permission internally

### What we lose (and why it's fine)

- Direct control over transcription timing — AST polls every ~1s vs our 3s. Better for responsiveness.
- Direct access to raw audio samples — we only need transcribed text.
- `setInputSuppressed` optimization — deferred to future iteration (see correction #1 above).

---

## Implementation

### Task 0: Unify audio session configuration

**Files:** `Lifehug/Pipeline/VoicePipeline.swift`, `Lifehug/Services/KokoroManager.swift`

The conversation has three components fighting over the audio session:
- STTService: `.playAndRecord` with `[.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]`
- AudioProcessor (WhisperKit): `.playAndRecord` with `[.defaultToSpeaker, .allowBluetooth]` (no A2DP)
- KokoroManager: `.playAndRecord` with `[.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]`

Each reconfiguration triggers `AVAudioEngineConfigurationChange` — one of the root causes.

- [ ] Configure the audio session **once** at conversation start in `VoicePipeline.startListening()` or `wireAudioObservers()` with the superset: `.playAndRecord`, `[.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]`
- [ ] Remove `configureAudioSession()` from KokoroManager — it no longer owns the session
- [ ] Remove audio session setup from STTService — AudioProcessor's internal `setupAudioSessionForDevice()` will run but the session is already active with matching category, so the re-set is a no-op
- [ ] Keep `setActive(false)` only in `VoicePipeline.stopAll()` (conversation end)

### Task 1: Rewrite STTService around AudioStreamTranscriber

**File:** `Lifehug/Services/STTService.swift`

- [ ] Remove all manual recording code (`startRecordingLive`, `stopRecording`, `audioProcessor` access)
- [ ] Remove `startPeriodicTranscription()`, `transcribe()` helper, `finalTranscriptionTask`, `transcriptionTask`
- [ ] Add `transcriber: AudioStreamTranscriber?` and `transcriptionTask: Task<Void, Never>?` properties
- [ ] Create new `AudioStreamTranscriber` for each recording session (state doesn't reset between cycles):
  ```swift
  private func createStreamTranscriber() -> AudioStreamTranscriber? {
      guard let pipe = whisperPipe, let tokenizer = pipe.tokenizer else { return nil }
      return AudioStreamTranscriber(
          audioEncoder: pipe.audioEncoder,
          featureExtractor: pipe.featureExtractor,
          segmentSeeker: pipe.segmentSeeker,
          textDecoder: pipe.textDecoder,
          tokenizer: tokenizer,
          audioProcessor: pipe.audioProcessor,
          decodingOptions: DecodingOptions(language: "en"),
          requiredSegmentsForConfirmation: 2,
          silenceThreshold: 0.3,
          useVAD: true,
          stateChangeCallback: { [weak self] _, newState in
              Task { @MainActor [weak self] in
                  self?.handleStateChange(newState)
              }
          }
      )
  }
  ```
- [ ] `startListening()` creates the transcriber, launches `startStreamTranscription()` in a stored Task, returns the AsyncStream. The `startStreamTranscription()` suspends for the entire recording — it handles permission, recording start, and the transcription loop internally. This eliminates the stream-returned-before-recording race.
- [ ] `handleStateChange()` combines confirmed + unconfirmed segment text into `partialTranscript` and yields to the continuation. Filter out `"Waiting for speech..."` from `currentText` before yielding.
- [ ] `stopListening()` cancels the transcription Task AND calls `await transcriber.stopStreamTranscription()`. Both are needed — Task cancellation triggers `CancellationError` at sleep points, `stopStreamTranscription` properly tears down the audio engine. Set `transcriber = nil` after stopping.
- [ ] For the final transcript, combine `confirmedSegments + unconfirmedSegments` text — short utterances (one to two words) may never reach `confirmedSegments` since confirmation requires two consecutive matching passes.
- [ ] Add three-minute recording guard: if `audioProcessor.audioSamples.count > 16000 * 180` (~2.88M samples), auto-stop. After stopping, consider calling `audioProcessor.purgeAudioSamples(keepingLast: 0)` to free the buffer before LLM inference (peak memory consumer).

### Task 2: Add VoicePipeline.finishListening() and fix state machine

**Files:** `Lifehug/Pipeline/VoicePipeline.swift`, `Lifehug/Views/DailyQuestionView.swift`

- [ ] Add `finishListening()` method to VoicePipeline — transitions from `.listening` to processing the transcript. DailyQuestionView currently calls `sttService.stopListening()` directly (line 704), bypassing the pipeline.
- [ ] Replace all direct `sttService.stopListening()` calls in views with `pipeline.finishListening()`
- [ ] Update `runListening()` to consume the new STTService stream — the `AsyncStream<String>` API stays the same, so the `for await transcript in stream` loop should work unchanged
- [ ] Verify the `transition(to:)` → cancel → `onTermination` → `stopListening` chain works cleanly — the `onTermination` handler should be scoped to avoid killing a newly started session if `transition(to: .listening)` is called while already in `.listening` (e.g., from `autoReopenMic`). Consider using a session ID or generation counter.
- [ ] For the conversation loop (auto-reopen mic after TTS), the flow is: TTS finishes → `startListening()` → creates new AST → new recording session. The ~200ms engine rebuild latency is within the natural pause between TTS finishing and the user speaking.

### Task 3: Verify and test

- [ ] Build with `xcodebuild archive` (Release, Swift 6 strict concurrency)
- [ ] Run all 99 existing tests
- [ ] **On-device test 1**: Tap mic, speak for 10 seconds, tap stop — verify transcript appears
- [ ] **On-device test 2**: Speak a single word ("yes") — verify it appears (may be in unconfirmed only)
- [ ] **On-device test 3**: Full conversation loop — STT → LLM → TTS → auto-reopen mic → STT again
- [ ] **On-device test 4**: Speak for 60+ seconds — verify no cutoff, complete transcript
- [ ] **On-device test 5**: Connect/disconnect AirPods during recording — verify graceful handling
- [ ] Verify Console.app shows AudioStreamTranscriber state changes (use `os.Logger`)
- [ ] Monitor memory via Instruments during a three-minute recording — verify no runaway growth

---

## Key API Details

### AudioStreamTranscriber initialization

Requires individual components from WhisperKit (not the WhisperKit instance itself):
```
audioEncoder, featureExtractor, segmentSeeker, textDecoder, tokenizer, audioProcessor
```
Plus: `decodingOptions`, `requiredSegmentsForConfirmation`, `silenceThreshold`, `useVAD`, `stateChangeCallback`

Creating a new AST per session is cheap — it wraps existing model references, no reloading. The heavy `WhisperKit` pipeline (CoreML models, Metal prewarm) is created once and persists across sessions.

### State model

```swift
struct State {
    var isRecording: Bool
    var currentText: String              // live token-by-token partial
    var confirmedSegments: [TranscriptionSegment]   // stable — only grows
    var unconfirmedSegments: [TranscriptionSegment] // fluctuates each pass
    var bufferEnergy: [Float]            // for waveform visualization
}
```

The `stateChangeCallback` fires on every mutation with `(oldState, newState)`. Fires on the actor's thread — dispatch to MainActor for UI. `State` is structurally Sendable (all fields are value types). `TranscriptionSegment` conforms to `Sendable` (Models.swift:596). If the compiler warns, add `extension AudioStreamTranscriber.State: @retroactive Sendable {}`.

### Start/stop

- `startStreamTranscription()` — async, suspends for entire recording duration. Must be called from a stored `Task`, not awaited inline from a `@MainActor` method.
- `stopStreamTranscription()` — sync on actor. Sets `isRecording = false`, stops recording. Call via `Task { await transcriber.stopStreamTranscription() }` from MainActor. No deadlock — actor methods are serialized cooperatively, not via blocking locks.

### Concurrency safety

Actor isolation serializes `startStreamTranscription()` and `stopStreamTranscription()`. The `stop` call executes when the `realtimeLoop` hits its next `await` point (sleep or transcribe). No deadlock, no race. Task cancellation propagates correctly through actor suspension points.

### Reference implementation

```swift
func startListening() -> AsyncStream<String> {
    let (stream, continuation) = AsyncStream<String>.makeStream()

    let transcriber = createStreamTranscriber()
    self.transcriber = transcriber

    transcriptionTask = Task {
        do {
            try await transcriber?.startStreamTranscription()
        } catch { }
        await MainActor.run { continuation.finish() }
    }

    return stream
}

func stopListening() {
    transcriptionTask?.cancel()
    let t = transcriber
    transcriber = nil
    transcriptionTask = nil
    Task { await t?.stopStreamTranscription() }
}
```

---

## Known Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| `audioSamples` grows unboundedly | HIGH | Three-minute cap; purge after stopping |
| Audio session options mismatch (KokoroManager vs AudioProcessor) | MEDIUM | Task 0: configure once at conversation start |
| Short utterances stay in unconfirmedSegments | MEDIUM | Combine confirmed + unconfirmed for final text |
| Hallucination during ambient noise (not speech) | MEDIUM | VAD filters most; post-process known patterns if needed |
| TextDecoder force-unwrap crash during extended transcription (#414) | MEDIUM | Typical sessions are 1–2 minutes; monitor PRs #417/#420/#424 |
| Data race on `audioSamples` (#442) | LOW | Encapsulated behind AST actor; no direct access from our code |
| `onTermination` kills newly started session on rapid transition | LOW | Session ID / generation counter in `onTermination` handler |
| "Waiting for speech..." text in `currentText` | LOW | Filter in `handleStateChange` |

---

## Acceptance Criteria

- [ ] Recording works on real device (the critical bug broken since build 5)
- [ ] Partial transcription results appear within ~3 seconds of speaking
- [ ] Final transcript is complete — combines confirmed + unconfirmed segments
- [ ] Single-word utterances are captured (even if only in unconfirmed)
- [ ] No double audio session configuration — session set once at conversation start
- [ ] No race condition between stream return and recording start
- [ ] Conversation loop works: STT → LLM → TTS → new AST → STT again
- [ ] 60+ second recordings produce complete transcripts
- [ ] Three-minute cap prevents unbounded memory growth
- [ ] Build succeeds with `xcodebuild archive` (Release, Swift 6 strict concurrency)
- [ ] All 99 existing tests pass

---

## Institutional Learnings Applied

From `docs/solutions/ios-audio-pipeline/mlx-kokoro-crash-and-apple-stt-cutoff.md`:

1. **"Await actor setup before starting producers"** — AudioStreamTranscriber's `startStreamTranscription()` is a single awaited call that handles setup + recording + transcription. No fire-and-forget race possible.
2. **"Use `OSAllocatedUnfairLock` for double-resume guards"** — the continuation's `finish()` call should be guarded if there's any chance of concurrent access. With the new architecture, `finish()` is called only from the transcription Task's completion, reducing the risk. But add a guard if the `onTermination` handler can also finish.
3. **"Keep `.playAndRecord` active throughout"** — Task 0 ensures this.
4. **"Don't use MLX on iOS"** — WhisperKit uses CoreML, confirmed safe.

---

## Sources

- WhisperKit `AudioStreamTranscriber`: actor at `Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift` (224 lines)
- WhisperKit `AudioProcessor`: open class at `Sources/WhisperKit/Core/Audio/AudioProcessor.swift`
- WhisperAX sample app: `Examples/WhisperAX/ContentView.swift` — manual streaming pattern (does NOT use AudioStreamTranscriber)
- WhisperKit issue #261: `IsFormatSampleRateAndChannelCountValid` crash (237 events / 215 users)
- WhisperKit issue #442: Data race on `audioSamples`
- WhisperKit issue #414: TextDecoder force-unwrap crash during extended live transcription
- WhisperKit issue #393: CoreML audio resource leak (`coreaudiod` holds 10–12% CPU)
- Documented solution: `docs/solutions/ios-audio-pipeline/mlx-kokoro-crash-and-apple-stt-cutoff.md`
- Previous plan: `docs/plans/2026-03-23-001-refactor-replace-fluidaudio-asr-with-whisperkit-plan.md`
- Apple: Responding to audio route changes — apps must observe `AVAudioEngineConfigurationChange`
- Swift actor concurrency: no deadlock risk between `start`/`stop` — cooperative scheduling, not blocking locks
