---
status: completed
priority: p3
issue_id: "011"
tags: [code-review, security, ios]
dependencies: []
---

# NSFileProtectionComplete not applied to individual file writes

## Problem Statement

`StorageService` sets `NSFileProtectionComplete` on directories, but the `atomicWrite` method and `Data.write(to:options:.atomic)` don't specify `.completeFileProtection` in write options. Temporary files created during atomic writes may not inherit the directory's protection class.

## Findings

- `StorageService.swift:62-73` — protection set on directories
- Atomic writes create temp files and rename — may not inherit directory protection
- Should add `.completeFileProtection` to write options

## Proposed Solutions

### Option 1: Add .completeFileProtection to write options

**Approach:** `try data.write(to: url, options: [.atomic, .completeFileProtection])`

**Effort:** 15 minutes

**Risk:** Low

## Technical Details

**Affected files:**
- `Lifehug/Lifehug/Services/StorageService.swift` — all Data.write() calls

## Acceptance Criteria

- [ ] All file writes include `.completeFileProtection` option
- [ ] Answer files encrypted when device is locked

## Work Log

### 2026-03-08 - Initial Discovery

**By:** Claude Code (security audit during /deepen-plan)
