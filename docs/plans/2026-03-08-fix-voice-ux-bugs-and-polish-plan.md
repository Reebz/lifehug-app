---
title: "Fix Voice UX Bugs and Polish"
type: fix
status: active
date: 2026-03-08
deepened: 2026-03-08
---

# Fix Voice UX Bugs and Polish

## Enhancement Summary

**Deepened on:** 2026-03-08
**Research agents used:** best-practices-researcher (x4: downloads, tab bar, voice UX, model state), architecture-strategist, performance-oracle, code-simplicity-reviewer

### Key Improvements from Research
1. Simplified silence timeout: slider with 0="Off" instead of Toggle + Slider (fewer controls)
2. Tab bar fix: must set BOTH `standardAppearance` AND `scrollEdgeAppearance` to prevent flickering
3. Model status: potential duplicate model loading between `ModelDownloader` and `LLMService` — audit needed
4. Double-tap save: needs re-entry guard to prevent double-save on rapid taps
5. Button layout: `.safeAreaInset(edge: .bottom)` is the correct pattern for pinned bottom buttons

### New Considerations Discovered
- Kokoro download uses `URLRequest.timeoutInterval` which sets BOTH request AND idle timeout to 60s — root cause confirmed
- `recheckModelAvailability()` has a dead guard (`phase == .ready`) that makes it useless after any unload
- The expanding-ring pulse animation pattern is industry standard for recording buttons
- iOS 26 liquid glass: `UIDesignRequiresCompatibility` Info.plist key exists as escape hatch if needed

---

## Overview

9 bugs and enhancements across the voice recording UX, model downloads, settings, and tab bar. Most are quick fixes in DailyQuestionView, with two download reliability issues requiring deeper investigation.

## Issues

### 1. Silence Timeout: Add "Off" Option, Expand Range to 2-15s

**File:** `SettingsView.swift:288-306`, `StorageService.swift:13-26`, `STTService.swift:218-228`

**Current:** Slider from 1.0-10.0s, step 0.5, default 3.0. No way to disable.

**Fix (simplified):**
- Change slider range to `0...15.0`, step 0.5
- When value is 0, display "Off" instead of "0.0s"
- In `STTService.resetSilenceTimer()`, guard `timeout > 0` before creating the timer task — do NOT create a timer with infinite sleep
- No Toggle needed — the slider at 0 IS the off state

```swift
// In SettingsView voiceSection
Slider(value: $silenceTimeout, in: 0...15.0, step: 0.5)
    .tint(Theme.terracotta)

// Label
Text(silenceTimeout == 0 ? "Off" : "\(silenceTimeout, specifier: "%.1f")s")

// In STTService.resetSilenceTimer()
private func resetSilenceTimer() {
    silenceTimer?.cancel()
    let timeout = StorageService.silenceTimeout
    guard timeout > 0 else { return }  // disabled — no timer
    silenceTimer = Task { @MainActor [weak self] in
        // ...existing timer logic...
    }
}
```

**Acceptance Criteria:**
- [ ] Slider at 0 shows "Off" and disables silence timeout
- [ ] Slider range 0-15s
- [ ] When off, recording continues indefinitely (until user stops)

---

### 2. Kokoro Voice Download Fails at ~75-80%

**File:** `KokoroManager.swift:290-370`, `ModelConfig.swift`

**Current:** Downloads `kokoro-v1_0.safetensors` (~160MB) from HuggingFace and `voices.npz` (~14.6MB) from GitHub LFS. URLRequest timeout is 60s. One retry with 2s delay.

**Root Cause (confirmed by research):**
- `URLRequest.timeoutInterval = 60` sets BOTH the request timeout AND idle timeout to 60s. If the connection stalls for >60s at 75%, the download fails.
- This is the documented behavior: `timeoutInterval` on the request itself overrides both `timeoutIntervalForRequest` AND `timeoutIntervalForResource` from the session configuration.

**Fix (keep it simple — just increase timeout):**
- Change `request.timeoutInterval` from `60` to `300` (5 minutes)
- Increase retry count from 1 to 3 (change the retry loop bound)
- Add `UIApplication.shared.isIdleTimerDisabled = true` during download to prevent sleep

```swift
// In downloadFileOnce()
request.timeoutInterval = 300  // was 60

// In downloadFile() — change retry from 1 to 3
for attempt in 0..<3 {  // was 0..<1

// Prevent device sleep during download
func startDownload() {
    UIApplication.shared.isIdleTimerDisabled = true
    // ... existing download code ...
    // In completion/error: UIApplication.shared.isIdleTimerDisabled = false
}
```

