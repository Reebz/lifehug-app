---
title: "MLX Kokoro TTS crash and Apple Speech STT cutoff — replaced with FluidAudio"
category: ios-audio-pipeline
date: 2026-03-22
tags: [ios, tts, stt, mlx, coreml, fluidaudio, kokoro, parakeet, avaudiosession, crash, memory]
module: VoicePipeline
symptom: "Hard crash 5 seconds into TTS playback; STT recording cuts off at 10-20 seconds"
root_cause: "MLX GPU memory balloon (300MB→2.3GB) + Apple Speech aggressive isFinal endpointing"
---

# MLX Kokoro TTS Crash and Apple Speech STT Cutoff

## Problem

Two critical voice pipeline failures that made the app unusable:

1. **TTS crash**: App hard-crashed to home screen ~5 seconds into AI voice playback, every time. No logging, no crash report in Xcode Organizer (indicating jetsam/SIGKILL, not a Swift error).

2. **STT cutoff**: Recording stopped transcribing after 10-20 seconds while the mic button stayed active. User's spoken answer was lost.

## Investigation Steps

### TTS Crash (Builds 22-26)

| Build | Hypothesis | Fix Attempted | Result |
|-------|-----------|---------------|--------|
| 22 | Audio session conflict (.playAndRecord vs .playback) | Unified to .playAndRecord, removed setActive(false) | Still crashed |
| 24 | Concurrent MLX Metal GPU inference (LLM + Kokoro) | Serialized pipeline: collect all LLM output, then speak | Still crashed |
| 25 | Kokoro/MLX is the cause (diagnostic) | Disabled Kokoro, system TTS only | **No crash** |
| 26 | Memory pressure from Kokoro model loaded but unused | Disabled Kokoro model loading entirely | Confirmed Kokoro is sole cause |

**Research found the smoking gun**: [kokoro-ios Issue #5](https://github.com/mlalma/kokoro-ios/issues/5) — the 300MB model balloons to **2.3GB runtime RAM** on iOS. [mlx-swift Issue #121](https://github.com/ml-explore/mlx-swift/issues/121) — random "Address size fault" crashes on iOS, barely occurs on macOS. These are upstream framework bugs with no fix.

### STT Cutoff (Builds 7-9)

Apple's `SFSpeechRecognizer` fires `isFinal = true` on natural speech pauses (not just the 60-second timeout). The chaining mechanism that was supposed to handle this either lost audio during the swap (build 7-8) or left the recognition task done with no new results coming (build 9). The behavior is inherent to Apple's on-device recognizer — not fixable in our code.

## Root Cause

**TTS**: MLX's GPU memory management on iOS is fundamentally broken. The `@preconcurrency import MLX` hacks, `Mutex<EngineState>`, and `nonisolated(unsafe)` wrappers in KokoroManager were fighting the framework, not fixing it. The model simply uses too much Metal GPU memory on iPhone.

**STT**: Apple's on-device `SFSpeechRecognizer` has aggressive voice activity detection that considers natural pauses as end-of-speech. The 60-second chaining mechanism added complexity (~150 lines: `SegmentState`, `taskGeneration`, `shouldKeepListening`, `chainRecognitionRequest`) but couldn't prevent audio loss during request swaps.

## Solution

Replaced both components with **FluidAudio** (already in the project for Kokoro TTS):

### TTS: FluidAudio KokoroTtsManager (CoreML)
- Same Kokoro-82M model, but runs via CoreML instead of MLX
- 55% less peak memory than MLX
- `synthesize()` returns WAV Data → played via simple `AVAudioPlayer`
- Eliminated: AVAudioEngine, playerNode, 3 notification observers, PlaybackState lock, `nonisolated(unsafe)` wrappers
- KokoroManager: 620 lines → 275 lines

### STT: FluidAudio StreamingEouAsrManager (Parakeet)
- NVIDIA Parakeet EOU 120M params, CoreML on Neural Engine
- 160ms frame-level streaming with partial + EOU callbacks
- **No time limits** — processes indefinitely until finish() is called
- Built-in end-of-utterance detection (1280ms debounce)
- Eliminated: SFSpeechRecognizer, chaining mechanism, SegmentState, taskGeneration, silence timer
- STTService: 421 lines → 230 lines
- No Speech Recognition permission needed (microphone only)

### Key Implementation Details

**Audio tap → ASR actor threading**: AVAudioPCMBuffer is non-Sendable. Wrapped in `@unchecked Sendable` struct (`SendableBuffer`) to cross actor boundary. The ASR manager's `process(audioBuffer:)` resamples internally (48kHz→16kHz).

**Callback wiring race**: Must `await` `reset()` and `setPartialCallback()` on the ASR actor BEFORE starting the audio engine. Fire-and-forget `Task { }` for these caused a race where buffers arrived before callbacks were registered.

**PlayerDelegate thread safety**: AVAudioPlayer's `audioPlayerDidFinishPlaying` fires on an AVFoundation background thread. `forceComplete()` fires from `@MainActor`. Both could resume the continuation simultaneously. Fixed with `OSAllocatedUnfairLock<Bool>`.

**Voice ID prefix bug**: `populateVoiceNames()` stripped the `af_`/`am_` prefix from voice IDs ("af_bella" → "bella"). FluidAudio tried to download `voices/bella.json` instead of `voices/af_bella.json` → 404 → initialization failure → phase stuck at .failed → voice picker hidden → user trapped.

## Prevention

1. **Don't use MLX for on-device inference on iOS** — Metal GPU memory management is broken upstream. Use CoreML or ONNX instead.
2. **Don't rely on Apple's SFSpeechRecognizer for long recordings** — the `isFinal` behavior is aggressive and undocumented. Use FluidAudio Parakeet or WhisperKit.
3. **Always `await` actor setup before starting producers** — fire-and-forget `Task { }` for actor method calls races with synchronous code that follows.
4. **Use `OSAllocatedUnfairLock` for double-resume guards** — plain `Bool` is not thread-safe when AVFoundation callbacks fire on arbitrary threads.
5. **Keep full FluidAudio voice IDs** (e.g., `af_heart`, not `heart`) — the prefix is part of the HuggingFace file path.

## Related

- [kokoro-ios Issue #5](https://github.com/mlalma/kokoro-ios/issues/5) — MLX memory balloon
- [mlx-swift Issue #121](https://github.com/ml-explore/mlx-swift/issues/121) — iOS crash bugs
- [FluidAudio GitHub](https://github.com/FluidInference/FluidAudio) — CoreML TTS + ASR
- `docs/plans/2026-03-21-001-refactor-replace-mlx-kokoro-with-coreml-fluidaudio-plan.md`
- `docs/plans/2026-03-22-004-refactor-replace-apple-stt-with-fluidaudio-asr-plan.md`
