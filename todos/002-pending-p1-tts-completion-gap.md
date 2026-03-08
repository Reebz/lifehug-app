---
status: completed
priority: p1
issue_id: "002"
tags: [code-review, architecture, ios, voice-pipeline]
dependencies: []
---

# TTSService.speak() doesn't signal completion — pipeline can't auto-resume listening

## Problem Statement

The VoicePipeline needs to know when TTS finishes speaking to auto-resume listening (hands-free loop). Currently, `TTSService.speak()` is marked `async` but doesn't actually await completion — it just appends to the sentence queue and returns immediately. The pipeline has no mechanism to transition from `.speaking` back to `.listening`.

## Findings

- `TTSService.swift` — `speak()` appends utterance to queue and returns. No completion signal exposed.
- `VoicePipeline.swift:84` — `.speaking` case does `break` with comment "Speaking is handled by TTS callbacks" but no callback exists back to the pipeline.
- The `TTSDelegate.onFinished` closure only drains the internal sentence queue — it never signals the pipeline.
- Without this fix, the voice conversation loop cannot work hands-free.

## Proposed Solutions

### Option 1: Add `onAllSpeechFinished` callback

**Approach:** Add a completion callback to TTSService that fires when the sentence queue is empty and the synthesizer is no longer speaking.

```swift
var onAllSpeechFinished: (() -> Void)?

// In AVSpeechSynthesizerDelegate:
func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    if sentenceQueue.isEmpty && !synthesizer.isSpeaking {
        onAllSpeechFinished?()
    }
}
```

**Pros:**
- Minimal change, clear contract
- Pipeline sets the callback and receives the signal

**Cons:**
- Callback pattern (not async/await)

**Effort:** 1 hour

**Risk:** Low

---

### Option 2: Make speak() truly awaitable with CheckedContinuation

**Approach:** Wrap the delegate callback in a CheckedContinuation so `await ttsService.speak(text)` suspends until speech completes.

**Pros:**
- Cleaner async/await integration
- Pipeline can use structured concurrency

**Cons:**
- More complex, must handle cancellation
- Only one continuation at a time

**Effort:** 2 hours

**Risk:** Medium

## Recommended Action

Start with Option 1 (callback) for simplicity. Upgrade to Option 2 if the pipeline benefits from structured concurrency.

## Technical Details

**Affected files:**
- `Lifehug/Lifehug/Services/TTSService.swift` — add completion callback
- `Lifehug/Lifehug/Pipeline/VoicePipeline.swift` — wire callback to transition to `.listening`

## Acceptance Criteria

- [ ] VoicePipeline receives a signal when TTS finishes all queued speech
- [ ] Pipeline auto-transitions from `.speaking` to `.listening` after signal
- [ ] Works correctly when multiple sentences are queued

## Work Log

### 2026-03-08 - Initial Discovery

**By:** Claude Code (architecture review during /deepen-plan)

**Actions:**
- Identified TTSService.speak() doesn't await completion
- Confirmed VoicePipeline has no speaking->listening transition mechanism
- Proposed callback and continuation-based solutions