**Research insight:** The HuggingFace Hub library's `snapshot()` already skips fully-downloaded files on retry, so retrying `loadContainer` after partial failure effectively resumes at file-level granularity.

**Acceptance Criteria:**
- [ ] Kokoro model downloads successfully on stable Wi-Fi
- [ ] 3 retry attempts before giving up
- [ ] Device doesn't sleep during download

---

### 3. Model Shows "Not Downloaded" on Every Launch

**File:** `ModelState.swift:82-96`, `ModelDownloader.swift:126-137`

**Current:** When app backgrounds, `handleScenePhaseChange(.background)` sets `status = .notDownloaded`. On foreground, `recheckModelAvailability()` guards on `phase == .ready` (dead code after unload).

**Root Cause (confirmed):** `unloadModel()` sets phase to `.idle`, making `recheckModelAvailability()` a no-op. Status stays `.notDownloaded`.

**Fix (simplest — don't lie about download status):**
- On background: unload from memory but do NOT change status to `.notDownloaded`
- Add a new case or simply keep `.ready` but set `isLoaded = false`
- On foreground: check `isModelCached`, reload if files exist

```swift
// In handleScenePhaseChange
case .background:
    downloader.unloadModel()
    isLoaded = false
    // Do NOT set status = .notDownloaded — files are still on disk

case .active:
    if !isLoaded && downloader.isModelCached {
        status = .loading
        Task {
            await downloader.loadCachedModel()
            syncFromDownloader()
        }
    }
```

**Performance research insight:** Model loading from disk takes 1-3s on A15+. The `Task {}` in LifehugApp already handles this async. But there's a potential duplicate: both `ModelState` and `LLMService` independently load the model. Audit whether `ModelDownloader.modelContainer` and `LLMService.modelContainer` hold separate instances — if so, that's ~2GB RAM for a 1B model.

**Architecture insight:** Consider consolidating model loading to ONE path (either ModelState or LLMService, not both).

**Acceptance Criteria:**
- [ ] App does not show download prompt when model is already on disk
- [ ] Model reloads correctly after backgrounding/foregrounding
- [ ] First-time users still see the download prompt
- [ ] No duplicate model loading (single source of truth)

---

### 4. Record Button Needs to Be Twice the Size

**File:** `DailyQuestionView.swift:29-30`

**Current:** `micDiameter = 140`, `micIconSize = 56`

**Fix:**
- User asked for "twice the size" → `micDiameter = 200` (280 is too large for most screens)
- `micIconSize = 72` (maintains ~36% icon-to-button ratio)

**Research context:** Standard voice recording buttons in iOS apps (Voice Memos, WhatsApp) are 64-80pt. At 200pt this button is intentionally oversized for a voice-first memoir app targeting an older demographic. At 200pt it's ~50% of screen width on iPhone 15 Pro (393pt) — verify layout on iPhone SE (375pt).

**Acceptance Criteria:**
- [ ] Mic button is ~200pt diameter
- [ ] Icon scales proportionally
- [ ] Layout doesn't clip on iPhone SE (375pt width)

---

### 5. "Type Instead" Should Be a Pill-Shaped Button

**File:** `DailyQuestionView.swift:372-384`

**Current:** Plain text link, no visual container, below 44pt touch target.

**Fix (simplified — fill only, no stroke):**
```swift
Button { ... } label: {
    HStack(spacing: 6) {
        Image(systemName: "keyboard")
            .font(.system(size: 14, weight: .medium))
        Text("Type instead")
            .font(.subheadline.weight(.medium))
    }
    .foregroundStyle(Theme.walnut)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)  // 12 + text + 12 ≈ 44pt touch target
    .background(Capsule().fill(Theme.walnut.opacity(0.08)))
}
```

**Research insight:** Adding a keyboard icon alongside the text improves scanability. The capsule fill alone provides sufficient visual affordance — the stroke border adds visual noise without improving usability.

**Acceptance Criteria:**
- [ ] Pill/capsule button with keyboard icon
- [ ] Meets 44pt minimum touch target
- [ ] Visually secondary to mic button

---

### 6. Record Button Should Not Move When Recording Starts

**File:** `DailyQuestionView.swift` — `idleLayout` (lines 66-85) and `voiceSessionLayout` (lines 89-203)

**Current:** Two separate VStack layouts swap the mic button between center (idle) and bottom (voice session).

**Fix — use `.safeAreaInset(edge: .bottom)` to pin the mic:**

```swift
var body: some View {
    NavigationStack {
        ZStack {
            Theme.cream.ignoresSafeArea()

            // Content area (question + transcript)
            contentArea  // changes between idle/voice, scrolls if needed
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                micButton
                typeInsteadButton
            }
            .padding(.bottom, 8)
            .background(
                Theme.cream
                    .shadow(color: .black.opacity(0.04), radius: 8, y: -4)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .navigationDestination(isPresented: $navigateToConversation) { ... }
    }
}
```

**Research insight:** This is the iMessage/Voice Memos pattern — content scrolls above, action button stays pinned. `.safeAreaInset` automatically adjusts the ScrollView's content inset, handles safe areas on home indicator devices, and requires zero GeometryReader or manual offset calculation.

**Key detail:** Both idle and voice session modes share the SAME mic button position. Only the content area above changes (question text → transcript scroll view).

**Acceptance Criteria:**
- [ ] Mic button in exactly the same screen position in both modes
- [ ] No visible jump on mode transitions
- [ ] Content scrolls independently above the mic area

---

### 7. Recording Color Should Be Bright Red, Not Terracotta

**File:** `DailyQuestionView.swift:259-273` (`micButtonColor`), `DesignTokens.swift`

**Current:** `.listening` uses `Theme.mutedRose` (0xC47070 — dusty rose, only 3.2:1 contrast on white, below WCAG AA).

**Fix:**
- Add `static let recordingRed = Color(hex: 0xE53E3E)` to Theme
- Change `micButtonColor` for `.listening` from `Theme.mutedRose` to `Theme.recordingRed`
- Do NOT modify `mutedRose` — it's used elsewhere for destructive buttons

**Research color comparison:**
| Color | Hex | Usage |
|-------|-----|-------|
| iOS System Red | `#FF3B30` | Voice Memos, Phone app |
| Warm Recording Red | `#E53E3E` | Fits warm palette, 4.5:1+ contrast |
| Current mutedRose | `#C47070` | Too muted, 3.2:1 contrast (fails WCAG) |

**Optional enhancement — expanding ring pulse animation:**
```swift
// Fading ring that expands from the button during recording
Circle()
    .stroke(Theme.recordingRed.opacity(0.4), lineWidth: 2)
    .frame(width: micDiameter, height: micDiameter)
    .scaleEffect(isPulsing ? 1.5 : 1.0)
    .opacity(isPulsing ? 0.0 : 0.6)
    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: isPulsing)
```

**Acceptance Criteria:**
- [ ] Recording state shows bright red (#E53E3E)
- [ ] Clear distinction from idle (terracotta) and recording (red)
- [ ] WCAG AA contrast ratio (4.5:1+) for white icon on red

---

### 8. Double-Tap Should Save, Not Navigate to Text Conversation

**File:** `DailyQuestionView.swift:328-335, 520-537`

**Current:** `.onTapGesture(count: 2)` calls `endVoiceSessionAndNavigate()`.

**Fix:**
```swift
.onTapGesture(count: 2) {
    triggerHaptic()
    endVoiceSessionAndSave()  // was endVoiceSessionAndNavigate()
}
```

**Architecture insight — add re-entry guard:** `endVoiceSessionAndSave()` includes a 1.5s `Task.sleep` for the saved overlay. Rapid double-taps could trigger concurrent saves. Add guard:

```swift
func endVoiceSessionAndSave() {
    guard !isSaving else { return }  // prevent double-save
    isSaving = true
    // ... existing save logic ...
}
```

**Also verify:** `handleSingleTap()` calls `pipeline.pauseListening()` — confirm this method exists on VoicePipeline. If not, implement it (stop STT but keep pipeline alive) or use `pipeline.stopListening()` as a fallback.

**Acceptance Criteria:**
- [ ] Double-tap ends session and saves the answer
- [ ] No navigation to ConversationView from voice mode
- [ ] Re-entry guard prevents double-save
- [ ] Single-tap pauses/resumes recording

---

### 9. Tab Bar Liquid Glass Effect Inconsistency

**File:** `LifehugApp.swift:57-93` (ContentView), `LifehugApp.swift:14-17` (init)

**Current:** No tab bar appearance configuration. iOS 26 liquid glass causes black/clear flickering.

**Fix — UIKit appearance (most reliable cross-version):**

```swift
// In LifehugApp.init(), add alongside existing UISegmentedControl.appearance()
private func configureTabBarAppearance() {
    let appearance = UITabBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = UIColor(Theme.cream)

    // CRITICAL: Set BOTH to prevent flickering during scroll transitions
    UITabBar.appearance().standardAppearance = appearance
    UITabBar.appearance().scrollEdgeAppearance = appearance
}
```

**Research insight — why UIKit over SwiftUI modifiers:**
- SwiftUI `.toolbarBackground()` must be applied INSIDE each Tab's content, NOT on TabView itself — easy to get wrong
- UIKit appearance is a single point of configuration in `init()`
- Setting only ONE of `standardAppearance`/`scrollEdgeAppearance` causes the other to fall back to default glass, producing the exact flickering artifact the user reported
- The existing `.tint(Theme.terracotta)` on TabView will continue to work for selected icon color

**Acceptance Criteria:**
- [ ] Tab bar has consistent opaque cream background
- [ ] No black/clear flickering on tab switch or scroll
- [ ] Works on iOS 18+ through iOS 26

---

## Implementation Order

| Priority | Issue | File(s) | Effort | Risk |
|----------|-------|---------|--------|------|
| 1 | #8 Double-tap save + guard | DailyQuestionView.swift | Trivial | Low |
| 2 | #7 Recording red | DesignTokens.swift, DailyQuestionView.swift | Small | Low |
| 3 | #4 Button size 200pt | DailyQuestionView.swift | Small | Low |
| 4 | #5 Pill button | DailyQuestionView.swift | Small | Low |
| 5 | #6 Button position (.safeAreaInset) | DailyQuestionView.swift | Medium | Medium |
| 6 | #1 Silence timeout 0=Off | SettingsView.swift, StorageService.swift, STTService.swift | Small | Low |
| 7 | #9 Tab bar appearance | LifehugApp.swift | Small | Low |
| 8 | #3 Model status fix | ModelState.swift | Medium | Medium |
| 9 | #2 Kokoro download timeout | KokoroManager.swift | Small | Low |

## Agent Team Split

- **Agent A** (DailyQuestionView + DesignTokens): Issues #4, #5, #6, #7, #8
  - All in one file with interdependent layout changes
  - #6 is the biggest structural change — do it first, then layer others on top
  - Must read VoicePipeline.swift to verify `pauseListening()` exists

- **Agent B** (Settings + App): Issues #1, #9
  - Settings silence timeout slider change
  - Tab bar appearance in LifehugApp.init()
  - Also update STTService guard for timeout=0

- **Agent C** (Downloads + Model State): Issues #2, #3
  - Kokoro timeout increase
  - ModelState background/foreground fix
  - Audit duplicate model loading between ModelDownloader and LLMService

## Sources

### Key Files
- `DailyQuestionView.swift` — mic button, layouts, gestures, save flow
- `DesignTokens.swift` — Theme colors and typography
- `SettingsView.swift` — voice section, silence timeout
- `StorageService.swift` — silence timeout preference
- `STTService.swift` — silence timer implementation
- `KokoroManager.swift` — Kokoro model download logic
- `ModelState.swift` — LLM model state, background/foreground handling
- `ModelDownloader.swift` — model cache detection, download
- `LifehugApp.swift` — ContentView tab bar, UIAppearance init
- `VoicePipeline.swift` — voice state machine, pause/resume

### Research References
- [iOS large file downloads with URLSession](https://www.momentslog.com/development/ios/handling-large-file-downloads-with-urlsession-background-tasks-and-progress-tracking)
- [URLSession common pitfalls](https://www.avanderlee.com/swift/urlsession-common-pitfalls-with-background-download-upload-tasks/)
- [iOS 26 liquid glass tab bars — Donny Wals](https://www.donnywals.com/exploring-tab-bars-on-ios-26-with-liquid-glass/)
- [Disable liquid glass in SwiftUI/UIKit](https://blog.stackademic.com/disable-or-opt-out-liquid-glass-in-swiftui-and-uikit-ios-26-5c6d55d3e8e5)
- [SwiftUI safeAreaInset](https://www.hackingwithswift.com/quick-start/swiftui/how-to-inset-the-safe-area-with-custom-content)
- [Pin view to bottom of safe area](https://nilcoalescing.com/blog/PinAViewToTheBottomOfSafeArea/)
- [Apple HIG touch targets](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [ScenePhase lifecycle issues](https://www.jessesquires.com/blog/2024/06/29/swiftui-scene-phase/)
- [swift-huggingface library](https://huggingface.co/blog/swift-huggingface)
- [HuggingFace cache management](https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache)
