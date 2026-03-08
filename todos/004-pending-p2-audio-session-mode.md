---
status: completed
priority: p2
issue_id: "004"
tags: [code-review, architecture, ios, audio]
dependencies: []
---

# Audio session uses .measurement mode — degrades TTS and causes Bluetooth issues

## Problem Statement

`STTService.swift:157` configures the audio session with `.measurement` mode, which disables system audio processing (AGC, echo cancellation). This hurts TTS playback quality and can cause Bluetooth routing problems when transitioning between STT and TTS.

## Findings

- `STTService.swift:157` — `try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])`
- `.measurement` mode is designed for raw audio capture, not conversational use
- `.allowBluetoothHFP` alone locks to HFP profile (mono, 8kHz) — TTS sounds terrible
- Missing `.allowBluetoothA2DP` means no high-quality Bluetooth output for TTS
- Audio session should be set ONCE with `.playAndRecord` + `.default` mode for the entire voice session

## Proposed Solutions

### Option 1: Switch to .default mode with full Bluetooth options

**Approach:** Change audio session configuration to use `.default` mode with both Bluetooth options.

```swift
try audioSession.setCategory(.playAndRecord, mode: .default, options: [
    .defaultToSpeaker,
    .allowBluetooth,
    .allowBluetoothA2DP
])
```

**Pros:**
- Better TTS quality, better Bluetooth routing
- Matches Apple's recommendation for conversational apps

**Cons:**
- May slightly reduce raw STT accuracy (AGC enabled)

**Effort:** 30 minutes

**Risk:** Low

## Technical Details

**Affected files:**
- `Lifehug/Lifehug/Services/STTService.swift:157` — change mode and options
- `Lifehug/Lifehug/Pipeline/VoicePipeline.swift` — ensure audio session set once, not per-transition

## Acceptance Criteria

- [ ] Audio session uses `.default` mode, not `.measurement`
- [ ] Both `.allowBluetooth` and `.allowBluetoothA2DP` in options
- [ ] TTS playback sounds acceptable through Bluetooth speakers/AirPods
- [ ] Audio session configured once per voice session, not per STT/TTS transition

## Work Log

### 2026-03-08 - Initial Discovery

**By:** Claude Code (audio session agent during /deepen-plan)
