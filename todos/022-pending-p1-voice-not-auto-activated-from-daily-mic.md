---
status: completed
priority: p1
issue_id: "022"
tags: [code-review, ux, voice, ios]
dependencies: []
---

# Voice Mode Not Auto-Activated When Starting From DailyQuestionView Mic

## Problem Statement
When a user taps the prominent 80x80 mic button on DailyQuestionView, records their answer via STT, and is navigated to ConversationView, the conversation opens in TEXT mode — not voice mode. The AI responds with text only (no TTS). The user has to find and tap a tiny toolbar mic icon, then tap ANOTHER mic button to actually start a voice conversation. This is 3 extra steps and fundamentally breaks the voice-first experience.

## Findings
- **Source**: UX Regression Review
- **Files**: `DailyQuestionView.swift` line 254, `ConversationView.swift`
- `DailyQuestionView.stopRecording()` sets `navigateToConversation = true` but passes no signal that the user started from voice
- `ConversationView` always starts with `voiceMode = false` (line 21)
- Expected flow: tap mic → speak → navigate → AI speaks back → mic reopens
- Actual flow: tap mic → speak → navigate → AI responds as TEXT → silence → user confused

## Proposed Solutions

### Option A: Pass voiceMode binding or flag from DailyQuestionView
Add a `@State var startInVoiceMode = false` on DailyQuestionView. Set it to `true` when the mic button triggers navigation. Pass it to ConversationView as a parameter. ConversationView auto-activates voice mode in `.task` if the flag is set.
- **Pros**: Explicit, no hidden state
- **Cons**: Adds a parameter to ConversationView
- **Effort**: Small
- **Risk**: Low

## Acceptance Criteria
- [ ] Starting from the mic button on DailyQuestionView enters voice conversation mode automatically
- [ ] AI's first response is spoken aloud via TTS
- [ ] Mic auto-reopens after AI speaks (depends on fix #021)
- [ ] Starting from "Type instead" still enters text mode

## Work Log
- 2026-03-08: Created from UX regression review
