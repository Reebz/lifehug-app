---
status: completed
priority: p3
issue_id: "019"
tags: [code-review, quality, ios]
dependencies: []
---

# Remove Dead Code and Minor Cleanup

## Problem Statement
Several minor cleanup items identified across multiple reviewers.

## Findings
- **Source**: Architecture Strategist, Code Simplicity Reviewer
- Old `requestPermission(completion:)` in NotificationService is dead code after adding `requestPermissionAsync()`
- `NotificationService` enum lives at bottom of SettingsView.swift instead of its own file
- Auto-save `try?` silently swallows encoding failures (Security M3)
- Export error alert may leak internal file paths (Security L3)
- SAFETY comments could be trimmed to single lines
- `availableVoices` and `bestAvailableVoice()` could be cached

## Proposed Solutions
- Delete `requestPermission(completion:)` if unused
- Move `NotificationService` to `Services/NotificationService.swift`
- Replace `try?` with `do/catch` + logger in auto-save
- Use generic error message in export alert
- Cache computed voice lists
- **Effort**: Small (each item)

## Acceptance Criteria
- [ ] No dead callback-based methods
- [ ] Auto-save encoding failures logged
- [ ] Export error uses generic user message

## Work Log
- 2026-03-08: Created from code review of commit ac14023
