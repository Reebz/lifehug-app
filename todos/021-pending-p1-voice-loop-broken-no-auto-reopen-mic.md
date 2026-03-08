---
status: completed
priority: p1
issue_id: "021"
tags: [code-review, ux, voice, ios]
dependencies: []
---

# Voice Conversation Loop Broken — Mic Never Auto-Reopens After TTS

## Problem Statement
After the AI speaks a response via TTS, the microphone never reopens for the next user turn. The `autoReopenMic` flag is set to `true` in `ConversationView.toggleVoiceMode()` but the VoicePipeline never acts on it after TTS finishes speaking. The result is a dead conversation — the AI speaks once, then the pipeline sits idle. The user must manually tap the mic button again for each exchange.

## Findings
- **Source**: UX Regression Review
- **File**: `Lifehug/Lifehug/Pipeline/VoicePipeline.swift`, lines 206-248
- `autoReopenMic` is only checked in `handleInterruption()` (line 300) — an audio session interruption recovery path
- After `processUserInput()` finishes TTS (line 239 `onResponseGenerated`), the state is left as-is with no transition back to `.listening`
- `TTSService.onAllSpeechFinished` callback exists but is never connected to VoicePipeline
- The user expects: speak → AI responds with voice → mic auto-reopens → speak again (continuous loop)
- Actual behavior: speak → AI responds with voice → dead silence, pipeline idle

## Proposed Solutions

### Option A: Reopen mic after processUserInput completes TTS
After `onResponseGenerated?(fullResponse)` in `processUserInput()`, check `autoReopenMic` and call `transition(to: .listening)`.
- **Pros**: Simple, keeps logic in pipeline
- **Cons**: None significant
- **Effort**: Small
- **Risk**: Low

## Acceptance Criteria
- [ ] After AI speaks response, mic automatically reopens if `autoReopenMic == true`
- [ ] Continuous voice conversation loop works: user speaks → AI speaks → user speaks → ...
- [ ] Pipeline state transitions correctly: listening → processing → speaking → listening

## Work Log
- 2026-03-08: Created from UX regression review
