---
status: completed
priority: p2
issue_id: "024"
tags: [code-review, ux, design, ios]
dependencies: []
---

# User Chat Bubble Invisible on Cream Background

## Problem Statement
User message bubbles in ConversationView use `Theme.cream` fill on a `Theme.cream` page background, with only a `Color.black.opacity(0.05)` stroke. The bubble is effectively invisible — user messages blend into the background. This makes the conversation hard to read and looks like "no colours" to the user.

## Findings
- **Source**: UX Regression Review
- **File**: `ConversationView.swift`, `bubbleBackground()` lines 162-176
- User bubble: `RoundedRectangle.fill(Theme.cream)` + stroke `Color.black.opacity(0.05)` — cream on cream
- Assistant bubble: `RoundedRectangle.fill(.white)` + shadow — this one is visible
- The 5% opacity border is nearly invisible to the human eye
- This likely explains the user complaint about "no colours"

## Proposed Solutions

### Option A: Use terracotta-tinted background for user bubbles
Use a light terracotta tint like `Theme.terracotta.opacity(0.08)` or `Theme.terracotta.opacity(0.12)` for user bubbles. This matches the question header styling already used and creates clear visual distinction.
- **Pros**: Warm, on-brand, clearly distinguishes user vs assistant messages
- **Cons**: None
- **Effort**: Small (change 2 lines)
- **Risk**: Low

## Acceptance Criteria
- [ ] User messages are clearly visible against the cream background
- [ ] Visual distinction between user and assistant messages is obvious
- [ ] Color choice matches the app's warm memoir aesthetic

## Work Log
- 2026-03-08: Created from UX regression review
