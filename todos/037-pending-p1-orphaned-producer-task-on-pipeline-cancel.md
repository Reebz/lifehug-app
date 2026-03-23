---
status: pending
priority: p1
issue_id: "037"
tags: [code-review, concurrency, voice-pipeline]
dependencies: []
---

# Orphaned Producer Task Not Cancelled When Pipeline Transitions

## Problem Statement

In VoicePipeline.processUserInput(), the `producer` Task is an unstructured task that is NOT cancelled when `activeTask` is cancelled. If the user taps interrupt mid-response, the outer activeTask gets cancelled, but the producer keeps consuming LLM tokens that nobody will ever hear — wasting CPU, GPU, and battery.

## Findings

- **Source:** Concurrency Races Reviewer
- **File:** `Lifehug/Pipeline/VoicePipeline.swift` lines 239-266
- The `producer` Task on line 239 is `Task { }` — an unstructured task
- When `transition(to:)` cancels `activeTask`, the producer is not a child task and continues running
- The orphaned producer keeps pulling LLM tokens, writing to responseChunks and sentenceBuffer

## Proposed Solutions

### Option A: Explicitly cancel producer after consumer loop
- Add `producer.cancel()` before `try await producer.value`
- Also cancel in the catch block
- **Pros:** Simple, minimal change
- **Cons:** Producer still runs briefly before cancellation propagates
- **Effort:** Small
- **Risk:** Low

### Option B: Use TaskGroup for structured cancellation
- Replace unstructured Task with a TaskGroup
- When the group is cancelled, both producer and consumer are cancelled
- **Pros:** Automatic cancellation propagation
- **Cons:** More restructuring needed
- **Effort:** Medium
- **Risk:** Low

## Recommended Action

_To be filled during triage_

## Technical Details

- **Affected files:** VoicePipeline.swift

## Acceptance Criteria

- [ ] Interrupting mid-response cancels LLM token generation
- [ ] No orphaned tasks consuming resources after pipeline transition

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-03-10 | Created from code review | Concurrency races reviewer identified orphan |

## Resources

- Concurrency Races Reviewer agent analysis
