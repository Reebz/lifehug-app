---
title: "fix: UI/UX Audit — 25 Issues Across P1/P2/P3"
type: fix
status: completed
date: 2026-03-10
---

# fix: UI/UX Audit — 25 Issues Across P1/P2/P3

## Overview

Comprehensive UI/UX fix pass for the Lifehug iOS app based on a full-app audit. 25 issues identified across 7 view files, grouped into 6 P1 (critical UX), 10 P2 (important polish), and 9 P3 (nice-to-have) items. The biggest theme: **voice interaction lacks feedback** — users can't tell what state the mic is in or what to do next.

## Problem Statement

Users testing build 16-17 on device reported confusion around:
- What the mic button is doing (recording? paused? thinking?)
- Whether saves succeeded
- How to navigate between voice session and conversation
- Delayed/missing error feedback

Beyond the reported bugs, a systematic audit found 25 distinct UI/UX issues affecting the app's warmth, clarity, and polish.

## Implementation Phases

All 25 issues organized into 5 parallel-friendly phases. Issues within a phase can be worked concurrently by separate agents.

---

### Phase 1: Mic Button & Voice Feedback (P1 — Issues 1, 4, 5)

**Goal:** Make the voice interaction state crystal clear at all times.

#### Issue 1: Mic button states need solid colors + text labels

**File:** `Lifehug/Views/DailyQuestionView.swift`

**Current:** Mic button changes color subtly between states. Uses `pause.fill` icon for idle (confusing). No text label.

**Fix:**
- Replace `micButtonColor` computed property with bold, unmistakable solid colors:

```swift
// DailyQuestionView.swift — micButtonColor
private var micButtonColor: Color {
    guard voiceSessionActive, let pipeline else {
        return Theme.terracotta  // Idle/not started — warm default
    }
    switch pipeline.state {
    case .listening:
        return Color(hex: 0xDC3545)  // Solid RED — actively recording
    case .idle:
        return Theme.amber           // ORANGE — paused/waiting
    case .processing:
        return Theme.amber           // ORANGE — thinking
    case .speaking:
        return Color(hex: 0x28A745)  // Solid GREEN — AI speaking
    }
}
```

- Replace `micButtonIcon` to use clearer icons:

```swift
// DailyQuestionView.swift — micButtonIcon
case .listening:
    Image(systemName: "waveform")  // Waveform = actively capturing audio
case .processing:
    ProgressView().controlSize(.large).tint(.white)
case .speaking:
    Image(systemName: "speaker.wave.2.fill")  // Speaker = AI talking
case .idle:
    Image(systemName: "mic.fill")  // Mic = ready to record again
```

- **Add a text label below the mic circle** showing state:

```swift
// Below the mic ZStack, add:
Text(micStateLabel)
    .font(.caption.weight(.semibold))
    .foregroundStyle(Theme.walnut)
    .padding(.top, 4)

private var micStateLabel: String {
    guard voiceSessionActive, let pipeline else {
        return "Tap to start"
    }
    switch pipeline.state {
    case .listening: return "Recording..."
    case .processing: return "Thinking..."
    case .speaking: return "AI speaking"
    case .idle: return "Tap to resume"
    }
}
```

- Add the new red/green colors to `DesignTokens.swift`:

```swift
static let recordingRed = Color(hex: 0xDC3545)
static let speakingGreen = Color(hex: 0x28A745)
```

**Acceptance Criteria:**
- [x] Mic button is solid RED when recording
- [x]Mic button is ORANGE when paused/processing
- [x]Mic button is GREEN when AI is speaking
- [x]Mic button is terracotta when idle (session not started)
- [x]Text label below mic shows current state
- [x]Colors added to `DesignTokens.swift` as `Theme.recordingRed` and `Theme.speakingGreen`

#### Issue 4: Pipeline errors never rendered

**File:** `Lifehug/Views/DailyQuestionView.swift`

**Current:** `pipeline?.error` is set but never displayed in the view body.

**Fix:** Add an error toast that appears when `pipeline?.error` is non-nil:

```swift
// In voiceSessionContentArea, above the Done & Save button:
if let errorMsg = pipeline?.error {
    Text(errorMsg)
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Theme.mutedRose))
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            // Auto-dismiss after 3 seconds
            Task {
                try? await Task.sleep(for: .seconds(3))
                pipeline?.error = nil
            }
        }
}
```

**Acceptance Criteria:**
- [x]Error messages appear as a toast/capsule above the Done & Save button
- [x]Auto-dismiss after 3 seconds
- [x]Animated in/out

#### Issue 5: No LLM loading indicator during voice session

