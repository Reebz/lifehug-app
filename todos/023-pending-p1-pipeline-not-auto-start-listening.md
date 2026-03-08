---
status: completed
priority: p1
issue_id: "023"
tags: [code-review, ux, voice, ios]
dependencies: ["021"]
---

# Voice Pipeline Created But Doesn't Auto-Start Listening

## Problem Statement
When the user toggles voice mode ON in ConversationView, `toggleVoiceMode()` creates the VoicePipeline and sets up all callbacks, but never calls `startListening()`. The pipeline sits idle showing "Tap mic to start" — the user must tap another button to actually begin. This extra step makes voice mode feel broken.

## Findings
- **Source**: UX Regression Review
- **File**: `ConversationView.swift`, `toggleVoiceMode()` lines 345-393
- Pipeline is created at line 360, callbacks wired, but no `p.startListening()` call
- The voice input bar shows "Tap mic to start" in idle state (line 254)
- User expectation: toggle voice mode ON → mic immediately starts listening
- Actual: toggle ON → "Tap mic to start" → user taps mic → THEN listening starts

## Proposed Solutions

### Option A: Call startListening() after pipeline setup
Add `p.startListening()` at the end of the `toggleVoiceMode()` setup block (after `pipeline = p`).
- **Pros**: Immediate voice activation, matches user expectation
- **Cons**: None
- **Effort**: Trivial (1 line)
- **Risk**: Low

## Acceptance Criteria
- [ ] Toggling voice mode ON immediately starts listening
- [ ] No extra tap required to begin speaking

## Work Log
- 2026-03-08: Created from UX regression review
