---
status: completed
priority: p2
issue_id: "018"
tags: [code-review, performance, ux, ios]
dependencies: []
---

# Download Lacks Real Progress Reporting

## Problem Statement
Model download (~175MB) uses `URLSession.shared.download(from:)` with no progress callbacks. The progress bar jumps from 0 to 0.7 to 1.0. Users on slow connections may think the app is frozen. Also lacks explicit timeout configuration.

## Findings
- **Source**: Performance Oracle (#7), Security Sentinel (M4)
- **File**: `Lifehug/Lifehug/Services/KokoroManager.swift`
- `downloadProgress` only updated at fixed milestones
- Default URLSession timeout is 60s request / 7 days resource

## Proposed Solutions

### Option A: Use URLSession delegate for byte-level progress
Use `URLSession(configuration:delegate:)` with a download delegate that reports `bytesWritten/totalBytesExpectedToWrite`.
- **Pros**: Real progress bar, configurable timeouts
- **Cons**: More code, delegate pattern
- **Effort**: Medium
- **Risk**: Low

## Acceptance Criteria
- [ ] Progress bar updates continuously during download
- [ ] Explicit timeout configured (e.g., 30s request, 10min resource)
- [ ] User sees meaningful progress feedback

## Work Log
- 2026-03-08: Created from code review of commit ac14023
