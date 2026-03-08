---
status: completed
priority: p2
issue_id: "025"
tags: [code-review, ux, accessibility, ios]
dependencies: []
---

# Voice Mode Toggle Button Too Small and Undiscoverable

## Problem Statement
The voice mode toggle in ConversationView is a standard toolbar icon (`mic.slash`/`mic.fill`). Standard toolbar buttons are ~22pt — tiny compared to the 80x80 mic button on DailyQuestionView. The user complaint about "button is small" likely refers to this. Voice is a core feature of the app but the toggle to activate it is hidden in the navigation bar as a generic-looking icon.

## Findings
- **Source**: UX Regression Review
- **File**: `ConversationView.swift`, toolbar at lines 54-62
- Standard `Image(systemName: "mic.slash")` in `ToolbarItem` — approximately 22pt
- No label, no visual indication this is important
- Apple HIG recommends 44x44pt minimum touch target — toolbar items may be borderline
- Voice is the app's primary interaction method but its toggle looks like a secondary option

## Proposed Solutions

### Option A: Move voice toggle to the input bar area
Replace the toolbar icon with a prominent toggle button near the text input area. Show it as a mode switcher (keyboard icon / mic icon) at the same visual weight as the send button.
- **Pros**: Discoverable, meets touch target size, intuitive location
- **Cons**: Changes input bar layout
- **Effort**: Medium
- **Risk**: Low

### Option B: Keep toolbar but add visual emphasis
Enlarge the toolbar button, add a colored background circle or badge when voice is active.
- **Pros**: Minimal layout change
- **Cons**: Toolbar items have limited customization
- **Effort**: Small
- **Risk**: Low

## Acceptance Criteria
- [ ] Voice toggle meets 44x44pt minimum touch target
- [ ] Toggle is visually prominent and discoverable
- [ ] Active voice mode has clear visual indicator

## Work Log
- 2026-03-08: Created from UX regression review
