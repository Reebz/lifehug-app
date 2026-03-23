---
status: pending
priority: p2
issue_id: "041"
tags: [code-review, ux, voice-pipeline]
dependencies: []
---

# Auto-Reopen Sets State to .idle Causing UI Flicker

## Problem Statement

After TTS finishes, the auto-reopen code sets `state = .idle` then sleeps 300ms before calling `startListening()`. During those 300ms, the UI shows idle state (record indicator disappears) then flips back to listening. Users see a visible jank.

## Findings

- **Source:** Concurrency Races Reviewer
- **File:** `Lifehug/Pipeline/VoicePipeline.swift` lines 281-284

## Fix

Remove `self.state = .idle` before the sleep. Let `startListening()` handle the state transition directly.

## Acceptance Criteria

- [ ] No visible UI flicker between TTS finishing and mic reopening
- [ ] Auto-reopen still works with 300ms delay

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-03-10 | Created from code review | Concurrency Races Reviewer identified flicker |
