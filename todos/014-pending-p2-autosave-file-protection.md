---
status: completed
priority: p2
issue_id: "014"
tags: [code-review, security, privacy, ios]
dependencies: []
---

# Auto-Save Uses UserDefaults Without File Protection

## Problem Statement
User's in-progress memoir conversation is stored in UserDefaults (plaintext plist). This data lacks iOS Data Protection and is included in unencrypted backups. The app enforces on-device STT for privacy but then stores the resulting text without protection at rest.

## Findings
- **Source**: Security Sentinel (H2)
- **File**: `Lifehug/Lifehug/App/SessionState.swift`, lines 41-53
- Data stored via `UserDefaults.standard.set(data, forKey:)`
- Contains question text, all conversation turns, timestamps
- No `NSFileProtectionComplete` applied

## Proposed Solutions

### Option A: Write auto-save to Application Support with file protection
Write JSON to a file in the app's Application Support directory with `NSFileProtectionComplete`. Already have `StorageService` infrastructure for this.
- **Pros**: Consistent with existing answer storage, gets iOS Data Protection
- **Cons**: Slightly more code than UserDefaults
- **Effort**: Small
- **Risk**: Low

## Acceptance Criteria
- [ ] Auto-save data written to file with NSFileProtectionComplete
- [ ] Old UserDefaults key cleaned up on migration
- [ ] iCloud backup exclusion applied to auto-save file

## Work Log
- 2026-03-08: Created from code review of commit ac14023
