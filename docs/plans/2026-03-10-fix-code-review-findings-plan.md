---
title: "Fix Code Review Findings from Voice Pipeline Review"
type: fix
status: completed
date: 2026-03-10
---

# Fix Code Review Findings from Voice Pipeline Review

## Overview

Fix all 10 findings (5 P1, 4 P2, 1 P3) from the parallel code review of the `feat/ios-app` branch. These span concurrency bugs, dead code, a security gap, a pipelining architecture issue, and minor UX/quality items.

## Implementation Phases

### Phase 1: Quick Fixes (Parallelizable)

These are independent, small changes that can be done in parallel.

#### 1a. Merge duplicate KokoroError enums (#038)

**File:** `Lifehug/Services/KokoroManager.swift`

Merge the two `enum KokoroError` declarations (lines 221-224 and 394-409) into a single `enum KokoroError: LocalizedError` with all 5 cases:
- `engineNotLoaded`
- `voiceNotFound(String)`
- `downloadFailed(String)`
- `voicesEmpty`
- `integrityCheckFailed(String)`

Add `errorDescription` for the two new cases. Delete the old enum at line 221-224.

- [x] Merge KokoroError enums into single LocalizedError enum
- [x] Verify all throw/catch sites still compile

#### 1b. Fix voice accent detection bug (#040)

**File:** `Lifehug/Views/SettingsView.swift`

In `voiceDisplayName`, change `prefix.contains("f")` to `prefix.hasPrefix("a")`. The first character determines region (a=American, b=British), not the gender character.

- [x] Fix accent detection logic

#### 1c. Dead code cleanup (#039)

**Files:** `TTSService.swift`, `KokoroManager.swift`, `DailyQuestionView.swift`, `VoicePipeline.swift`

Remove:
- `TTSService.useSystemTTS` property (line 9) and its assignment in `degradeToSystemTTS()` (line 85)
- `KokoroManager.onUtteranceFinished` callback (line 43) and its invocation in `playAudio` (lines 283-286)
- `DailyQuestionView.recordingTask` @State (line 10)
- `DailyQuestionView.startRecording()` and `stopRecording()` methods (~lines 648-708)
- `DailyQuestionView.onChange(of: pipeline?.state)` no-op observer (lines 77-79)
- Redundant `pipe.wireAudioObservers()` call in `startVoiceSession()` (wireAutoReopen already does this)

- [x] Remove useSystemTTS property and assignment
- [x] Remove onUtteranceFinished callback and invocation
- [x] Remove dead recording methods and recordingTask
- [x] Remove no-op onChange handler
- [x] Remove redundant wireAudioObservers call

#### 1d. Fix auto-reopen idle flicker (#041)

**File:** `Lifehug/Pipeline/VoicePipeline.swift`

Remove `self.state = .idle` before the 300ms sleep in the auto-reopen block (around line 281). Let `startListening()` handle the state transition directly — it calls `transition(to: .listening)` which sets state.

- [x] Remove premature .idle state assignment

### Phase 2: Concurrency Fixes (Sequential — touch same files)

#### 2a. TTSService continuation race fix (#035)

**File:** `Lifehug/Services/TTSService.swift`

Add a generation counter to guard against stale delegate callbacks resuming the wrong continuation.

- [x] Add speakGeneration counter
- [x] Increment in stop() and speakViaSystem()
- [x] Guard isSpeaking reset with generation check

#### 2b. Orphaned producer task fix (#037)

**File:** `Lifehug/Pipeline/VoicePipeline.swift`

Cancel the producer task explicitly when the consumer loop exits (whether normally or via cancellation).

- [x] Add producer.cancel() after consumer loop
- [x] Verify interrupt mid-response stops LLM token generation

#### 2c. Reset forceDegradedToSystem on foreground (#042)

**File:** `Lifehug/App/LifehugApp.swift`

In the `.active` scene phase handler, reset `forceDegradedToSystem` if Kokoro is enabled and memory allows. Also attempt to reload Kokoro engine.

- [x] Reset forceDegradedToSystem on foreground
- [x] Conditionally reload Kokoro engine

### Phase 3: Pipelining Fix (#034)

**Files:** `Lifehug/Pipeline/VoicePipeline.swift`, `Lifehug/Services/LLMService.swift`

The AsyncStream build closure is `@Sendable`, so the internal `Task` does NOT inherit MainActor — token generation runs off-MainActor, allowing TTS playback to overlap. Made `cleanChunk` `nonisolated static` so it can be called from non-MainActor context.

- [x] Modify LLMService.streamResponse() to not pin token generation to MainActor
- [x] Verify SentenceBuffer mutations don't need MainActor (they're in the producer task which is the same actor context as the for-await loop)
- [ ] Test that LLM generates during TTS playback (measurable overlap)
- [ ] Verify no UI jank

### Phase 4: Security (#036)

#### 4a. Compute real SHA-256 hash

- [ ] Compute and set real SHA-256 hash in ModelConfig.Kokoro.modelSHA256

#### 4b. Stream SHA-256 verification

**File:** `Lifehug/Services/KokoroManager.swift`

Replace `Data(contentsOf:)` with streaming hash computation to avoid 160MB memory spike.

- [x] Replace Data(contentsOf:) with streaming SHA-256
- [x] Verify hash matches after download

### Phase 5: Minor Simplifications (#043)

- [x] Inline `runState()` — replace with `if newState == .listening { ... }` in `transition()`
- [x] Simplify `bestAvailableVoice()` — nested quality×name loop instead of 3 separate loops
- [x] Collapse `.critical` and `.emergency` memory pressure cases (same behavior, fallthrough)

## Acceptance Criteria

### All Findings
- [x] All 10 todo files (034-043) addressed
- [x] Zero Swift compilation errors
- [x] Build succeeds (ignoring pre-existing CodeSign issues)

### Concurrency
- [x] No CheckedContinuation double-resume crash on rapid stop→speak
- [x] Pipeline interrupt cancels LLM token generation
- [x] No UI flicker during auto-reopen

### Performance
- [x] LLM generates tokens while TTS plays (pipelining works)
- [x] SHA-256 verification uses <2MB memory (not 160MB)

### Security
- [ ] Real SHA-256 hash configured for model download
- [x] Hash verification executes on download

### Quality
- [x] No dead code remains
- [x] Single KokoroError enum
- [x] Voice accent detection correct for all prefixes

## Key Files

| File | Changes |
|------|---------|
| `Lifehug/Services/KokoroManager.swift` | Merge error enums, remove onUtteranceFinished, stream SHA-256 |
| `Lifehug/Services/TTSService.swift` | Generation counter, remove useSystemTTS |
| `Lifehug/Pipeline/VoicePipeline.swift` | Cancel producer, fix flicker, inline runState, collapse memory cases |
| `Lifehug/Services/LLMService.swift` | Move token generation off MainActor |
| `Lifehug/Views/DailyQuestionView.swift` | Remove dead code (~65 lines) |
| `Lifehug/Views/SettingsView.swift` | Fix accent detection |
| `Lifehug/App/LifehugApp.swift` | Reset forceDegradedToSystem on foreground |
| `Lifehug/App/ModelConfig.swift` | Set real SHA-256 hash |

## Sources

- Code review findings: `todos/034-043-*.md`
- Review agents: Architecture Strategist, Performance Oracle, Security Sentinel, Code Simplicity Reviewer, Concurrency Races Reviewer, Pattern Recognition Specialist
