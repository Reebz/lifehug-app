---
status: pending
priority: p2
issue_id: "040"
tags: [code-review, bug, settings]
dependencies: []
---

# Voice Accent Detection Bug in SettingsView

## Problem Statement

`voiceDisplayName` uses `prefix.contains("f")` to determine US vs UK accent. Kokoro voice IDs use format `af_heart` (a=American, b=British, f=Female, m=Male). The check `contains("f")` matches both `af` (American Female, correct) AND `bf` (British Female, wrong — would show as "US" instead of "UK").

## Findings

- **Source:** Code Simplicity Reviewer
- **File:** `Lifehug/Views/SettingsView.swift` lines 305-322

## Fix

Change `prefix.contains("f")` to `prefix.hasPrefix("a")` — first character determines region.

## Acceptance Criteria

- [ ] `af_*` voices show as "US"
- [ ] `bf_*` voices show as "UK"
- [ ] `am_*` voices show as "US"
- [ ] `bm_*` voices show as "UK"

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-03-10 | Created from code review | Code Simplicity Reviewer found logic error |
