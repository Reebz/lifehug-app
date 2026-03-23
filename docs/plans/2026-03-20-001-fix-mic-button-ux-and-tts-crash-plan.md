---
title: "Fix mic button UX and TTS playback crash"
type: fix
status: completed
date: 2026-03-20
deepened: 2026-03-20
---

# Fix Mic Button UX and TTS Playback Crash

## Enhancement Summary

**Deepened on:** 2026-03-20
**Research agents used:** AVAudioSession best practices, SwiftUI animation patterns, Architecture Strategist, Performance Oracle, Code Simplicity Reviewer

### Key Corrections from Deepening

1. **P0 SIMPLIFICATION: Use `.playAndRecord` everywhere** — the original plan proposed reconfiguring the audio session to `.playback` before every `playAudio()` call. This adds 10-50ms latency per sentence (perceived as stuttering). The correct fix: use `.playAndRecord` for both STT and TTS. This eliminates the category conflict entirely without per-call overhead. Apple's documentation confirms `.playAndRecord` supports both input and output.

2. **Remove `setActive(false)` from STTService** — deactivating the session between STT and TTS releases hardware resources and causes the next activation to take significant time. Apple's guide says: "While the app is in the foreground, keep the audio session active." Deactivate only when the entire voice conversation ends.

3. **Drop per-sentence memory checks (Task 1.4)** — YAGNI. Memory pressure does not fluctuate meaningfully within a 3-5 second TTS playback window after LLM inference is complete. The existing check at `processUserInput()` start is sufficient.

4. **Reduce crash-path logging from 4 to 2 calls** — 4 log lines per sentence (5-8 sentences per response = 20-32 log lines) is over-instrumented for a hot path. One at entry, one at completion.

5. **Drop engine retry logic** — if `engine.start()` fails after correct session configuration, creating a fresh engine is unlikely to help. Let TTSService degrade to system TTS.

6. **Add post-speak cancellation guard** — prevents the interrupt race where `playAudio()` fires after STT has already started.

7. **Add `mediaServicesWereResetNotification` handler** — when mediaserverd restarts, all audio objects become orphaned. Must tear down and recreate everything.

---

## Overview

Two critical issues with the voice conversation loop, the core user experience of the app:

1. **Mic button UX** -- the record button has a delayed color change (~300ms interpolation) and jumps downward when entering recording mode. This is the primary UI element; state feedback must be instant and spatially stable.
2. **Hard crash** -- the app crashes to home screen with no logging every time during AI voice playback, about 5-6 seconds into the first response. This is a ship-blocking bug.

## Problem Statement

### Mic Button UX

When the user taps the mic button to start recording:
- **Delayed color**: The button color transitions from terracotta to red over ~300ms instead of snapping instantly. There is also a brief amber flash (pipeline starts in `.idle` before transitioning to `.listening`).
- **Layout jump**: The button sits higher in idle mode, then drops lower when recording starts because elements below it (`typeInsteadButton`, "View Conversation" button) are removed from the view hierarchy, shrinking the `safeAreaInset` height.

### Hard Crash During TTS Playback

The app crashes straight to the home screen with zero logging. It happens consistently about 5-6 seconds into the AI speaking after the first recording. The timing corresponds to: STT stops -> LLM generates first sentence (a few seconds) -> Kokoro TTS tries to play audio -> crash.

---

## Root Cause Analysis

### Mic Button: Delayed Color

**File:** `Lifehug/Views/DailyQuestionView.swift`

1. `startVoiceSession()` wraps `voiceSessionActive = true` in `withAnimation(.easeOut(duration: 0.3))` (line 563). This animation transaction propagates to `micButtonColor`, causing SwiftUI to interpolate the color over 300ms. Per SwiftUI's transaction precedence rules, `withAnimation` at the call site overrides `.transaction { $0.animation = nil }` on the view when the state being changed (`voiceSessionActive`) is what the view's computed property reads.

