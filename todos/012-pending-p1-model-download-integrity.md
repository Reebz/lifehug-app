---
status: completed
priority: p1
issue_id: "012"
tags: [code-review, security, ios, supply-chain]
dependencies: []
---

# Model Download Integrity Verification

## Problem Statement
Downloaded model files (~175MB total) from HuggingFace and a third-party GitHub repo are accepted with only an HTTP 200 status check. No SHA-256 or other hash verification is performed. A compromised CDN, TLS interception, or repo takeover could serve modified model weights.

The voices file depends on a personal GitHub repo (`mlalma/KokoroTestApp`) — a supply chain risk if the owner deletes, renames, or replaces the file.

## Findings
- **Source**: Security Sentinel (H1, C1)
- **Files**: `Lifehug/Lifehug/App/ModelConfig.swift`, `Lifehug/Lifehug/Services/KokoroManager.swift`
- `ModelConfig.Kokoro.modelDownloadURL` and `voicesDownloadURL` use force-unwrap (`URL(string:)!`)
- `downloadFileOnce()` only checks `httpResponse.statusCode == 200`
- No checksum constants exist anywhere in the codebase

## Proposed Solutions

### Option A: Add SHA-256 verification after download
Add hash constants to `ModelConfig.Kokoro` and verify in `downloadFileOnce()` before `moveItem`.
- **Pros**: Simple, effective, catches corruption and tampering
- **Cons**: Must update hashes when models are upgraded
- **Effort**: Small
- **Risk**: Low

### Option B: Mirror voice file to owned infrastructure
Host `voices.npz` on your own CDN/GitHub org + add hash verification.
- **Pros**: Eliminates third-party dependency entirely
- **Cons**: Hosting cost, maintenance burden
- **Effort**: Medium
- **Risk**: Low

## Acceptance Criteria
- [ ] SHA-256 hash constants added to ModelConfig for both files
- [ ] Downloaded files verified against hashes before moving to final location
- [ ] Force-unwraps on URL constants replaced with safe construction
- [ ] Verification failure produces a user-facing error message

## Work Log
- 2026-03-08: Created from code review of commit ac14023
