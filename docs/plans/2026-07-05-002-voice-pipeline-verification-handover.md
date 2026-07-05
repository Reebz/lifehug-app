---
title: "Handover: verify + close the voice-pipeline reliability fix (Xcode required)"
date: 2026-07-05
type: handover
execution: code
target_repo: lifehug-app
branch: fix/voice-pipeline-stt-tts-reliability
implements_plan: docs/plans/2026-07-05-001-fix-voice-pipeline-stt-tts-reliability-plan.md
status: implementation-complete-unverified
tags: [ios, verification, archive, concurrency, whisperkit, handover]
---

# Handover: verify + close the voice-pipeline reliability fix

## Why this exists

All 14 implementation units of `docs/plans/2026-07-05-001-fix-voice-pipeline-stt-tts-reliability-plan.md`
are **implemented and committed** on branch `fix/voice-pipeline-stt-tts-reliability`
(commits `b9e4e5f..3608bd8`). They could **not** be build-verified in the session
that wrote them because that host had **no Xcode** (Command Line Tools only) — so
none of the plan's Verification Contract gates ran. This document is the resume
plan for a session on a machine **with Xcode installed**: run the gates, fix any
errors, then do the U14 on-device pass. Everything below is execution-ready.

## Preconditions

- Full Xcode installed (`xcode-select -p` must point at `Xcode.app`, not
  `CommandLineTools`; run `sudo xcode-select -s /Applications/Xcode.app` if needed).
- On branch `fix/voice-pipeline-stt-tts-reliability` (`git switch fix/voice-pipeline-stt-tts-reliability`).
- SPM will resolve the pinned deps on first build (WhisperKit fork `Reebz/WhisperKit@aed3b1c`,
  MLX, FluidAudio, Kokoro). Allow the first build extra time for checkout.

## What's already verified (no Xcode needed, already done)

- Syntax parse of all 14 changed `.swift` files (`swiftc -frontend -parse`) — clean.
- Symbol cross-check — no dangling references to removed symbols.
- `project.pbxproj` — `plutil -lint` clean; new-file UUID reference counts correct.
- WhisperKit fork API (KTD3) verified against `Reebz/WhisperKit@aed3b1c` source.
- Concurrency-boundary audit (see the risk map in Step 2).

## Step 1 — Simulator build + test (per-unit gate)

```bash
cd Lifehug
xcodebuild build -project Lifehug.xcodeproj -scheme Lifehug -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild test  -project Lifehug.xcodeproj -scheme Lifehug -destination 'platform=iOS Simulator,name=iPhone 16'
```

Fix any compile errors first (most likely spots are the concurrency boundaries in
Step 2). Then confirm the new/updated tests pass:

- `LifehugTests/LLMServiceTests.swift` — U1 lazy session (pending-prompt retention,
  replace), U7 simulator load/unload, U12 simulator streamResponse mock.
- `LifehugTests/STTServiceTests.swift` (new) — U2 ASR state machine (idle→loading→ready,
  failed, retry, idempotent), gating (not-ready → empty stream + distinct error; ready → mock),
  U3 pure helpers (`shouldRunFinalTranscription`, `joinTranscriptionText`, `recordingExceededCap`).
- `LifehugTests/TTSServiceTests.swift` (new) — U4 KokoroError descriptions + `useKokoro` gate,
  U5 `timeoutShouldStop`, U10 `recoverFromDegradationIfNeeded` clears the latch.
- `LifehugTests/VoicePipelineTests.swift` — U6 `shouldRetryEmpty` budget.

Device-only behaviors intentionally have NO simulator test (documented in each test
file): the WhisperKit final-transcription path, Kokoro synth/playback, the STT
session-token race, U8 producer cancellation. These are covered in Step 3.

## Step 2 — Release archive (strict-concurrency gate)

Required for the concurrency-touching units (U3, U4, U5, U8, U9, U10, U11):

```bash
cd Lifehug
xcodebuild archive -project Lifehug.xcodeproj -scheme Lifehug \
  -archivePath /tmp/Lifehug.xcarchive -destination 'generic/platform=iOS' -allowProvisioningUpdates
```

Release builds enable stricter Swift 6 concurrency checking than Debug (CLAUDE.md).
No **new** warnings on the touched files is the bar. Pre-scoped fixes if it fails —
the risk map (audited statically, expected to pass because each mirrors an existing
shipping pattern):

| Spot | Boundary | If it errors, do this |
|---|---|---|
| `STTService.runFinalTranscriptionIfNeeded` | `nonisolated(unsafe) let p = pipe; let r: [TranscriptionResult]? = try? await p.transcribe(audioArray:decodeOptions:)` | keep the `[TranscriptionResult]` annotation (disambiguates the overload); if the return crossing complains, extract text inside a `nonisolated` helper |
| `STTService` transcriptionTask → `finishRecording(sessionID:continuation:transcriber:)` | `Task{}` inherits MainActor; `ast`/`continuation`/`Int` are Sendable | if capture errors, add an explicit `[ast, continuation]` capture list |
| `VoicePipeline.stopAll` | `Task {[audioSession, sttService] in await audioSession.end { await sttService.stopAndWait() } }` | if `end`'s closure param must be Sendable, mark `end(afterTeardown: @Sendable () async -> Void)` |
| `VoicePipeline.processUserInput` | `audioSession.beginPlaybackPhase()` inside the activeTask | task is MainActor-isolated (mutates `state`); no change expected |
| `LLMService.streamResponse` (`#if simulator`) | `Task` + `onTermination` cancel; `await MainActor.run { isGenerating = false }` | mirrors the device path; no change expected |
| `LLMService.modelContainer` / `isLoaded` computed | reads `containerProvider?()` → `modelState.modelContainer` | if observation of `isLoaded` looks stale in a View, that's runtime (Step 3), not a compile error |
| `AudioSessionController.end(afterTeardown:)` | non-Sendable async closure param, same isolation | add `@Sendable` only if the compiler asks |