**File:** `Lifehug/Views/DailyQuestionView.swift`

**Current:** LLM loads in background after mic starts. If user speaks before model is ready, response is delayed with no explanation.

**Fix:** Show a subtle "Preparing AI..." indicator when `!llmService.isLoaded && voiceSessionActive`:

```swift
// In voiceSessionContentArea, below the question:
if voiceSessionActive && !llmService.isLoaded {
    HStack(spacing: 6) {
        ProgressView().controlSize(.small).tint(Theme.terracotta)
        Text("Preparing AI responses...")
            .font(.caption)
            .foregroundStyle(Theme.walnut)
    }
    .padding(.horizontal, 16)
    .transition(.opacity)
}
```

**Acceptance Criteria:**
- [x]"Preparing AI responses..." shown with spinner while LLM loads
- [x]Disappears once `llmService.isLoaded` becomes true
- [x]Does not block mic usage

---

### Phase 2: Save & Navigation Flow (P1 — Issues 2, 3, 6)

**Goal:** Make save actions clear and navigation discoverable.

#### Issue 2: Double-tap to navigate is undiscoverable

**File:** `Lifehug/Views/DailyQuestionView.swift:322-324`

**Current:** Double-tap on mic opens ConversationView. No hint exists.

**Fix:** Remove the double-tap gesture. Add an explicit "View Conversation" text button that appears when `session.conversationTurns.count > 0`:

```swift
// In the VStack with micButton and typeInsteadButton, add conditionally:
if !session.conversationTurns.isEmpty && !voiceSessionActive {
    Button {
        navigateToConversation = true
    } label: {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 14, weight: .medium))
            Text("View Conversation")
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(Theme.terracotta)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
    .buttonStyle(.plain)
}
```

**Acceptance Criteria:**
- [x]Double-tap gesture removed from mic button
- [x]"View Conversation" button appears when turns exist and voice session is not active
- [x]Tapping navigates to ConversationView

#### Issue 3: Done & Save button lacks loading state

**File:** `Lifehug/Views/DailyQuestionView.swift:182-196`

**Current:** Button disabled during save but shows no visual change.

**Fix:** Show a ProgressView inside the button when `isSaving`:

```swift
Button {
    Task { await endVoiceSessionAndSave() }
} label: {
    Group {
        if isSaving {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        } else {
            Text("Done & Save")
                .font(.subheadline.weight(.semibold))
        }
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 32)
    .padding(.vertical, 12)
    .background(
        Capsule()
            .fill(isSaving ? Theme.terracotta.opacity(0.6) : Theme.terracotta)
    )
}
.disabled(session.conversationTurns.isEmpty || isSaving)
```

**Acceptance Criteria:**
- [x]Button shows spinner while saving
- [x]Button background slightly dimmed during save
- [x]Still disabled when no turns or already saving

#### Issue 6: Saved overlay blocks interaction without dismiss

**File:** `Lifehug/Views/DailyQuestionView.swift:429-449`

**Current:** 1.5-second forced wait. No tap-to-dismiss.

**Fix:** Add `.onTapGesture` to dismiss immediately:

```swift
private var savedOverlay: some View {
    ZStack {
        Color.black.opacity(0.3).ignoresSafeArea()
            .onTapGesture { dismissSavedOverlay() }
        VStack(spacing: 16) {
            // ... existing content ...
        }
        .padding(32)
        .background(...)
        .onTapGesture { dismissSavedOverlay() }
    }
    .transition(.opacity)
}

private func dismissSavedOverlay() {
    withAnimation(.easeOut(duration: 0.3)) {
        showSavedConfirmation = false
    }
}
```

Keep the 1.5s auto-dismiss as fallback.

**Acceptance Criteria:**
- [x]Tapping anywhere dismisses the overlay immediately
- [x]Auto-dismiss at 1.5s still works as fallback
- [x]No crash if user taps during the auto-dismiss timer

---

### Phase 3: Onboarding & Navigation Polish (P2 — Issues 7, 8, 9, 10, 13, 14)

#### Issue 7: Onboarding has no back button

**File:** `Lifehug/Views/OnboardingView.swift`

**Fix:** Add a "Back" button above or next to the continue button when step != .welcome:

```swift
if step != .welcome {
    Button {
        handleBack()
    } label: {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left")
            Text("Back")
        }
        .font(.subheadline)
        .foregroundStyle(Theme.walnut)
    }
    .padding(.bottom, 8)
}
```

Add `handleBack()` method that decrements the step.

- [x]Back button visible on steps 2-5
- [x]Navigates to previous step
- [x]Not shown on welcome step

