# Claude Code Prompt: Lifehug iOS App

## Context

Build a native iOS app called **Lifehug** — an AI-guided memoir writing assistant that asks the user one question per day, listens to their spoken answer, and helps them build their life story over time. All AI inference runs fully on-device. No data ever leaves the device.

The product logic, question format, rotation engine, and file structure are defined in this same repo. Before writing any code, read:
- `CLAUDE.md` — AI operating instructions and the full system design
- `README.md` — product overview and how the system works
- `system/ask.py` — the rotation engine (this must be ported faithfully to Swift)
- `system/question-bank.md` — question format and category structure
- `system/rotation.json` and `system/coverage.json` — state file formats

The rotation logic, question categories, coverage tracking, and answer file format defined in those files must be preserved in this iOS implementation.

---

## Target Device & OS

- Minimum deployment target: iOS 18.0 (consider iOS 26 if timeline allows — see STT notes below)
- Benchmark device: iPhone 15 Pro (A17 Pro, 8GB unified memory)
- Swift 6.0+, SwiftUI, strict concurrency checking enabled

---

## Architecture

### AI Stack (fully on-device, no network calls for inference)

**STT — Speech to Text**
- **iOS 18 target:** Use Apple's `SFSpeechRecognizer` with on-device recognition (`requiresOnDeviceRecognition = true`). Use `AVAudioEngine` for streaming partial transcripts.
- **iOS 26 target (preferred if timeline allows):** Use `SpeechAnalyzer` with `SpeechTranscriber` — Apple's modern replacement for SFSpeechRecognizer. Fully on-device, supports long-form audio, provides volatile results (fast, for live UI) and final results (high accuracy). If targeting iOS 26, use this instead of SFSpeechRecognizer.
- Set the task locale explicitly (e.g. `Locale(identifier: "en-US")`)
- Handle `AVAudioSession` interruptions (phone calls, Siri, other apps) gracefully — pause recognition and resume or notify the user
- Silence detection: use `SFSpeechRecognitionRequest`'s `shouldReportPartialResults` and detect when the final result arrives (no new partials for ~1.5s). Do not roll your own silence timer on the audio buffer unless Apple's built-in detection proves insufficient.
- **Known issue (iOS 18):** There are reported bugs where streaming results only include newly spoken text after a gap (not cumulative), and recognition can become throttled. Test thoroughly on device.

**LLM — Language Model**
- Framework: MLX Swift via Swift Package Manager
- Package URL: `https://github.com/ml-explore/mlx-swift-lm` (this is the current home of `MLXLLM` — it was split out of `mlx-swift-examples` which now only contains example apps)
- Primary import: `import MLXLLM` (provides `LLMModelFactory`, `ModelConfiguration`, and streaming generation APIs)
- Model: `mlx-community/Llama-3.2-1B-Instruct-4bit` (~713MB on disk, ~60 tokens/sec on iPhone 15 Pro)
- Alternative models if size/speed is a concern: `Qwen3-0.6B-4bit` (351MB, ~65 TPS) or `LFM2.5-1.2B-Instruct-4bit` (663MB, ~60 TPS)
- Download model on first launch with a progress UI. Cache to the app's Application Support directory (not Documents — see Data Layer). Verify the download completed (check for a sentinel file or known file count) so interrupted downloads don't leave a corrupt cache.
- Context window management: system prompt + current question + user's answer + last 2 exchanges only. This keeps the context under ~2K tokens which is critical for speed on a 1B model. Do NOT let the KV cache grow unbounded — on 8GB devices the full 128K context would require ~4GB for KV cache alone.
- Enable **KV cache quantization** (`kvBits: 4` in `GenerateParameters`) to reduce memory usage for the KV cache during conversation turns.
- Use streaming token generation — pipe output to TTS sentence by sentence
- Expect ~250ms time-to-first-token for medium prompts

**TTS — Text to Speech**
- **Primary option:** Kokoro TTS via `kokoro-ios` SPM package
  - Package URL: `https://github.com/mlalma/kokoro-ios` (v1.0.8+, MLX Swift-native, based on Kokoro-82M model)
  - Generates audio ~3.3x faster than real-time on iPhone 13 Pro (faster on A17 Pro)
  - This provides natural-sounding speech significantly better than Apple's built-in voices
  - Dependencies: MisakiSwift (grapheme-to-phoneme), MLX framework
  - Model size: ~80-100MB (downloaded alongside the LLM on first launch)
  - Voice: use the default English US voice embedding
