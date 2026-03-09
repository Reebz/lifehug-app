---
status: pending
priority: p1
issue_id: "036"
tags: [code-review, security, kokoro]
dependencies: []
---

# SHA-256 Model Integrity Verification Disabled (Placeholder Hash)

## Problem Statement

The SHA-256 verification for the downloaded Kokoro model (~160MB safetensors) is completely bypassed. `ModelConfig.Kokoro.modelSHA256` is set to `"PLACEHOLDER_COMPUTE_ON_FIRST_DOWNLOAD"`, which causes the verification code to never execute. A MITM attacker on public Wi-Fi could substitute a malicious model file.

## Findings

- **Source:** Security Sentinel agent
- **File:** `Lifehug/App/ModelConfig.swift` line 21
- **File:** `Lifehug/Services/KokoroManager.swift` lines 374-387
- The verification code itself is correctly implemented — it just needs the real hash
- No certificate pinning for the HuggingFace download domain
- Additionally, the SHA-256 computation reads the entire 160MB file into memory (Performance Oracle)

## Proposed Solutions

### Option A: Compute and set the real hash
- Download the model, run `shasum -a 256` on it, update ModelConfig.swift
- Also fix the memory spike by streaming SHA-256 computation in chunks
- **Pros:** One-line fix for the hash, simple streaming fix for memory
- **Cons:** Hash must be updated if model version changes
- **Effort:** Small
- **Risk:** Low

## Recommended Action

_To be filled during triage_

## Technical Details

- **Affected files:** ModelConfig.swift, KokoroManager.swift

## Acceptance Criteria

- [ ] Real SHA-256 hash set in ModelConfig
- [ ] Verification code executes on download
- [ ] SHA-256 computed via streaming (no 160MB memory spike)

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-03-10 | Created from code review | Security Sentinel + Performance Oracle identified |

## Resources

- Security Sentinel agent analysis