2. `pipeline.startListening()` is called AFTER `voiceSessionActive = true` (line 568). Since `PipelineState` starts as `.idle`, `micButtonColor` resolves to `Theme.amber` (not red) for a brief moment before transitioning to `.listening` (red). The user sees: terracotta -> amber flash -> red, all interpolated over 300ms.

### Mic Button: Layout Jump

**File:** `Lifehug/Views/DailyQuestionView.swift` (lines 46-78)

The mic button lives in `.safeAreaInset(edge: .bottom)`. In idle mode, the VStack below the mic contains:
- `typeInsteadButton` (~44pt tall)
- "View Conversation" button (~34pt tall, if conversation exists)

Both are guarded by `!voiceSessionActive` and are removed from the hierarchy when recording starts. This shrinks the safeAreaInset by ~44-78pt, causing the mic button to drop on screen.

### Hard Crash: Audio Session Conflict

**Files:** `Lifehug/Services/KokoroManager.swift`, `Lifehug/Services/STTService.swift`

This is the primary crash cause. The sequence:

1. `KokoroManager.setupAudioEngine()` runs once during `loadEngine()` at app startup. Sets audio session to `.playback` and creates an `AVAudioEngine`.
2. User taps record. `STTService.startRecognition()` sets audio session to `.playAndRecord` and starts its own `AVAudioEngine` with an input tap.
3. User stops talking. `STTService.stopListening()` stops its engine and calls `AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)` -- **deactivating the entire audio session**.
4. LLM generates response. Pipeline transitions to `.speaking`.
5. `KokoroManager.playAudio()` checks `engine.isRunning` (line 339). The engine is not running (session was deactivated). It calls `engine.start()` -- but the session is deactivated and the category was last set to `.playAndRecord` by STT, not `.playback`.
6. Audio buffer is scheduled and `player.play()` is called. CoreAudio's `mediaserverd` encounters an engine operating on a misconfigured/deactivated session and terminates the app -- a hard crash with no Swift-level error handling possible.

**Root architectural problem:** Three components independently manipulate the singleton `AVAudioSession.sharedInstance()` with no coordination:

| Component | Category Set | When | setActive(false)? |
|-----------|-------------|------|-------------------|
| STTService | `.playAndRecord` | Every `startRecognition()` | Yes -- every `stopListening()` |
| KokoroManager | `.playback` | Once at load time | Never |
| VoicePipeline | (none) | Interruption handler calls `setActive(true)` | No |

### Secondary Crash Risks

| Risk | Severity | Description |
|------|----------|-------------|
| `CheckedContinuation` leak | High | If `withTimeout` cancels the playback task, the continuation is never resumed -- Swift fatal trap: "leaked continuation" |
| Interrupt race | High | `interrupt()` starts STT while `playAudio()` continuation is pending; next sentence's `playAudio()` reconfigures session under running STT |
| Media services reset | Medium | `mediaserverd` crash orphans all audio objects with no notification handling |
| Concurrent Metal GPU inference | Low | LLM and Kokoro share Metal GPU; concurrent inference is safe (Metal serializes internally) but on 4GB devices, memory pressure could trigger OS kill |

---

## Proposed Solution

### Phase 1: Fix TTS Crash (P0 -- Ship-blocking)

**Goal:** Eliminate the hard crash during AI voice playback.

#### Task 1.1: Unify audio session category to `.playAndRecord`

**Why `.playAndRecord` everywhere:** Apple's Audio Session Programming Guide states that `.playAndRecord` supports both input and output. By using the same category for STT and TTS, the audio session category never needs switching. This eliminates the root cause (category conflict) rather than patching around it. The `.defaultToSpeaker` option ensures audio routes to the speaker, not the earpiece. The `.allowBluetoothA2DP` option lets output stay high-quality through A2DP while the built-in mic handles input — the correct behavior for a voice conversation app.

