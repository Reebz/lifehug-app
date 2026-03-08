---
status: completed
priority: p3
issue_id: "010"
tags: [code-review, accessibility, ios, ui]
dependencies: []
---

# warmGray text on cream background fails WCAG AA contrast

## Problem Statement

`Theme.warmGray` (#6B5E54) on `Theme.cream` (#FBF8F3) has a contrast ratio of ~3.8:1, which fails WCAG AA for normal-sized text (requires 4.5:1). This color is used extensively for secondary text throughout the app.

## Findings

- warmGray on cream: ~3.8:1 (fails AA for <18pt text)
- terracotta on cream: ~2.9:1 (fails for text entirely — only use for decorative elements)
- warmCharcoal on cream: ~10.5:1 (passes AAA — good for primary text)
- walnut (#3A3632) on cream: ~7.2:1 (passes AA — good replacement for warmGray in body text)

## Proposed Solutions

### Option 1: Use walnut for secondary body text

**Approach:** Switch secondary text from `warmGray` to `walnut` (#3A3632). Keep warmGray only for large text (18pt+) or decorative use.

**Effort:** 1 hour

**Risk:** Low

## Technical Details

**Affected files:**
- Multiple views using `.foregroundStyle(Theme.warmGray)` for body-sized text
- `DesignTokens.swift` — may need to add `walnut` color if not present

## Acceptance Criteria

- [ ] All body-sized secondary text meets WCAG AA contrast (4.5:1)
- [ ] warmGray only used for large text or non-text elements

## Work Log

### 2026-03-08 - Initial Discovery

**By:** Claude Code (UI/UX review during /deepen-plan)
