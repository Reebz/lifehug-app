---
status: completed
priority: p2
issue_id: "026"
tags: [code-review, ux, voice, ios]
dependencies: ["022", "023"]
---

# First LLM Response Not Spoken Even After Voice Mode Enabled

## Problem Statement
When ConversationView loads, it immediately triggers `generateLLMResponse(to:)` in `.task`. This generates a TEXT response that is appended to conversation turns. Even if voice mode is later activated, this first response was already generated as text — it's never spoken aloud. The user sees text but hears nothing from the AI on the first exchange.

## Findings
- **Source**: UX Regression Review
- **File**: `ConversationView.swift`, lines 64-71 (`.task`) and lines 408-435 (`generateLLMResponse`)
- `generateLLMResponse` uses `llmService.respond(to:)` (non-streaming) and adds the response as text
- This runs BEFORE voice mode could possibly be activated
- The VoicePipeline processes user input through streaming LLM + TTS — but the initial response bypasses this entirely
- If voice mode is auto-activated (per fix #022), the initial response should route through the pipeline

## Proposed Solutions

### Option A: Route initial response through pipeline when voice mode is active
If `startInVoiceMode` is true, skip the text-based `generateLLMResponse` call and instead feed the user's first message through the VoicePipeline using `processTextInput()`.
- **Pros**: First response is spoken, consistent with voice flow
- **Cons**: Requires coordinating pipeline readiness with initial response timing
- **Effort**: Medium
- **Risk**: Low-Medium (timing between pipeline setup and initial response)

## Acceptance Criteria
- [ ] When entering from voice (mic button), the AI's first response is spoken aloud
- [ ] Response appears as text in the chat AND is spoken via TTS
- [ ] Text-mode entry still works as before (text-only response)

## Work Log
- 2026-03-08: Created from UX regression review
