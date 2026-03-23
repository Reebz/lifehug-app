---
title: "Replace Apple Speech STT with FluidAudio ASR"
type: refactor
status: completed
date: 2026-03-22
deepened: 2026-03-22
---

# Replace Apple Speech STT with FluidAudio ASR

## Enhancement Summary

**Deepened on:** 2026-03-22
**Research agents used:** FluidAudio API verifier, Architecture Strategist, Code Simplicity Reviewer

### Key Corrections from Deepening

1. **Collapsed 5 tasks to 2.** Tasks 2-4 (model download, remove Speech, silence timer) are mechanical subparts of the rewrite, not standalone tasks.
2. **`process(audioBuffer:)` accepts any sample rate** — FluidAudio resamples internally. No manual 48→16kHz conversion needed.
3. **`process()` is async** — cannot be called from the real-time audio tap. Must dispatch via a buffered async stream or Task to avoid backpressure issues.
4. **Pre-load ASR model at app launch (Option B)** — prevents surprise latency on first recording. Adds ~3 lines to LaunchView/ModelState.
5. **Remove silence timer entirely.** FluidAudio's EOU detection (configurable `eouDebounceMs`) replaces it. Keeping both is YAGNI.
6. **Reuse the ASR manager across sessions via `reset()`** — `reset()` clears all state without unloading models. No per-session model reload.
7. **`stopListening()` stays synchronous.** The partial callback already yields the full transcript on every chunk, so `finish()` returns the same text. Fire-and-forget is safe.
8. **`startListening()` stays synchronous** because the ASR model is pre-loaded at launch, not inside `startRecognition()`.
9. **Net reduction: ~180 lines deleted (43% of STTService).** The entire chaining mechanism, SegmentState, taskGeneration, and nonisolated(unsafe) workarounds are eliminated.

---

## Overview

Replace `SFSpeechRecognizer` (Apple Speech) with FluidAudio's `StreamingEouAsrManager` (NVIDIA Parakeet EOU, 120M params) for speech-to-text. This eliminates the 60-second time limit, the aggressive `isFinal` endpointing that cuts off recordings at 10-20 seconds, and the complex chaining mechanism. FluidAudio is already a dependency.

## Problem Statement

Apple's on-device `SFSpeechRecognizer` aggressively fires `isFinal = true` on natural speech pauses (as early as 10-15 seconds), ending the recognition session. Attempted fixes across builds 7-9 (ignoring isFinal, restoring chaining) failed because the behavior is inherent to Apple's recognizer — not a bug in our code. Users consistently lose the bulk of their spoken answers.

## Proposed Solution

**`StreamingEouAsrManager`** (actor):
- **160ms frame-level streaming** — partial results after each chunk
- **Built-in EOU detection** — configurable debounce (default 1280ms)
- **No time limits** — processes indefinitely until `finish()` is called
- **On-device CoreML** — Neural Engine, no cloud, no privacy concerns
- **Already a dependency** — FluidAudio is in the project
- **Accepts any sample rate** — resamples to 16kHz internally

---

## Implementation

### Task 1: Rewrite STTService + pre-load ASR model

**Files:** `STTService.swift`, `ModelState.swift` (or `LifehugApp.swift`), `Info.plist`

**Pre-load ASR model at app launch:**

- [x] Create and load the ASR manager once during app startup, not per-recording:
  ```swift
  // In STTService or a new ASR property on ModelState:
  private var asrManager: StreamingEouAsrManager?

  func loadASRModel() async throws {
      let manager = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 1280)
      try await manager.loadModelsFromHuggingFace()
      self.asrManager = manager
  }
  ```
- [x] Call `loadASRModel()` from LifehugApp's `.task` (or ModelState's `prepareOnLaunch()`) alongside LLM loading:
  ```swift
  .task {
      ttsService.setKokoroManager(kokoroManager)
      kokoroManager.cleanupLegacyFilesIfNeeded()
      // Load ASR model alongside everything else
      try? await sttService.loadASRModel()
      if KokoroManager.isEnabled && kokoroManager.isModelDownloaded {
          await kokoroManager.loadEngine()
      }
  }
  ```
- [x] The manager persists across recording sessions — reuse via `reset()` (clears state, keeps models loaded)

**Rewrite STTService internals:**

- [x] Replace `import Speech` with FluidAudio types (no new import needed — FluidAudio is already imported transitively, or add `import FluidAudio`)
- [x] Delete: `SFSpeechRecognizer`, `SFSpeechAudioBufferRecognitionRequest`, `installRecognitionTask()` (~90 lines), `chainRecognitionRequest()` (~30 lines), `SegmentState` class (~15 lines), `createRecognitionRequest()`, `taskGeneration`, `shouldKeepListening`, `accumulatedTranscript`, `nonisolated(unsafe) sharedRequest`, `requestSpeechPermission()`
- [x] Delete: `resetSilenceTimer()`, `silenceTimer` — FluidAudio's EOU detection replaces the silence timer entirely
- [x] In `startRecognition()`:
  - Keep: AVAudioEngine creation, audio session configuration, `engine.prepare()` / `engine.start()`
  - Replace: recognition request + task with FluidAudio callbacks:
  ```swift
  // Reset ASR state for new session (models stay loaded)
  await asrManager?.reset()

  // Wire partial callback → stream yield
  await asrManager?.setPartialCallback { [weak self] text in
      Task { @MainActor in
          guard let self else { return }
          self.partialTranscript = text
          self.continuation?.yield(text)
      }
  }

  // Wire EOU callback — log but don't auto-stop
  await asrManager?.setEouCallback { [weak self] text in
      Task { @MainActor in
          self?.logger.info("EOU detected: \(text.count) chars")
      }
  }
  ```
  - Replace: audio tap buffer handling — dispatch to ASR actor with backpressure:
  ```swift
  // Buffered stream to avoid unbounded Task queue from the real-time audio tap.
  // The tap fires ~47 times/sec; if ASR processing lags, oldest buffers are dropped.
  let (bufferStream, bufferContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
      bufferingPolicy: .bufferingNewest(10)
  )
  self.bufferContinuation = bufferContinuation

  // Audio tap — enqueues buffers (never blocks the render thread)
  inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [bufferContinuation] buffer, _ in
      bufferContinuation.yield(buffer)
  }

  // Consumer task — feeds buffers to ASR actor at its own pace
  self.processingTask = Task {
      for await buffer in bufferStream {
          try? await self.asrManager?.process(audioBuffer: buffer)
      }
  }
  ```
