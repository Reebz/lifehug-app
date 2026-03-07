---
title: "feat: Lifehug iOS App — On-Device AI Memoir Writing Assistant"
type: feat
date: 2026-03-06
deepened: 2026-03-06
---

# Lifehug iOS App — On-Device AI Memoir Writing Assistant

## Overview

Build a native iOS app that delivers the full Lifehug experience — daily memoir questions, voice-based answers, AI-driven follow-up conversation — entirely on-device. The app uses MLX Swift for LLM inference, Apple's SFSpeechRecognizer for STT, and Kokoro TTS for natural-sounding voice responses. No data ever leaves the device.

The app must faithfully implement the rotation engine, question bank format, and answer file format defined in the existing Lifehug repo so that answers remain compatible with the desktop tool.

## Problem Statement

Lifehug currently runs as a CLI/chat-based tool that depends on an AI platform (OpenClaw, Claude Code, etc.) and requires a desktop environment. Most people who would benefit from capturing their life story don't sit at a computer for this — they'd do it on their phone, speaking naturally, during quiet moments. An iOS app with a voice-first UX removes the friction and makes daily story capture feel like a conversation rather than a writing exercise.

## Proposed Solution

A SwiftUI iOS app with a streaming voice pipeline (STT -> LLM -> TTS) that creates a conversational interviewing experience. The app:

1. Downloads ML models on first launch (~800MB total)
2. Runs onboarding to personalise the question bank
3. Delivers one question per day via local notification
4. Listens to spoken answers, responds conversationally via voice
5. Saves answers as markdown files compatible with the desktop tool
6. Tracks coverage and progress across categories

All inference runs on-device using MLX Swift. Zero network calls after model download.

## Technical Approach

### Architecture

```
+---------------------------------------------------------+
|                     SwiftUI Views                        |
|  Launch | Onboarding | Daily Q | Coverage | Settings    |
+---------------------------------------------------------+
|  ModelState     |  SessionState      |  AppState         |
|  (@Observable)  |  (@Observable)     |  (@Observable)    |
|  download,load  |  question,turns    |  navigation,      |
|  warmup,evicted |  transcript,draft  |  onboarding       |
+---------------------------------------------------------+
|                    VoicePipeline                          |
|  STT -> LLM -> TTS orchestration (structured concurrency)|
|  TaskGroup with explicit cancellation on state transition |
+----------+-----------+-----------+-----------------------+
|STTService| LLMService| TTSService|   RotationEngine      |
|SFSpeech  | MLX Swift | Kokoro/AV |   (port of ask.py)    |
+----------+-----------+-----------+-----------------------+
|                   StorageService                          |
|   Markdown I/O | JSON state | Model cache | File protect |
+---------------------------------------------------------+
|                    File System                            |
|  App Support (models, state)  |  Documents (answers)     |
|  NSFileProtectionComplete on all user data files          |
+---------------------------------------------------------+
```

### Research Insights: Architecture

**Split AppState into three focused @Observable classes** (architecture review finding):
- `ModelState` — owns model download status, loaded/evicted detection, warm-up lifecycle. Updated infrequently.
- `SessionState` — owns the current conversation (turns, active question, transcript). Updated rapidly during conversation.
- `AppState` — owns navigation-level state (onboarding complete, current screen). Holds references to the above.

