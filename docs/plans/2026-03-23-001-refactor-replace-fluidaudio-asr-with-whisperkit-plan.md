---
title: "Replace FluidAudio ASR with WhisperKit"
type: refactor
status: completed
date: 2026-03-23
deepened: 2026-03-23
---

# Replace FluidAudio ASR with WhisperKit

## Enhancement Summary

**Deepened on:** 2026-03-23

### Key Corrections from Deepening

1. **SPM dependency conflict discovered.** WhisperKit requires `swift-transformers <1.2.0` (via `.upToNextMinor(from: "1.1.6")`), but FluidAudio requires `>=1.2.0`. They cannot coexist. **Fix: Fork WhisperKit and widen the constraint to `.upToNextMajor(from: "1.1.6")`.** This is a one-line change in the fork's Package.swift.
2. **Exact API verified.** `transcribe(audioArray:)` returns `[TranscriptionResult]` with `.text`, `.segments` (with word timings), and `.language`. Expects 16kHz mono `[Float]`.
3. **Audio tap format confirmed.** Set tap format to 16kHz mono — AVAudioEngine handles resampling from hardware rate automatically. No manual resampling needed.
4. **`segmentCallback` parameter available** on `transcribe(audioArray:segmentCallback:)` — fires per-segment during transcription. Can be used for partial results within a single transcription call.

---

## Overview

Replace FluidAudio's Parakeet EOU ASR (which fails with CoreML error on the user's device) with WhisperKit — an Apple-native Whisper implementation with CoreML, SPM integration, and automatic model download.

## Problem Statement

FluidAudio's `StreamingEouAsrManager` fails with `Error Domain=com.apple.CoreML Code=0` during model loading. The Parakeet EOU CoreML model compilation fails, leaving `asrManager` permanently nil. Every recording attempt produces "I didn't catch that."

## Proposed Solution

**WhisperKit** (`argmaxinc/WhisperKit`, forked to widen swift-transformers constraint):
- `transcribe(audioArray:)` — batch transcription of accumulated 16kHz audio
- Periodic transcription every ~3 seconds for live partial results
- `segmentCallback` for per-segment updates during transcription
- CoreML-native on Neural Engine
- Auto model download from HuggingFace
- 5,829 stars, MIT license, actively maintained

## Model Selection

**Default: `base.en`** — 60 MB download, ~388 MB runtime. Lighter than small.en, leaves more headroom for LLM + Kokoro TTS.

Use `base.en` rather than `small.en` because:
- The app already runs Llama 3B (~2 GB) + Kokoro TTS (~400 MB)
- `base.en` at ~388 MB fits comfortably; `small.en` at ~852 MB is tight
- For conversational memoir answers (1-2 minutes), `base.en` accuracy is sufficient
- Can upgrade to `small.en` later if accuracy is insufficient

---

## Implementation

### Task 0: Fork WhisperKit to fix dependency conflict

- [ ] Fork `argmaxinc/WhisperKit` to `lifehug/WhisperKit` (or your GitHub org)
- [ ] In the fork's `Package.swift`, change:
  ```swift
  // FROM:
  .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMinor(from: "1.1.6"))
  // TO:
  .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.1.6")
  ```
  This allows swift-transformers 1.2.0+ (which FluidAudio needs) while still satisfying WhisperKit's minimum of 1.1.6.
- [ ] Add the fork as the SPM dependency in Lifehug:
  ```swift
  .package(url: "https://github.com/lifehug/WhisperKit.git", branch: "main")
  ```
- [ ] Verify `swift package resolve` succeeds with both FluidAudio and WhisperKit

### Task 1: Rewrite STTService with WhisperKit

**File:** `STTService.swift`