- [x] In `stopListening()` (stays synchronous):
  ```swift
  func stopListening(reason: String = "unknown") {
      logger.info("stopListening — reason: \(reason)")

      // Stop audio capture
      audioEngine?.stop()
      audioEngine?.inputNode.removeTap(onBus: 0)
      audioEngine = nil

      // Stop buffer stream → consumer task exits
      bufferContinuation?.finish()
      bufferContinuation = nil
      processingTask?.cancel()
      processingTask = nil

      // Get final transcript (fire-and-forget — partial callback already yielded it)
      Task {
          let final = try? await asrManager?.finish()
          await MainActor.run {
              if let final, !final.isEmpty {
                  self.partialTranscript = final
                  self.continuation?.yield(final)
              }
              self.continuation?.finish()
              self.continuation = nil
              self.isRecording = false
          }
      }
  }
  ```
  **Note:** The `finish()` fire-and-forget is safe because the partial callback has already yielded the same text. The final `finish()` call is just cleanup + a potential last few tokens.
- [x] In `requestAuthorization()`: only request microphone permission, NOT speech recognition. Remove `requestSpeechPermission()`.
- [x] Remove `NSSpeechRecognitionUsageDescription` from Info.plist (keep `NSMicrophoneUsageDescription`)
- [x] Remove Speech framework from Xcode project's "Link Binary With Libraries" if explicitly linked
- [x] Update VoicePipeline error message at line 129 from "Speech recognition not authorized" to "Microphone access not authorized"

### Task 2: Test and verify

- [x] Test recording for 60+ seconds — no cutoff, continuous transcription
- [x] Test natural pauses (5-10 seconds) — transcription resumes after pause
- [x] Test rapid speech — partial results arrive within ~200ms
- [x] Test with Kokoro TTS — full pipeline: record → LLM → TTS → auto-reopen mic
- [x] Test microphone permission only (no speech recognition dialog)
- [x] Test first launch — ASR model downloads alongside LLM model
- [x] Test termination phrases — "that's my answer" still works
- [x] Test manual tap-to-stop — stops recording immediately
- [x] Test interruption (phone call) — recording stops cleanly
- [x] Build with `xcodebuild archive` (Release, Swift 6 strict concurrency)

---

## Stream Termination Paths (Documented)

The AsyncStream from `startListening()` finishes when `stopListening()` is called. This happens in these scenarios:

1. **User taps mic button** — DailyQuestionView calls `sttService.stopListening()`
2. **Termination phrase detected** — VoicePipeline calls `sttService.stopListening()` then breaks
3. **Transcript exceeds 50K chars** — VoicePipeline calls `sttService.stopListening()` then breaks
4. **Audio interruption** — VoicePipeline interruption handler calls `sttService.stopListening()`
5. **Bluetooth disconnect** — VoicePipeline route change handler calls `sttService.stopListening()`
6. **Pipeline cancelled** — Task cancellation propagates, stream `onTermination` fires

**No automatic endpointing.** The EOU callback fires on utterance boundaries but does NOT stop recording — the user may pause and continue. Recording runs until explicitly stopped by one of the paths above.

---

## Acceptance Criteria

### Functional
- [x] Recording works for 60+ seconds without cutoff
- [x] Partial transcript updates in real-time as user speaks
- [x] Natural pauses (5+ seconds) do NOT terminate recording
- [x] Termination phrases still work
- [x] Manual tap-to-stop works
- [x] Full voice pipeline works end-to-end
- [x] No Speech Recognition permission dialog
- [x] ASR model downloads and caches on first launch

### Non-Functional
- [x] Transcription accuracy comparable to or better than Apple Speech
- [x] Partial result latency < 500ms
- [x] Build succeeds with `xcodebuild archive`

### Cleanup
- [x] No `import Speech` remaining
- [x] No `SFSpeechRecognizer` references
- [x] `NSSpeechRecognitionUsageDescription` removed from Info.plist
- [x] Chaining mechanism fully deleted
- [x] Silence timer fully deleted
- [x] Net ~180 lines deleted from STTService

---

## Sources & References

### FluidAudio ASR (verified from source)
- `StreamingEouAsrManager` — Swift actor, 160ms chunks, `setPartialCallback` + `setEouCallback`
- `process(audioBuffer:)` — async, accepts any sample rate, resamples internally
- `finish()` — returns accumulated transcript, clears state
- `reset()` — clears state without unloading models (reusable across sessions)
- Model: NVIDIA Parakeet EOU 120M (`FluidInference/parakeet-realtime-eou-120m-coreml`)
- CoreML on Neural Engine (`.cpuAndNeuralEngine`)
- No time limits

### Internal
- `Lifehug/Services/STTService.swift` — current 421 lines, target ~220 lines
- `Lifehug/Pipeline/VoicePipeline.swift` — consumes `AsyncStream<String>`, needs error message update only