**Tradeoff acknowledged:** `.playAndRecord` keeps the mic active even during TTS playback, which is unnecessary for playback-only. If a future feature needs playback-only mode (e.g., replaying saved answers), that feature should set `.playback` explicitly. For the current voice conversation use case, `.playAndRecord` is correct.

**Files:**
- `Lifehug/Services/KokoroManager.swift` -- `setupAudioEngine()`
- `Lifehug/Services/STTService.swift` -- `startRecognition()`, `stopListening()`

Changes:
- [x] In `KokoroManager.setupAudioEngine()`, change `.playback` to `.playAndRecord` with matching options:
  ```swift
  try AVAudioSession.sharedInstance().setCategory(
      .playAndRecord, mode: .default,
      options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
  )
  try AVAudioSession.sharedInstance().setActive(true)
  ```
- [x] In `STTService.startRecognition()`, remove the `setCategory` call (session is already configured correctly by KokoroManager at load time)
- [x] In `STTService.stopListening()`, **remove** `setActive(false)` -- do NOT deactivate the session between STT and TTS turns. Apple: "While the app is in the foreground, keep the audio session active."
- [x] In `KokoroManager.playAudio()`, add a guard to ensure session is active before scheduling buffers:
  ```swift
  // Ensure session is active (STT may have deactivated it in older code paths)
  if !AVAudioSession.sharedInstance().isOtherAudioPlaying {
      try? AVAudioSession.sharedInstance().setActive(true)
  }
  ```
- [x] Deactivate the session only when the voice conversation truly ends -- in `VoicePipeline.stopAll()`:
  ```swift
  try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  ```

#### Task 1.2: Fix `CheckedContinuation` leak on timeout/cancellation

**File:** `Lifehug/Services/KokoroManager.swift` -- `playAudio()` method

The `withCheckedContinuation` inside `withTimeout` can be cancelled without the continuation being resumed. This is a fatal Swift runtime trap.

**Implementation note from architecture review:** The `resumed` lock must be hoisted outside the continuation block so `withTaskCancellationHandler`'s `onCancel` can capture it. The `onCancel` closure runs on an arbitrary thread (not `@MainActor`), so it cannot access `playerNode` directly — but it can resume the continuation through the lock.

- [x] Hoist `resumed` lock outside the continuation, wrap in `withTaskCancellationHandler`:
  ```swift
  let resumed = OSAllocatedUnfairLock(initialState: false)
  await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
          unsafePlayer.scheduleBuffer(unsafeBuffer, ...) { @Sendable _ in
              resumed.withLock { alreadyResumed in
                  guard !alreadyResumed else { return }
                  alreadyResumed = true
                  Task { @MainActor in continuation.resume() }
              }
          }
          unsafePlayer.play()
      }
  } onCancel: {
      resumed.withLock { alreadyResumed in
          guard !alreadyResumed else { return }
          alreadyResumed = true
          // Cannot access playerNode here (non-Sendable), but the
          // timeout catch block calls player.stop() which triggers
          // the scheduleBuffer callback — so we only need to handle
          // the case where cancellation happens before the callback.
      }
  }
  ```
- [x] Verify the TTSService system TTS path (which uses inline timeout, not withTimeout) does not have the same issue

#### Task 1.3: Add crash-path logging (reduced)

**File:** `Lifehug/Services/KokoroManager.swift`

- [x] Add `logger.info("playAudio: \(samples.count) samples, engine.isRunning=\(audioEngine?.isRunning ?? false)")` at entry
- [x] Add `logger.info("playAudio: completed")` in the scheduleBuffer completion callback
- [x] Two log lines per sentence — sufficient for crash diagnostics without over-instrumenting the hot path

#### Task 1.4: Add post-speak cancellation guard in consumer loop

**File:** `Lifehug/Pipeline/VoicePipeline.swift` -- consumer loop in `processUserInput()`