- [ ] Replace FluidAudio ASR imports with `import WhisperKit`
- [ ] Replace `StreamingEouAsrManager` with WhisperKit pipeline:
  ```swift
  private var whisperPipe: WhisperKit?
  private var audioSamples: [Float] = []
  private var transcriptionTask: Task<Void, Never>?

  func loadASRModel() async {
      do {
          whisperPipe = try await WhisperKit(WhisperKitConfig(
              model: "base.en",
              verbose: false,
              prewarm: true,
              load: true,
              download: true
          ))
          print("[STT] WhisperKit loaded: base.en")
      } catch {
          print("[STT] WhisperKit load failed: \(error)")
          self.error = "Voice recognition failed to load."
      }
  }
  ```
- [ ] Audio tap accumulates 16kHz mono samples:
  ```swift
  let format16kHz = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
  inputNode.installTap(onBus: 0, bufferSize: 4096, format: format16kHz) { buffer, _ in
      // Extract float samples and append to audioSamples
      guard let channelData = buffer.floatChannelData else { return }
      let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
      // Thread-safe append (audioSamples accessed from both tap and transcription task)
      // Use a lock or dispatch to main
  }
  ```
- [ ] Periodic transcription every ~3 seconds:
  ```swift
  transcriptionTask = Task {
      while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(3))
          guard !Task.isCancelled, !audioSamples.isEmpty else { continue }
          let samples = audioSamples  // snapshot
          let results = try? await whisperPipe?.transcribe(audioArray: samples)
          if let text = results?.first?.text, !text.isEmpty {
              self.partialTranscript = text
              self.continuation?.yield(text)
          }
      }
  }
  ```
- [ ] On stopListening(), final transcription of complete buffer:
  ```swift
  let results = try? await whisperPipe?.transcribe(audioArray: audioSamples)
  if let text = results?.first?.text, !text.isEmpty {
      cont?.yield(text)
  }
  cont?.finish()
  audioSamples = []
  ```
- [ ] Thread safety for `audioSamples`: the audio tap writes from the render thread, the transcription task reads. Use `nonisolated(unsafe)` or a lock-free approach (e.g., accumulate in the tap, snapshot + clear in the transcription task).
- [ ] Remove all FluidAudio ASR code (SendableBuffer, StreamingEouAsrManager references)
- [ ] Keep FluidAudio for Kokoro TTS — only ASR is replaced

### Task 2: Test and verify

- [ ] Test partial transcripts appear every ~3 seconds during recording
- [ ] Test final transcript is complete and accurate after stopListening()
- [ ] Test 1-2 minute recordings produce full, accurate transcripts
- [ ] Test memory: base.en (~388 MB) + Llama 3B (~2 GB) + Kokoro (~400 MB) fits on 8 GB
- [ ] Test model auto-download on first launch
- [ ] Test SPM resolution: both FluidAudio and WhisperKit(fork) resolve without conflict
- [ ] Build with `xcodebuild archive` (Release, Swift 6 strict concurrency)

---

## Acceptance Criteria

- [ ] Periodic partial transcripts appear every ~3 seconds during recording
- [ ] Final transcript is accurate for 1-2 minute spoken answers
- [ ] No CoreML loading failures
- [ ] No "I didn't catch that" errors
- [ ] Memory fits alongside LLM + Kokoro on 8 GB device
- [ ] SPM resolves without swift-transformers version conflict
- [ ] Build succeeds with `xcodebuild archive`

---

## Sources

- [WhisperKit GitHub](https://github.com/argmaxinc/WhisperKit) — v0.17.0, MIT, iOS 16+
- [WhisperKit Package.swift](https://github.com/argmaxinc/WhisperKit/blob/main/Package.swift) — swift-transformers constraint
- `transcribe(audioArray:)` returns `[TranscriptionResult]` with `.text`, expects 16kHz mono `[Float]`
- [WhisperKit Issue #442](https://github.com/argmaxinc/WhisperKit/issues/442) — Data race (avoided by our own audio tap approach)
- [WhisperKit Issue #392](https://github.com/argmaxinc/WhisperKit/issues/392) — iOS 26 crash (workaround: `supressTokens: []`)
- Current STTService: `Lifehug/Services/STTService.swift`
- Documented solution: `docs/solutions/ios-audio-pipeline/mlx-kokoro-crash-and-apple-stt-cutoff.md`
