---
title: "feat: Voice-First Conversation UX & Book Tab"
type: feat
date: 2026-03-07
---

## Enhancement Summary

**Deepened on:** 2026-03-07
**Sections enhanced:** 5 phases + architecture + UX
**Research agents used:** SFSpeech specialist, Audio session expert, TTS voice quality, Voice command detection, Chapter generation, Architecture review, Performance profiling, Security audit, Simplicity review, UI/UX driving-safe design

### Key Improvements

1. **Simplicity overhaul** — Removed VoiceSessionState (reuse SessionState), removed VoiceConversationView (extend DailyQuestionView with voice mode toggle), simplified BookService to static functions
2. **TTSService completion gap identified** — `speak()` doesn't await completion; pipeline needs `onAllSpeechFinished` callback or CheckedContinuation wrapper to know when TTS is done before resuming listening
3. **Security fix** — Must guard `supportsOnDeviceRecognition` explicitly; current code silently falls back to server-based recognition (privacy violation for memoir content)
4. **Multi-pass chapter generation** — Single-pass with 1B model produces incoherent text; use 3-pass pipeline (extract key details, outline, flesh out per-section)
5. **Driving-safe touch targets** — 100x100pt minimum for all interactive elements, state-specific colors, breathing animation instead of real-time waveform

### New Considerations Discovered

- iOS 26 `SpeechAnalyzer` API eliminates the 60s limit entirely (future migration target)
- AVAudioSession must stay in `.playAndRecord` with `.default` mode throughout (not `.measurement`); stop AVAudioEngine before TTS playback
- Memory budget is tight: ~960MB-1.14GB total; monitor with `os_proc_available_memory()` at 200MB threshold; unload model when backgrounded
- Use "that's my answer" as termination phrase instead of "I'm done" (fewer false positives); require trailing position + stability across 2 consecutive partials

---

# Voice-First Conversation UX & Book Tab

## Overview

Two features that transform Lifehug from a "record-then-type" app into a fully voice-driven memoir capture tool with a living book output:

1. **Voice-First Conversation** — Replace the text-based conversation flow with a hands-free voice loop (listen -> respond via TTS -> listen again). Key use case: capturing stories while driving or walking.
2. **Book Tab** — A new tab that auto-generates a table of contents from question categories and fills in chapter drafts as answers accumulate.

## Problem Statement

### Voice UX Issues (Current State)

1. **Silence timer cuts users off after 1.5 seconds** (`STTService.swift:22` -- `silenceTimeout: 1.5`). Users feel "cut off" mid-thought when they pause to think. This is the #1 complaint.
2. **Conversation mode is text-only** -- After recording, the app navigates to `ConversationView` which shows a text input bar and chat bubbles. There is no voice output. The user must type follow-up responses.
3. **VoicePipeline exists but is unused** -- `VoicePipeline.swift` has a full STT->LLM->TTS state machine with sentence buffering, but `DailyQuestionView` bypasses it entirely.
4. **No hands-free operation** -- Cannot use the app while driving/walking because text input requires looking at the screen.

### Book Tab (Missing Feature)

- Users answer questions across categories (A-E main, F-J project, K+ spotlight) but there's no way to see how those answers form a narrative.
- The Coverage tab shows progress percentages, but not content.
- Users don't understand how their answers will "turn into a book."

## Proposed Solution

### Feature 1: Voice-First Conversation

**Extend `DailyQuestionView` with a voice mode toggle powered by the existing `VoicePipeline`.**

> **Simplicity note:** Do NOT create a separate `VoiceConversationView`. Extend `DailyQuestionView` to show voice conversation state inline. This avoids duplicating question display, navigation, and save logic. The existing `ConversationView` remains as the text fallback.

#### UX Flow