The `interrupt()` -> `startListening()` path can fire while the consumer loop is between sentences. Without a post-speak cancellation check, the loop calls `playAudio()` for the next sentence after STT has already started.

- [x] Add `guard !Task.isCancelled else { break }` after `await ttsService.speak(sentence)` (line ~264), in addition to the existing check before it

#### Task 1.5: Fix interruption handler audio session

**File:** `Lifehug/Services/KokoroManager.swift` -- `observeAudioInterruptions()`

- [x] In the `.ended` case, call `setActive(true)` before `engine.start()` (category is already `.playAndRecord` from Task 1.1)
- [x] This ensures the session is active after phone calls or Siri interruptions

#### Task 1.6: Handle Bluetooth route changes during playback

**File:** `Lifehug/Services/KokoroManager.swift`

If AirPods disconnect mid-playback, the audio route changes. KokoroManager's `AVAudioEngine` is connected to the previous route's output format. Without handling `routeChangeNotification`, the engine can produce silence or crash on the stale audio graph.

- [x] Add observer for `AVAudioSession.routeChangeNotification` in `setupAudioEngine()` (or alongside `observeAudioInterruptions()`)
- [x] On route change with reason `.oldDeviceUnavailable` (device disconnected): stop the player, let the completion callback resume the continuation naturally. The engine will adapt to the new route on next `engine.start()`.
- [x] On route change with reason `.newDeviceAvailable` (device connected): no action needed — the engine picks up the new route automatically
- [x] Clean up observer in `unloadEngine()`

#### Task 1.7: Handle Siri/background interruption state recovery

**File:** `Lifehug/Pipeline/VoicePipeline.swift` -- interruption handler

When Siri takes over the audio session and returns, or when the app backgrounds and returns, the pipeline needs to resume the correct state — not just blindly reopen the mic.

- [x] In the `.ended` interruption handler with `.shouldResume`, check what state the pipeline was in before interruption:
  - If `.listening` -> reopen mic (`startListening()`)
  - If `.speaking` -> the current sentence is lost; let the consumer loop continue to the next sentence (or degrade to system TTS if Kokoro engine was unloaded during background)
  - If `.processing` -> LLM is still running; do nothing (the consumer will start speaking when the next sentence is ready)
- [x] On return from background (`.background` -> `.active` scene phase): if `kokoroManager.phase != .ready`, set `ttsService.forceDegradedToSystem = true` so remaining sentences use system TTS rather than waiting for Kokoro to reload

#### Task 1.8: Handle media services reset

**File:** `Lifehug/Services/KokoroManager.swift`

When `mediaserverd` crashes (rare but possible), all `AVAudioEngine` instances become orphaned. Without handling this, the next playback attempt crashes.

- [x] Add observer for `AVAudioSession.mediaServicesWereResetNotification` in `setupAudioEngine()`
- [x] On reset: stop player, nil out engine and playerNode, reconfigure audio session from scratch, call `setupAudioEngine()` to recreate
- [x] Clean up observer in `unloadEngine()`
- [x] Log the event: `logger.warning("Media services reset — recreating audio engine")`

### Acceptance Criteria -- Phase 1

**Functional (test on real device — simulator does not reproduce audio session crashes):**
- [x] Voice conversation loop works end-to-end: record -> LLM -> TTS playback -> auto-reopen mic
- [x] No crash during first AI voice response
- [x] No crash during subsequent voice responses in the same session (3+ turns)
- [x] Interrupting AI speech (tapping mic) and resuming works without crash
- [x] Phone call during playback -> return to app -> playback resumes or degrades gracefully
- [x] Siri invocation mid-session -> return to app -> session resumes correctly (check if pipeline was in .listening vs .speaking and resume the correct state)
- [x] Background/foreground transition during voice session -> app returns without crash (Kokoro engine reloads; degrade to system TTS if still speaking)

