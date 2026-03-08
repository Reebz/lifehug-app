---
status: completed
priority: p2
issue_id: "007"
tags: [code-review, architecture, ios, llm]
dependencies: []
---

# 1B model needs multi-pass chapter generation — single-pass produces incoherent text

## Problem Statement

Llama-3.2-1B-Instruct-4bit cannot coherently generate a full memoir chapter in one pass. The practical context window is ~2K-3K tokens, and the model lacks the reasoning capacity to simultaneously extract narrative arc, maintain voice, and produce polished prose.

## Findings

- Model's effective context window: 2048-3072 tokens (~1500-2300 words total including prompt + output)
- At ~150 words per answer, only 8-12 short answers fit in a single prompt
- `LLMService.maxTokens = 200` is too low for chapter generation (needs 500-800)
- Multi-pass pipeline proven effective: extract (temp 0.1) -> outline (temp 0.3) -> flesh out per-section (temp 0.7)
- Each pass fits within model's sweet spot, producing dramatically better output
- Total generation time: ~20-30 seconds for a 5-section chapter (streamable from second 3)

## Proposed Solutions

### Option 1: 3-pass pipeline as described in deepened plan

**Approach:**
1. Pass 1 (Extract): Compress each answer into key facts/phrases/emotions as bullets
2. Pass 2 (Outline): Generate 5-8 point narrative arc from bullets
3. Pass 3 (Flesh out): Generate 1-2 paragraphs per outline point, feeding previous section's last sentence for continuity

**Pros:**
- Dramatically better output quality
- Each pass is a simple, focused prompt
- Extracted bullets cacheable for reuse

**Cons:**
- 3x the inference calls
- ~20-30s total (but streamable)

**Effort:** 4-6 hours

**Risk:** Medium (quality depends on prompt tuning)

## Technical Details

**Affected files:**
- New: `ChapterGenerator` enum (or extension) with static `generate()` method
- `Lifehug/Lifehug/Services/LLMService.swift` — need per-call maxTokens (not global 200)
- `Lifehug/Lifehug/Services/StorageService.swift` — cache extracted bullets per answer

## Acceptance Criteria

- [ ] Chapter generation uses 3-pass pipeline
- [ ] Pass 1 bullets cached per answer (invalidated when answer changes)
- [ ] Generated chapters readable and coherent
- [ ] Progress indicator shown during generation
- [ ] maxTokens configurable per LLM call

## Work Log

### 2026-03-08 - Initial Discovery

**By:** Claude Code (chapter generation agent during /deepen-plan)
