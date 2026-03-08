---
status: completed
priority: p1
issue_id: "003"
tags: [code-review, security, privacy, ios]
dependencies: []
---

# iCloud Backup includes answer files — breaks privacy promise

## Problem Statement

Answer files containing deeply personal memoir content are stored in the Documents directory, which is included in iCloud Backup by default. Users with iCloud Backup enabled (most users) have their intimate life stories synced to Apple's servers, contradicting the "all data stays on your device" promise.

## Findings

- `StorageService.swift:75-79` — Only `modelsDirectory` is excluded from iCloud backup via `isExcludedFromBackup`.
- `answersDirectory`, `questionBankURL`, `configURL`, and `stateDirectory` are NOT excluded.
- All answer markdown files (containing full memoir answers) are backed up to iCloud.
- The user's name and project configuration are also backed up.

## Proposed Solutions

### Option 1: Exclude all user data directories from backup

**Approach:** Set `isExcludedFromBackup = true` on `answersDirectory`, `stateDirectory`, and config files.

```swift
var answersURL = answersDirectory
answersURL.setResourceValue(true, forKey: .isExcludedFromBackupKey)
```

**Pros:**
- Simple, complete fix
- Consistent with the privacy promise

**Cons:**
- Users lose backup protection for their answers (no cloud recovery)

**Effort:** 30 minutes

**Risk:** Low

---

### Option 2: User-controlled backup toggle in Settings

**Approach:** Add a toggle in SettingsView: "Include answers in iCloud Backup?" Default OFF.

**Pros:**
- User choice, transparent
- Power users can opt in to backup

**Cons:**
- More UI work, more settings to maintain

**Effort:** 2 hours

**Risk:** Low

## Recommended Action

Implement Option 1 immediately (exclude by default). Consider Option 2 in a future release for user choice.

## Technical Details

**Affected files:**
- `Lifehug/Lifehug/Services/StorageService.swift` — add `isExcludedFromBackup` to answers, state, config directories

## Acceptance Criteria

- [ ] Answer files are NOT included in iCloud Backup
- [ ] Config and state files are NOT included in iCloud Backup
- [ ] Model files remain excluded (already done)
- [ ] User data persists locally (not deleted, just not backed up)

## Work Log

### 2026-03-08 - Initial Discovery

**By:** Claude Code (security audit during /deepen-plan)

**Actions:**
- Identified only modelsDirectory excluded from backup
- Confirmed answersDirectory contains sensitive memoir content
- Flagged as P1 privacy violation
