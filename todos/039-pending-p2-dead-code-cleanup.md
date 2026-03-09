---
status: pending
priority: p2
issue_id: "039"
tags: [code-review, quality, dead-code]
dependencies: []
---

# Dead Code Cleanup (~82 lines)

## Problem Statement

Multiple unused properties, methods, and handlers across the codebase. ~82 lines of dead code that increases cognitive load.

## Findings

- **Source:** Code Simplicity Reviewer
- `TTSService.useSystemTTS` — property set but never read (lines 9, 85)
- `KokoroManager.onUtteranceFinished` — callback declared and fired but never assigned by any caller (line 43, 283-286)
- `DailyQuestionView.startRecording/stopRecording` — 61 lines of dead recording fallback never called (lines 648-708)
- `DailyQuestionView.recordingTask` — unused @State (line 10)
- `DailyQuestionView.onChange(of: pipeline?.state)` — no-op observer (lines 77-79)
- `VoicePipeline.wireAudioObservers()` — redundant call in DailyQuestionView since wireAutoReopen() does the same thing

## Acceptance Criteria

- [ ] All identified dead code removed
- [ ] Build still succeeds
- [ ] No behavioral changes

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-03-10 | Created from code review | Code Simplicity Reviewer identified ~82 LOC |
