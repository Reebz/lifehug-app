---
status: pending
priority: p1
issue_id: "034"
tags: [code-review, performance, concurrency, voice-pipeline]
dependencies: []
---

# AsyncStream Pipelining Defeated by @MainActor Serialization

## Problem Statement

The sentence pipelining feature (AsyncStream producer/consumer in VoicePipeline.processUserInput) was designed to let the LLM generate sentence N+1 while TTS plays sentence N. **This is not happening.** Both the producer and consumer run on @MainActor, so they are cooperatively scheduled on the same serial executor. The LLM cannot generate tokens while TTS is playing because both are waiting for MainActor time.

The net effect: every sentence adds the full LLM-generation latency as a gap between spoken sentences. For a 5-sentence response, this means 2-5 extra seconds of silence gaps that pipelining was supposed to eliminate.

## Findings

- **Source:** Performance Oracle agent
- **File:** `Lifehug/Pipeline/VoicePipeline.swift` lines 231-293
- **File:** `Lifehug/Services/LLMService.swift` lines 83-116
- `VoicePipeline` is `@MainActor`. The `activeTask` and `producer` Task both inherit @MainActor.
- `LLMService.streamResponse()` creates its own `Task { @MainActor in ... }`, pinning token generation to MainActor.
- Since both producer and consumer run on the same serial executor, the pipelining benefit is illusory.

## Proposed Solutions

### Option A: Move LLM stream consumption off MainActor
- Move the token generation loop in `LLMService.streamResponse()` to a background context
- Only hop to MainActor for UI updates (`responseChunks`, `isGenerating`)
- Make the producer Task in processUserInput use `Task.detached` or a non-MainActor context
- **Pros:** True pipelining, eliminates inter-sentence gaps
- **Cons:** Requires careful isolation of UI state updates
- **Effort:** Medium
- **Risk:** Medium — must ensure sentenceBuffer and fullResponse mutations are thread-safe

### Option B: Keep sequential but optimize latency
- Accept that pipelining doesn't work on MainActor
- Remove AsyncStream overhead, revert to simpler sequential loop
- Focus on reducing per-sentence TTS latency instead
- **Pros:** Simpler code, no concurrency risks
- **Cons:** Does not fix the inter-sentence gap problem
- **Effort:** Small
- **Risk:** Low

## Recommended Action

_To be filled during triage_

## Technical Details

- **Affected files:** VoicePipeline.swift, LLMService.swift
- **Components:** Voice pipeline, LLM streaming

## Acceptance Criteria

- [ ] LLM generates tokens while TTS plays previous sentence (measurable overlap)
- [ ] No UI jank during concurrent generation
- [ ] Inter-sentence silence gaps reduced by >50%

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-03-10 | Created from code review | Performance Oracle identified @MainActor serialization defeating pipelining |

## Resources

- Performance Oracle agent analysis
