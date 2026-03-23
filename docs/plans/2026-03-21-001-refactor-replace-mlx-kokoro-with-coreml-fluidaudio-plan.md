---
title: "Replace MLX Kokoro TTS with CoreML FluidAudio"
type: refactor
status: active
date: 2026-03-21
deepened: 2026-03-21
---

# Replace MLX Kokoro TTS with CoreML FluidAudio

## Enhancement Summary

**Deepened on:** 2026-03-21
**Research agents used:** FluidAudio API deep dive, Silero VAD API deep dive, Architecture Strategist, Performance Oracle, Code Simplicity Reviewer

### Key Corrections from Deepening

1. **Collapsed Phases 1-3 into one atomic phase.** Adding FluidAudio, removing MLX, and re-enabling Kokoro is one change — shipping them separately creates a window with both dependencies and invites confusion.
2. **Moved Silero VAD to a separate follow-up plan.** VAD is a UX enhancement for turn-taking, not a crash fix. Ship the FluidAudio migration first, stabilize in production, then add VAD. Mixing them risks the P0 fix.
3. **Investigate AVAudioPlayer over AVAudioEngine.** If FluidAudio returns standard audio Data (WAV/PCM), AVAudioPlayer eliminates ~115 lines of engine lifecycle, three notification observers, and the PlaybackState lock machinery.
4. **Keep the sequential pipeline.** Streaming producer/consumer restoration is premature optimization — the 1-2 second time-to-first-speech difference is not worth the coordination complexity. Profile after shipping, optimize if needed.
5. **Pin FluidAudio to exact version.** Too central a dependency for semantic version ranges.
6. **Verify FluidAudio's synthesize() return format before coding.** The Data blob could be raw Float32 PCM or WAV-encoded — this determines whether playback uses AVAudioPlayer or raw buffer scheduling.

### FluidAudio API Details (from research)

**Main class:** `KokoroTtsManager` (not `TtSManager` — corrected)

```swift
// Init
let manager = KokoroTtsManager(defaultVoice: "af_heart")

// Download + compile models (with progress)
let models = try await TtsModels.download(
    variants: [.fiveSecond, .fifteenSecond],
    progressHandler: { progress in /* .listing, .downloading, .compiling */ }
)

// Initialize with downloaded models
try await manager.initialize(models: models, preloadVoices: ["af_heart"])

// Synthesize — returns Data at 24kHz
let audioData = try await manager.synthesize(
    text: "Hello!",
    voice: "af_heart",
    voiceSpeed: 1.1,    // matches our current speed
    deEss: true          // built-in de-esser
)

// Cleanup
manager.cleanup()
```

**Key facts:**
- Returns `Data` (format to be verified — raw Float32 PCM or WAV)
- Sample rate: 24,000 Hz (same as current KokoroSwift — `TtsConstants.audioSampleRate`)
- Voice selection: String per call (e.g., `"af_heart"`, `"am_adam"`)
- Speed: `voiceSpeed` parameter (1.0 default, our 1.1 works)
- Not `@MainActor`, not `Sendable` — needs `nonisolated(unsafe)` wrapper
- CoreML models use `.cpuAndGPU` (not ANE — corrected from initial research)
- First-run compilation: 10-30 seconds per model variant, cached by OS after that
- Models auto-download from HuggingFace if not cached

---

## Overview

