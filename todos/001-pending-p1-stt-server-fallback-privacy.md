---
status: completed
priority: p1
issue_id: "001"
tags: [code-review, security, privacy, ios]
dependencies: []
---

# STT silently falls back to server-based recognition (privacy violation)

## Problem Statement

The app promises "all data stays on your device" but `STTService.swift` silently falls back to Apple's server-based speech recognition when on-device recognition is unavailable. This sends raw audio of deeply personal memoir content to Apple's servers without user knowledge or consent.

## Findings

- `STTService.swift:165-168` — Code checks `supportsOnDeviceRecognition` and only sets `requiresOnDeviceRecognition = true` when supported. Otherwise, audio is sent to Apple servers.
- On devices or OS versions where on-device isn't available, the app records and transmits memoir content over the network.
- Apple's server-based recognition also has a 60-second limit and per-device daily request quotas (~1000/hour).

## Proposed Solutions

### Option 1: Require on-device, fail gracefully to text input

**Approach:** Guard on `supportsOnDeviceRecognition`. If unavailable, throw an error and show the user a message to use text input instead.

```swift
guard recognizer.supportsOnDeviceRecognition else {
    throw STTError.onDeviceUnavailable
}
request.requiresOnDeviceRecognition = true
```

**Pros:**
- Simple, definitive privacy guarantee
- Clear user communication

**Cons:**
- Some older devices lose voice input entirely

**Effort:** 30 minutes

**Risk:** Low

## Recommended Action

Implement Option 1. Add a new `STTError.onDeviceUnavailable` case with a user-friendly message guiding them to text input.

## Technical Details

**Affected files:**
- `Lifehug/Lifehug/Services/STTService.swift:165-168` — guard check
- `Lifehug/Lifehug/Services/STTService.swift:244` — add new error case to `STTError` enum

## Acceptance Criteria

- [ ] App refuses to start voice recording if on-device recognition is unavailable
- [ ] User sees clear message explaining why and offering text input alternative
- [ ] No audio is ever sent to Apple servers

## Work Log

### 2026-03-08 - Initial Discovery

**By:** Claude Code (plan review)

**Actions:**
- Identified silent server fallback in STTService
- Confirmed via security agent review during /deepen-plan
- Flagged as P1 privacy violation
