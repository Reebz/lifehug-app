---
status: pending
priority: p2
issue_id: "031"
tags: [code-review, simplification, voice, ios]
dependencies: ["028", "029", "030"]
---

# Plan Over-Engineers Bugs 2, 3, and 5 — Bundles Optimizations with Bug Fixes

## Problem Statement
The plan bundles performance optimizations and architectural refactoring with critical bug fixes. The simplicity reviewer identified ~80 LOC of unnecessary additions. Bugs 2, 3, and 5 each have a minimal fix that solves the reported problem, plus 2-4 additional changes that solve unreported problems or optimize for hypothetical scenarios.

## Findings

### Bug 2: 4 changes proposed, only 1-2 needed
| Change | Needed? | Reason |
|--------|---------|--------|
| Reorder chainRecognitionRequest | YES | Root cause fix — eliminates gap where buffers go to nil |
| Generation counter | MAYBE | Belt-and-suspenders for stale callbacks. Low cost, good defense. |
| segmentStartTime | NO | Solves unreported problem (silence vs timeout disambiguation) |
| OSAllocatedUnfairLock | NO | Premature. Current nonisolated(unsafe) works. Risks priority inversion on real-time audio thread. |

### Bug 3: 5 changes proposed, only 1 needed
| Change | Needed? | Reason |
|--------|---------|--------|
| Delete TTSService line 49 | YES | Root cause fix — stops onAllSpeechFinished firing per-sentence |
| Remove wireAutoReopen from DailyQuestionView | NO | Breaks system TTS (see todo #029) |
| AsyncStream sentence pipelining | NO | Performance optimization — nobody reported inter-sentence gaps |
| CheckedContinuation for system TTS | NO | Refactor — current delegate+queue works |
| Audio session management | NO | Optimization — 100-200ms delay not reported as bug |

### Bug 5: 6 changes proposed, 3-4 needed
| Change | Needed? | Reason |
|--------|---------|--------|
| Bundle voices.npz | YES | URL is 404, no alternative |
| Update voicesFileURL for Bundle.main | YES | Required for bundling |
| Remove voicesDownloadURL | YES | Dead code after bundling |
| Remove voices download from performDownload | YES | Dead code after bundling |
| SHA-256 streaming fix | NO | Dead code (placeholder hashes, verification skipped) |
| Legacy voices.npz migration cleanup | MAYBE | 14.6MB in App Support is harmless, but 3 lines is cheap |

## Proposed Solutions

### Option A: Ship minimal fixes only (RECOMMENDED)
- Bug 2: Reorder + generation counter (2 changes)
- Bug 3: Delete line 49 only (1 change)
- Bug 5: Bundle + update path + remove download logic (3-4 changes)
- Total: ~6-7 changes vs plan's ~15 changes
- **Pros**: Lower risk, faster to implement, easier to review
- **Cons**: Leaves some technical debt (system TTS not awaitable, no sharedRequest lock)
- **Effort**: Medium (reduced from Large)
- **Risk**: Low

### Option B: Ship minimal fixes now, create follow-up tasks for optimizations
Same as Option A but create separate tasks for:
- Make system TTS awaitable (refactor)
- Add sentence pipelining (performance)
- Add sharedRequest lock (thread safety)
- **Pros**: Gets bug fixes shipped fast, tracks optimization work
- **Cons**: More task management overhead
- **Effort**: Medium initially, Medium for follow-ups
- **Risk**: Low

## Acceptance Criteria
- [ ] Plan updated to separate bug fixes from optimizations
- [ ] Each bug's "minimal fix" is clearly identified
- [ ] Optional optimizations are either deferred or clearly marked as non-blocking

## Work Log
- 2026-03-09: Simplicity reviewer + architecture reviewer + performance reviewer all flagged over-engineering
