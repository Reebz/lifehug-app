---
status: pending
priority: p1
issue_id: "035"
tags: [code-review, concurrency, crash-risk, tts]
dependencies: []
---

# TTSService Delegate Can Resume Wrong Continuation After Stop→Re-Speak

## Problem Statement

When `stop()` is called then `speak()` is called again immediately (e.g., interrupt → new response), the old delegate's `didFinish` callback can resume the **new** continuation prematurely, causing the new utterance's caller to think it finished while it's still playing.

## Findings

- **Source:** Concurrency Races Reviewer
- **File:** `Lifehug/Services/TTSService.swift` lines 30-38, 59-82
- Sequence: stop() resumes old continuation and nils it → new speakViaSystem() sets new continuation → old delegate Task fires and sees the NEW continuation → resumes it prematurely
- Result: overlapping speech, caller thinks utterance finished early
- KokoroManager.playAudio already has the correct pattern: `OSAllocatedUnfairLock<Bool>` per-invocation

## Proposed Solutions

### Option A: OSAllocatedUnfairLock per-utterance (match KokoroManager pattern)
- Create a `resumed` lock per `speakViaSystem()` call
- Both delegate callback and stop() check-and-set through the lock
- **Pros:** Proven pattern already in codebase, eliminates race
- **Cons:** Slightly more code per speak call
- **Effort:** Small
- **Risk:** Low

### Option B: Generation counter on TTSService
- Increment `speakGeneration` in stop() and speakViaSystem()
- Delegate callback captures generation, only resumes if it matches current
- **Pros:** Lightweight, familiar pattern (already used in STTService)
- **Cons:** Must ensure generation is captured correctly in @Sendable closure
- **Effort:** Small
- **Risk:** Low

## Recommended Action

_To be filled during triage_

## Technical Details

- **Affected files:** TTSService.swift

## Acceptance Criteria

- [ ] Rapid stop→speak sequence does not resume wrong continuation
- [ ] No overlapping speech artifacts
- [ ] No CheckedContinuation double-resume crash

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-03-10 | Created from code review | Concurrency races reviewer identified timing window |

## Resources

- KokoroManager.playAudio lines 278-291 — reference implementation of the lock pattern