This prevents SwiftUI re-evaluation noise (a model status change shouldn't trigger conversation view updates) and makes testing cleaner.

**SwiftUI pattern** (from Context7 SwiftUI Agent Skill):
```swift
@Observable
@MainActor
final class ModelState {
    var downloadProgress: Double = 0
    var status: ModelStatus = .notDownloaded
    var isLoaded: Bool = false
}

// Inject via environment
ContentView()
    .environment(ModelState())
    .environment(SessionState())
    .environment(AppState())
```

**VoicePipeline must use structured concurrency with explicit cancellation** (architecture review finding):
Every state transition in the pipeline (`idle -> listening -> processing -> speaking -> idle`) must cancel any active `Task` from the previous state. Use `Task` references or `TaskGroup` and call `.cancel()` on transition. This prevents:
- Orphaned LLM generation tasks producing tokens after the user interrupts
- STT continuing to process audio after the pipeline moves to `speaking`
- Memory leaks from uncancelled async work after backgrounding

### Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| LLM framework | MLX Swift (`mlx-swift-lm`) | Apple's own ML framework, optimised for Apple Silicon, active development |
| LLM model | Llama 3.2 1B 4-bit (~713MB) | Best quality-to-size ratio at ~60 TPS on iPhone 15 Pro |
| LLM conversation API | `ChatSession` from MLXLLM | Built-in multi-turn context, KV cache reuse, streaming via `streamResponse` |
| STT | SFSpeechRecognizer (on-device) | Zero additional model download, adequate for conversational input |
| TTS | Kokoro via `kokoro-ios` | Natural voice quality, 82M params, ~3.3x real-time on A17 Pro |
| TTS fallback | AVSpeechSynthesizer | Zero-download fallback if Kokoro has issues |
| Storage | Files (markdown + JSON) | Compatible with desktop Lifehug tool, visible in Files app |
| Config | JSON (not YAML) | No parser dependency needed on iOS. Diverges from desktop YAML — acceptable since config is device-local, not shared data |
| Coverage tracking | Computed on-the-fly | No persisted `coverage.json` — derive from question bank in memory (25-50 questions, sub-millisecond) |
| Min iOS | 18.0 | On-device SFSpeech more reliable, modern SwiftUI features |
| Swift | 6.0+ strict concurrency | Pipeline is heavily async — concurrency safety matters |

### Memory Budget (iPhone 15 Pro, 8GB)

**Corrected estimate** (performance review — original understated peak allocations):

| Component | Steady State | Peak | Notes |
|-----------|-------------|------|-------|
| LLM weights | 713MB | 713MB | Static after load |
| LLM KV cache (2K tokens, 4-bit) | 32MB | 32MB | Quantised, capped |
| LLM inference working memory | — | 50-100MB | Transient tensors per token |
| TTS (Kokoro 82M) | 100-150MB | 150MB | Weights + audio buffers |
| TTS audio queue | — | 5-10MB | Multiple queued sentence waveforms |
| STT (Apple framework) | 50-100MB | 100MB | OS-managed |
| App + SwiftUI + async runtime | 150-200MB | 200MB | Views, observation, tasks |
| **Total** | **~1.1-1.3GB** | **~1.3-1.5GB** | |

Available app memory with `increased-memory-limit` entitlement on 8GB device: ~3-4GB. Margin is adequate but not generous.

**Memory circuit breaker** (performance review recommendation):
```swift
// Check periodically during conversation
let available = os_proc_available_memory()
if available < 300_000_000 { // 300MB
    // Unload Kokoro, fall back to AVSpeechSynthesizer
    ttsService.degradeToSystemTTS()
    logger.warning("Memory low (\(available / 1_000_000)MB available), switched to system TTS")
}
```

**Critical entitlement:** `com.apple.developer.kernel.increased-memory-limit` — without this, iOS kills the app silently.

### Research Insights: MLX Swift API (from Context7 docs)

**Use `ChatSession` for multi-turn conversation** — this is the highest-level API and handles KV cache reuse automatically:

```swift
import MLXLMCommon
import MLXLLM

let model = try await loadModel(id: "mlx-community/Llama-3.2-1B-Instruct-4bit")
let session = ChatSession(
    model,
    instructions: systemPrompt, // the memoir interviewer prompt
    generateParameters: GenerateParameters(
        maxTokens: 200,
        temperature: 0.7,
        topP: 0.9,
        kvBits: 4,          // Quantise KV cache
        maxKVSize: 2048      // Cap context window
    )
)

// Streaming response (for piping to TTS):
for try await chunk in session.streamResponse(to: userTranscript) {
    sentenceBuffer.append(chunk)
    if sentenceBuffer.hasSentenceEnd() {
        await ttsService.speak(sentenceBuffer.flush())
    }
}
```

**For follow-up question generation** (separate, non-streaming call — run post-session):

```swift
let followUpSession = ChatSession(model, instructions: followUpPrompt)
let response = try await followUpSession.respond(to: fullAnswer)
// Parse response into individual questions
```

### Design Direction (UI/UX review)

**Style: "Nature Distilled"** — warm, organic, unhurried. The UI should recede so the question and voice interaction are the focus.

| Role | Color | Hex | Usage |
|------|-------|-----|-------|
| Background | Warm Cream | `#FBF8F3` | App background |
| Surface | Soft White | `#FFFFFF` | Cards, conversation bubbles |
| Primary Text | Warm Charcoal | `#2C2420` | Questions, headings |
| Secondary Text | Warm Gray | `#6B5E54` | Metadata, labels |
| Accent | Warm Terracotta | `#C67B5C` | Mic button, CTAs |
| Active | Soft Coral | `#E8856C` | Recording indicator |
| Coverage Green | Sage | `#7BA17D` | "Ready" status |
| Coverage Yellow | Amber | `#D4A855` | "Building depth" status |
| Coverage Red | Muted Rose | `#C47070` | "Needs answers" status |

**Typography:**
- Questions: `.font(.title2).fontDesign(.serif)` — Apple's New York serif. Literary, warm.
- Body/answers: `.font(.body)` — San Francisco. Clean, readable.
- Metadata: `.font(.caption)` — lighter weight.

**Key design principles:**
- Generous whitespace, soft rounded corners (16-20pt), natural ease-out animations
- Mic button is the hero element — large (~80pt), center stage, warm terracotta
- No hard edges, no neon colors, no "productivity app" aesthetic
- The app should feel like talking to a good interviewer over coffee

### Project Structure

```
Lifehug/
    App/
        LifehugApp.swift           @main entry point
        AppState.swift             Navigation, onboarding state
        ModelState.swift           Model download/load lifecycle
        SessionState.swift         Current question, conversation turns
    Views/
        LaunchView.swift           Model download + warm-up
        OnboardingView.swift       First-run setup
        DailyQuestionView.swift    Main screen — question + mic
        ConversationView.swift     Chat bubbles during session
        CoverageView.swift         Category coverage grid
        AnswersBrowserView.swift   Browse past answers
        SettingsView.swift         Preferences, export, reset
    Models/
        Question.swift
        Answer.swift
        Category.swift
        RotationState.swift
        UserConfig.swift
    Services/
        RotationEngine.swift       Port of ask.py
        QuestionBankParser.swift   Markdown parsing
        LLMService.swift           MLX Swift / ChatSession
        TTSService.swift           Kokoro / AVSpeechSynthesizer
        STTService.swift           SFSpeechRecognizer
        StorageService.swift       File I/O, security, export
        ModelDownloader.swift      First-launch model fetch
    Pipeline/
        VoicePipeline.swift        STT -> LLM -> TTS orchestration
    Resources/
        question-bank.md           Bundled default questions
```

---

## Implementation Phases

### Phase 1: Foundation (Data Layer + Rotation Engine)

**Goal:** All data structures, file I/O, and the rotation algorithm working and tested — no ML, no UI beyond stubs.

#### Tasks

- [x] Create Xcode project with SwiftUI lifecycle, set deployment target iOS 18.0
- [ ] Add SPM dependencies: `mlx-swift-lm` (MLXLLM product), `kokoro-ios`
- [ ] Verify SPM resolution and clean build (this catches dependency issues early)
- [ ] Add `com.apple.developer.kernel.increased-memory-limit` entitlement
- [ ] Add `Info.plist` keys: `NSSpeechRecognitionUsageDescription`, `NSMicrophoneUsageDescription`
- [ ] Add `PrivacyInfo.xcprivacy` declaring no data collection
- [ ] Enable Background Modes > Audio capability

**Data Models** (`Models/`):
- [ ] `Question.swift` — `struct Question: Codable, Identifiable` with `id` (String, e.g. "A1"), `category` (Character), `text`, `answered` (Bool)
- [ ] `Answer.swift` — `struct Answer` with markdown serialisation matching the exact repo format:
  ```
  # Question {ID}: {text}
  **Category:** {letter} ({name}) | **Pass:** {pass_number}
  **Asked:** {date} | **Answered:** {date}
  ---
  {answer text}
  ---
  ## Follow-up Questions Generated
  - {ID}: "{question}"
  ```
- [ ] `Category.swift` — `struct Category: Identifiable` with `id` (Character), `name` (String), `group` (enum: `.main`, `.project`, `.spotlight`). Group assignment uses letter range only: A-E = main, F-J = project, K+ = spotlight. (Note: `ask.py`'s `parse_categories()` has dead code that scans for section headers — the Swift port should skip this and use only the letter-range heuristic.)
- [ ] `RotationState.swift` — `Codable` struct mirroring `rotation.json`. Include all fields for compatibility. The code only reads `spotlight_frequency`, `questions_asked`, and `last_question_id`. It writes `last_question_id`, `last_asked_at`, `questions_asked`.
- [ ] `UserConfig.swift` — `Codable` struct for `config.json` (name, projects array). No `channel` or `question_time` fields needed (iOS handles delivery via local notifications).

**Storage Service** (`Services/StorageService.swift`):
- [ ] File paths: Application Support for models/state, Documents for user content
- [ ] **Security:** Set `NSFileProtectionComplete` on all user data directories — `Documents/answers/`, `Documents/question-bank.md`, `Documents/config.json`, and `Application Support/system/rotation.json`. Files are only decryptable when the device is actively unlocked. Note: this means notification extensions cannot pre-pick question text while locked (notifications should use generic text).
  ```swift
  try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.complete],
      ofItemAtPath: answersDirectoryPath
  )
  ```
- [ ] **iCloud backup exclusion** for model cache directory (~800MB should not be backed up):
  ```swift
  var url = modelsDirectoryURL
  var resourceValues = URLResourceValues()
  resourceValues.isExcludedFromBackup = true
  try url.setResourceValues(resourceValues)
  ```
- [ ] First-launch: copy bundled `question-bank.md` from app bundle to Documents
- [ ] Read/write JSON state files (rotation.json only — coverage is computed on-the-fly)
- [ ] Read/write markdown answer files with atomic writes (`FileManager.replaceItemAt` or write-to-temp-then-rename)
- [ ] List all answer files in `answers/` directory

**Question Bank Parser** (`Services/QuestionBankParser.swift`):
- [ ] Port `parse_categories()` — regex to discover categories from headers like `## A: Origins (Childhood & Family)`. Assign groups by letter range only (skip the dead section-header scanning code in ask.py).
- [ ] Port `parse_questions()` — regex `^- \[([ x])\] ([A-Z]\d+): (.+?)(?:\s*\*\(.+\)\*)?$`
- [ ] Port `mark_answered_in_md()` — in-place regex replacement
- [ ] Use Swift `Regex` (available iOS 16+) for cleaner syntax
- [ ] `computeCoverage(questions:categories:) -> [Character: CoverageInfo]` — compute coverage on-the-fly from parsed questions. No persistent coverage.json needed. (Simplicity review: 25-50 questions across 5-10 categories computes in sub-milliseconds.)

**Rotation Engine** (`Services/RotationEngine.swift`):
- [ ] Port `pick_next_question()` faithfully:
  1. Filter to unanswered questions
  2. Check spotlight turn: `questions_asked > 0 && questions_asked % spotlight_frequency == 0`
  3. Compute answered ratio per category
  4. Sort categories by ratio ascending (lowest coverage = highest priority)
  5. Separate spotlight vs non-spotlight categories
  6. If spotlight turn + spotlight questions exist: pick lowest-coverage spotlight category
  7. Otherwise: alternate between main/project groups based on `last_question_id`
  8. Within chosen category: pick first pending question in document order
  9. Fallback: first pending question overall
- [ ] `markAnswered()` — update question bank markdown and rotation.json

**Unit Tests:**
- [ ] Test answer file serialisation roundtrip (write then read, verify format matches repo spec)
- [ ] Test question bank parsing against the actual bundled `question-bank.md`
- [ ] Test rotation engine: lowest-coverage category gets picked
- [ ] Test rotation engine: group alternation (main -> project -> main)
- [ ] Test rotation engine: spotlight interleaving at configured frequency
- [ ] Test rotation engine: all-answered returns nil
- [ ] Test computed coverage thresholds (red/yellow/green at 0.3 and 0.7)

#### Success Criteria
- All Codable structs decode the actual JSON files from the repo
- Parser correctly extracts all 25 starter questions from `question-bank.md`
- Rotation engine produces the same question sequence as `ask.py` for the same input state
- Answer files written by iOS can be read by the Python tool (format-compatible)

#### Estimated Effort
2-3 days

---

### Phase 2: Model Download + Launch Experience

**Goal:** Models download on first launch with progress UI, are cached permanently, and the app handles every download state gracefully.

#### Tasks

**Model Downloader** (`Services/ModelDownloader.swift`):
- [ ] Download LLM using `LLMModelFactory.shared.loadContainer(configuration:progressHandler:)` — MLX Swift handles the Hugging Face download internally
- [ ] Download Kokoro TTS model files
- [ ] Cache to `Application Support/models/`
- [ ] Progress reporting: fraction complete for each model, combined progress for UI
- [ ] **Download verification:** after download, attempt to load the model. If loading fails, delete cache and show retry UI. (Security review: this also serves as integrity verification — a corrupted/tampered model won't load.)
- [ ] **Resume/retry:** if download is interrupted, detect on next launch and restart
- [ ] **Airplane mode:** if no network on first launch, show "Lifehug needs to download AI models (~800MB). Connect to Wi-Fi to get started."

**Launch View** (`Views/LaunchView.swift`):
- [ ] State machine (simplified from 6 to 4 states per simplicity review):
  - `needsDownload` — show download button / auto-start
  - `downloading(progress: Double)` — progress bar with MB count
  - `loading` — "Preparing Lifehug..." while models warm up (2-4s)
  - `ready` — transition to main app
- [ ] "Download failed — tap to retry" on error
- [ ] "No internet connection" with clear instructions

**Observable State** (`App/ModelState.swift`, `App/SessionState.swift`, `App/AppState.swift`):
- [ ] `ModelState` — `@Observable @MainActor`: `downloadProgress`, `status` (enum), `isLoaded`
- [ ] `SessionState` — `@Observable @MainActor`: `currentQuestion`, `conversationTurns`, `isRecording`, `draftTranscript`
- [ ] `AppState` — `@Observable @MainActor`: `isOnboardingComplete`, `activeScreen`
- [ ] On `scenePhase` -> `.active`: check if models still loaded. If evicted, show "Warming up..." and reload.

#### Success Criteria
- Clean install: download UI -> models download -> transition to main screen
- Kill app mid-download, relaunch: detects and restarts cleanly
- Airplane mode: clear message, no crash
- Background 10+ minutes, return: reloads if needed

#### Estimated Effort
2-3 days

---

### Phase 3: Voice Pipeline (STT + LLM + TTS)

**Goal:** A working end-to-end voice conversation on a real iPhone.

#### Tasks

**STT Service** (`Services/STTService.swift`):
- [ ] Request speech recognition authorisation
- [ ] `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`
- [ ] `AVAudioEngine` input node tap for streaming audio
- [ ] `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults = true`
- [ ] Publish partials via `AsyncStream<String>` for real-time UI
- [ ] Silence detection: `result.isFinal` or no new partials for ~1.5s
- [ ] Handle auth denied: show Settings deep-link
- [ ] Handle `AVAudioSession` interruptions: pause, notify pipeline
- [ ] iOS 18 workaround: if results are non-cumulative, accumulate manually
- [ ] Handle the 1-minute-per-request limit: if approaching, finalise current segment and start a new request seamlessly

**LLM Service** (`Services/LLMService.swift`):
- [ ] Use `ChatSession` API for multi-turn conversation (see API patterns above)
- [ ] System prompt: the memoir interviewer prompt from `lifehug-ios-claude-code-prompt.md`, with runtime variable injection
- [ ] `GenerateParameters`: `maxTokens: 200`, `temperature: 0.7`, `topP: 0.9`, `kvBits: 4`, `maxKVSize: 2048`
- [ ] Streaming via `session.streamResponse(to:)` -> `AsyncSequence` of text chunks
- [ ] Strip system prompt leakage, `<|` tokens, and markdown artifacts before yielding
- [ ] Expose `isLoaded` for backgrounding detection
- [ ] Create a new `ChatSession` for each daily question session (don't carry context across days)

**TTS Service** (`Services/TTSService.swift`):
- [ ] **Kokoro path:** initialise from cached model files, load voice embedding
- [ ] **AVSpeechSynthesizer fallback:** `.premium` quality voice
- [ ] `speak(sentence:) async` — generate audio, play via `AVAudioPlayer`
- [ ] Sentence queue: accept sentences, play sequentially without gaps
- [ ] `stop()` — immediately halt playback (user interrupt)
- [ ] `degradeToSystemTTS()` — called by memory circuit breaker
- [ ] `AVAudioSession`: `.playAndRecord` with `[.defaultToSpeaker, .allowBluetooth]`
- [ ] Handle audio route changes without crashing

**Voice Pipeline** (`Pipeline/VoicePipeline.swift`):
- [ ] State machine: `idle` -> `listening` -> `processing` -> `speaking` -> `idle`
- [ ] **Cancellation protocol:** Each state transition cancels the active `Task` from the previous state:
  ```swift
  private var activeTask: Task<Void, Never>?

  func transition(to newState: PipelineState) {
      activeTask?.cancel()
      state = newState
      activeTask = Task { await runState(newState) }
  }
  ```
- [ ] When STT finalises: send to LLM, stream response
- [ ] **Sentence boundary detection:** Accumulate LLM chunks, detect `.!?` followed by space/newline/end-of-stream. Handle abbreviations ("Dr.", "U.S.") by checking for uppercase after period. Fire TTS per complete sentence.
- [ ] **Interrupt:** user taps mic -> cancel LLM/TTS tasks, restart STT
- [ ] **Error recovery:**
  - Empty STT: "I didn't catch that" message, re-enable mic
  - LLM garbage: discard, "Let me try that again"
  - TTS fails: display text without audio
- [ ] **Memory monitoring:** check `os_proc_available_memory()` before starting LLM generation. If low, degrade TTS.

#### Research Insights: Sentence Boundary Detection

Simple regex-based detection (`.!?` + space) works for 95% of cases. For the remaining edge cases:

- **Abbreviations:** Maintain a small set of common abbreviations ("Dr.", "Mr.", "Mrs.", "U.S.", "etc."). Don't split on these.
- **Numbers:** "3.14" is not a sentence end. Check if the character before the period is a digit.
- **Ellipsis:** "..." should not trigger three sentence fires. Collapse consecutive periods.
- **End of stream:** When the LLM finishes, flush any remaining buffer to TTS regardless of punctuation.

For a 1B model generating 2-4 sentence responses, this is sufficient. Don't over-engineer with NLP tokenizers.

#### Success Criteria
- Speak -> see transcript -> hear AI response within ~2s
- Multi-turn conversation works
- Tap-to-interrupt works
- Empty/garbage inputs handled gracefully
- Works in airplane mode

#### Estimated Effort
5-7 days

---

### Phase 4: Main Screens (Daily Question + Conversation)

**Goal:** The core daily experience — see today's question, have a voice conversation, save the answer.

#### Tasks

**Daily Question View** (`Views/DailyQuestionView.swift`):
- [ ] On appearance: check if question picked today. If not, `RotationEngine.pickNext()`.
- [ ] Display question in `.title2` serif font (New York), warm charcoal on cream background
- [ ] Category badge and pass indicator in secondary text
- [ ] Large mic button (terracotta, ~80pt, centred) with pulsing animation when recording
- [ ] Real-time transcript below mic button
- [ ] Transition to conversation view on AI response

**Conversation View** (`Views/ConversationView.swift`):
- [ ] Chat bubble layout: user (right, cream), AI (left, white with subtle shadow)
- [ ] AI text appears chunk-by-chunk synced with TTS
- [ ] Auto-scroll on new messages
- [ ] Tap AI message to interrupt TTS
- [ ] "End Session" button — always visible
- [ ] On end session:
  1. Cancel active pipeline tasks
  2. Compile user turns into single answer
  3. Save answer file (atomic write, `NSFileProtectionComplete`)
  4. Mark question answered in question bank
  5. Update rotation.json
  6. Show "Answer saved" confirmation with warm animation
  7. Navigate back to daily question view

**Session Management:**
- [ ] Track conversation turns for current session
- [ ] Combine user turns into cohesive answer for the answer file
- [ ] Handle backgrounding mid-session: save draft, resume on return

#### Success Criteria
- Full flow: see question -> speak -> hear AI -> end -> answer saved
- Answer file format-compatible with desktop tool
- Coverage computed correctly after answering

#### Estimated Effort
3-4 days

---

### Phase 5: Onboarding

**Goal:** First-run experience that sets up the user's question bank.

#### Tasks

**MVP Approach** (simplicity review recommendation — defer LLM-generated categories):

For MVP, use a structured SwiftUI form rather than LLM-generated categories. A 1B model produces inconsistent structured output, making robust parsing risky.

- [ ] Welcome screen explaining Lifehug (warm, serif typography, minimal)
- [ ] "What's your name?" — text field
- [ ] "What do you want to write?" — picker: Memoir, Founder Story, Family History, Creative Journey, Career Story
- [ ] Based on selection, add pre-written project categories F-J from a bundled template (e.g., Memoir gets "Career & Work", "Travel & Adventure", "Health & Growth"; Founder Story gets "The Problem", "Building", "The Hard Parts", "Vision")
- [ ] "Who are important people in your story?" — optional text field for names (stored in config, spotlight categories can be created later)
- [ ] Create `config.json`, update `question-bank.md` with template categories, initialise `rotation.json`
- [ ] Mark onboarding complete, transition to first question

**Post-MVP enhancement:** Add LLM-powered onboarding that generates truly custom categories. This requires structured output parsing with fallback and is better suited for after the core app is stable.

**Edge Cases:**
- [ ] "Reset" in Settings clears config and re-runs onboarding
- [ ] User skips name: use "friend" as default

#### Success Criteria
- Fresh install -> download -> onboard -> first question, seamless
- Question bank has project-specific categories
- Config created correctly

#### Estimated Effort
1-2 days

---

### Phase 6: Supporting Screens

**Goal:** Coverage tracking, answer browsing, settings, and export.

#### Tasks

**Coverage View** (`Views/CoverageView.swift`) — renamed from ProgressView to avoid SwiftUI collision:
- [ ] Compute coverage on-the-fly from parsed question bank (no coverage.json)
- [ ] Category grid: each cell shows name, colour indicator, fraction (e.g., "2/5")
- [ ] **Accessibility:** Text labels alongside colours: "Needs answers" (red), "Building depth" (yellow), "Ready" (green)
- [ ] Total questions answered
- [ ] Tappable categories -> list of questions with status

**Answers Browser** (`Views/AnswersBrowserView.swift`):
- [ ] List answer files from `Documents/answers/`, grouped by category
- [ ] Show question text, date, answer preview
- [ ] Tap to view full answer
- [ ] Edit button -> text editor (save back to markdown)

**Settings View** (`Views/SettingsView.swift`):
- [ ] User name (editable)
- [ ] Daily reminder toggle + time picker (`UNUserNotificationCenter`)
- [ ] Model status and storage usage
- [ ] "Delete model cache" with confirmation
- [ ] "Export answers" -> zip markdown files, present share sheet
- [ ] "Reset Lifehug" with confirmation -> clear all data, re-onboard
- [ ] App version

**Local Notifications:**
- [ ] Schedule daily repeating notification at configured time
- [ ] Notification content: generic "Your daily question is ready" (avoid pre-picking question text because `NSFileProtectionComplete` means files may not be readable from a notification extension while locked)
- [ ] Tapping notification opens app to daily question screen
- [ ] Handle notification permission denied: show gentle prompt in Settings

#### Success Criteria
- Coverage screen reflects actual question bank state
- Answers browsable and editable
- Export produces valid zip
- Notification fires at configured time

#### Estimated Effort
3-4 days

---

### Phase 7: Polish and TestFlight

**Goal:** Production-quality app ready for TestFlight distribution.

#### Tasks

**Verification:**
- [ ] **Audit dependency tree:** Verify only `mlx-swift-lm` and `kokoro-ios` are included. No analytics, no crash reporting, no ad frameworks.
- [ ] **Verify NSFileProtectionComplete:** Confirm files in `Documents/` are unreadable when device is locked (test by locking device and checking from a debugger or second process).

**Error Handling & Edge Cases:**
- [ ] Disk full: check before writing, alert user
- [x] Model evicted after backgrounding: detect via `ModelState.isLoaded`, reload with "Warming up..." UI
- [ ] Audio session interruption (phone call): pause gracefully, resume after
- [ ] SFSpeechRecognizer unavailable: show clear error
- [ ] Memory circuit breaker: degrade Kokoro to AVSpeechSynthesizer if `os_proc_available_memory() < 300MB`

**Accessibility:**
- [x] All interactive elements have accessibility labels
- [x] Conversation transcript accessible to VoiceOver
- [ ] Dynamic Type support for all text
- [x] Mic button: "Start recording your answer" / "Stop recording"
- [x] Coverage indicators use text labels, not just colour

**Performance Testing (on real iPhone 15 Pro):**
- [ ] Time from "user stops speaking" to "first TTS audio" — target < 2s
- [ ] LLM tokens/second — expect ~60 TPS
- [ ] Memory during sustained conversation (5+ turns) — should stay under 1.5GB
- [ ] Thermal: 10-minute continuous conversation, note degradation

**TestFlight Prep:**
- [ ] Bundle ID: `com.lifehug.app`
- [ ] Automatic signing
- [x] Privacy manifest: no data collection, declare `NSPrivacyAccessedAPIType` for UserDefaults and file timestamps
- [ ] App icon and launch screen (warm cream background, simple wordmark)
- [ ] Archive, upload, add internal testers
- [ ] Verify clean install on second test device

**Quality Gates:**
- [ ] No crashes on any user flow
- [x] All unit tests passing
- [x] Works fully offline after model download
- [ ] Answer files verified compatible with desktop tool
- [ ] Memory stays under 1.5GB during normal use
- [ ] `NSFileProtectionComplete` verified (files unreadable when device locked)

#### Estimated Effort
3-4 days

---

## Feature Parity Gaps (Deferred to Post-MVP)

The CLAUDE.md spec defines several features that are not in this MVP plan. These are documented here for future implementation.

### 1. Spotlight Discovery (Critical gap — implement in v1.1)
CLAUDE.md (lines 212-237): The AI should watch for recurring names/events in answers and proactively offer to create Spotlight categories. **Deferred because:** Requires cross-answer analysis and a reliable LLM prompt for entity extraction. A 1B model's ability to do this well is uncertain. Plan to add after the core conversation flow is validated.

**When implementing:** After saving an answer, run a lightweight LLM call checking for recurring names across the last 5-10 answers. If a name appears 3+ times, surface a prompt to the user.

### 2. Deliverable Drafting (Important — implement in v1.2)
CLAUDE.md (lines 242-264): When categories reach GREEN (70%+), offer to draft chapters, essays, or profiles. **Deferred because:** Drafting quality with a 1B model may be insufficient. The core answer-capture loop must work first.

### 3. Follow-up Question Generation (Important — implement in v1.1)
CLAUDE.md (lines 190-196): Generate 1-3 follow-up questions after each answer. **Deferred from MVP because:** Requires a second LLM call per session, structured output parsing, and question bank mutation. Add after MVP is stable. The 25 starter questions provide ~25 days of content without follow-ups.

### 4. Weekly/Monthly Review Rhythms (Nice-to-have — v1.2+)
CLAUDE.md (lines 397-414): Weekly coverage checks, monthly narrative review, milestone celebrations. **Deferred because:** These are engagement features, not core functionality.

---

## Alternative Approaches Considered

### 1. Use Core ML instead of MLX Swift
**Rejected.** Core ML requires pre-converting models and bundling in the app binary (~700MB+). MLX Swift downloads from Hugging Face at runtime, keeping the binary small.

### 2. Use Whisper (via WhisperKit) instead of SFSpeechRecognizer
**Rejected for now.** Higher accuracy but +150MB model download and more memory pressure. Revisit if SFSpeechRecognizer accuracy proves insufficient.

### 3. Server-based inference
**Rejected.** Privacy is non-negotiable. Life stories never leave the device.

### 4. SwiftData for structured storage
**Rejected.** Must produce markdown files compatible with the desktop tool.

### 5. iOS 26 for SpeechAnalyzer
**Deferred.** Better API but limits device compatibility. Keep iOS 18 minimum.

### 6. Persist coverage.json (original plan)
**Rejected.** Coverage is trivially computed from the question bank in memory. Persisting it adds complexity with zero benefit on iOS where the app holds all questions in memory.

---

## Acceptance Criteria

### Functional Requirements
- [ ] First launch: download models (~800MB) with progress UI
- [ ] Onboarding: choose project type, get category templates
- [ ] Daily question: one per day, chosen by rotation engine
- [ ] Voice conversation: speak -> hear AI follow-up -> multi-turn
- [ ] Answer saving: markdown format matching desktop spec exactly
- [ ] Rotation engine: matches `ask.py` (coverage priority, group alternation, spotlight interleaving)
- [ ] Coverage view: red/yellow/green per category, computed on-the-fly
- [ ] Answers browser: view and edit past answers
- [ ] Export: zip of markdown files
- [ ] Daily notification at configured time
- [ ] Settings: name, reminder, model management, export, reset

### Non-Functional Requirements
- [ ] Zero network calls during AI interaction
- [ ] Time to first TTS audio < 2 seconds
- [ ] LLM >= 50 TPS on iPhone 15 Pro
- [ ] Memory < 1.5GB during conversation
- [ ] No crashes on any user flow
- [ ] Dynamic Type and VoiceOver throughout
- [ ] Works fully offline after model download
- [ ] NSFileProtectionComplete on all user data

### Quality Gates
- [ ] Unit tests for rotation engine matching `ask.py` output
- [ ] Unit tests for question bank parser
- [ ] Unit tests for answer file serialisation roundtrip
- [ ] Integration test: full conversation flow on device
- [ ] Answer file compatibility verified with desktop tool
- [ ] TestFlight clean install on fresh device
- [ ] 10+ test sessions, no crashes

---

## Dependencies & Prerequisites

| Dependency | Type | Risk | Mitigation |
|------------|------|------|------------|
| `mlx-swift-lm` (MLXLLM) | SPM | Medium — API may change | Pin commit; `ChatSession` API is stable |
| `kokoro-ios` | SPM | Medium — 3 contributors | AVSpeechSynthesizer fallback |
| Llama 3.2 1B 4-bit | HF model | Low | Swap to Qwen3 0.6B if needed |
| Apple Developer ($99/yr) | Account | Low | Required for TestFlight |
| iPhone 15 Pro+ | Device | Low | Any A17 Pro+ with 8GB |

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| MLX Swift API changes | Medium | High | Pin version; ChatSession API stable |
| Kokoro build issues | Medium | Medium | AVSpeechSynthesizer fallback |
| Memory kills app | Medium | High | `increased-memory-limit`; KV cache quantisation; memory circuit breaker |
| SFSpeech iOS 18 bugs | Medium | Medium | Manual accumulation; consider WhisperKit |
| 1B model quality | Low | Medium | Crafted prompt; lean context; upgrade to 3B on 12GB devices |
| Model download fails | Medium | Low | Retry UI; clear messaging |
| Answer format drift | Low | High | Unit tests verify format |
| Thermal throttling | Medium | Low | Sessions are short; monitor |

## Resource Requirements

- **Developer:** 1 iOS developer with SwiftUI + MLX Swift experience
- **Devices:** iPhone 15 Pro (primary), one older 8GB device
- **Apple Developer account:** Active with TestFlight
- **Timeline:** ~3 weeks for all 7 phases
- **Storage:** ~2GB free on test devices

## Future Considerations

- **iOS 26 SpeechAnalyzer:** Swap SFSpeechRecognizer for better accuracy and long-form support
- **Spotlight discovery:** Post-answer entity extraction to suggest spotlight categories
- **Deliverable drafting:** LLM-powered chapter/essay generation from accumulated answers
- **Follow-up questions:** Auto-generated depth questions after each answer
- **iCloud sync:** Optional sync (privacy considerations)
- **Larger models:** 3B on iPhone 16 Pro (12GB RAM)
- **Widget:** Today's question or streak count
- **Apple Watch:** Quick voice answer from wrist

## References & Research

### Internal
- Rotation algorithm: `system/ask.py:121-200`
- Question bank format: `system/question-bank.md`
- Answer file format: `CLAUDE.md:172-188`
- State files: `system/rotation.json`
- iOS build prompt: `lifehug-ios-claude-code-prompt.md`

### External
- MLX Swift LM: https://github.com/ml-explore/mlx-swift-lm
- MLX Swift LM docs (ChatSession, streaming): https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLLM/Documentation.docc/evaluation.md
- Kokoro iOS: https://github.com/mlalma/kokoro-ios
- Kokoro 82M model: https://huggingface.co/hexgrad/Kokoro-82M
- Llama 3.2 1B: https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit
- SFSpeechRecognizer: https://developer.apple.com/documentation/speech/sfspeechrecognizer
- SpeechAnalyzer (iOS 26): https://developer.apple.com/documentation/speech/speechanalyzer
- MLX on Apple Silicon (WWDC): https://developer.apple.com/videos/play/wwdc2025/298/