```
DailyQuestionView
  Question displayed: "Tell me about where you grew up"

  [ Large Mic Button -- tap to start voice mode ]
  [ "Type instead" link below -> navigates to ConversationView ]

      | Tap mic -> enters voice mode inline
      v

  Voice Mode (same view, different state)
  -----------------------------------------------
  State: LISTENING
    Breathing circle animation (terracotta pulsing)
    Live transcript shown as subtitle text
    [ Stop Button -- 100x100pt, centered ]
    [ "Switch to text" -- small link ]

  User taps Stop or says "that's my answer"
      |
      v
  State: PROCESSING
    Circle color shifts to warmGray
    "Thinking..." subtitle
      |
      v
  State: SPEAKING
    Circle color shifts to sageGreen
    LLM response spoken via TTS
    Response text shown as subtitle
    [ Interrupt button -- tap to speak again ]
      |
      v
  State: LISTENING (auto-resumes after TTS finishes)
    "Add more, or say 'that's my answer'"

      User speaks more         User says "that's my answer"
      -> back to PROCESSING    or taps End Session
                                     |
                                     v
                               Save & show confirmation
                               Return to DailyQuestionView idle state
```

#### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Silence handling | **No auto-stop from silence**. User must tap Stop or say termination phrase. | Memoir storytelling involves long pauses for thinking. 1.5s is far too short. |
| Recording limit | **Remove the silence timer entirely**. Chain SFSpeech requests at ~60s limit. | SFSpeech has a ~60s limit per request. Chain requests to achieve unlimited duration. |
| After TTS finishes | **Auto-resume listening** | Hands-free: user doesn't need to tap anything to continue talking |
| Text fallback | **"Switch to text" button** transitions to current `ConversationView` | Some users prefer typing; don't remove the option |
| End session | **Tap "End Session" button OR say "that's my answer"** | Hands-free needs a voice command to stop. "That's my answer" has fewer false positives than "I'm done". |
| Default mode | **Voice is default** | Core UX is hands-free memoir capture |
| View architecture | **Extend DailyQuestionView** with voice mode toggle, don't create new view | Avoids duplicating question display, navigation, and save logic |
| Touch targets | **100x100pt minimum** for all buttons in voice mode | Driving-safe: must be hittable without looking |
| State colors | Terracotta=idle/listening, warmGray=processing, sageGreen=speaking | Peripheral-vision-friendly state indication |
| Animation | **Breathing circle** not real-time waveform | Simpler, less distracting, lower CPU, works at a glance |

### Feature 2: Book Tab

**A new tab that generates a living table of contents and chapter drafts from accumulated answers.**

#### UX Flow

```
Tab Bar: Today | Coverage | Book | Answers | Settings

  "Your Book"

  Progress: 3 of 12 chapters started
  [----________________] 25%

  Table of Contents

  1. Origins .......................... 2 answers  [->]
  2. Becoming ......................... 0 answers  [locked]
  3. Relationships & People ........... 1 answer   [->]
  4. Purpose & Calling ................ 0 answers  [locked]
  5. Reflection & Wisdom .............. 0 answers  [locked]
  --- Your Projects ---
  6. The Founding Story ............... 3 answers  [->]
  7. Building the Product ............. 0 answers  [locked]
  --- Spotlights ---
  8. Spotlight: Dad ................... 2 answers  [->]

  Tap a chapter with answers to read the draft.
  "Check back soon" shown for chapters without
  enough material (< 3 answers).

Chapter Detail View (e.g., "Origins")

  Chapter 1: Origins
  Based on 2 answers

  [LLM-generated chapter draft woven from the user's
   answers in this category. Written in the user's voice,
   maintaining their phrasing and emotional tone.]

  -- Source Answers --
  * A1: What's your earliest memory? (Mar 6)
  * A3: Family's financial situation (Mar 7)

  [ Regenerate Draft ]  [ Share ]
```

#### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Chapter mapping | **1 chapter per category** (A->"Origins", B->"Becoming", etc.) | Direct mapping from existing category system |
| Minimum answers | **3 answers in a category** before generating a draft | Need enough material for a coherent narrative |
| Draft generation | **On-demand via LLM** when user taps into a chapter | Don't waste compute pre-generating; generate when viewed |
| Draft caching | **Cache generated drafts to disk**, invalidate when new answers added to that category | Avoid re-generating on every view |
| Locked chapters | Show chapter title + "Check back soon -- answer more questions in this category" | User understands what's coming |
| Regenerate | Button to re-generate with updated/additional answers | User can refresh after answering more |
| Generation strategy | **Multi-pass pipeline** (extract -> outline -> flesh out) | 1B model can't coherently generate a chapter in one pass |

