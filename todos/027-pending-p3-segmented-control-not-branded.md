---
status: completed
priority: p3
issue_id: "027"
tags: [code-review, ux, design, ios]
dependencies: []
---

# Segmented Control in AnswersBrowserView Not Styled With Brand Colors

## Problem Statement
The Answers/Book segmented control in `AnswersBrowserView` uses `.tint(Theme.terracotta)` but on iOS, `.tint()` doesn't reliably color a `.segmented` picker. The selected segment likely appears in the default system blue or gray, not terracotta. This contributes to the "no colours" complaint.

## Findings
- **Source**: UX Regression Review
- **File**: `AnswersBrowserView.swift`, lines 22-30
- `.pickerStyle(.segmented)` with `.tint(Theme.terracotta)` — tint doesn't fully control segmented picker colors on iOS
- The selected segment indicator may appear gray/blue depending on iOS version
- To reliably color a segmented control, you need `UISegmentedControl.appearance()` or a custom implementation

## Proposed Solutions

### Option A: Use UISegmentedControl.appearance() in app setup
Set `UISegmentedControl.appearance().selectedSegmentTintColor` in `LifehugApp.init()` or an `onAppear` modifier.
- **Pros**: Works reliably, one-line fix
- **Cons**: Global appearance setting affects all segmented controls (which is likely desired)
- **Effort**: Small
- **Risk**: Low

## Acceptance Criteria
- [ ] Selected segment in Answers/Book picker uses terracotta color
- [ ] Unselected segment text is readable

## Work Log
- 2026-03-08: Created from UX regression review
