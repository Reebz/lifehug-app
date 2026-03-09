---
status: pending
priority: p1
issue_id: "038"
tags: [code-review, quality, kokoro]
dependencies: []
---

# Duplicate KokoroError Enums in KokoroManager

## Problem Statement

KokoroManager contains two separate `enum KokoroError` declarations: one at line 221 (Error) with `engineNotLoaded`/`voiceNotFound`, and another at line 394 (LocalizedError) with `downloadFailed`/`voicesEmpty`/`integrityCheckFailed`. This is confusing and can cause silent error mishandling in catch blocks.

## Findings

- **Source:** Architecture Strategist, Code Simplicity Reviewer, Pattern Recognition Specialist (all 3 flagged this)
- **File:** `Lifehug/Services/KokoroManager.swift` lines 221-224 and 394-409

## Proposed Solutions

### Option A: Merge into single enum
- Combine all cases into one `enum KokoroError: LocalizedError`
- Add `errorDescription` for all cases
- **Effort:** Small
- **Risk:** Low

## Acceptance Criteria

- [ ] Single KokoroError enum with all 5 cases
- [ ] All cases conform to LocalizedError

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-03-10 | Created from code review | 3 agents independently flagged this |
