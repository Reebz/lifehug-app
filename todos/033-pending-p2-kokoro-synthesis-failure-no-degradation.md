---
status: pending
priority: p2
issue_id: "033"
tags: [code-review, voice, safety, ios]
dependencies: []
---

# Kokoro Synthesis Failure Silently Skips Sentences — No Degradation to System TTS

## Problem Statement
If `KokoroManager.speak()` throws during audio generation (OOM, corrupted model, GPU error), the sentence is silently skipped. The user hears nothing. For a driving user, this means missing the AI's response entirely with no indication or fallback. The plan does not address runtime synthesis failure degradation.

## Findings
- **Source**: Spec-flow analyzer during `/ce:review`
- **File**: `KokoroManager.swift` line 213-215 on `feat/ios-app`
- When `engine.generateAudio()` throws, the error is logged and `speak()` returns silently
- `TTSService.speak()` wraps this — sets `isSpeaking = true`, calls `await kokoroManager?.speak(sentence)`, sets `isSpeaking = false`
- The sentence is simply lost — no retry, no fallback to system TTS
- `forceDegradedToSystem` flag exists but is only set by `degradeToSystemTTS()` which is only called from `checkMemoryPressure()`
- The plan's Bug 3 fixes address the auto-reopen race but don't address synthesis failure

## Proposed Solutions

### Option A: Degrade to system TTS on synthesis failure (RECOMMENDED)
In `TTSService.speak()`, catch Kokoro failure and replay via system TTS:
```swift
func speak(_ sentence: String) async {
    if useKokoro {
        isSpeaking = true
        do {
            try await kokoroManager?.speakThrowing(sentence)
        } catch {
            logger.warning("Kokoro synthesis failed, degrading to system TTS")
            forceDegradedToSystem = true
            // Fall through to system TTS for this sentence
            await speakViaSystem(sentence)
        }
        isSpeaking = false
        return
    }
    // ... system TTS path
}
```
- **Pros**: Driving users hear the response, graceful degradation
- **Cons**: Requires making `KokoroManager.speak()` throw on failure (currently swallows error)
- **Effort**: Small-Medium
- **Risk**: Low

### Option B: Add to plan as a separate phase
Address after the core bug fixes land. Create a follow-up task.
- **Pros**: Keeps scope minimal for current fixes
- **Cons**: Driving users remain at risk until follow-up ships
- **Effort**: None now
- **Risk**: Medium (deferred safety issue)

## Acceptance Criteria
- [ ] If Kokoro synthesis fails mid-stream, remaining sentences play via system TTS
- [ ] User hears the complete AI response (possibly with voice change mid-stream)
- [ ] `forceDegradedToSystem` is set so subsequent responses use system TTS without retry

## Work Log
- 2026-03-09: Identified by spec-flow analyzer during `/ce:review`