#### Issue 8: Onboarding lacks progress dots

**File:** `Lifehug/Views/OnboardingView.swift`

**Fix:** Add step indicator dots at the top:

```swift
HStack(spacing: 8) {
    ForEach(Array(OnboardingStep.allCases.enumerated()), id: \.offset) { index, s in
        Circle()
            .fill(s == step ? Theme.terracotta : Theme.warmGray.opacity(0.3))
            .frame(width: 8, height: 8)
    }
}
.padding(.top, 16)
```

- [x]5 dots shown at top of onboarding
- [x]Current step dot is terracotta, others are gray
- [x]Dots animate on step change

#### Issue 9: Question text change needs animation

**File:** `Lifehug/Views/DailyQuestionView.swift`

**Fix:** Add `.id(session.currentQuestion?.id)` and `.transition(.opacity)` to the question content:

```swift
questionContent
    .id(session.currentQuestion?.id)
    .transition(.opacity)
    .animation(.easeInOut(duration: 0.4), value: session.currentQuestion?.id)
```

- [x]Question text cross-fades when a new question loads after save

#### Issue 10: Tab bar icons could be more meaningful

**File:** `Lifehug/App/LifehugApp.swift:88-103`

**Fix:** Update tab icons:
- Today: `quote.bubble.fill` (conversation/question)
- Coverage: `chart.bar.fill` (keep — it works)
- Answers: `book.fill` (keep — it works)
- Settings: `gearshape.fill` (keep — it works)

- [x]Today tab icon changed to `quote.bubble.fill`

#### Issue 13: No "Skip Question" action

**File:** `Lifehug/Views/DailyQuestionView.swift`

**Fix:** Add a "Skip" button next to or below the question text:

```swift
Button {
    skipCurrentQuestion()
} label: {
    Text("Skip this question")
        .font(.caption)
        .foregroundStyle(Theme.softGray)
}

private func skipCurrentQuestion() {
    if let next = RotationEngine.pickNextQuestion(
        questions: questions,
        categories: categories,
        rotation: rotationState,
        excluding: session.currentQuestion?.id
    ) {
        withAnimation(.easeInOut(duration: 0.4)) {
            session.currentQuestion = next
        }
    }
}
```

Note: May need to add `excluding` parameter to `RotationEngine.pickNextQuestion` or simply pick next in sequence.

- [x]"Skip this question" link appears below the question
- [x]Loads a different question without marking the skipped one as answered
- [x]Styled subtly (caption, soft gray) so it doesn't compete with mic button

#### Issue 14: Coverage "Answer" button doesn't set correct question

**File:** `Lifehug/Views/CoverageView.swift:219-220`

**Fix:** Pass the selected question to `SessionState.currentQuestion` before switching tabs:

```swift
Button {
    // Set the specific question before navigating
    if let sessionState = /* get from environment */ {
        sessionState.currentQuestion = question
    }
    onAnswer?(question)
    dismiss()
} label: { ... }
```

This requires threading `SessionState` through the environment into `CategoryDetailSheet`.

- [x]Tapping "Answer" on a specific question in Coverage sets that question as active
- [x]Switching to Today tab shows the selected question

---

### Phase 4: Consistency & Interaction Polish (P2 — Issues 11, 12, 15, 16)

#### Issue 11: Chat bubbles have fixed 280pt max-width

**File:** `Lifehug/Views/ConversationView.swift:182`

**Fix:** Use a proportional width:

```swift
.frame(maxWidth: UIScreen.main.bounds.width * 0.72, alignment: ...)
```

- [x]Chat bubbles scale proportionally on larger devices

#### Issue 12: Silence Timeout slider → discrete Picker

**File:** `Lifehug/Views/SettingsView.swift:341-363`

**Fix:** Replace the Slider with a Picker:

```swift
private let timeoutOptions: [(String, Double)] = [
    ("Off", 0), ("3s", 3), ("5s", 5), ("10s", 10), ("15s", 15)
]

Picker("Silence Timeout", selection: $silenceTimeout) {
    ForEach(timeoutOptions, id: \.1) { label, value in
        Text(label).tag(value)
    }
}
.foregroundStyle(Theme.warmCharcoal)
```

- [x]Slider replaced with Picker showing 5 discrete options
- [x]"Off" option clearly labeled
- [x]Value persists correctly via StorageService

#### Issue 15: Answer list separators don't match theme

**File:** `Lifehug/Views/AnswersBrowserView.swift:87-103`

**Fix:** Add `.listRowSeparatorTint(Theme.warmGray.opacity(0.15))` to each section.

- [x]Separators use warm gray tint matching the cream aesthetic

