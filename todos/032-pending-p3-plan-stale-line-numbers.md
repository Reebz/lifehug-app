---
status: pending
priority: p3
issue_id: "032"
tags: [code-review, plan-accuracy, documentation]
dependencies: []
---

# Plan Has Stale Line Number References

## Problem Statement
Multiple line numbers in the plan don't match the actual code on `feat/ios-app`. While minor, these could cause confusion during implementation.

## Findings
- Plan says wireAutoReopen at DailyQuestionView line 492 → actual is line 484
- Plan says unwireAutoReopen at lines 518, 533, 556 → actual is 510, 525, 547
- Plan says safeAreaInset at lines 47-63 → doesn't exist at all
- Plan says UITabBarAppearance at lines 19-25 → only UISegmentedControl at lines 15-17
- Plan says question font at line 229 → actual appears to be around line 228

## Proposed Solutions

### Option A: Update line numbers during implementation
Fix references as you encounter them during `/ce:work`. No separate pass needed.
- **Effort**: Tiny (as you go)
- **Risk**: None

## Acceptance Criteria
- [ ] Line numbers corrected during implementation

## Work Log
- 2026-03-09: Noted during `/ce:review` code validation