Rule to preserve while fixing (KTD6 / CLAUDE.md): **no locks on the audio render
thread**; keep `nonisolated(unsafe)` wrappers for non-Sendable Apple/WhisperKit types
crossing `@Sendable`/`sending`; don't add a net-new `nonisolated(unsafe)` without a
documented single-owner justification.

## Step 3 — On-device iPhone 17 acceptance + U14 gated optimizations

Device target: iPhone 17 (A19 / iOS 26). Use the retained `3d5fb60` diagnostic
`print()` logging for attribution. Confirm the R1–R7 behaviors (from the source
plan's U14 verification): transcript-empty rate near zero across short/soft/normal
answers; TTS speaks or degrades cleanly; no stuck states; cold-launch first turn
works; one resident LLM container; recoverable degradation; visible failures.

Then evaluate the three **gated** optimizations (KTD2 — land each only if its
measurement passes; they are NOT in the current commits):

1. **Start TTS after the first sentence (P2-9)** — `VoicePipeline.processUserInput`:
   measure whether MLX LLM generation and FluidAudio CoreML synthesis contend on A19
   (crash / glitch / memory spike). If clean, change the two-phase "collect all, then
   speak" to speak the first sentence as soon as it is extracted. If contention
   appears, keep serialized but still start after the first (not the last) sentence.
2. **`useVAD: false` (STTService `AudioStreamTranscriber` init)** — with U3's final
   full-buffer pass in place, measure empty-rate with `useVAD:false`; flip only if it
   reduces empties without runaway recordings.
3. **MemoryMonitor thresholds** — measure `os_proc_available_memory()` during
   concurrent inference on the 8 GB device with `increased-memory-limit`; loosen the
   `.elevated`/`.critical` bands only if headroom is demonstrably ample.

Record the measurements in the PR/commit so each decision is auditable.

## Step 4 — Finish

- **Only after** the device pass completes, remove the `3d5fb60` diagnostic `print()`
  logging (grep `"\[STT\] DIAG"` and `"\[Pipeline\] DIAG"`; a small follow-up commit).
- Open the PR (branch already carries per-unit commits). Note in the body that the
  three gated optimizations landed / did-not-land per the recorded measurements.
- Separately (with explicit path authorization) delete the empty
  `Lifehug/LocalPackages/{kokoro-ios,MisakiSwift}` directories — deliberately left
  in place; the pbxproj file references were already removed in U13.

## Deviations already made (be aware when reviewing)

- **U9 `AudioSessionController`** is an app-scoped shared instance with a default init
  param on `VoicePipeline` (`= .shared`), not `@Environment` DI — chosen to minimize
  un-compilable wiring on the no-Xcode host. Still satisfies P2-10 (durable owner
  across per-entry pipelines). LifehugApp was not changed for U9.
- **U7** uses option 2 (LLMService *borrows* the downloader's container via a provider;
  ModelDownloader stays the owner) — `ModelDownloader.swift` is unchanged.
- **U4+U5** share one commit (`9336fde`) — both edit `TTSService.swift` and hunk-level
  staging was unavailable on that host.
- **U2** gates readiness on `WhisperKit(config)` returning (not `modelStateCallback`) —
  the callback is observation-only and was omitted (exact `ModelState` cases weren't
  pinned; not needed for the gate).
- New test/source files use readable placeholder pbxproj UUIDs (`AC…` STTServiceTests,
  `AD…` TTSServiceTests, `AE…` AudioSessionController).

## Commit map (branch `fix/voice-pipeline-stt-tts-reliability`)

```
b9e4e5f U1  Lazy LLM session after cold-launch load
9a5a89c U2  ASR readiness gating + retry + download progress
a4a477b U3  Restore final transcription; teardown-before-purge ordering
9336fde U4,U5 Kokoro→system fallback; system-TTS didCancel + gen-gated timeout
8959d8c U6  Bounded empty-transcript retry + surface pipeline.error
7fc43be U7  LLMService borrows single downloader container
a13d274 U8  Cancel LLM generation on stop/interrupt
353155a U9  Centralize audio-session ownership; awaitable STT teardown
9c07f29 U10 Recoverable TTS degradation; safe Kokoro unload
e7f7d6c U11 Session-token STT teardown; stop control; cancel guards
0ff7b2f U12 Background lifecycle + cleanups (dead isSpeaking, sim stream mock)
740e358 U13 Docs: real stack; drop dead package refs
3608bd8 U14 Correct stale contention comment; gate opts on device
```
