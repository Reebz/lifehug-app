---
status: completed
priority: p3
issue_id: "009"
tags: [code-review, accessibility, ios, ui]
dependencies: []
---

# Dynamic Type broken — hardcoded font sizes in DesignTokens

## Problem Statement

`DesignTokens.swift` uses hardcoded `Font.system(size:)` throughout, which completely breaks Dynamic Type accessibility. Users who set larger text sizes in iOS Settings see no effect in the app.

## Findings

- `DesignTokens.swift` — all font definitions use fixed sizes (e.g., `Font.system(size: 22, weight: .regular, design: .serif)`)
- Should use `Font.system(.title2, design: .serif)` or text styles that scale with Dynamic Type
- Apple's accessibility guidelines require Dynamic Type support
- This is the single highest-priority accessibility fix across the entire app

## Proposed Solutions

### Option 1: Switch to text styles with design parameter

**Approach:** Replace `Font.system(size:)` with `Font.system(.textStyle, design: .serif)`.

**Effort:** 1 hour

**Risk:** Low (may need layout adjustments for very large text sizes)

## Technical Details

**Affected files:**
- `Lifehug/Lifehug/App/DesignTokens.swift` — all font definitions

## Acceptance Criteria

- [ ] All fonts use Dynamic Type text styles
- [ ] App responds to system text size changes
- [ ] Layout doesn't break at largest accessibility text sizes

## Work Log

### 2026-03-08 - Initial Discovery

**By:** Claude Code (UI/UX review during /deepen-plan)