## Technical Approach

### Phase 1: Fix Recording Duration (Critical Bug Fix)

**Files to modify:**

- [ ] `STTService.swift` -- Remove silence timer, implement continuous recognition with auto-restart

**Changes:**

1. **Remove `silenceTimeout` and `silenceTimer`** -- No more auto-cutoff from silence
2. **Implement recognition request chaining** -- When SFSpeech hits its ~60s limit, automatically start a new recognition request and append to accumulated transcript
3. **User-controlled stop only** -- Recording stops when `stopListening()` is called (from button tap or voice command)
4. **Guard on-device recognition** -- Explicitly check `supportsOnDeviceRecognition` and refuse to fall back to server-based (privacy requirement for memoir content)

```swift
// STTService.swift -- Key changes

// REMOVE these:
// private var silenceTimer: Timer?
// private let silenceTimeout: TimeInterval = 1.5
// private func resetSilenceTimer() { ... }

// ADD: Auto-restart on recognition task completion (not error/cancellation)
// In the recognitionTask result handler:
if result.isFinal {
    // SFSpeech hit its limit -- restart seamlessly
    accumulatedTranscript = currentTranscript
    continuation?.yield(currentTranscript) // Update UI with latest
    restartRecognition() // Start new request, append to accumulated
}

// ADD: On-device guard (privacy requirement)
guard recognizer.supportsOnDeviceRecognition else {
    throw STTError.onDeviceUnavailable
    // Do NOT silently fall back to server-based recognition
}
request.requiresOnDeviceRecognition = true
```

#### Research Insights

**SFSpeech Request Chaining (iOS 18):**
- When `result.isFinal` fires at ~60s, the recognition request is done. You must create a NEW `SFSpeechAudioBufferRecognitionRequest`, install it on the SAME audio engine tap, and start a new `recognitionTask`.
- Critical: Do NOT stop/restart the AVAudioEngine -- just swap the request object. Stopping the engine causes an audible gap.
- Keep the accumulated transcript in a property; prepend it to new results from the chained request.
- On the new request's first partial result, there may be a brief overlap with the last few words of the previous request. Use word count comparison to avoid duplication.

**iOS 26 Future Migration:**
- `SpeechAnalyzer` (WWDC 2025) is fully async/await, eliminates the 60s limit entirely, and supports continuous recognition natively. When the deployment target moves to iOS 26, replace the chaining logic with a single `SpeechAnalyzer` session.

**Security: On-Device Requirement:**
- The current code has `if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }` which SILENTLY falls back to server-based when on-device isn't available. For memoir content, this is a privacy violation. Instead, REQUIRE on-device and throw an error if unavailable.

### Phase 2: Voice Conversation Loop

> **Simplicity: Do NOT create `VoiceConversationView` or `VoiceSessionState`.** Extend `DailyQuestionView` with a voice mode state and reuse existing `SessionState`.

**Files to modify:**

- [ ] `DailyQuestionView.swift` -- Add voice mode toggle, show voice state indicator, action buttons per pipeline state
- [ ] `VoicePipeline.swift` -- Wire up to be used by DailyQuestionView, fix TTS completion gap, add auto-resume after TTS
- [ ] `TTSService.swift` -- Add completion callback so pipeline knows when speech finishes
- [ ] `SessionState.swift` -- Add `voiceMode: Bool` flag (minimal addition to existing state)
- [ ] `ConversationView.swift` -- Keep as-is for text fallback mode

**TTSService Completion Fix (Critical):**

```swift
// TTSService.swift -- Current problem: speak() is async but doesn't await completion
// It just appends to the sentence queue and returns immediately.
// Pipeline has no way to know when TTS is done speaking.

// FIX: Add completion callback
var onAllSpeechFinished: (() -> Void)?

// In AVSpeechSynthesizerDelegate:
func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    if sentenceQueue.isEmpty && !synthesizer.isSpeaking {
        onAllSpeechFinished?()
    }
}
```

