---
title: "Fix mic button animation, TTS speed, and TTS crash"
type: fix
status: completed
date: 2026-03-10
---

# Fix Mic Button Animation, TTS Speed, and TTS Playback Crash

## Overview

Three issues reported after TestFlight build 18 (v1.2.1):

1. **Mic button UX** — Bouncing animation is distracting; color transitions fade instead of snapping; button feels laggy
2. **AI voice too slow** — TTS playback speed needs a 10% increase
3. **TTS crash** — Hard crash ~5 seconds into AI voice playback (no crash report generated)

## Issue 1: Mic Button — Remove Bounce, Instant Colors, Faster Response

### Problem

The mic button on the Today screen has:
- A `.scaleEffect(1.08)` bounce animation with `.easeInOut(duration: 1.0).repeatForever(autoreverses: true)` when listening
- A `.easeOut(duration: 0.2)` fade transition on color changes between states
- Visual lag because SwiftUI animation system batches state changes

### User's Requirement

> "Keep it still and make it respond faster to presses and the color change should be immediate and not fade. When its recording its just red. when its paused, its just orange, when its playback its just green. end of story."

### Solution

**File:** `Lifehug/Views/DailyQuestionView.swift` (lines ~388-414)

- [x] Remove `.scaleEffect(1.08)` and its `.animation()` modifier entirely
- [x] Remove all `.animation()` modifiers from the mic button's color/fill — use `.animation(.none)` or wrap in `withAnimation(.none)` so color changes are instant
- [x] Simplify color logic to exactly 3 states with no intermediate:
  - `.listening` → `Theme.recordingRed` (red)
  - `.idle` (paused/not recording) → `Theme.amber` (orange)
  - `.speaking` → `Theme.speakingGreen` (green)
- [x] Remove any `.contentTransition()` or `.transition()` on the button icon that causes fade effects
- [x] Ensure button tap handler triggers state change synchronously (no async delay before visual update)

### Acceptance Criteria

- [x] Mic button never bounces or scales
- [x] Color snaps instantly on state change — no fade, no animation
- [x] Recording = red, paused/idle = orange, AI speaking = green
- [x] Button press feels immediately responsive (no perceptible delay)

---

## Issue 2: TTS Playback Speed — Increase by 10%

### Problem

AI voice playback feels slightly slow. The speed parameter is available but never used:

- **KokoroManager.swift line 212**: `engine.generateAudio(voice:language:text:)` — the `speed` parameter is not passed, defaulting to 1.0
- **TTSService.swift line 66**: System TTS rate hardcoded at `0.48`

### Solution

**File:** `Lifehug/Services/KokoroManager.swift` (line ~212)

- [x] Pass `speed: 1.1` to `engine.generateAudio()` call

**File:** `Lifehug/Services/TTSService.swift` (line ~66)

- [x] Increase system TTS rate from `0.48` to `0.53` (proportional 10% increase)

### Acceptance Criteria

- [x] Kokoro neural TTS plays at 1.1x speed
- [x] System TTS fallback also plays ~10% faster
- [x] Speech remains natural-sounding (not chipmunk)

---

## Issue 3: TTS Hard Crash After ~5 Seconds of Playback

### Problem

The app crashes hard during AI voice playback after approximately 5 seconds. No crash report is generated, suggesting it may be an unrecoverable signal (e.g., `EXC_BAD_ACCESS`) rather than a Swift error.

### Investigation Findings

**Likely crash candidates in `KokoroManager.swift`:**

1. **Force unwrap at line 231** — `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)!` in `setupAudioEngine()`. If format creation fails, this crashes.

2. **Force unwrap at line 248** — `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)!` in `playAudio()`. Same risk, called per-sentence.

3. **Force unwrap at line 256** — `buffer.floatChannelData![0]` in `playAudio()`. If the buffer allocation failed, this crashes with `EXC_BAD_ACCESS`.

4. **Audio engine state** — The `AVAudioEngine` may become invalid after an interruption (phone call, notification sound, etc.) and the completion callback on `AVAudioPlayerNode` may fire with the engine in a bad state.

5. **Continuation safety** — `playAudio()` uses `withCheckedContinuation` with `OSAllocatedUnfairLock<CheckedContinuation?>`. If the completion handler fires twice (e.g., on interruption + normal completion) or the lock state becomes inconsistent, this could cause a double-resume crash.

6. **Buffer lifecycle** — The `AVAudioPCMBuffer` created in `playAudio()` holds Float samples. If the buffer is deallocated while the player node still references it, this is a use-after-free (`EXC_BAD_ACCESS`). The ~5 second timing aligns with when a buffer might be released after playback of a longer sentence.

7. **Audio session interruption** — No `AVAudioSession.interruptionNotification` observer. If the system interrupts audio (Siri, phone call, another app), the engine stops but the code doesn't know.

### Solution

**File:** `Lifehug/Services/KokoroManager.swift`

- [x] Replace all force unwraps (`!`) with `guard let` + graceful error handling:
  - Line 231: `AVAudioFormat(...)!` → guard let with return
  - Line 248: `AVAudioFormat(...)!` → guard let with return
  - Line 256: `buffer.floatChannelData![0]` → guard let with return
- [x] Retain the `AVAudioPCMBuffer` in `currentBuffer` property until the completion handler fires (prevent premature deallocation)
- [x] Clear `currentBuffer` in `unloadEngine()` to prevent stale references
- [x] Add `engine.isRunning` check before scheduling buffers on the player node (already existed)

Note: Audio session interruption handling already exists in VoicePipeline.swift (observeInterruptions). The `withCheckedContinuation` callback already uses `OSAllocatedUnfairLock` for single-resume safety. TTSService.speak() already catches Kokoro errors and degrades to system TTS.

### Acceptance Criteria

- [x] No force unwraps remain in audio playback path
- [x] Buffer retained until playback completes
- [x] App handles audio format creation failures gracefully (returns instead of crashing)

---

## Implementation Order

1. **Issue 3 (crash)** — Fix first since it's a blocker
2. **Issue 1 (mic button)** — Quick UI fix
3. **Issue 2 (speed)** — One-line changes

## Sources

- `Lifehug/Views/DailyQuestionView.swift:388-414` — Mic button animation code
- `Lifehug/Services/KokoroManager.swift:212,231,248,256` — TTS engine, force unwraps
- `Lifehug/Services/TTSService.swift:66` — System TTS rate
- `Lifehug/Pipeline/VoicePipeline.swift` — TTS consumer error handling
