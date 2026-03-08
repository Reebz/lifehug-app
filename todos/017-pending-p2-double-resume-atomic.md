---
status: completed
priority: p2
issue_id: "017"
tags: [code-review, concurrency, ios]
dependencies: []
---

# Double-Resume Guard Uses Non-Atomic Flag

## Problem Statement
The `resumed` boolean guard in `KokoroManager.playAudio()` uses `nonisolated(unsafe) var` which is not atomic. If AVAudioPlayerNode calls the completion callback from multiple threads simultaneously, the read-check-write is a data race.

## Findings
- **Source**: Security Sentinel (M2)
- **File**: `Lifehug/Lifehug/Services/KokoroManager.swift`, lines 255-263
- Thread Sanitizer would flag this pattern
- Similarly, `SegmentState` in STTService lacks synchronization (Security M1)

## Proposed Solutions

### Option A: Use OSAllocatedUnfairLock<Bool>
Replace with `OSAllocatedUnfairLock<Bool>(initialState: false)` and use `withLock`.
- **Pros**: Correct, minimal overhead, iOS 16+
- **Cons**: Slightly more verbose
- **Effort**: Small
- **Risk**: Low

## Acceptance Criteria
- [ ] `resumed` flag uses atomic or locked access
- [ ] SegmentState in STTService also gets lock protection
- [ ] No Thread Sanitizer warnings

## Work Log
- 2026-03-08: Created from code review of commit ac14023
