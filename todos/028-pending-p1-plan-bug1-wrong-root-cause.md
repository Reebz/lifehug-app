---
status: pending
priority: p1
issue_id: "028"
tags: [code-review, plan-accuracy, ux, ios]
dependencies: []
---

# Bug 1 Plan Has Wrong Root Cause — No safeAreaInset Exists

## Problem Statement
The plan for Bug 1 (mic button visible border) says to "Remove the shadow from the `.safeAreaInset` background at `DailyQuestionView.swift:60-61`" — but **there is no `.safeAreaInset` anywhere in DailyQuestionView.swift**. A grep of the entire file returns zero matches. The plan's root cause analysis and proposed fix are both wrong.

## Findings
- **Source**: Manual code validation during `/ce:review`
- **File**: `DailyQuestionView.swift` on `feat/ios-app` branch
- `grep -n safeAreaInset DailyQuestionView.swift` returns no results
- The mic button is a `Circle()` inside a `ZStack` with a `.shadow(color: micButtonColor.opacity(0.3), radius: 8, y: 4)` at line 312
- The "box" the user sees may be: (a) the circle shadow creating a visible halo on cream, (b) some other visual artifact, or (c) a SwiftUI rendering artifact
- The mic button is inside a simple VStack in `idleLayout` — no separate container or inset

## Proposed Solutions

### Option A: Re-investigate the actual source of the visible border
Run the app on device, screenshot the Today screen, and identify what creates the "box" appearance. It might be:
- The circle shadow being too visible against cream (reduce opacity or remove)
- A SwiftUI debug border
- A focus ring or accessibility highlight
- **Pros**: Fixes the actual problem
- **Cons**: Requires running the app to diagnose
- **Effort**: Small
- **Risk**: Low

### Option B: Remove/reduce the circle shadow
Change `micButtonColor.opacity(0.3)` to `micButtonColor.opacity(0.1)` or remove the shadow entirely. The user said "blend into the background."
- **Pros**: Quick fix if the shadow IS the border
- **Cons**: May not be the actual cause; may look worse without shadow depth cue
- **Effort**: Small
- **Risk**: Low

## Acceptance Criteria
- [ ] Identify the actual source of the visible "box" around mic button
- [ ] Update plan Bug 1 with correct root cause and fix
- [ ] Mic button blends seamlessly into cream background after fix

## Work Log
- 2026-03-09: Discovered during `/ce:review` — plan's safeAreaInset reference doesn't exist in code