**DailyQuestionView Voice Mode:**

```swift
// DailyQuestionView.swift additions
@State private var pipeline: VoicePipeline?
@State private var isVoiceMode = false

var body: some View {
    // ... existing question display ...

    if isVoiceMode {
        // Voice state indicator (breathing circle)
        voiceStateIndicator

        // Live transcript subtitle
        if !session.draftTranscript.isEmpty {
            Text(session.draftTranscript)
                .font(Theme.bodySerifFont)
                .foregroundStyle(Theme.warmGray)
        }

        // Action buttons per pipeline state
        voiceActionButtons
    } else {
        // Original mic button + "Type instead" link
        micButton
    }
}
```

**VoicePipeline Auto-Resume:**

```swift
// After TTS finishes speaking, auto-resume listening:
ttsService.onAllSpeechFinished = { [weak self] in
    Task { @MainActor in
        guard let self, self.state == .speaking else { return }
        // Stop the audio engine input before TTS, restart for STT
        self.transition(to: .listening)
    }
}
```

#### Research Insights

**Audio Session Management:**
- Use `.playAndRecord` with `.default` mode (NOT `.measurement`) throughout the entire voice session. `.measurement` disables automatic gain control which makes TTS sound bad.
- Options: `.defaultToSpeaker`, `.allowBluetooth`, `.allowBluetoothA2DP`. Using `.allowBluetoothHFP` alone locks Bluetooth to HFP profile (mono, low quality). Add `.allowBluetoothA2DP` for stereo TTS output through AirPods.
- Before TTS playback: stop the AVAudioEngine's input tap (but don't deactivate the audio session). After TTS finishes: re-install the tap and restart the engine for the next STT segment.
- Handle `AVAudioSession.interruptionNotification` to pause/resume gracefully during phone calls or Siri.

**TTS Voice Quality Tiers:**
- Default voices: fast, low quality. Enhanced voices: better, download required. Premium voices (iOS 16+): near-human, large download (~100-500MB).
- Programmatic selection: `AVSpeechSynthesisVoice.speechVoices().filter { $0.quality == .enhanced }` then pick by language.
- For MVP, use enhanced if available, fall back to default. Don't bundle premium (memory budget too tight).
- Verify selected voice is on-device (privacy): check `voice.voiceURI` doesn't start with `com.apple.speech.synthesis.voice.network`.

**Memory Budget:**
- Total budget ~960MB-1.14GB on iPhone 15/16 (with increased-memory-limit entitlement).
- Breakdown: ~713MB model + 100-200MB KV cache + 50-80MB STT + 20-30MB TTS + 80-120MB app.
- Monitor with `os_proc_available_memory()` at 200MB threshold.
- Cap KV cache at 2048 tokens in LLMService.
- When backgrounded: unload model immediately to free ~700MB.

**UI/UX for Driving:**
- 100x100pt touch targets minimum for all interactive elements.
- State-specific colors visible in peripheral vision: terracotta (idle), softCoral (listening), warmGray (processing), sageGreen (speaking).
- Breathing circle animation (scale 1.0->1.15->1.0, 2s period) instead of real-time waveform. Lower CPU, works at a glance.
- 250ms cross-dissolve transitions between states (not instant, not slow).
- Show transcript in large, high-contrast font (20pt+) for quick glances.

### Phase 3: "That's My Answer" Voice Command

**Files to modify:**

- [ ] `VoicePipeline.swift` -- Detect termination phrases in transcript

**Implementation:**

```swift
// Use trailing-position check on partial results
// Wait for stability across 2 consecutive partials to avoid false positives
private let terminationPhrases = ["that's my answer", "that's all", "end session"]
private var lastPartialWithTermination: String?

func checkForTermination(_ transcript: String) -> Bool {
    let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let hasTermination = terminationPhrases.contains { lower.hasSuffix($0) }

    if hasTermination {
        if lastPartialWithTermination == lower {
            // Same termination phrase in 2 consecutive partials -- confirmed
            lastPartialWithTermination = nil
            return true
        }
        lastPartialWithTermination = lower
    } else {
        lastPartialWithTermination = nil
    }
    return false
}
```

