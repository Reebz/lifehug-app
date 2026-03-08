---
status: completed
priority: p2
issue_id: "005"
tags: [code-review, performance, ios, voice-pipeline]
dependencies: []
---

# checkMemoryPressure() exists but is never called — risk of jetsam kills

## Problem Statement

`VoicePipeline.checkMemoryPressure()` exists at line 171 but is dead code — never invoked anywhere. With ~960MB-1.14GB memory usage (LLM + STT + TTS + app), the app operates near iOS memory limits. Without monitoring, extended voice sessions or chapter generation can trigger jetsam kills, losing unsaved conversation data.

## Findings

- `VoicePipeline.swift:171` — `checkMemoryPressure()` checks `os_proc_available_memory()` with 300MB threshold
- No call site exists in the codebase
- Memory breakdown: ~713MB model + 100-200MB KV cache + 50-80MB STT + 20-30MB TTS + 80-120MB app
- On 4GB devices (iPhone 12, SE 3rd gen), margins are very thin
- Model should be unloaded when app backgrounds to free ~700MB

## Proposed Solutions

### Option 1: Call checkMemoryPressure() at key points + background unloading

**Approach:** Invoke before LLM generation, between TTS utterances, and unload model on `didEnterBackground`.

**Pros:**
- Prevents crashes, graceful degradation
- Unloading on background prevents jetsam

**Cons:**
- ~2-3s model reload cost on foreground resume

**Effort:** 2 hours

**Risk:** Low

## Technical Details

**Affected files:**
- `Lifehug/Lifehug/Pipeline/VoicePipeline.swift` — add calls to checkMemoryPressure()
- `Lifehug/Lifehug/App/LifehugApp.swift` — unload model on background, reload on foreground
- `Lifehug/Lifehug/Services/LLMService.swift` — add unload/reload methods

## Acceptance Criteria

- [ ] `checkMemoryPressure()` called before each LLM generation
- [ ] Model unloaded when app enters background
- [ ] Model reloaded when app returns to foreground
- [ ] Threshold raised from 300MB to 500MB (200MB is too late)

## Work Log

### 2026-03-08 - Initial Discovery

**By:** Claude Code (performance review during /deepen-plan)
