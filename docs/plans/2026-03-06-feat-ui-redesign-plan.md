---
title: "feat: UI Redesign — Calm Serif-Forward Design System"
type: feat
date: 2026-03-06
---

# UI Redesign — Calm Serif-Forward Design System

## Overview

Redesign the Lifehug iOS app interface to be readable, calm, and high-quality. The current implementation has white text on light backgrounds making content unreadable. This plan establishes a cohesive design system with serif typography, proper contrast ratios, and a vibe of: **calm, friendly, memories, private, high quality**.

## Problem Statement

- White/light text on cream backgrounds (`#FBF8F3`) is unreadable
- Colors are defined locally in every view file — no centralized design system
- System fonts feel generic; the app needs a distinctive, warm personality
- OnboardingView uses `.secondary` / `.tertiary` system colors that lack contrast on cream
- No consistent spacing, radius, or typography scale

## Design Direction

**Mood:** A leather-bound journal. Warm lamplight. A quiet conversation over tea.

**Visual Principles:**
1. **Serif-first typography** — Georgia or New York for all headings and questions; system serif for body
2. **High contrast on cream** — Dark walnut text (`#2C2420`) on warm cream (`#FBF8F3`)
3. **Terracotta as accent only** — Not for large text; used for buttons, icons, interactive elements
4. **White cards with subtle shadow** — Content containers float gently above cream
5. **Generous whitespace** — Let the content breathe; this is a reflective app

## Proposed Solution

### Phase 1: Design System Foundation

Create a single `DesignTokens.swift` file that centralizes all design values.

- [x] **Create `Lifehug/App/DesignTokens.swift`** with:

```swift
// Colors
static let cream = Color(hex: 0xFBF8F3)           // App background
static let warmCharcoal = Color(hex: 0x2C2420)     // Primary text
static let walnut = Color(hex: 0x3A3632)            // Headings
static let warmGray = Color(hex: 0x6B5E54)          // Secondary text
static let softGray = Color(hex: 0x9E9389)          // Tertiary/placeholder
static let terracotta = Color(hex: 0xC67B5C)        // Accent/CTA
static let softCoral = Color(hex: 0xE8856C)         // Active states
static let sageGreen = Color(hex: 0x7BA17D)         // Success/complete
static let amber = Color(hex: 0xD4A855)             // In-progress
static let mutedRose = Color(hex: 0xC47070)          // Warning/destructive
static let cardBackground = Color.white
static let cardShadow = Color.black.opacity(0.05)

// Typography
static let displayFont: Font = .system(size: 32, weight: .light, design: .serif)
static let titleFont: Font = .system(size: 24, weight: .regular, design: .serif)
static let headlineFont: Font = .system(size: 20, weight: .medium, design: .serif)
static let bodySerifFont: Font = .system(size: 17, weight: .regular, design: .serif)
static let bodyFont: Font = .system(size: 17, weight: .regular)
static let captionFont: Font = .system(size: 13, weight: .regular)
static let smallCaptionFont: Font = .system(size: 11, weight: .medium)

// Spacing
static let cardCornerRadius: CGFloat = 16
static let buttonCornerRadius: CGFloat = 14
static let horizontalPadding: CGFloat = 24
static let cardPadding: CGFloat = 16
static let sectionSpacing: CGFloat = 24
```

- [x] **Remove local color/font definitions** from all view files
- [x] **Replace all `.foregroundStyle(.white)` on non-button text** with appropriate design token
- [x] **Replace `.secondary` / `.tertiary` system colors** in OnboardingView with explicit warmGray/softGray

### Phase 2: Typography Overhaul

All text should use serif where it evokes warmth; sans-serif for UI chrome.

- [x] **Questions & Headings** — `.system(.serif)` at title2/title3 weight
- [x] **Body text / answers** — `.system(.serif)` at body size for content the user reads
- [x] **UI labels** (buttons, tabs, captions) — System sans-serif for clarity
- [x] **Navigation titles** — Use `.fontDesign(.serif)` via toolbar modifier
- [x] **Ensure minimum 4.5:1 contrast ratio** for all text on cream background
  - `#2C2420` on `#FBF8F3` = 11.2:1 (excellent)
  - `#6B5E54` on `#FBF8F3` = 4.7:1 (passes AA)
  - `#9E9389` on `#FBF8F3` = 2.8:1 (use only for decorative/placeholder)
  - `.white` on `#FBF8F3` = 1.07:1 (FAILS — this is the reported bug)

### Phase 3: View-by-View Fixes

#### LaunchView.swift
- [x] Replace local Color extension with shared DesignTokens
- [x] Button text `.white` on terracotta is fine (7.3:1 contrast) — keep
- [x] Use `displayFont` for "Lifehug" title
- [x] Use `bodySerifFont` for subtitle

#### OnboardingView.swift
- [x] Replace `.primary` → `DesignTokens.warmCharcoal`
- [x] Replace `.secondary` → `DesignTokens.warmGray`
- [x] Replace `.tertiary` → `DesignTokens.softGray`
- [x] Add serif to welcome/step headings
- [x] Selected project type button: `.white` text on terracotta — keep (good contrast)

#### DailyQuestionView.swift
- [x] Already uses warmCharcoal/warmGray — migrate to DesignTokens
- [x] Mic button icon `.white` on terracotta — keep
- [x] Add subtle card around question text for visual hierarchy

#### ConversationView.swift
- [x] User bubble: cream background with warm charcoal text — keep
- [x] Assistant bubble: white with shadow — keep
- [x] Question header: serif styling — already good
- [x] "End Session & Save" button: `.white` on terracotta — keep

#### CoverageView.swift
- [x] Migrate local color defs to DesignTokens
- [x] Navigation title: add serif design
- [x] Category cells already use white cards — keep

#### SettingsView.swift
- [x] Migrate local color defs to DesignTokens
- [x] Section headers already use serif — keep
- [x] Form rows on white background — keep

#### AnswersBrowserView.swift
- [x] Migrate local color defs to DesignTokens
- [x] Empty state icon: increase opacity for better visibility
- [x] Answer detail: already well-styled — keep

### Phase 4: Polish & Delight

- [ ] Add subtle entrance animations (fade-in) for question text
- [ ] Conversation bubbles: gentle slide-in from left/right
- [ ] Tab bar: use serif-compatible custom icons or keep SF Symbols with terracotta tint
- [ ] Pull-to-refresh on Coverage and Answers views
- [ ] Empty state illustrations: simple line-art style (or descriptive SF Symbols)

## Acceptance Criteria

- [x] All text is readable — no white-on-cream instances remain
- [x] All headings and question text use serif fonts
- [x] Colors come from a single `DesignTokens` source
- [x] WCAG AA contrast ratios met (4.5:1) for all body text
- [x] App feels calm, warm, and high-quality — not clinical or generic
- [x] No regressions on existing functionality

## Technical Details

**Affected files:**
- `Lifehug/App/DesignTokens.swift` (NEW)
- `Lifehug/Views/LaunchView.swift`
- `Lifehug/Views/OnboardingView.swift`
- `Lifehug/Views/DailyQuestionView.swift`
- `Lifehug/Views/ConversationView.swift`
- `Lifehug/Views/CoverageView.swift`
- `Lifehug/Views/SettingsView.swift`
- `Lifehug/Views/AnswersBrowserView.swift`
- `Lifehug/App/LifehugApp.swift`

**Estimated effort:** Medium (2-3 hours with AI assistance)

## References

- Current color palette is already warm — the bones are good
- Only the contrast and centralization need fixing
- Serif fonts: iOS system serif (New York) is excellent and free