- **Fallback option:** If KokoroSwift proves problematic (build issues, model size concerns, or audio quality issues), fall back to `AVSpeechSynthesizer` with an `AVSpeechSynthesisVoice` using `.premium` quality. This is zero additional download but noticeably less natural.
- Sentence boundary detection on the LLM token stream: fire TTS for each complete sentence as it arrives. Do not wait for the full LLM response.
- **Audio session category:** Set to `.playAndRecord` with options `[.defaultToSpeaker, .allowBluetooth]` so TTS plays through the speaker while mic is available. Switch modes carefully — do not interrupt TTS playback when starting a new STT session.

### Pipeline Flow
```
User speaks
    -> SFSpeechRecognizer (streaming, on-device, finalises on silence)
    -> LLM (Llama 1B via MLX Swift, streaming tokens)
    -> Sentence boundary detector (split on .!? followed by space/newline)
    -> TTS (fires per sentence, queued)
    -> AVAudioPlayer (queued playback, one sentence at a time)
```

**Target latency:** First TTS audio should begin within ~1-2 seconds of user finishing speech. This depends on model warm-up being complete (see below). Do not treat this as a hard guarantee — measure and optimise iteratively.

### Model Warm-up & Memory Management

**Memory budget:** On iPhone 15 Pro (8GB total, ~5-6GB available to apps), the memory breakdown is roughly:
- LLM (Llama 1B 4-bit): ~700-800MB
- TTS model (Kokoro): ~100-150MB
- STT (Apple framework): ~50-100MB (managed by OS)
- App + overhead: ~100MB

This totals ~1-1.2GB which is within budget, but leaves little margin.

**Critical:** Add the `com.apple.developer.kernel.increased-memory-limit` entitlement to the app target. Without this, iOS will aggressively terminate the app under memory pressure with no useful crash log. This entitlement requests more memory from the OS — it's required for any app loading ML models of this size.

Monitor memory pressure using `os_proc_available_memory()` and log warnings if available memory drops below 200MB. If memory is critically low, consider unloading the TTS model and falling back to `AVSpeechSynthesizer`.

**Warm-up strategy:**
1. On app launch, show a loading screen while preloading the LLM into memory
2. Load the TTS model/voice immediately after the LLM
3. Cold load takes 2-4 seconds on A17 Pro — this must complete before any conversation starts
4. If the app is backgrounded and the OS reclaims memory, detect this on `scenePhase` change back to `.active` and reload models before allowing conversation to resume. Show a brief "Warming up..." indicator.

---

## Data Layer

All data is stored locally on-device. No backend, no sync, no cloud.

**Directory structure** within the app sandbox:

```
Application Support/     (not user-visible — models, state, config)
    models/              LLM and TTS model files (cached downloads)
    system/
        rotation.json
        coverage.json

Documents/               (visible in Files app — user's actual content)
    question-bank.md     the question bank, seeded from bundle, writable
    config.json          user configuration (see below)
    answers/             one markdown file per answered question
    drafts/              chapter drafts, essays (future feature)
    spotlights/          spotlight deliverables (future feature)
```

**Why this split:** Models and state files go in Application Support (not user-visible, not backed up by default). The user's answers and question bank go in Documents so they're accessible via the Files app for backup and export.

**Answer file format:** Must exactly match the repo's format:
```markdown
# Question {ID}: {Question text}
**Category:** {letter} ({name}) | **Pass:** {pass_number}
**Asked:** {date} | **Answered:** {date}

---

{Full answer}

---

## Follow-up Questions Generated
- {ID}: "{follow-up question}"
```

**Config format:** Use JSON instead of YAML on iOS (no need for a YAML parser dependency). Map the same fields:
```json
{
  "name": "Their Name",
  "timezone": "America/New_York",
  "projects": [
    {"name": "My Memoir", "type": "memoir", "categories": ["F", "G", "H"]}
  ]
}
```

**Question bank parsing:** The question bank is a markdown file. Write a dedicated parser that handles:
- Category headers: `## A: Origins (Childhood & Family)`
- Question lines: `- [ ] A1: Question text` and `- [x] A1: Question text *(2026-03-01)*`
- Section markers for Spotlights and Project categories

Port the regex patterns from `system/ask.py` (`parse_categories` and `parse_questions` functions) directly — they define the canonical format.

