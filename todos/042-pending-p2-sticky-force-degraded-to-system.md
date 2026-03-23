---
status: pending
priority: p2
issue_id: "042"
tags: [code-review, ux, tts]
dependencies: []
---

# forceDegradedToSystem Never Resets

## Problem Statement

`TTSService.forceDegradedToSystem` is set to `true` on Kokoro failure or memory pressure but is never reset. Users who experience a transient failure are stuck on system TTS for the entire app session — no way to recover without force-quitting.

## Findings

- **Source:** Architecture Strategist
- **File:** `Lifehug/Services/TTSService.swift` line 10

## Proposed Solutions

### Option A: Reset on foreground with sufficient memory
- In LifehugApp scene phase handler, reset forceDegradedToSystem if memory is OK and Kokoro is still loaded
- **Effort:** Small

### Option B: Also reload Kokoro on foreground
- Reset forceDegradedToSystem AND reload Kokoro engine (mirrors LLM reload pattern)
- **Effort:** Small

## Acceptance Criteria

- [ ] Transient Kokoro failure doesn't permanently degrade TTS for the session
- [ ] Memory pressure degradation respects current memory state on recovery

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-03-10 | Created from code review | Architecture Strategist identified sticky flag |