#### Research Insights

**Why "that's my answer" instead of "I'm done":**
- "I'm done" has high false positive rate in memoir storytelling ("I'm done with that job", "when I'm done cooking").
- "That's my answer" is unambiguous in context -- people don't naturally say this mid-story.
- "That's all" and "end session" as alternatives.
- Trailing-position check: the phrase must be at the END of the current transcript, not embedded in the middle of a sentence.
- 2-consecutive-partial stability: SFSpeech partial results can flicker. Requiring the same termination phrase in 2 consecutive partials eliminates false triggers from momentary transcription artifacts.

**Strip termination phrase from saved answer:**
- When "that's my answer" is detected, remove it from the final transcript before saving. The user doesn't want their memoir to contain "that's my answer" at the end of every answer.

### Phase 4: Book Tab

> **Simplicity: Skip `BookService` as a full `@Observable` class.** Use a static function for chapter generation and keep state in the view. The only persistence needed is draft caching (a simple file write).

**New files:**

- [ ] `BookView.swift` -- Main book tab with table of contents
- [ ] `ChapterDetailView.swift` -- Shows generated chapter draft

**Files to modify:**

- [ ] `LifehugApp.swift` -- Add Book tab to TabView
- [ ] `StorageService.swift` -- Add `draftsDirectory` and chapter draft read/write helpers

**LifehugApp.swift TabView update:**

```swift
TabView(selection: $selectedTab) {
    Tab("Today", systemImage: "sun.max.fill", value: 0) {
        DailyQuestionView()
    }
    Tab("Coverage", systemImage: "chart.bar.fill", value: 1) {
        CoverageView()
    }
    Tab("Book", systemImage: "text.book.closed.fill", value: 2) {
        BookView()
    }
    Tab("Answers", systemImage: "archivebox.fill", value: 3) {
        AnswersBrowserView()
    }
    Tab("Settings", systemImage: "gearshape.fill", value: 4) {
        SettingsView()
    }
}
```

**Chapter generation (static function, not a service):**

```swift
// In ChapterDetailView or a simple ChapterGenerator enum

enum ChapterGenerator {
    /// Multi-pass chapter generation for 1B model
    /// Pass 1: Extract key details from answers (bullets)
    /// Pass 2: Create outline from bullets
    /// Pass 3: Flesh out each outline section
    static func generate(
        category: Category,
        answers: [Answer],
        userName: String,
        llm: LLMService
    ) async throws -> String {
        // Pass 1: Extract
        let extractPrompt = """
        Extract the key facts, moments, and emotions from these interview answers about "\(category.name)".
        Return as bullet points. Be specific -- include names, places, dates mentioned.

        \(answers.map { "Q: \($0.questionText)\nA: \($0.answerText)" }.joined(separator: "\n\n"))
        """
        let bullets = try await llm.respond(to: extractPrompt)

        // Pass 2: Outline
        let outlinePrompt = """
        Create a brief chapter outline for "\(category.name)" using these key details:
        \(bullets)
        Structure: opening hook, 2-3 main sections, closing reflection.
        """
        let outline = try await llm.respond(to: outlinePrompt)

        // Pass 3: Flesh out
        let draftPrompt = """
        Write a memoir chapter called "\(category.name)" for \(userName).
        Follow this outline: \(outline)
        Use these source details: \(bullets)
        Write in first person. Use \(userName)'s own words where possible.
        Keep it authentic -- don't add facts they didn't mention.
        """
        return try await llm.respond(to: draftPrompt)
    }
}
```

**Draft caching in StorageService:**

