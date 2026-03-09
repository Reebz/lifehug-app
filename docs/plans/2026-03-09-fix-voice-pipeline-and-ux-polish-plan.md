---
title: "Fix Voice Pipeline Bugs and UX Polish Round 2"
type: fix
status: completed
date: 2026-03-09
deepened: 2026-03-09
---

# Fix Voice Pipeline Bugs and UX Polish Round 2

## Enhancement Summary

**Deepened on:** 2026-03-09 (2 rounds — 7 agents + 4 deep-dive agents)
**Reviewed on:** 2026-03-09 (6 review agents — architecture, performance, simplicity, spec-flow, agent-native, learnings)
**Research agents used:** 11 total (SFSpeech chaining, TTS/STT coordination, iOS 26 liquid glass, resumable downloads, architecture strategist, performance oracle, code simplicity reviewer, TTS pipeline deep-dive, STT chaining deep-dive, liquid glass deep-dive, download infra deep-dive)

### Key Improvements from Research
1. **Bug 3 simplified to 1-line fix** — delete `onAllSpeechFinished?()` from Kokoro path (TTSService:49). Keep `wireAutoReopen` for system TTS.
2. **Bug 2: generation counter replaces chainingInProgress flag** — simpler, handles all edge cases including rapid double-chains
3. **Bug 4+8: replace UIKit appearance proxies with SwiftUI modifiers** — create `LifehugBarStyle` ViewModifier, apply per-tab. No UITabBar proxies exist to remove (only UISegmentedControl — keep those).
4. **Bug 5: voices.npz URL is confirmed BROKEN (404)** — bundle 14.6MB in app. SHA-256 verification is dead code (placeholder hashes).
5. **Bug 4+8 deep-dive: `.toolbarBackgroundVisibility` is iOS 18+** — must use `.toolbarBackground(.visible, for:)` for iOS 17 target; exact 7-8 modifier locations identified
6. **Bug 5 deep-dive: SHA-256 is dead code** — hashes are `PLACEHOLDER_COMPUTE_ON_FIRST_DOWNLOAD`, verification always skipped. Bundle voices + update `loadEngine()` to resolve from Bundle.main
7. **Future: SpeechAnalyzer (iOS 26)** eliminates entire STT chaining problem class

### Review Corrections (P1)
- **Bug 1: Root cause is WRONG** — no `.safeAreaInset` exists in DailyQuestionView. Mic button shadow at line 312 is the likely culprit but needs investigation.
- **Bug 3: DO NOT remove `wireAutoReopen` from DailyQuestionView** — required for system TTS auto-reopen. System TTS `speak()` returns immediately (sentenceQueue pattern), so inline auto-reopen fires BEFORE TTS finishes.
- **Bug 4: No UITabBar appearance proxies exist** — `LifehugApp.init()` only contains UISegmentedControl appearance (3 lines). "Remove UITabBarAppearance" step is a no-op.

### Review Corrections (P2 — Deferred Optimizations)
The following items from the original plan are **not bug fixes** and are deferred to follow-up tasks:
- **Bug 2:** `OSAllocatedUnfairLock` for sharedRequest (premature — current `nonisolated(unsafe)` works, lock risks priority inversion on audio thread)
- **Bug 2:** `segmentStartTime` tracking (solves unreported problem — silence vs timeout disambiguation)
- **Bug 3:** AsyncStream sentence pipelining (performance optimization — no one reported inter-sentence gaps)
- **Bug 3:** CheckedContinuation for system TTS (refactor — current delegate+queue works)
- **Bug 3:** TaskGroup cancellation scope (wrong primitive per architecture review — if goal is pre-synthesis overlap)
- **Bug 3:** Audio session management (optimization — 100-200ms delay not reported)
- **Bug 5:** SHA-256 streaming fix (dead code — placeholder hashes, verification always skipped)
- **NEW:** Kokoro synthesis failure degradation — if `engine.generateAudio()` throws, sentence is silently skipped with no fallback to system TTS