**Bluetooth (test with AirPods or similar):**
- [x] Connect AirPods -> record via built-in mic -> TTS plays through AirPods (A2DP quality, not HFP)
- [x] Disconnect AirPods mid-playback -> audio routes to speaker without crash (route change notification handled)

**Verification:**
- [x] `logger.info` at `playAudio()` entry shows `engine.isRunning=true` and category is `.playAndRecord`
- [x] `AVAudioSession.sharedInstance().category` logged once per session start confirms `.playAndRecord`
- [x] Build succeeds with `xcodebuild archive` (Release, Swift 6 strict concurrency)

---

### Phase 2: Fix Mic Button UX (P1 -- Core Experience)

**Goal:** Instant color feedback and no layout jump when tapping the mic button.

#### Task 2.1: Fix color change delay

**File:** `Lifehug/Views/DailyQuestionView.swift` -- `startVoiceSession()`

Per SwiftUI transaction precedence rules: `withAnimation` at the call site sets the root transaction animation, which propagates to all views reading the changed state. A `.transaction { $0.animation = nil }` on a child view runs after and can override — but only if the state it reads is not the same state wrapped in `withAnimation`. Since `micButtonColor` reads `voiceSessionActive` (which is the state wrapped in `withAnimation`), the animation leaks through.

The fix requires two changes:

1. **Reorder state changes** so pipeline is listening before UI reads color:
   ```swift
   // 1. Create and assign pipeline (so micButtonColor can read pipeline.state)
   pipeline = pipe
   // 2. Start listening (sets state = .listening synchronously on MainActor)
   pipe.startListening()
   // 3. THEN flip the layout flag — WITHOUT withAnimation
   voiceSessionActive = true
   ```

2. **Remove `withAnimation` from `voiceSessionActive = true`**. Apply animation selectively to only the content area crossfade:
   ```swift
   // On the content area ZStack (lines 36-41):
   .animation(.easeOut(duration: 0.3), value: voiceSessionActive)
   ```

- [x] Reorder: `pipeline = pipe` -> `pipe.startListening()` -> `voiceSessionActive = true`
- [x] Remove `withAnimation` wrapper from `voiceSessionActive = true` (line 563)
- [x] Apply `.animation(.easeOut(duration: 0.3), value: voiceSessionActive)` to the content area ZStack so the idle-to-voice-session crossfade is still smooth
- [x] Apply same treatment to the reverse transition in `endVoiceSessionAndSave()` and session reset
- [x] Verify `.transaction { $0.animation = nil }` still present on mic button (line 385) as defense-in-depth

#### Task 2.2: Fix layout jump

**File:** `Lifehug/Views/DailyQuestionView.swift` -- safeAreaInset (lines 46-78)

The buttons below the mic disappear when `voiceSessionActive` flips, shrinking the safeAreaInset. Fix by keeping them in the hierarchy but invisible.

Create a visibility extension to reduce modifier noise:

```swift
extension View {
    func visible(_ isVisible: Bool) -> some View {
        self.opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}
```

- [x] Add `.visible()` extension (in a shared file or inline)
- [x] Replace `if !voiceSessionActive` conditionals on `typeInsteadButton` and "View Conversation" button with:
  ```swift
  typeInsteadButton
      .visible(!voiceSessionActive)
  ```
- [x] Verify the mic button stays at the exact same vertical position when toggling `voiceSessionActive`

**Why `.opacity(0)` over `.hidden()`:** `.hidden()` in SwiftUI preserves layout space but does NOT disable hit testing -- buttons remain tappable when hidden. `.opacity(0)` + `.allowsHitTesting(false)` is the correct pattern. Adding `.accessibilityHidden(true)` ensures VoiceOver skips invisible elements.

#### Task 2.3: Add double-tap guard

**File:** `Lifehug/Views/DailyQuestionView.swift` -- `startVoiceSession()`

- [x] Add `guard !voiceSessionActive, pipeline == nil else { return }` at the top of `startVoiceSession()` to prevent double-tap creating two pipelines and two STT streams

