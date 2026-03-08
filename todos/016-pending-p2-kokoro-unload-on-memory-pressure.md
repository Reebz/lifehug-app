---
status: completed
priority: p2
issue_id: "016"
tags: [code-review, performance, ios, memory]
dependencies: []
---

# Memory Pressure Handler Doesn't Unload Kokoro Model

## Problem Statement
At `.critical` memory pressure, `VoicePipeline.checkMemoryPressure()` calls `ttsService.degradeToSystemTTS()` but does not call `kokoroManager.unloadEngine()`. The ~80MB Kokoro model stays in memory while unused, risking jetsam termination.

## Findings
- **Source**: Performance Oracle (#2, #10)
- **File**: `Lifehug/Lifehug/Pipeline/VoicePipeline.swift`, lines 357-375
- Comment says "Unload Kokoro model entirely" but implementation only sets flags
- 80MB of model weights remain allocated despite switching to system TTS

## Proposed Solutions

### Option A: Call unloadEngine() at critical/emergency pressure
Add `kokoroManager.unloadEngine()` call at `.critical` and `.emergency` levels.
- **Pros**: Actually reclaims 80MB, prevents jetsam kills
- **Cons**: Must re-download/reload if pressure drops
- **Effort**: Small
- **Risk**: Low

## Acceptance Criteria
- [ ] `kokoroManager.unloadEngine()` called at critical memory pressure
- [ ] 80MB freed when degrading to system TTS
- [ ] ChapterGenerator also re-checks memory between passes

## Work Log
- 2026-03-08: Created from code review of commit ac14023
