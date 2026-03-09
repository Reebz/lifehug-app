---
status: pending
priority: p3
issue_id: "043"
tags: [code-review, quality, simplification]
dependencies: []
---

# Minor Simplifications and Code Quality

## Items

1. **Inline runState**: VoicePipeline.runState() has 3 of 4 cases as `break`. Replace with `if newState == .listening { await runListening() }` in transition().

2. **Simplify bestAvailableVoice**: TTSService triple loop over preferredNames can be reduced to nested loop (quality × name).

3. **Remove KokoroManager.availableVoices**: Trivial wrapper over cachedVoiceNames. Use cachedVoiceNames directly or rename it.

4. **Memory pressure cases**: VoicePipeline .critical and .emergency do the same thing. Combine with fallthrough.

5. **Boolean naming**: `voiceSessionActive` → `isVoiceSessionActive`, `autoReopenMic` → `isAutoReopenMicEnabled` per Swift API Design Guidelines.

6. **Error enum scoping**: Standardize on either top-level or nested error enums across services.

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-03-10 | Created from code review | Code Simplicity + Pattern Recognition agents |