**Question rotation logic:** Port `system/ask.py` to Swift faithfully. The key functions to port:
- `parse_categories()` — discovers categories and groups from markdown headers
- `parse_questions()` — parses question lines with answered/unanswered status
- `pick_next_question()` — the rotation algorithm (coverage-based priority, group alternation, spotlight interleaving)
- `update_coverage()` — recalculates coverage stats per category
- `mark_answered_in_md()` — checks off a question and adds the date

Do not simplify the rotation logic. The category weighting, group alternation, and spotlight frequency must all be preserved.

**Porter's note:** Some fields in `rotation.json` (`current_pass`, `pass_names`, `next_question_id`, `questions_answered`) exist in the schema but are **not read by `ask.py`'s rotation logic**. The fields the code actually reads are: `spotlight_frequency`, `questions_asked`, and `last_question_id`. Include all fields in the Codable struct for forward compatibility, but don't implement logic around the unused ones.

---

## Core Features

### 1. Onboarding
- Conversational onboarding flow (can use the LLM to make it feel natural, or use a structured SwiftUI form — implementer's choice based on what feels better)
- Ask: what do you want to write? (memoir, founder story, family history, etc.)
- Ask: who are the important people in your story?
- Ask: what episodes do you already know you want to capture?
- Generate project-specific question categories F-J based on answers (use LLM)
- Create config.json and initialise question bank with new categories
- Store onboarding answers as answer files too

### 2. Daily Question Screen (main screen)
- Display today's question prominently
- Show category and pass indicator
- Large mic button — tap to speak answer
- Real-time transcript displayed as user speaks
- When user stops speaking (silence detection), finalise transcript and begin AI response
- AI responds conversationally via voice (TTS), asking a follow-up or affirming the answer
- Conversation continues naturally until user ends the session
- On session end: save answer file, generate 1-3 follow-up questions, update rotation and coverage state
- If no question has been picked today, pick one on screen appearance using the rotation engine

### 3. Conversation UX
- Conversation view showing transcript of current session (chat bubble style)
- AI responses appear as text simultaneously with TTS playback
- Tap to interrupt AI mid-speech (stop TTS playback, re-enable mic)
- "End session" button saves and exits
- Clean the LLM response before display — strip any markdown artifacts, system prompt leakage, or formatting tokens that shouldn't be user-visible
- Handle edge cases: if STT returns empty/garbage, prompt user to try again rather than sending to LLM

### 4. Progress Screen
- Coverage grid showing RED / YELLOW / GREEN status per category (thresholds: 0-30% / 30-70% / 70%+)
- Total questions answered
- Current pass
- List of all answered questions with dates, tappable to view

### 5. Answers Browser
- Scrollable list of all answers organised by category
- Tap to read full answer
- Edit answer text (no re-recording)

### 6. Settings
- User name
- Daily reminder notification (local, not push — scheduled via `UNUserNotificationCenter`)
- Reminder time picker
- Model download status and storage usage (show LLM size + TTS model size + answers size)
- Delete model cache (re-download on next launch)
- Export all answers as a zip of markdown files (use `FileManager` to create a zip in a temporary directory, then present `UIActivityViewController` / ShareLink)

---

## LLM System Prompt

Use this as the base system prompt for all conversational turns. Inject the relevant variables at runtime:

```
You are a warm, skilled memoir interviewer helping {name} write their {project_type}.

Your role is to listen to their answers and respond in one of two ways:
1. Ask a single focused follow-up question that goes deeper into what they just shared
2. If the answer is complete and rich, affirm it briefly and signal the session can end

Rules:
- One question maximum per response. Never ask two questions.
- Keep responses short: 2-4 sentences maximum.
- Be warm but not sycophantic. No hollow praise.
- Speak in second person, conversationally.
- Focus on: specific moments, sensory detail, emotions, other people present.
- Never summarise their answer back to them at length.
- Never break character or mention AI, models, or technology.

Current question asked: {question_text}
Category: {category_name}
Pass: {pass_number}

User's answer: {transcript}
```

For follow-up question generation (run after session ends, not during conversation), use a separate prompt:

```
Based on this answer to a memoir question, generate 1-3 follow-up questions for a future session.

Original question: {question_text}
Category: {category_name}
Answer: {full_answer}

Generate follow-up questions that:
- Go deeper into specific details mentioned in the answer
- Ask about sensory details, emotions, or other people present
- Use the format: one question per line, no numbering
- Keep each question to one sentence
```

Parse the output and assign IDs sequentially (e.g., if the parent was A1, follow-ups become A6, A7, A8 — using the next available number in that category).

---

## Swift Package Dependencies

```swift
dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
    // TTS — try kokoro-ios first, fall back to AVSpeechSynthesizer if issues arise
    .package(url: "https://github.com/mlalma/kokoro-ios", from: "1.0.8"),
]
```

**Note on MLX Swift LM:** You need the `MLXLLM` product from this package. The typical usage pattern is:
```swift
import MLXLMCommon
import MLXLLM

let config = ModelConfiguration(id: "mlx-community/Llama-3.2-1B-Instruct-4bit")
let container = try await LLMModelFactory.shared.loadContainer(
    configuration: config,
    progressHandler: { progress in /* update UI */ }
)
```
If the API surface has changed since this prompt was written, adapt accordingly but preserve the same behavior (streaming generation, model loading from local cache). Check the package's `Package.swift` for exact product names.

---

## Project Structure

```
Lifehug/
    App/
        LifehugApp.swift           SwiftUI app entry point (@main)
        AppState.swift             Observable app state (model loaded, current question, etc.)
    Views/
        LaunchView.swift           Model loading + download progress
        OnboardingView.swift       First-run setup flow
        DailyQuestionView.swift    Main screen — question + mic + conversation
        ConversationView.swift     Chat-style transcript during a session
        ProgressView.swift         Coverage grid and stats
        AnswersBrowserView.swift   Browse and read past answers
        SettingsView.swift         Preferences, export, model management
    Models/
        Question.swift             Question struct (id, category, text, answered)
        Answer.swift               Answer struct + markdown serialisation
        Category.swift             Category with name, group, coverage
        RotationState.swift        Codable mirror of rotation.json
        CoverageState.swift        Codable mirror of coverage.json
        UserConfig.swift           Codable mirror of config.json
    Services/
        RotationEngine.swift       Faithful port of ask.py
        QuestionBankParser.swift   Markdown parsing for question-bank.md
        LLMService.swift           MLX Swift wrapper — load, generate, stream
        TTSService.swift           TTS wrapper (Kokoro or AVSpeechSynthesizer)
        STTService.swift           SFSpeechRecognizer wrapper — streaming + silence detection
        StorageService.swift       File I/O — read/write markdown, JSON, config
        ModelDownloader.swift      First-launch model fetch with progress
    Pipeline/
        VoicePipeline.swift        Orchestrates STT -> LLM -> TTS with sentence streaming
    Resources/
        question-bank.md           Bundled default question bank (copied to Documents on first launch)
```

---

## App Lifecycle & Error Handling

### Backgrounding
- When the app moves to background mid-conversation: stop STT, stop TTS playback, save the current transcript as a draft
- When returning to foreground: check if models are still loaded (OS may have reclaimed memory). If not, show "Warming up..." and reload before resuming
- Use `@Environment(\.scenePhase)` to detect transitions

### Audio Session
- Configure `AVAudioSession` category as `.playAndRecord` with `.defaultToSpeaker` and `.allowBluetooth`
- Register for interruption notifications (`AVAudioSession.interruptionNotification`)
- On interruption (phone call, Siri): pause gracefully, resume when interruption ends
- On route change (headphones plugged/unplugged): handle without crashing

### Error Recovery
- **Model download interrupted:** Detect incomplete downloads on next launch. Delete partial files and restart download. Show clear progress and "download failed, tap to retry" UI.
- **STT returns empty:** Don't send empty text to the LLM. Show "I didn't catch that — try again?" message.
- **LLM generates garbage or system prompt leakage:** Strip any text that contains system prompt fragments before displaying. If the response is clearly broken (empty, just whitespace, or contains `<|` tokens), discard and show a gentle retry message.
- **TTS fails:** Fall back to displaying text without audio. Don't crash.
- **Disk full:** Check available space before writing answer files. Alert the user if space is critically low.

### Accessibility
- All interactive elements must have accessibility labels
- The conversation transcript must be accessible to VoiceOver
- Support Dynamic Type for all text
- The mic button should have a clear accessibility action ("Start recording your answer" / "Stop recording")
- Ensure sufficient colour contrast for the RED/YELLOW/GREEN coverage indicators (don't rely on colour alone — add text labels like "Needs answers", "Building depth", "Ready")

---

## Distribution: TestFlight

This app is distributed via TestFlight only. It will not be submitted to the App Store.

### Requirements
- Apple Developer Program membership ($99/year) — required for TestFlight
- Bundle ID: `com.lifehug.app` (or your preferred reverse-domain identifier — set this once and never change it)
- Signing: Automatic signing in Xcode using your Apple Developer account

### Xcode Project Configuration
- Set the deployment target to iOS 18.0
- Enable the following capabilities in the target's Signing & Capabilities tab:
  - **Speech Recognition** — required for `SFSpeechRecognizer`
  - **Microphone Usage** — required for `AVAudioEngine`
  - **Background Modes > Audio** — allows TTS to continue if app is briefly backgrounded
  - **Increased Memory Limit** — add the `com.apple.developer.kernel.increased-memory-limit` entitlement (required for ML model loading)
- Add the following keys to `Info.plist` with user-facing descriptions:
  - `NSSpeechRecognitionUsageDescription` — "Lifehug uses speech recognition to transcribe your spoken answers. All processing happens on your device."
  - `NSMicrophoneUsageDescription` — "Lifehug uses the microphone to record your spoken answers. Audio is never stored or transmitted."
- **Privacy Manifest** (`PrivacyInfo.xcprivacy`): Include a privacy manifest declaring no data collection. Required for TestFlight processing. Declare the `NSPrivacyAccessedAPIType` entries for any APIs you use (e.g., `UserDefaults`, file timestamp APIs).

### Build & Upload Process
1. In Xcode: Product > Archive
2. Distribute App > TestFlight & App Store > Upload
3. In App Store Connect: add testers by email under the Internal Testing group
4. Testers install via the TestFlight app on their iPhone
5. Maximum 100 internal testers, no review required

### TestFlight-specific behaviour
- The app must not crash on launch on a clean install — the launch/download screen must handle every state (no model, partial download, download complete, model loaded)
- TestFlight builds expire after 90 days — upload a new build before expiry to maintain access
- Do not hardcode any build numbers — let Xcode manage them automatically via `CURRENT_PROJECT_VERSION`

---

## Non-negotiable Constraints

1. Zero network calls during any AI interaction — STT, LLM, and TTS all run fully on-device
2. Answer files must be written in exactly the markdown format defined in this repo so they remain compatible with the desktop tool
3. Rotation engine logic must match `system/ask.py` — do not simplify or approximate it
4. Models must be downloaded once and cached — never re-downloaded unless user explicitly resets in Settings
5. App must be fully usable after first-launch model download with no internet connection whatsoever
6. No analytics, no telemetry, no crash reporting SDKs — privacy is the core value proposition
7. App must pass TestFlight processing — avoid any APIs that trigger extra review (no StoreKit, no ad frameworks, no web browser entitlements)

---

## Build Order

Build and verify in this sequence to avoid integration problems. Each step should compile and run before moving to the next.

1. **Project scaffold + SPM resolution** — Create the Xcode project, add SPM dependencies, verify they resolve and the project builds with no code yet. This catches dependency issues early.

2. **Data models + StorageService** — Define all Codable structs (Question, Answer, RotationState, CoverageState, UserConfig). Implement file I/O: read/write JSON, read/write markdown answer files. Write unit tests that verify the answer file format matches the repo spec exactly.

3. **QuestionBankParser** — Port the markdown parsing from `ask.py` (`parse_categories` and `parse_questions`). Unit test against the actual `system/question-bank.md` file from this repo.

4. **RotationEngine** — Port `pick_next_question`, `update_coverage`, `mark_answered_in_md` from `ask.py`. Unit test the rotation logic: verify it picks the lowest-coverage category, alternates groups, interleaves spotlights at the configured frequency.

5. **ModelDownloader + LaunchView** — Model fetch with progress reporting, cache verification, resume/retry on failure. Test on a real device with airplane mode toggling.

6. **STTService** — Streaming on-device recognition, silence detection, transcript finalisation. Test on a real device (the simulator's mic support is limited).

7. **LLMService** — Model loading from cache, streaming token generation, context assembly with the system prompt template. Test on a real device for performance.

8. **TTSService** — TTS initialisation, sentence-level audio generation, queued playback. Test both Kokoro (if available) and AVSpeechSynthesizer fallback.

9. **VoicePipeline** — Wire STT > LLM > TTS with sentence boundary streaming and interrupt handling. This is the critical integration point — test end-to-end on device.

10. **DailyQuestionView + ConversationView** — Full conversation flow with the pipeline.

11. **Onboarding, Progress, Answers Browser, Settings** — These are standard SwiftUI screens with no complex dependencies.

Do not proceed to step N+1 until step N compiles, runs, and passes its tests.