Replace the MLX-based Kokoro TTS implementation (`LocalPackages/kokoro-ios`) with [FluidAudio](https://github.com/FluidInference/FluidAudio), a CoreML-based Kokoro implementation. This eliminates the class of memory/GPU crashes that cause hard app termination during TTS playback.

## Problem Statement

The current MLX-based Kokoro TTS crashes the app ~5 seconds into voice playback on every use. Root cause: MLX's GPU memory management on iOS — the 300MB model balloons to **2.3GB RAM at runtime** ([kokoro-ios Issue #5](https://github.com/mlalma/kokoro-ios/issues/5)), and MLX Swift has **known random crash bugs on iOS** ([mlx-swift Issue #121](https://github.com/ml-explore/mlx-swift/issues/121)). These are upstream framework bugs with no fix available.

Confirmed through systematic elimination:
- Build 22: Audio session fix → still crashes
- Build 24: Serialized MLX inference → still crashes
- Build 25: **Kokoro disabled, system TTS only → NO CRASH**
- Conclusion: Kokoro/MLX is the sole cause

---

## Proposed Solution

Replace `KokoroSwift` (MLX) with `FluidAudio` (CoreML). FluidAudio wraps the same Kokoro-82M model but runs inference via CoreML (CPU+GPU), which:
- Uses significantly less peak memory than MLX (avoids the 2.3GB runtime balloon)
- Avoids MLX's iOS-specific crash bugs entirely
- Supports all 48 Kokoro voices (same as current)
- Is a single SPM dependency with Swift 6 support
- Has only two open GitHub issues (remarkably stable, 1.7K stars)

---

## Technical Approach

### What Gets Deleted

- `LocalPackages/kokoro-ios/` — entire MLX-based Kokoro package (~4,000 LOC)
- `LocalPackages/MisakiSwift/` — G2P processor (FluidAudio bundles CoreML G2P as of v0.12.3)
- `Lifehug/Resources/voices.npz` — 14MB voice embeddings file (FluidAudio manages voices internally)
- All `@preconcurrency import MLX`, `@preconcurrency import KokoroSwift`, `@preconcurrency import MLXUtilsLibrary`
- All MLX-specific code: `Mutex<EngineState>`, `Task.detached { engine.generateAudio() }`, `nonisolated(unsafe)` player/buffer wrappers for MLX types

### What Gets Added

- SPM dependency: `FluidAudio` from `https://github.com/FluidInference/FluidAudio.git`, exact `"0.12.4"`
- Transitive dependency: `swift-transformers` (pulled in by FluidAudio)

### What Gets Rewritten

`KokoroManager.swift` — internal implementation changes, **public API stays identical**:

| Public API | Current (MLX) | New (FluidAudio) |
|-----------|---------------|-------------------|
| `speak(_ text:) async throws` | `engine.generateAudio()` → `playAudio()` | `manager.synthesize()` → play returned audio |
| `loadEngine() async` | Load safetensors + npz via MLX | `KokoroTtsManager().initialize()` |
| `unloadEngine()` | Clear MLX arrays + engine | `manager.cleanup()`, release instance |
| `downloadModel()` | URLSession download safetensors | `TtsModels.download()` with progress |
| `phase` / `isReady` / etc. | Same state machine | Same state machine |
| `selectedVoice` / `cachedVoiceNames` | Read from npz keys | Read from `TtsConstants.availableVoices` |

### Call Sites (No Changes Needed)

- `TTSService.swift` — calls `speak()`, `stopPlayback()`, `unloadEngine()`
- `VoicePipeline.swift` — no direct KokoroManager references
- `LifehugApp.swift` — calls `loadEngine()`, `unloadEngine()`, injects via environment
- `SettingsView.swift` — reads `phase`, `downloadProgress`, `cachedVoiceNames`, `errorMessage`

---

## Implementation

### Pre-Implementation: Verify FluidAudio API (30 minutes)

Before writing code, clone FluidAudio and confirm:
- [ ] `synthesize()` return format: raw Float32 PCM or WAV-encoded Data?
- [ ] Output sample rate: confirm 24,000 Hz (matching current KokoroSwift)
- [ ] `swift-transformers` transitive dependency: verify it does NOT pull in MLX
- [ ] Binary size: check total size of bundled CoreML models
- [ ] Run `swift package resolve` with FluidAudio added to verify no SPM conflicts

**Based on synthesize() format, choose playback approach:**
- If raw Float32 PCM → keep AVAudioEngine + playerNode (existing playAudio infrastructure)
- If WAV/standard audio → use AVAudioPlayer(data:) — eliminates ~115 lines of engine management

### Phase 1: Replace MLX Kokoro with FluidAudio

One atomic change: add FluidAudio, rewrite KokoroManager, delete MLX packages, re-enable Kokoro.

**Files to modify:**
- `Lifehug.xcodeproj` — add FluidAudio SPM, remove kokoro-ios + MisakiSwift
- `Lifehug/Services/KokoroManager.swift` — rewrite internals
- `Lifehug/Services/TTSService.swift` — remove `false &&` from `useKokoro`
- `Lifehug/App/LifehugApp.swift` — uncomment `loadEngine()` and Kokoro reload
- `Lifehug/App/ModelConfig.swift` — update or remove Kokoro download config
- `Lifehug/App/MemoryMonitor.swift` — calibrate thresholds for CoreML

**Tasks:**

- [ ] Add FluidAudio SPM dependency (exact: `"0.12.4"`)
- [ ] Remove kokoro-ios and MisakiSwift local package references from Xcode project
- [ ] Delete `LocalPackages/kokoro-ios/` directory
- [ ] Delete `LocalPackages/MisakiSwift/` directory
- [ ] Remove `voices.npz` from `Lifehug/Resources/`
- [ ] Rewrite `KokoroManager` internals:
  - Replace `import MLX / KokoroSwift / MLXUtilsLibrary` with `import FluidAudio`
  - Replace `Mutex<EngineState>` with `nonisolated(unsafe) var ttsManager: KokoroTtsManager?`
  - Rewrite `downloadModel()`: use `TtsModels.download(progressHandler:)` → `manager.initialize(models:)`
  - Rewrite `loadEngine()`: create `KokoroTtsManager`, call `.initialize(preloadVoices:)`
  - Rewrite `speak()`: call `manager.synthesize(text:voice:voiceSpeed:)` → convert Data to playable audio
  - Rewrite `unloadEngine()`: call `manager.cleanup()`, nil the instance
  - Rewrite `deleteModel()`: call `DownloadUtils.clearAllModelCaches()`
  - Update `cachedVoiceNames`: populate from `TtsConstants.availableVoices` after init
  - **If raw PCM:** keep AVAudioEngine playback (playAudio, PlaybackState, observers)
  - **If WAV Data:** replace with AVAudioPlayer(data:) — delete engine, observers, PlaybackState
  - Keep NaN/Inf sample validation if using raw PCM playback
- [ ] Handle CoreML first-run compilation (~15-30 seconds):
  - Defer to background — do NOT block main thread or app launch
  - Use `TtsModels.download(progressHandler:)` which covers compilation phase
  - Show progress in SettingsView during download/compile (existing `downloadProgress` + `statusMessage`)
  - On first voice session, if model not yet compiled, show "Preparing voice..." indicator
- [ ] Remove `false &&` from `TTSService.useKokoro`
- [ ] Uncomment `kokoroManager.loadEngine()` in LifehugApp (launch + foreground)
- [ ] Update `ModelConfig.Kokoro` — remove safetensors URL/SHA-256 (FluidAudio manages models)
- [ ] Clean up `ModelDownloader.swift` — remove Kokoro-specific download logic if no longer needed
- [ ] Update `MemoryMonitor.canLoadKokoro` — require `.normal` only (>500MB), not `.elevated`
- [ ] Remove diagnostic code: breadcrumb writes in VoicePipeline, crash detection in LifehugApp
- [ ] Keep the sequential pipeline in VoicePipeline (do NOT restore streaming — premature optimization)
- [ ] Remove remaining `@preconcurrency import MLX` references
- [ ] Verify CodeSign bundle errors (`KokoroSwift_KokoroSwift.bundle`, `MisakiSwift_MisakiSwift.bundle`) are gone

### Phase 2: Test and ship

- [ ] Build with `xcodebuild archive` — verify Swift 6 strict concurrency passes
- [ ] Test on physical device: record → LLM → TTS playback → auto-reopen mic
- [ ] **Verify NO CRASH** during TTS playback (the P0 bug)
- [ ] Test multiple conversation turns (3+ rounds)
- [ ] Test interruption: tap mic during speech → resume
- [ ] Test voice selection: change voice in Settings, verify new voice
- [ ] Test first-run: fresh install, first Kokoro use triggers model download + compile
- [ ] Test Kokoro enable/disable toggle in Settings
- [ ] Test degradation: if model not ready, falls back to system TTS
- [ ] Monitor memory: verify peak < 1.5GB during voice conversation
- [ ] Bump build number and deploy to TestFlight

---

## Future Work (Separate Plans)

### Silero VAD for Precision Endpointing

**Deferred.** Ship the crash fix first. Add VAD after FluidAudio is stable in production.

When ready, key implementation notes from deepening research:
- Use `paean-ai/silero-vad-swift` (CoreML, MIT, zero deps, ~2MB model)
- **Do NOT run VAD on the audio render thread** — use a lock-free ring buffer + dedicated DispatchQueue
- Resample 48kHz→16kHz via AVAudioConverter, accumulate 576-sample chunks in a ring buffer
- For barge-in: raise VAD threshold to 0.7+ during `.speaking` state, add 200ms cooldown after TTS starts (echo cancellation)
- Consider `AVAudioSession.Mode.voiceChat` for better AEC during barge-in
- Factor audio tap into standalone `AudioCaptureService` to decouple tap lifecycle from STT recognition lifecycle

### Streaming Pipeline Restoration

**Deferred.** The sequential pipeline (collect all LLM output, then speak) works. With CoreML on CPU+GPU and LLM on MLX/Metal, concurrent execution is theoretically safe, but the 1-2 second time-to-first-speech improvement is not worth the coordination complexity for now. Profile after shipping.

---

## Alternative Approaches Considered

### 1. Fix MLX memory limits (`MLX.GPU.set(cacheLimit:)`)
**Rejected.** Workaround documented in kokoro-ios Issue #5, but reported to stop working on iOS 26. MLX Swift also has independent crash bugs (Issue #121). Patching MLX is fighting the framework.

### 2. Switch to quantized MLX model (Q8, ~86MB)
**Rejected.** Reduces memory but doesn't fix MLX iOS crash bugs. Still uses Metal GPU.

### 3. Use mattmireles/kokoro-coreml (raw CoreML conversion)
**Rejected.** Not a packaged SDK — conversion pipeline requiring Python tokenizer bridge.

### 4. Keep system TTS permanently
**Rejected.** Neural Kokoro voice is a core differentiator — warm and natural vs. robotic system voices.

### 5. OtosakuTTS-iOS / NeMoConformerASR-iOS / NeMoVAD-iOS
**Rejected.** Researched all three: OtosakuTTS abandoned (one voice, FastPitch), NeMoConformerASR no streaming, NeMoVAD no license. None better than current choices.

### 6. ONNX Runtime Silero VAD
**Rejected for this project.** Adds ~15-30MB ONNX Runtime binary. CoreML wrapper achieves the same with zero overhead.

---

## Acceptance Criteria

### Functional
- [ ] Voice conversation works end-to-end: record → LLM → Kokoro TTS → auto-reopen mic
- [ ] **NO CRASH** during TTS playback (the P0 bug that prompted this refactor)
- [ ] All 11 American English voices available in Settings voice picker
- [ ] Voice selection persists across app launches
- [ ] Kokoro enable/disable toggle works in Settings
- [ ] Graceful degradation to system TTS if CoreML initialization fails
- [ ] First-run model download + CoreML compilation shows progress

### Non-Functional
- [ ] Peak memory during voice conversation < 1.5GB
- [ ] Time-to-first-speech acceptable (< 5 seconds after LLM completes)
- [ ] Build succeeds with `xcodebuild archive` (Release, Swift 6 strict concurrency)
- [ ] No `@preconcurrency` imports needed for the TTS path

### Cleanup
- [ ] `LocalPackages/kokoro-ios/` deleted
- [ ] `LocalPackages/MisakiSwift/` deleted
- [ ] `voices.npz` removed from bundle
- [ ] No remaining MLX imports in TTS path
- [ ] CodeSign bundle errors for `KokoroSwift_KokoroSwift.bundle` and `MisakiSwift_MisakiSwift.bundle` are gone

---

## Sources & References

### External
- [FluidAudio GitHub](https://github.com/FluidInference/FluidAudio) — CoreML Kokoro SDK, MIT license, 1.7K stars
- [FluidAudio CoreML benchmarks](https://huggingface.co/FluidInference/kokoro-82m-coreml) — 23.2x RTF, less memory than MLX
- [kokoro-ios Issue #5](https://github.com/mlalma/kokoro-ios/issues/5) — 300MB model → 2.3GB runtime RAM
- [kokoro-ios Issue #7](https://github.com/mlalma/kokoro-ios/issues/7) — MLX.GPU.set(cacheLimit:) workaround
- [mlx-swift Issue #121](https://github.com/ml-explore/mlx-swift/issues/121) — Random Address size fault crashes on iOS
- [mlx-swift Issue #237](https://github.com/ml-explore/mlx-swift/issues/237) — Command queue creation failure
- [hexgrad/kokoro Issue #152](https://github.com/hexgrad/kokoro/issues/152) — Upstream memory leak
- [Silero VAD](https://github.com/snakers4/silero-vad) — MIT license, ~2MB model (deferred to follow-up)
- [paean-ai/silero-vad-swift](https://github.com/paean-ai/silero-vad-swift) — CoreML Swift wrapper (deferred)

### Internal
- `Lifehug/Services/KokoroManager.swift` — current MLX implementation (620 lines)
- `Lifehug/Services/TTSService.swift` — TTS facade, Kokoro currently disabled
- `docs/plans/2026-03-20-001-fix-mic-button-ux-and-tts-crash-plan.md` — prior crash fix attempts
