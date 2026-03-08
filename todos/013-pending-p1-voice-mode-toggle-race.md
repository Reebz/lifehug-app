---
status: completed
priority: p1
issue_id: "013"
tags: [code-review, concurrency, ios, ux]
dependencies: []
---

# Voice Mode Toggle Race Condition

## Problem Statement
`toggleVoiceMode()` in ConversationView creates an untracked `Task` for activation. If the user rapidly taps the mic toggle, the deactivation path (`voiceMode = false; pipeline?.stopAll()`) does not cancel the pending activation Task. The activation task could complete after deactivation, setting `voiceMode = true` and creating a dangling pipeline.

## Findings
- **Source**: Architecture Strategist (Risk #4)
- **File**: `Lifehug/Lifehug/Views/ConversationView.swift`, lines 343-388
- The `Task { ... }` is fire-and-forget — not stored in any `@State` property
- No `Task.checkCancellation()` after the `await llmService.loadModel()` call
- Model loading can take 10+ seconds on first use, widening the race window

## Proposed Solutions

### Option A: Track activation task and cancel on deactivate
Store the Task in `@State private var voiceModeTask: Task<Void, Never>?`. Cancel it in the else branch. Add `try Task.checkCancellation()` after model load.
- **Pros**: Simple, correct, idiomatic Swift concurrency
- **Cons**: None
- **Effort**: Small
- **Risk**: Low

## Acceptance Criteria
- [ ] Activation task stored in @State and cancelled on deactivation
- [ ] `Task.checkCancellation()` called after model load await
- [ ] Rapid toggle does not leave UI in inconsistent state

## Work Log
- 2026-03-08: Created from code review of commit ac14023