#### Issue 16: ConversationView voice mode waits for model load

**File:** `Lifehug/Views/ConversationView.swift:374-378`

**Fix:** Mirror the `DailyQuestionView` approach — start mic immediately, load model in background:

```swift
private func toggleVoiceMode() {
    if !voiceMode {
        voiceMode = true

        // Create pipeline and start listening IMMEDIATELY
        let p = VoicePipeline(...)
        p.autoReopenMic = true
        // ... wire callbacks ...
        pipeline = p
        p.startListening()  // Start mic NOW

        // Load model in background
        if !llmService.isLoaded {
            voiceModeTask = Task { try? await llmService.loadModel() }
        }
    } else { ... }
}
```

- [x]Mic starts immediately in ConversationView voice mode
- [x]LLM loads in background without blocking mic
- [x]Matches DailyQuestionView behavior

---

### Phase 5: Polish & Accessibility (P3 — Issues 17-25)

#### Issue 17: No haptic on save success

**Files:** `DailyQuestionView.swift`, `ConversationView.swift`

**Fix:** Add `UINotificationFeedbackGenerator().notificationOccurred(.success)` when save completes.

- [x]Success haptic fires on save

#### Issue 18: Launch "Ready" state is anticlimactic

**File:** `Lifehug/Views/LaunchView.swift:158-179`

**Fix:** Add app name text and a gentle scale animation to the checkmark:

```swift
Text("Lifehug")
    .font(Theme.displayFont)
    .foregroundStyle(Theme.walnut)
    .transition(.opacity)
```

- [x]"Lifehug" text appears with checkmark on ready state

#### Issue 19: AnswerDetailView uses `.body` not `Theme.bodySerifFont`

**File:** `Lifehug/Views/AnswersBrowserView.swift:599`

**Fix:** Change `.font(.body)` to `.font(Theme.bodySerifFont)`.

- [x]Answer detail text uses serif font

#### Issue 20: DateFormatter created on every render

**File:** `Lifehug/Views/AnswersBrowserView.swift:273-278` and `:690-695`

**Fix:** Make it a `static let`:

```swift
private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
}()
```

- [x]DateFormatter is static, not re-created per cell

#### Issue 21: No empty state for ConversationView

**File:** `Lifehug/Views/ConversationView.swift`

**Fix:** When `session.conversationTurns.isEmpty` and not `isThinking`, show:

```swift
Text("Share what comes to mind — speak or type below.")
    .font(Theme.bodySerifFont)
    .foregroundStyle(Theme.softGray)
    .multilineTextAlignment(.center)
    .padding(32)
```

- [x]Empty state text shown when no conversation turns exist

#### Issue 22: Book TOC header warmth

**File:** `Lifehug/Views/AnswersBrowserView.swift:147-159`

**Fix:** Add a subtle decorative element — e.g., a thin terracotta divider line below the header:

```swift
Rectangle()
    .fill(Theme.terracotta.opacity(0.3))
    .frame(height: 1)
    .padding(.horizontal, 40)
```

- [x]Book TOC header has a warm decorative divider

#### Issue 23: Segmented control looks stock iOS

**Note:** Already styled via `UISegmentedControl.appearance()` in `LifehugApp.init()`. The selected tint is terracotta and text colors are set. This is acceptable as-is. **Skip** — low ROI for a custom implementation.

#### Issue 24: Missing accessibility labels

**Files:** Multiple views

**Fix:** Add `accessibilityLabel` to:
- Book chapter rows in `AnswersBrowserView`
- Answer rows in `AnswersBrowserView`
- "Type instead" button in `DailyQuestionView`
- "Skip" button (new, Issue 13)
- Done & Save button

- [x]All interactive elements have descriptive accessibility labels

#### Issue 25: No pull-to-refresh on Answers/Coverage

**Files:** `AnswersBrowserView.swift`, `CoverageView.swift`

**Fix:** Add `.refreshable` modifier:

```swift
// AnswersBrowserView answersList
.refreshable { loadAnswers() }

// CoverageView ScrollView
.refreshable { loadData() }
```

- [x]Pull-to-refresh works on Answers tab
- [x]Pull-to-refresh works on Coverage tab

---

## Parallelization Strategy

These phases have minimal dependencies and can be worked by parallel agents:

| Phase | Issues | Dependencies | Agent |
|-------|--------|-------------|-------|
| Phase 1 | 1, 4, 5 | None — DailyQuestionView + DesignTokens | Agent A |
| Phase 2 | 2, 3, 6 | None — DailyQuestionView (different sections) | Agent B |
| Phase 3 | 7, 8, 9, 10, 13, 14 | Onboarding + CoverageView + LifehugApp | Agent C |
| Phase 4 | 11, 12, 15, 16 | ConversationView + SettingsView + AnswersBrowser | Agent D |
| Phase 5 | 17-25 | Various files, small changes | Agent E |