```swift
// StorageService.swift additions
var draftsDirectory: URL {
    documentsDirectory.appendingPathComponent("drafts", isDirectory: true)
}

func readDraft(for categoryID: Character) -> (text: String, date: Date)? {
    let url = draftsDirectory.appendingPathComponent("\(categoryID)-draft.md")
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8),
          let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let date = attrs[.modificationDate] as? Date else { return nil }
    return (text, date)
}

func writeDraft(_ text: String, for categoryID: Character) throws {
    try FileManager.default.createDirectory(at: draftsDirectory, withIntermediateDirectories: true)
    let url = draftsDirectory.appendingPathComponent("\(categoryID)-draft.md")
    try text.write(to: url, atomically: true, encoding: .utf8)
}
```

#### Research Insights

**Multi-Pass Generation (Critical for 1B Model):**
- A 1B model (Llama-3.2-1B-Instruct-4bit) has a practical context window of ~2K-3K tokens for coherent output. Single-pass chapter generation with multiple answers produces rambling, repetitive text.
- 3-pass pipeline: (1) extract key details as bullets, (2) create outline from bullets, (3) flesh out each section using outline + bullets. Each pass fits within the model's sweet spot.
- ~8-12 short answers (50-100 words each) fit comfortably in the extract prompt. For categories with more answers, batch into groups of 10.
- Cache the extracted bullets -- they can be reused when regenerating (only re-run passes 2-3).
- LLM response latency: ~0.8-1.7s for 50-100 tokens on iPhone 15. Full 3-pass generation: ~5-10s total. Show a progress indicator per pass.

**maxTokens Setting:**
- Current `LLMService.maxTokens = 200` is too low for chapter generation. Pass 3 needs 500-800 tokens for a decent chapter section. Set `maxTokens` per-call rather than globally, or increase default and let shorter prompts naturally produce shorter outputs.

### Phase 5: Audio Session Management

**Files to modify:**

- [ ] `STTService.swift` -- Use `.playAndRecord` with `.default` mode
- [ ] `TTSService.swift` -- Reuse same audio session, add completion callback
- [ ] `VoicePipeline.swift` -- Manage audio engine start/stop around TTS, handle interruptions

**Critical: audio session must NOT switch categories between STT and TTS.**

```swift
// Audio session configuration -- set ONCE at voice session start:
let session = AVAudioSession.sharedInstance()
try session.setCategory(.playAndRecord, mode: .default, options: [
    .defaultToSpeaker,
    .allowBluetooth,
    .allowBluetoothA2DP
])
try session.setActive(true)

// Before TTS: stop AVAudioEngine input (don't deactivate session)
audioEngine.inputNode.removeTap(onBus: 0)
audioEngine.stop()

// After TTS finishes: reinstall tap and restart engine
audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { ... }
try audioEngine.start()
```

#### Research Insights

**Bluetooth Audio Routing:**
- `.allowBluetoothHFP` alone locks to HFP profile (mono, 8kHz) which sounds terrible for TTS. Adding `.allowBluetoothA2DP` allows stereo, high-quality output through AirPods/car speakers.
- However, A2DP is output-only. When recording starts, iOS automatically switches to HFP for mic input. This is expected and unavoidable -- the key is that TTS output through A2DP sounds good between recordings.
- Don't use `.mixWithOthers` unless there's a reason to play alongside other audio. It can cause routing confusion.

**Interruption Handling:**
- Observe `AVAudioSession.interruptionNotification`. On `.began`: pause recording and TTS, save current state. On `.ended` with `.shouldResume`: resume from last state.
- Phone calls, Siri, and other apps can trigger interruptions. The pipeline state machine handles this naturally -- transition to `.idle` on interruption began, resume to `.listening` on ended.

**CarPlay Consideration (Future):**
- Not for MVP, but the `.playAndRecord` + `.allowBluetooth` configuration is already CarPlay-compatible. A future CarPlay extension would use the same audio session setup.

## Acceptance Criteria

### Voice-First Conversation

