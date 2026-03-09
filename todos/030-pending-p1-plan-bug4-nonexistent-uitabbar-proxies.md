---
status: pending
priority: p1
issue_id: "030"
tags: [code-review, plan-accuracy, appearance, ios]
dependencies: []
---

# Bug 4 Plan References Nonexistent UITabBar Appearance Proxies

## Problem Statement
The plan says "Remove the `UITabBarAppearance` code from `LifehugApp.init()` (lines 19-25)" but the actual `LifehugApp.init()` on `feat/ios-app` contains ONLY UISegmentedControl appearance (3 lines). There are no UITabBar or UITabBarAppearance proxies to remove.

## Findings
- **Source**: Manual code validation during `/ce:review`
- **File**: `LifehugApp.swift` on `feat/ios-app` branch
- Actual init() contents:
  ```swift
  init() {
      UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(Theme.terracotta)
      UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
      UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor(Theme.walnut)], for: .normal)
  }
  ```
- No `UITabBarAppearance`, no `UITabBar.appearance()`, no `UINavigationBarAppearance`
- The plan's "remove UIKit tab bar proxies" step would be a no-op

## Proposed Solutions

### Option A: Update plan to reflect reality
Remove the "Remove UITabBarAppearance code" step from Bug 4. The LifehugBarStyle ViewModifier is still needed (it adds toolbar styling that doesn't exist yet), but there are no proxies to remove.
- **Pros**: Accurate plan
- **Cons**: None
- **Effort**: Tiny
- **Risk**: None

## Acceptance Criteria
- [ ] Plan Bug 4 updated to remove the "Remove UITabBarAppearance" step
- [ ] Plan correctly states that only UISegmentedControl proxies exist (and should be kept)
- [ ] LifehugBarStyle ViewModifier is still created and applied

## Work Log
- 2026-03-09: Discovered during `/ce:review` — plan references code that doesn't exist
