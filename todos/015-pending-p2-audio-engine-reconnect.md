---
status: completed
priority: p2
issue_id: "015"
tags: [code-review, performance, ios, audio]
dependencies: []
---

# Audio Engine Reconnects on Every Utterance

## Problem Statement
`KokoroManager.playAudio()` calls `engine.connect()` and `engine.start()` on every utterance. This introduces per-sentence latency and potential audio pops in voice conversations.

## Findings
- **Source**: Performance Oracle (#1)
- **File**: `Lifehug/Lifehug/Services/KokoroManager.swift`, line 241
- `engine.connect(player, to: engine.mainMixerNode, format: format)` runs every call
- `engine.start()` is synchronous and can block main thread for several ms

## Proposed Solutions

### Option A: Move connect/start to setupAudioEngine()
Connect the player node graph once in `setupAudioEngine()`. Only call `engine.start()` in `playAudio()` if `!engine.isRunning`.
- **Pros**: Eliminates per-utterance overhead, prevents audio pops
- **Cons**: Must handle format changes if voice sample rate ever varies
- **Effort**: Small
- **Risk**: Low

## Acceptance Criteria
- [ ] `engine.connect()` called once in setupAudioEngine()
- [ ] `engine.start()` only called when engine is not running
- [ ] No audible pops between sentences in voice mode

## Work Log
- 2026-03-08: Created from code review of commit ac14023