**Conflict risk:** Phases 1 and 2 both touch `DailyQuestionView.swift` but in different sections (mic button vs save/navigation). Can be merged sequentially or use careful section-based editing.

## Acceptance Criteria (Global)

- [x]All 25 issues addressed
- [x]Mic button states are immediately obvious (red/orange/green/terracotta)
- [x]Text labels confirm mic state for users
- [x]All saves show loading spinners
- [x]Errors are visible and auto-dismiss
- [x]No regressions in voice pipeline behavior
- [x]App builds and runs on device without crashes
- [x]Design tokens used consistently (no hardcoded colors)

## Spec Flow Analysis — Key Findings

The following gaps were identified by spec flow analysis and incorporated into the plan:

### Resolved Design Decisions

1. **"Paused" is not a `PipelineState`** — There is no `.paused` case in the enum. "Paused" means `voiceSessionActive == true && pipeline.state == .idle`. The mic color mapping in Issue 1 handles this as a UI-only distinction (orange for `.idle` during active session, terracotta when session not started).

2. **Issue 14 architecture** — `CoverageView` needs `SessionState` injected via `@Environment`. Thread it from `LifehugApp` → `ContentView` → `CoverageView` → `CategoryDetailSheet`. Guard against overwriting an in-progress session by checking `session.conversationTurns.isEmpty` before setting a new question.

3. **Issue 13 edge cases** — "Skip" button only visible when `!voiceSessionActive && session.conversationTurns.isEmpty`. This prevents data loss from skipping mid-conversation. Skipped questions are NOT marked as answered — they stay in the rotation pool.

4. **Issue 6 + Issue 3 interaction** — Save flow sequence: (1) tap Done & Save → button shows spinner (Issue 3), (2) save completes → overlay appears (Issue 6), (3) overlay auto-dismisses after 1.5s OR user taps to dismiss. On save failure: show error-specific overlay with retry option instead of the success overlay.

5. **ConversationView save error bug** — Currently shows "Answer Saved" overlay even on failure (line 528-530). Fix as part of Issue 3: show a different error overlay with retry button when save fails.

6. **Issue 1 accessibility** — The `micStateLabel` text serves double duty: visible label AND `accessibilityLabel` content. Update the mic button's `accessibilityLabel` to use `micStateLabel` dynamically (Issue 24 coordination).

7. **Issue 16 race condition** — If user speaks before LLM loads, `processUserInput` will call `llmService.streamResponse` which will throw. The pipeline's error handler catches this and sets `pipeline.error`. With Issue 4's error toast now rendering errors, the user sees feedback. Acceptable UX.

### Parallelization Refinement

**Phases 1 and 2 should run sequentially** (not in parallel) because both heavily modify `DailyQuestionView.swift`. All other phases can run in parallel.

Recommended execution order:
1. **Phase 1** first (mic button + error toast + LLM indicator)
2. **Phase 2** second (save flow + navigation — same file, different sections)
3. **Phases 3, 4, 5** in parallel (different files)

## Technical Considerations

- **No new dependencies** — all fixes use native SwiftUI and existing design tokens
- **Theme.recordingRed and Theme.speakingGreen** — new colors that don't match the warm palette but are deliberately bold for clarity (traffic light metaphor)
- **RotationEngine.pickNextQuestion excluding** — Issue 13 may need a minor parameter addition to exclude current question
- **SessionState threading** — Issue 14 requires `@Environment(SessionState.self)` in `CategoryDetailSheet`
- **ConversationView save error** — Fix the misleading "Answer Saved" overlay shown on failure (existing bug, fix alongside Issue 3)

## Sources & References

- Design tokens: `Lifehug/App/DesignTokens.swift`
- Main view: `Lifehug/Views/DailyQuestionView.swift`
- Voice pipeline: `Lifehug/Pipeline/VoicePipeline.swift`
- Onboarding: `Lifehug/Views/OnboardingView.swift`
- Conversation: `Lifehug/Views/ConversationView.swift`
- Answers/Book: `Lifehug/Views/AnswersBrowserView.swift`
- Coverage: `Lifehug/Views/CoverageView.swift`
- Settings: `Lifehug/Views/SettingsView.swift`
- App entry: `Lifehug/App/LifehugApp.swift`
- Launch: `Lifehug/Views/LaunchView.swift`