### Acceptance Criteria -- Phase 2

- [x] Mic button color snaps instantly from terracotta to red on tap (no interpolation, no amber flash)
- [x] Mic button stays at the exact same vertical position between idle and recording modes
- [x] Content area (question text -> transcript bubbles) still crossfades smoothly
- [x] VoiceOver correctly hides the "Type instead" button during voice sessions
- [x] Double-tapping the mic does not create duplicate pipelines
- [x] `.transaction { $0.animation = nil }` still present on mic button (prevent future animation regressions)

---

## System-Wide Impact

### Interaction Graph

1. User taps mic -> `handleSingleTap()` -> `startVoiceSession()` -> creates `VoicePipeline` -> `STTService.startListening()` (session already `.playAndRecord`)
2. User stops talking -> `STTService.stopListening()` (stops engine, does NOT deactivate session) -> `processUserInput()` -> `LLMService.streamResponse()` (Metal GPU)
3. First sentence ready -> `TTSService.speak()` -> `KokoroManager.speak()` (Metal GPU) -> `playAudio()` (session still active, category still `.playAndRecord`) -> plays successfully

### Error Propagation

- `playAudio()` throws -> caught by `KokoroManager.speak()` which throws -> caught by `TTSService.speak()` which sets `forceDegradedToSystem = true` and falls back to system TTS
- With unified `.playAndRecord` category, audio session errors are eliminated at the source
- `engine.start()` failure now logs and throws (TTSService catches and degrades gracefully)

### State Lifecycle Risks

- If `playAudio()` crashes between setting `currentBuffer` and clearing it, the buffer is leaked (harmless -- ARC cleans up)
- Removing `setActive(false)` from STTService means the audio session stays active longer -- this is the correct behavior per Apple's guidance, and the session is deactivated in `VoicePipeline.stopAll()` when the conversation ends

---

## Sources & References

### Internal References

- `Lifehug/Views/DailyQuestionView.swift` -- mic button (lines 372-393), color (312-326), tap handler (695-708), startVoiceSession (530-590)
- `Lifehug/Services/KokoroManager.swift` -- playAudio (312-378), setupAudioEngine (251-279), speak (221-241)
- `Lifehug/Services/STTService.swift` -- startRecognition (line 182: `.playAndRecord`), stopListening (line 151: `setActive(false)`)
- `Lifehug/Services/TTSService.swift` -- speak (31-49), speakViaSystem (51-103)
- `Lifehug/Pipeline/VoicePipeline.swift` -- processUserInput (218-289), consumer loop (261-265)
- `Lifehug/Services/TaskTimeout.swift` -- withTimeout implementation

### External References

- [Apple: AVAudioSession Category .playAndRecord](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playandrecord) -- supports both input and output
- [Apple: Audio Session Programming Guide](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionBasics/AudioSessionBasics.html) -- "keep the audio session active while in the foreground"
- [Apple: Responding to Audio Interruptions](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html)
- [Apple Developer Forums: AVAudioEngine crash after category change](https://developer.apple.com/forums/thread/65656)
- [Fatbobman: Deep Dive into SwiftUI Transactions](https://fatbobman.com/en/posts/mastering-transaction/) -- `withAnimation` vs `.transaction` precedence
- [objc.io: Transactions and Animations](https://www.objc.io/blog/2021/11/25/transactions-and-animations/)

### CLAUDE.md Guidance

- "Non-Sendable Apple framework types (AVAudioPlayerNode, AVAudioPCMBuffer, AVSpeechUtterance) crossing @Sendable/sending boundaries require nonisolated(unsafe) wrappers"
- "STTService's nonisolated(unsafe) sharedRequest is intentional -- DO NOT add locks to the audio render thread"
- "Release builds have stricter Swift 6 concurrency checking than Debug -- always verify with archive before shipping"
