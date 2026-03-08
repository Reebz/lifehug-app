---
status: completed
priority: p2
issue_id: "006"
tags: [code-review, architecture, simplicity, ios]
dependencies: []
---

# Plan over-engineers: don't create VoiceConversationView or VoiceSessionState

## Problem Statement

The original plan proposed creating `VoiceConversationView.swift` and `VoiceSessionState.swift` as new files. The simplicity review found this duplicates existing functionality and adds unnecessary complexity. The deepened plan already incorporates this feedback but this todo ensures implementation follows through.

## Findings

- `SessionState.swift` already holds `currentQuestion`, `conversationTurns`, `isRecording`, `draftTranscript` — everything needed for voice conversations
- Creating `VoiceSessionState` would duplicate `compileAnswer()`, `resetSession()`, and conversation turn management
- `DailyQuestionView` already has the mic button, transcript area, and navigation — extending it with voice mode toggle avoids duplicating question display and save logic
- `BookService` as a full `@Observable` class is unnecessary — a static function + StorageService methods suffice
- Estimated ~200-250 LOC saved by not creating these files

## Proposed Solutions

### Option 1: Follow deepened plan's simplified architecture

**Approach:** Extend `DailyQuestionView` with voice mode inline. Add `voiceMode: Bool` to `SessionState`. Use `ChapterGenerator` enum with static function instead of `BookService` class.

**Pros:**
- ~30-40% fewer lines of new code
- No duplicated save logic
- Simpler mental model

**Cons:**
- DailyQuestionView gets more complex (but still single-responsibility: "today's question interaction")

**Effort:** N/A (architectural decision, saves effort)

**Risk:** Low

## Technical Details

**Files NOT to create:**
- ~~`VoiceConversationView.swift`~~ — extend DailyQuestionView instead
- ~~`VoiceSessionState.swift`~~ — add `inputMode` to SessionState instead
- ~~`BookService.swift`~~ — use ChapterGenerator enum with static functions

**Files to modify:**
- `DailyQuestionView.swift` — add voice mode state and UI
- `SessionState.swift` — add `inputMode: InputMode` enum property
- `StorageService.swift` — add `draftsDirectory`, `readDraft`, `writeDraft`

## Acceptance Criteria

- [ ] No `VoiceConversationView.swift` file created
- [ ] No `VoiceSessionState.swift` file created
- [ ] No `BookService.swift` class created
- [ ] Voice mode integrated into DailyQuestionView
- [ ] Chapter generation uses static function pattern

## Work Log

### 2026-03-08 - Initial Discovery

**By:** Claude Code (simplicity review during /deepen-plan)
