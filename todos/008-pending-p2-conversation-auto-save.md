---
status: completed
priority: p2
issue_id: "008"
tags: [code-review, data-integrity, ios]
dependencies: []
---

# Conversation turns not auto-saved — crash loses all data

## Problem Statement

Conversation turns exist only in `SessionState` (in-memory `@Observable`). If the app crashes, is jetsammed, or the user force-quits during a 10-minute voice session, all unsaved conversation turns are lost. This is especially risky given the tight memory budget.

## Findings

- `SessionState.swift` — `conversationTurns` is purely in-memory
- No draft/auto-save mechanism exists
- The only save point is "End Session & Save" button tap in ConversationView
- Voice sessions while driving could be 5-15 minutes long
- Memory pressure makes jetsam kills a real risk (see todo 005)

## Proposed Solutions

### Option 1: Auto-save each turn to a draft file

**Approach:** After each `addTurn()`, write conversation state to `drafts/in-progress-{questionID}.json`. Clean up on explicit save or discard.

**Pros:**
- Protects against data loss
- Simple implementation
- Draft can be resumed on next launch

**Cons:**
- Small disk I/O overhead per turn

**Effort:** 2 hours

**Risk:** Low

## Technical Details

**Affected files:**
- `Lifehug/Lifehug/App/SessionState.swift` — add auto-save after addTurn()
- `Lifehug/Lifehug/Services/StorageService.swift` — add draft read/write methods

## Acceptance Criteria

- [ ] Each conversation turn auto-saved to draft file
- [ ] Draft file cleaned up on explicit save
- [ ] On launch, check for in-progress drafts and offer to resume
- [ ] No noticeable UI lag from auto-save

## Work Log

### 2026-03-08 - Initial Discovery

**By:** Claude Code (spec flow analysis during /deepen-plan)