### Simplifications Applied
- Bug 2: Removed `chainingInProgress` flag → use generation counter
- Bug 3: Reduced from "remove wireAutoReopen entirely" → delete 1 line only
- Bug 5: Removed resume capability proposal → bundle voices.npz, URL is already dead (404)
- Bug 5: SHA-256 streaming fix is preemptive only — hashes are placeholders, verification skipped
- Bug 6: Removed `hasPartialDownload` property and startup detection → just show buttons for right phases

---

## Overview

> **Note:** Some line numbers in this plan are approximate. Verify against actual code during implementation. Known offsets: wireAutoReopen is at ~484 (not 492), unwireAutoReopen at ~510/525/547 (not 518/533/556), question font at ~228 (not 229).

8 bugs reported after TestFlight build 15 testing. Two are critical voice pipeline issues (TTS cutoff, recording cutoff), two are persistent appearance problems (tab bar flash, white headers/status bar), two are Kokoro download UX gaps, and two are visual polish items. The TTS cutoff bug (#3) is the highest priority — it makes Kokoro voice mode unusable and is dangerous for driving users who rely on audio.

## Bug List

| # | Bug | Severity | File(s) |
|---|-----|----------|---------|
| 1 | Mic button has visible box/border on Today screen | P3 | `DailyQuestionView.swift` |
| 2 | Long voice answers get cut off halfway (~60s) | P1 | `STTService.swift` |
| 3 | TTS speaks only 2-4 words then mic cuts it off | P1 | `TTSService.swift`, `VoicePipeline.swift` |
| 4 | Tab bar flashes dark/light mode when switching tabs | P2 | `LifehugApp.swift` |
| 5 | Kokoro voice download still failing | P2 | `KokoroManager.swift`, `ModelConfig.swift` |
| 6 | No way to delete/reset stuck Kokoro download | P2 | `SettingsView.swift` |
| 7 | Question font on Today screen too small | P2 | `DailyQuestionView.swift` |
| 8 | White headers + status bar on light cream background | P2 | `LifehugApp.swift` |

---

## Bug 1: Mic Button Has Visible Box/Border

**Symptom:** Visible rectangular border/shadow around the mic button area on the Today screen, doesn't blend into cream background.

**Root cause:** ⚠️ **Needs investigation** — the original root cause (`.safeAreaInset` shadow) is wrong. There is NO `.safeAreaInset` in `DailyQuestionView.swift`. The mic button is a `Circle()` with `.shadow(color: micButtonColor.opacity(0.3), radius: 8, y: 4)` at line 312. The visible "box" may come from a container view's background or border, or from the circle shadow itself appearing box-like on certain backgrounds.

**Fix:**
- [x] Investigate the actual cause of the visible box/border around the mic button area
- [x] Likely candidates: container background with different color than `Theme.cream`, or the circle shadow `opacity(0.3)` being too strong
- [x] The mic button circle shadow at line 312 may need reducing (try `opacity(0.15)` or removing entirely) — reduced to 0.15

---

## Bug 2: Long Voice Answers Get Cut Off Halfway

**Symptom:** Recordings longer than ~60 seconds lose content. The transcript stops mid-sentence.

**Root cause:** Apple's `SFSpeechRecognitionTask` has a hard 60-second limit (though Apple says on-device recognition should have no limit — WWDC 2019 Session 256). The `STTService` handles this via `chainRecognitionRequest()` (line 232-253), but there's a race condition: between `recognitionRequest = nil` (line 239) and `self.sharedRequest = request` (line 249), audio buffers from the tap are appended to `nil` and silently dropped. Additionally, `recognitionTask?.cancel()` triggers the error callback which races with the new task.

**Fix (reorder operations + generation counter):**
- [x] In `chainRecognitionRequest()`, create the new request and assign `sharedRequest` BEFORE tearing down the old one:
  ```swift
  private func chainRecognitionRequest() {
      // 1. Create new request FIRST
      let newRequest = createRecognitionRequest()

      // 2. Swap sharedRequest atomically — tap immediately feeds new request
      let oldRequest = self.recognitionRequest
      let oldTask = self.recognitionTask
      self.recognitionRequest = newRequest
      self.sharedRequest = newRequest

      // 3. NOW tear down old request/task
      oldRequest?.endAudio()
      oldTask?.cancel()

      // 4. Install new recognition task
      installRecognitionTask(for: newRequest)
  }
  ```
- [x] Use a generation counter to ignore errors from stale/cancelled tasks (replaces `chainingInProgress` flag):
  ```swift
  private var taskGeneration: Int = 0

  private func installRecognitionTask(for request: SFSpeechAudioBufferRecognitionRequest) {
      taskGeneration += 1
      let currentGeneration = taskGeneration
      // In error callback:
      // guard gen == self.taskGeneration else { return } // ignore stale
  }
  ```
- [x] Guard against both `isFinal` and error 1110 firing for same event — generation counter handles this automatically (both paths check `gen == self.taskGeneration`)

### Deferred (Not Bug Fixes)
The following were in the original plan but are optimizations/refactors, not fixes for the reported bug:
- ~~`segmentStartTime` tracking~~ — solves unreported problem (silence vs timeout disambiguation). Could cause regressions by rejecting legitimate chains at <55s. Defer.
- ~~`OSAllocatedUnfairLock` for sharedRequest~~ — premature. Current `nonisolated(unsafe)` with benign race is working. Lock on audio render thread risks priority inversion. Defer.

### Research Insights

**On-device recognition should have no 60s limit.** Apple WWDC 2019: "With on-device recognition, these limits do not apply." The code already sets `requiresOnDeviceRecognition = true` (line 213). Error 1110 (`kAFAssistantErrorDomain`) literally means "no speech detected" — it may fire due to natural pauses, not a time limit. Consider adding `addsPunctuation = true` to the request.

**Deep-dive: Both `isFinal` and error 1110 can fire for the same recognition event.** The generation counter pattern handles this naturally — whichever fires second sees a stale generation and returns. Without this, double-chaining creates two parallel recognition tasks competing for the same audio.

**Deep-dive: `sharedRequest` is `nonisolated(unsafe)`** — written on `@MainActor` in `chainRecognitionRequest()`, read on the audio render thread in `installTap`. This is a data race. `OSAllocatedUnfairLock` provides lock-free atomic swap on the main path and safe reads on the audio thread.

**Deep-dive: `segmentStartTime` is key to error 1110 disambiguation.** If elapsed time < 55s when error 1110 fires, it's silence detection (user stopped talking). If >= 55s, it's a timeout and we should chain. Only chain on timeout — silence should end the recording naturally.

**Future: SpeechAnalyzer (iOS 26+)** eliminates this problem class entirely. Uses `AsyncStream<AnalyzerInput>`, no chaining needed, no time limits. Worth planning a migration when the deployment target moves to iOS 26.

**References:**
- [WWDC 2019 Session 256: Advances in Speech Recognition](https://asciiwwdc.com/2019/sessions/256)
- [WWDC 2025: SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [kAFAssistantErrorDomain error 1110 = "no speech detected"](https://developer.apple.com/forums/thread/664037)

---

## Bug 3: TTS Speaks Only 2-4 Words Then Gets Cut Off (CRITICAL)

**Symptom:** When user pauses recording, the AI begins speaking but gets interrupted after one sentence fragment (2-4 words). Then the mic immediately starts recording again.

**Root cause:** In `TTSService.speak()` line 49, the Kokoro path fires `onAllSpeechFinished?()` after EACH sentence. The `wireAutoReopen` callback in VoicePipeline (line 92-103) transitions to `.idle` and calls `startListening()`, which cancels `activeTask` — killing the LLM streaming loop. Only the first sentence gets spoken.

**Fix (1-line deletion only):**
- [x] Delete `onAllSpeechFinished?()` from the Kokoro path in `TTSService.speak()` (line 49) — this is the direct cause. The inline auto-reopen at `VoicePipeline.swift:273-278` already handles reopening after all sentences complete.
- [x] Keep `wireAutoReopen()` intact in `DailyQuestionView.swift:484` — **required for system TTS**. System TTS `speak()` appends to `sentenceQueue` and returns immediately (line 52-55), so the inline auto-reopen at VoicePipeline:273-278 fires BEFORE TTS finishes. `wireAutoReopen` ensures `onAllSpeechFinished` fires only when the sentence queue drains (line 82-84).
- [x] Keep `unwireAutoReopen()` calls at lines 510, 525, 547 — these are the cleanup counterparts

### Deferred (Not Bug Fixes)
The following were in the original plan but are performance optimizations or refactors, not fixes for the reported TTS cutoff bug:
- ~~AsyncStream sentence pipelining~~ — performance optimization. Nobody reported inter-sentence gaps. Current sequential `await ttsService.speak(sentence)` loop works for Kokoro. Defer.
- ~~CheckedContinuation for system TTS~~ — architectural refactor. Current delegate+queue pattern works. Would allow removing `wireAutoReopen` but is a TTSService rewrite bundled with a bug fix. Must guard against double-resume on `stop()`. Defer.
- ~~TaskGroup cancellation scope~~ — wrong primitive if goal is pre-synthesis overlap (architecture review). Defer.
- ~~Audio session management~~ — optimization. 100-200ms delay not reported as a bug. Defer.

**References:**
- [LiveKit VoicePipelineAgent: single-authority state machine](https://docs.livekit.io/agents/voice-agent/voice-pipeline/)
- [LiveKit Turn Detection](https://docs.livekit.io/agents/logic/turns/)

---

## Bug 4: Tab Bar Flashes Dark/Light Mode

**Symptom:** When switching tabs, the bottom tab bar briefly flashes to dark mode or shows inconsistent glass effects.

**Root cause:** iOS 26's "liquid glass" applies translucent glass surfaces to system bars by default. Without explicit SwiftUI toolbar modifiers, iOS re-applies glass materials on each layout pass during tab transitions, causing a visible flash.

**Fix (add SwiftUI modifiers — no UIKit proxies to remove):**
- [x] ⚠️ `LifehugApp.init()` has NO `UITabBarAppearance` or `UITabBar.appearance()` — only `UISegmentedControl.appearance()` (3 lines, lines 15-17). Keep those — segmented controls need the UIKit proxy for `selectedSegmentTintColor`.
- [x] Create a `LifehugBarStyle` ViewModifier:
  ```swift
  struct LifehugBarStyle: ViewModifier {
      func body(content: Content) -> some View {
          content
              .toolbarBackground(Theme.cream, for: .navigationBar)
              .toolbarBackgroundVisibility(.visible, for: .navigationBar)
              .toolbarColorScheme(.light, for: .navigationBar)
              .toolbarBackground(Theme.cream, for: .tabBar)
              .toolbarBackgroundVisibility(.visible, for: .tabBar)
              .toolbarColorScheme(.light, for: .tabBar)
      }
  }
  ```
- [x] Apply `.modifier(LifehugBarStyle())` inside each Tab's content view (NOT on the TabView itself — it has no effect there)
- [x] Also apply to pushed views in NavigationStack

### Research Insights

**iOS 26 liquid glass is the root cause.** System bars are no longer opaque by default — they are translucent glass surfaces. Without explicit toolbar modifiers, iOS re-applies glass materials during tab transitions causing the flash.

**No UIKit tab bar proxies exist to remove.** `LifehugApp.init()` only contains `UISegmentedControl.appearance()` (3 lines). The fix is purely additive — add SwiftUI toolbar modifiers.

**SwiftUI modifiers are the Apple-recommended approach.** `.toolbarBackground`, `.toolbarColorScheme` work reliably on iOS 16+ and are the correct fix for iOS 26.

**Key caveat:** Modifiers must be on each tab's CONTENT view (inside the `Tab` closure), not on the `TabView` itself. Applying them on `TabView` has no effect.

### Deep-Dive: iOS 17 Compatibility + Exact Modifier Locations

**CRITICAL: `.toolbarBackgroundVisibility` is iOS 18+ only.** The plan's original code uses `.toolbarBackgroundVisibility(.visible, for:)` which will fail to compile on iOS 17 target. Use `.toolbarBackground(.visible, for:)` instead (iOS 16+):
- [x] Update `LifehugBarStyle` to use iOS 16+ compatible API:
  ```swift
  struct LifehugBarStyle: ViewModifier {
      func body(content: Content) -> some View {
          content
              .toolbarBackground(Theme.cream, for: .navigationBar)
              .toolbarBackground(Theme.cream, for: .tabBar)
              .toolbarBackground(.visible, for: .navigationBar)  // NOT .toolbarBackgroundVisibility
              .toolbarBackground(.visible, for: .tabBar)
              .toolbarColorScheme(.light, for: .navigationBar)
              .toolbarColorScheme(.light, for: .tabBar)
      }
  }
  ```

**Exact locations to apply `.modifier(LifehugBarStyle())` (7-8 places):**
- [x] `DailyQuestionView.swift` — on the ZStack/content view inside NavigationStack
- [x] `CoverageView.swift` — on the ScrollView inside NavigationStack
- [x] `AnswersBrowserView.swift` — on the VStack inside NavigationStack
- [x] `SettingsView.swift` — on the Form inside NavigationStack
- [x] `ConversationView.swift` — on the ZStack body (pushed destination — does NOT inherit from parent)
- [ ] `AnswerDetailView` in AnswersBrowserView.swift — on the ScrollView (pushed destination)
- [ ] `ChapterDetailView` in AnswersBrowserView.swift — on the ScrollView (pushed destination)
- [ ] `CategoryDetailSheet` in CoverageView.swift — on the List inside the sheet's NavigationStack

**`UISegmentedControl.appearance()` proxy stays** (lines 15-17 in LifehugApp.swift) — these are the ONLY UIKit appearance proxies in init(). Segmented controls need the UIKit proxy for `selectedSegmentTintColor` — `.tint()` doesn't reliably work in SwiftUI.

**Pushed views do NOT inherit toolbar modifiers** from their parent NavigationStack. Every pushed destination needs its own `LifehugBarStyle` modifier or the nav bar will revert to system defaults.

**References:**
- [Donny Wals: Exploring tab bars on iOS 26 with Liquid Glass](https://www.donnywals.com/exploring-tab-bars-on-ios-26-with-liquid-glass/)
- [Pratik Pathak: iOS 26 Glass Effect Fix](https://pratikpathak.com/fix-guide-to-ios-26-glass-effect-and-toolbarcolorscheme-issue-and-solution/)
- [Fatbobman: Grow on iOS 26](https://fatbobman.com/en/posts/grow-on-ios26/)

---

## Bug 5: Kokoro Voice Download Still Failing

**Symptom:** Natural voice download gets stuck at ~75% and fails with "Failed to download Kokoro voices."

**Root cause:** The voices URL (`media.githubusercontent.com/media/mlalma/KokoroTestApp/main/Resources/voices.npz`) is a Git LFS endpoint on a third-party repo. **GitHub LFS has a 1GB/month bandwidth limit per repository.** At 14.6MB per download, the quota exhausts after ~68 downloads. This is why retries don't help — the URL itself becomes unavailable.

**Fix (bundle voices + clean up dead code):**
- [x] **Bundle `voices.npz` in the app binary** (14.6MB is negligible — Apple's cellular download warning is 200MB). This eliminates the most fragile download entirely. Users only need to download the 160MB model.
  - Copy `voices.npz` to `Lifehug/Lifehug/Resources/voices.npz`
  - Add to `project.yml` as a bundle resource:
    ```yaml
    - path: Lifehug/Resources/voices.npz
      type: file
      buildPhase: resources
    ```
- [x] Update `KokoroManager.voicesFileURL` to check Bundle.main first:
  ```swift
  private var voicesFileURL: URL {
      // Prefer bundled voices (always available)
      if let bundled = Bundle.main.url(forResource: "voices", withExtension: "npz") {
          return bundled
      }
      // Fallback to downloaded (legacy)
      return modelDirectory.appendingPathComponent("voices.npz")
  }
  ```
- [x] Update `loadEngine()` to resolve voices from Bundle.main — ensure Kokoro's init uses the bundled path
- [x] Remove `voicesDownloadURL` from `ModelConfig.swift` — no longer needed
- [x] Remove voices download logic from `performDownload()` in KokoroManager — only download the model file
- [x] Add migration: delete legacy downloaded `voices.npz` from Application Support on first launch:
  ```swift
  private func cleanupLegacyVoices() {
      let legacy = modelDirectory.appendingPathComponent("voices.npz")
      try? FileManager.default.removeItem(at: legacy)
  }
  ```

### Deep-Dive: SHA-256 Is Dead Code + URL Confirmed Broken

**The voices URL returns 404.** Confirmed broken — GitHub LFS bandwidth is exhausted on `mlalma/KokoroTestApp`. No amount of retrying will fix this. Bundling is the only reliable solution.

**SHA-256 verification is effectively dead code.** The hashes in `ModelConfig.swift` are `PLACEHOLDER_COMPUTE_ON_FIRST_DOWNLOAD` — the verification function checks for this string and skips verification entirely. The streaming hash fix is preemptive for when real hashes are eventually computed, but is not blocking.

**SHA-256 streaming fix is deferred (dead code).** Hashes are `PLACEHOLDER_COMPUTE_ON_FIRST_DOWNLOAD` — verification is always skipped. When real hashes are eventually added, the streaming fix should be applied then (current code loads entire 160MB into `Data`).

**References:**
- [GitHub LFS bandwidth limits](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-storage-and-bandwidth-usage)
- [HuggingFace rate limits](https://huggingface.co/docs/hub/en/rate-limits)

---

## Bug 6: No Way to Delete/Reset Stuck Kokoro Download

**Symptom:** Download stuck at ~75%. No cancel button, no delete button, no retry option visible.

**Root cause:** The Settings UI only shows delete when `isModelDownloaded == true`. Partial downloads don't qualify. No cancel or retry buttons exist.

**Fix (add buttons for each phase — no new properties needed):**
- [x] When `phase == .downloading`: add "Cancel Download" button
  ```swift
  Button("Cancel Download", role: .destructive) {
      kokoroManager.cancelDownload()
  }
  ```
- [x] When `phase == .failed`: add "Retry Download" and "Delete Files" buttons
  ```swift
  Button("Retry Download") { kokoroManager.downloadModel() }
  Button("Delete Partial Files", role: .destructive) { kokoroManager.deleteModel() }
  ```
- [x] Change delete button guard from `isModelDownloaded` to `isModelDownloaded || phase == .failed`

### Research Insight: Keep It Simple

The `phase` enum already distinguishes all states. No `hasPartialDownload` computed property needed. No startup detection needed. If the app crashes mid-download, `phase` resets to `.idle` on relaunch and the user just toggles the switch again. The existing `cancelDownload()` already cleans up partial files (line 117-120).

---

## Bug 7: Question Font Too Small on Today Screen

**Symptom:** Can't read the daily question at a glance while walking.

**Root cause:** Idle question uses `Theme.title2Font` (≈ 22pt). Too small for glance-and-go.

**Fix:**
- [x] Change idle question font from `Theme.title2Font` to `Theme.titleFont` (`.system(.title, design: .serif)` ≈ 28pt) at `DailyQuestionView.swift:229`
- [ ] If `.title` still feels small, go to `.largeTitle` (≈ 34pt) — but test with longer questions
- [ ] Keep voice session question at `Theme.title2Font` to preserve transcript space
- [x] Consider `.minimumScaleFactor(0.7)` as safety valve for very long questions

---

## Bug 8: White Headers + Status Bar on Light Background

**Symptom:** Navigation titles and status bar items (clock, battery) are white and unreadable on cream background.

**Root cause:** No `UINavigationBarAppearance` configured. iOS 26 liquid glass infers a color scheme — on cream, it sometimes picks white text. Status bar follows nav bar.

**Fix (handled by LifehugBarStyle from Bug 4):**
- [x] The `LifehugBarStyle` ViewModifier from Bug 4 already includes `.toolbarColorScheme(.light, for: .navigationBar)` — this forces dark text for both nav title and status bar
- [x] Add `.preferredColorScheme(.light)` on the root `ContentView` in `LifehugApp.swift` as a global backstop
- [x] Test on all screens: Settings, Coverage, Answers, Today — titles should be dark walnut/charcoal

### Research Insight

`.toolbarColorScheme(.light, for: .navigationBar)` forces the navigation bar to use dark text on a light background, which **also forces the status bar** to use dark icons. This is the cleanest single fix for both nav titles and status bar.

---

## Known Issue (Deferred): Kokoro Synthesis Failure Has No Degradation

**Not a reported bug, but flagged by spec-flow analyzer.** If `KokoroManager.speak()` throws during audio generation (OOM, corrupted model, GPU error), the sentence is silently skipped — the user hears nothing. For a driving user, this means missing the AI's response entirely.

**Current behavior:** `speak()` at KokoroManager.swift:213 catches the error, logs it, and returns silently. `TTSService.speak()` sets `isSpeaking = false` and moves on. No retry, no fallback to system TTS.

**Recommended follow-up:** Catch Kokoro failure in `TTSService.speak()`, set `forceDegradedToSystem = true`, and replay the sentence via system TTS. This ensures driving users always hear the response (possibly with a voice change mid-stream).

---

## Implementation Order

### Phase 1: Critical Voice Pipeline (Bugs 3, 2) — Minimal Fixes Only

1. **Bug 3 (TTS cutoff)** — Delete `onAllSpeechFinished?()` from TTSService Kokoro path (line 49). That's it. Do NOT remove `wireAutoReopen` from DailyQuestionView.
2. **Bug 2 (recording cutoff)** — Reorder `chainRecognitionRequest()` to create-new-then-teardown-old. Add generation counter for stale error callback detection. (2 changes only — no OSAllocatedUnfairLock, no segmentStartTime.)

### Phase 2: Appearance & Readability (Bugs 4, 8, 7, 1)

3. **Bugs 4 + 8 (bars + status bar)** — Create `LifehugBarStyle` ViewModifier with SwiftUI toolbar modifiers (using iOS 16+ `.toolbarBackground(.visible, for:)` API). Apply to all 7-8 locations. Add `.preferredColorScheme(.light)` on root view. No UIKit proxies to remove — only UISegmentedControl exists (keep it).
4. **Bug 7 (question font)** — Change `.title2` to `.title` or `.largeTitle`.
5. **Bug 1 (mic button border)** — Investigate actual cause (no safeAreaInset exists). Likely the circle shadow at line 312.

### Phase 3: Kokoro Download UX (Bugs 5, 6)

6. **Bug 5 (download failure)** — Bundle `voices.npz` in app. Remove voices download logic + voicesDownloadURL. Clean up legacy downloaded voices.npz. (No SHA-256 fix — it's dead code.)
7. **Bug 6 (download controls)** — Add cancel/retry/delete buttons for `.downloading` and `.failed` phases.

---

## Acceptance Criteria

### Voice Pipeline (Required)
- [ ] AI speaks full multi-sentence response before mic reopens (Bug 3)
- [ ] System TTS auto-reopen still works correctly after fix (wireAutoReopen intact)
- [ ] Recordings of 2+ minutes work without cutoff (Bug 2)
- [ ] Chaining transitions are seamless — no lost words
- [ ] Driving user flow works: speak → hear full AI response → speak again → double-tap to save

### Appearance (Required)
- [ ] Tab bar never flashes dark mode when switching tabs (Bug 4)
- [ ] Navigation titles are dark (walnut/charcoal) on all screens (Bug 8)
- [ ] Status bar items (clock, battery) are always dark/readable (Bug 8)
- [ ] Mic button area blends seamlessly into cream background (Bug 1)
- [ ] Question text readable at arm's length while walking (Bug 7)

### Kokoro Download (Required)
- [ ] Cancel button visible during active download (Bug 6)
- [ ] Retry and Delete buttons visible when download fails (Bug 6)
- [ ] voices.npz bundled in app — no separate download needed (Bug 5)

### Deferred (Follow-Up Tasks)
- [ ] Sentence pipelining for inter-sentence gap elimination
- [ ] CheckedContinuation for system TTS (enables removing wireAutoReopen)
- [ ] OSAllocatedUnfairLock for sharedRequest thread safety
- [ ] segmentStartTime for silence vs timeout disambiguation
- [ ] SHA-256 streaming verification (when real hashes are added)
- [ ] Kokoro synthesis failure degradation to system TTS

---

## Key Files

| File | Bugs | Changes |
|------|------|---------|
| `Lifehug/Services/TTSService.swift` | 3 | Delete line 49 (`onAllSpeechFinished?()` in Kokoro path) |
| `Lifehug/Services/STTService.swift` | 2 | Reorder `chainRecognitionRequest()` + add generation counter |
| `Lifehug/App/LifehugApp.swift` | 4, 8 | Add `LifehugBarStyle` ViewModifier, add `.preferredColorScheme(.light)`. Keep UISegmentedControl proxy (only UIKit proxy that exists). |
| `Lifehug/Views/DailyQuestionView.swift` | 1, 7 | Investigate mic button border, increase question font, add LifehugBarStyle |
| `Lifehug/Views/CoverageView.swift` | 4, 8 | Add LifehugBarStyle (+ CategoryDetailSheet) |
| `Lifehug/Views/AnswersBrowserView.swift` | 4, 8 | Add LifehugBarStyle (+ AnswerDetailView, ChapterDetailView) |
| `Lifehug/Views/ConversationView.swift` | 4, 8 | Add LifehugBarStyle (pushed destination) |
| `Lifehug/Views/SettingsView.swift` | 4, 6, 8 | Add download buttons, add LifehugBarStyle |
| `Lifehug/Services/KokoroManager.swift` | 5 | Bundle voices, remove voices download, legacy cleanup |
| `Lifehug/App/ModelConfig.swift` | 5 | Remove `voicesDownloadURL` |
| `Lifehug/App/DesignTokens.swift` | 7 | Font token change |
| `Lifehug/project.yml` | 5 | Add voices.npz as bundle resource |

## Sources

- Previous plan: `docs/plans/2026-03-08-fix-voice-ux-bugs-and-polish-plan.md`
- [WWDC 2019: On-device recognition has no time limits](https://asciiwwdc.com/2019/sessions/256)
- [WWDC 2025: SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [LiveKit VoicePipelineAgent](https://docs.livekit.io/agents/voice-agent/voice-pipeline/)
- [Donny Wals: iOS 26 Liquid Glass tab bars](https://www.donnywals.com/exploring-tab-bars-on-ios-26-with-liquid-glass/)
- [Pratik Pathak: iOS 26 toolbarColorScheme fix](https://pratikpathak.com/fix-guide-to-ios-26-glass-effect-and-toolbarcolorscheme-issue-and-solution/)
- [GitHub LFS bandwidth limits](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-storage-and-bandwidth-usage)
- [HuggingFace rate limits](https://huggingface.co/docs/hub/en/rate-limits)
- [WWDC 2023: Resumable downloads](https://developer.apple.com/videos/play/wwdc2023/10006/)