- [ ] Recording continues until user taps Stop or says "that's my answer" -- no silence auto-cutoff
- [ ] Recording seamlessly handles SFSpeech's ~60s limit by chaining requests
- [ ] On-device speech recognition is REQUIRED (not optional fallback to server)
- [ ] After recording, LLM response is spoken via TTS (not just shown as text)
- [ ] After TTS finishes, app auto-resumes listening (hands-free loop)
- [ ] User can interrupt TTS by tapping to speak
- [ ] "Switch to text" button transitions to existing text-based ConversationView
- [ ] Full conversation (all voice turns) saved as the answer
- [ ] Works with Bluetooth audio (AirPods/car speakers)
- [ ] App handles audio interruptions gracefully (phone call, Siri)
- [ ] Touch targets are 100x100pt minimum in voice mode
- [ ] Termination phrase stripped from saved answer text
- [ ] Works when app is in foreground (no background audio requirement for MVP)

### Book Tab

- [ ] New "Book" tab appears in tab bar between Coverage and Answers
- [ ] Table of contents shows all categories as chapters, grouped by type (Main/Project/Spotlight)
- [ ] Chapters with < 3 answers show as locked with "Check back soon"
- [ ] Chapters with >= 3 answers are tappable and generate a draft on demand
- [ ] Chapter generation uses multi-pass pipeline (extract -> outline -> flesh out)
- [ ] Progress indicator shown during generation (~5-10s)
- [ ] Generated drafts are cached to disk
- [ ] Drafts are marked dirty when new answers are added to that category
- [ ] "Regenerate" button refreshes the draft
- [ ] Chapter drafts are written in the user's voice (first person, their phrasing)
- [ ] Overall progress indicator shows how many chapters are started

## Implementation Order

1. **Phase 1: Fix recording duration** -- Remove silence timer, add request chaining, guard on-device. Ship as v1.0.7.
2. **Phase 2: Voice conversation loop** -- Wire up VoicePipeline in DailyQuestionView, fix TTSService completion, add auto-resume. Ship as v1.1.0.
3. **Phase 3: Voice commands** -- "That's my answer" detection with 2-partial stability. Ship with Phase 2.
4. **Phase 4: Book tab** -- BookView, ChapterDetailView, multi-pass generation. Ship as v1.2.0.
5. **Phase 5: Audio session polish** -- Bluetooth routing, interruption handling. Ship with Phase 2.

## Dependencies & Risks

| Risk | Mitigation |
|------|------------|
| SFSpeech 60s limit causes gaps when chaining | Swap request on same engine (don't stop/restart engine); overlap detection via word count |
| AVSpeechSynthesizer sounds robotic | Use enhanced voices if available; upgrade to Kokoro in Phase 3 (currently disabled in project.yml) |
| TTSService.speak() doesn't signal completion | Add `onAllSpeechFinished` callback in AVSpeechSynthesizerDelegate |
| LLM chapter generation quality with 1B model | Multi-pass pipeline (3 passes); user can regenerate; upgrade model in future |
| Memory pressure from simultaneous STT + LLM + TTS | Monitor `os_proc_available_memory()` at 200MB; cap KV cache at 2048; unload model on background |
| Audio session conflicts between STT and TTS | Use `.playAndRecord` throughout; stop engine input before TTS, restart after |
| Silent fallback to server-based speech recognition | Guard `supportsOnDeviceRecognition`; throw error if unavailable |
| Bluetooth audio routing (HFP vs A2DP) | Use both `.allowBluetooth` + `.allowBluetoothA2DP`; accept HFP during recording |

## References

### Internal Files

- `STTService.swift` -- Speech recognition, silence timer at line 22
- `VoicePipeline.swift` -- Existing STT->LLM->TTS state machine (currently unused)
- `TTSService.swift` -- AVSpeechSynthesizer with sentence queue (missing completion callback)
- `LLMService.swift` -- MLX LLM with streaming and non-streaming response, maxTokens=200
- `ConversationView.swift` -- Current text-based conversation (becomes fallback)
- `DailyQuestionView.swift` -- Recording trigger, will be extended with voice mode
- `SessionState.swift` -- Conversation turns, draft transcript (reuse for voice, don't create new state)
- `LifehugApp.swift` -- Tab bar configuration
- `StorageService.swift` -- Answer persistence, directory structure
- `Category.swift` -- Category groups (main/project/spotlight), coverage tracking
