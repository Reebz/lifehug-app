---
status: pending
priority: p1
issue_id: "029"
tags: [code-review, plan-accuracy, voice, ios]
dependencies: []
---

# Bug 3 Plan Would Break System TTS Auto-Reopen

## Problem Statement
The plan says to "Remove the `wireAutoReopen()` call from `DailyQuestionView.swift:484`" and the `unwireAutoReopen()` calls. But `wireAutoReopen` is **required for system TTS auto-reopen to work correctly**. Removing it would cause a regression where the mic never reopens after system TTS speaks.

## Findings
- **Source**: Architecture review + simplicity review + manual code validation
- **Files**: `VoicePipeline.swift`, `TTSService.swift`, `DailyQuestionView.swift` on `feat/ios-app`
- For Kokoro TTS: `speak()` is truly async (awaits playback completion via `withCheckedContinuation` in `playAudio`). The inline auto-reopen at `VoicePipeline.swift:273-278` fires AFTER all sentences complete. Works correctly.
- For system TTS: `speak()` appends to `sentenceQueue` and returns immediately (line 52-55 of TTSService). The inline auto-reopen fires BEFORE system TTS finishes speaking. This is why `wireAutoReopen` exists — `onAllSpeechFinished` fires only when `sentenceQueue` is empty (line 82-84).
- If `wireAutoReopen` is removed without making system TTS `speak()` awaitable first, the mic reopens while TTS is still speaking (for system TTS users).

## Proposed Solutions

### Option A: Keep wireAutoReopen, only delete TTSService line 49 (RECOMMENDED)
The 1-line fix (delete `onAllSpeechFinished?()` from Kokoro path at line 49) is the complete bug fix. Keep `wireAutoReopen` intact for system TTS. Do NOT remove the call from DailyQuestionView.
- **Pros**: Minimal change, no regression risk, fixes the reported bug completely
- **Cons**: `onAllSpeechFinished` callback pattern stays in codebase (some complexity)
- **Effort**: Tiny (1 line deletion)
- **Risk**: None

### Option B: Make system TTS awaitable THEN remove wireAutoReopen
Add `CheckedContinuation` to system TTS path, making `speak()` truly async for both paths. Then inline auto-reopen works for both, and `wireAutoReopen`/`onAllSpeechFinished`/`sentenceQueue`/`processSentenceQueue` can all be removed.
- **Pros**: Clean architectural simplification, removes complexity
- **Cons**: Larger change scope, TTSService rewrite bundled with bug fix
- **Effort**: Medium
- **Risk**: Medium (must guard CheckedContinuation double-resume on `stop()`)

### Option C: Plan's approach (remove wireAutoReopen without making system TTS awaitable)
- **Pros**: None
- **Cons**: **BREAKS system TTS auto-reopen**. Mic reopens while TTS is still speaking.
- **Effort**: Small
- **Risk**: HIGH — regression

## Recommended Action
Option A for the bug fix. Option B as a separate follow-up task.

## Acceptance Criteria
- [ ] Plan updated to NOT remove wireAutoReopen from DailyQuestionView
- [ ] Plan updated to only delete TTSService line 49 for the immediate fix
- [ ] If CheckedContinuation refactor is desired, it's a separate task

## Work Log
- 2026-03-09: Identified by architecture + simplicity reviewers during `/ce:review`
