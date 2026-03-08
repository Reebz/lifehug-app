---
status: completed
priority: p3
issue_id: "020"
tags: [code-review, performance, ios]
dependencies: ["014"]
---

# Debounce Auto-Save Writes

## Problem Statement
`autoSave()` fires on every conversation turn, re-serializing the entire history and writing to UserDefaults synchronously. For a 20-turn conversation, this means 20 full re-serializations of increasing size.

## Findings
- **Source**: Performance Oracle (#4)
- **File**: `Lifehug/Lifehug/App/SessionState.swift`
- Each call creates a new `SaveableTurn` array, encodes to JSON, writes to disk
- UserDefaults writes are synchronous plist writes

## Proposed Solutions

### Option A: Debounce with 2-3 second delay
Cancel pending save on new turn, only write latest state.
- **Pros**: Reduces writes from N to ~1-2 per conversation burst
- **Cons**: Risk of data loss if crash within debounce window (acceptable for crash recovery)
- **Effort**: Small
- **Risk**: Low

## Acceptance Criteria
- [ ] Auto-save debounced with configurable delay
- [ ] At most 1-2 disk writes per conversation burst

## Work Log
- 2026-03-08: Created from code review of commit ac14023
