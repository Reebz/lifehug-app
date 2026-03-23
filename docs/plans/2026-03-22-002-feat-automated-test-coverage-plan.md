---
title: "Automated test coverage for critical paths"
type: feat
status: active
date: 2026-03-22
---

# Automated Test Coverage for Critical Paths

## Current State

The Lifehug iOS app has three test files using the Swift Testing framework (`import Testing`), all located in `Lifehug/LifehugTests/`:

| Test File | Suite Name | Test Count | What It Covers |
|---|---|---|---|
| `AnswerTests.swift` | Answer Serialization | 3 | `Answer.toMarkdown()` roundtrip, simple answer without follow-ups, format compatibility with desktop tool spec |
| `RotationEngineTests.swift` | RotationEngine | 10 | Lowest-coverage priority, group alternation (both directions), spotlight interleaving, no-spotlight on non-spotlight turn, all-answered returns nil, document order, fallback when no preferred group, spotlight fallback, `markAnswered` updates |
| `QuestionBankParserTests.swift` | QuestionBankParser | 10 | Category parsing, question parsing, full question bank parsing, `markAnswered` (success, already-answered, not-found, end-of-file, answer-text collision), oversized input rejection, coverage computation, coverage threshold boundaries |

**Total existing tests: 23**

These cover the core markdown-based data layer well. The major gaps are in models (encoding/decoding, edge cases), StorageService (file I/O), the SentenceBuffer (text chunking), and the VoicePipeline state machine.

## Coverage Gaps

| File | Directory | Has Tests | Priority | Notes |
|---|---|---|---|---|
| **Models** | | | | |
| `Answer.swift` | Models | Partial | P1 | Roundtrip tested; missing: malformed markdown, edge-case parsing, empty fields |
| `Question.swift` | Models | None | P1 | Codable with custom init(from:)/encode(to:); no encode/decode tests |
| `RotationState.swift` | Models | None | P1 | Codable with CodingKeys mapping; no roundtrip or default-value tests |
| `UserConfig.swift` | Models | None | P1 | Codable; no roundtrip tests |
| `Category.swift` | Models | Indirect | P2 | `groupForLetter` used in parser tests but not directly tested at boundaries |
| **Services** | | | | |
| `StorageService.swift` | Services | None | P1 | Atomic writes, read fallbacks, path traversal guard, directory setup; no tests |
| `RotationEngine.swift` | Services | Yes | P2 | Good coverage; expand: empty questions array, single category, tie-breaking |
| `QuestionBankParser.swift` | Services | Yes | P2 | Good coverage; expand: malformed lines, mixed indentation, Unicode |
| `OnboardingTemplates.swift` | Services | None | P2 | Pure data + `markdownSections` formatter; easy to test |
| `ChapterGenerator.swift` | Services | None | P3 | Requires LLMService mock; test prompt construction, batching logic |
| `TaskTimeout.swift` | Services | None | P2 | Small utility; test timeout fires, operation completes before timeout |
| `LLMService.swift` | Services | None | P3 | Hardware-dependent (MLX/Metal); test `cleanChunk`, `cleanResponse`, `memoirInterviewerPrompt` |
| `STTService.swift` | Services | None | P4 | Hardware-dependent (microphone, Speech framework); not unit-testable without protocol extraction |
| `TTSService.swift` | Services | None | P4 | Hardware-dependent (AVSpeechSynthesizer, Kokoro); not unit-testable without protocol extraction |
| `ModelDownloader.swift` | Services | None | P4 | Network + disk I/O; integration test territory |
| `KokoroManager.swift` | Services | None | P4 | FluidAudio dependency; integration test territory |
| **Pipeline** | | | | |
| `VoicePipeline.swift` (SentenceBuffer) | Pipeline | None | P1 | Pure struct with clear contract; high risk of subtle bugs in abbreviation/number/ellipsis handling |
| `VoicePipeline.swift` (PipelineState) | Pipeline | None | P2 | State enum is simple; state machine transitions require service mocks |
| `VoicePipeline.swift` (termination phrases) | Pipeline | None | P2 | `stripTerminationPhrase` is pure and testable |
| **App** | | | | |
| `AppState.swift` | App | None | P3 | Thin UserDefaults wrapper; low logic density |
| `SessionState.swift` | App | None | P2 | `compileAnswer`, auto-save encode/decode, migration logic |
| `ModelState.swift` | App | None | P4 | Wrapper around ModelDownloader; integration-level |
| `ModelConfig.swift` | App | None | Skip | Constants only |
| `MemoryMonitor.swift` | App | None | P3 | Threshold logic testable; `availableMB` is runtime-dependent |
| `DesignTokens.swift` | App | None | Skip | Visual constants; no logic to test |
| `LifehugApp.swift` | App | None | Skip | Entry point |
| **Views** | | | | |
| `LaunchView.swift` | Views | None | Skip | UI only |
| `OnboardingView.swift` | Views | None | Skip | UI only |
| `DailyQuestionView.swift` | Views | None | Skip | UI only |
| `DailyQuestionComponents.swift` | Views | None | Skip | UI only |
| `ConversationView.swift` | Views | None | Skip | UI only |
| `CoverageView.swift` | Views | None | Skip | UI only |
| `AnswersBrowserView.swift` | Views | None | Skip | UI only |
| `SettingsView.swift` | Views | None | Skip | UI only |

## Implementation Plan

### Phase 1: Model Tests (Quick Wins)

Pure value types with Codable conformance. No dependencies, no mocking. These should take under an hour.

**File: `QuestionTests.swift`**

| Test Method | What It Verifies |
|---|---|
| `test_questionEncodeDecode_roundtrip` | Encode a `Question` to JSON, decode it back, verify all fields match |
| `test_questionDecode_derivesCategory` | Decode from JSON with id "B3" and verify `category == "B"` |
| `test_questionDecode_emptyID_throws` | JSON with `"id": ""` throws `DecodingError.dataCorrupted` |
| `test_questionCategoryString` | `categoryString` returns `String(category)` correctly |
| `test_questionEncode_omitsCategory` | Encoded JSON contains only `id`, `text`, `answered` (no `category` key) |

**File: `RotationStateTests.swift`**

| Test Method | What It Verifies |
|---|---|
| `test_rotationState_encodeDecode_roundtrip` | Full roundtrip with all fields populated |
| `test_rotationState_decodesSnakeCaseKeys` | JSON with `"last_question_id"`, `"questions_asked"`, etc. decodes correctly |
| `test_rotationState_defaultValues` | `RotationState()` has version=1, questionsAsked=0, spotlightFrequency=4, nils for optional fields |
| `test_rotationState_partialJSON` | JSON with only `"version": 1` decodes successfully with defaults for missing fields |
| `test_rotationState_encodesSnakeCaseKeys` | Encoded JSON uses snake_case keys matching the Python tool |

**File: `UserConfigTests.swift`**

| Test Method | What It Verifies |
|---|---|
| `test_userConfig_encodeDecode_roundtrip` | Encode with name + projects, decode, verify match |
| `test_userConfig_defaultValues` | `UserConfig()` has name="friend", empty projects |
| `test_userConfig_projectIdentifiable` | `Project.id` returns `name` |
| `test_userConfig_emptyJSON` | `{}` decodes successfully with defaults |

**File: `CategoryTests.swift`**

| Test Method | What It Verifies |
|---|---|
| `test_groupForLetter_mainRange` | A through E return `.main` |
| `test_groupForLetter_projectRange` | F through J return `.project` |
| `test_groupForLetter_spotlightRange` | K, L, Z return `.spotlight` |
| `test_coverageInfo_ratioCalculation` | Verify `ratio` = answered/total, handles total=0 |
| `test_coverageInfo_statusBoundaries` | 0% = red, 29% = red, 30% = yellow, 69% = yellow, 70% = green, 100% = green |

**Expand `AnswerTests.swift`**

| Test Method | What It Verifies |
|---|---|
| `test_fromMarkdown_malformedHeader_returnsNil` | Missing "# Question" prefix returns nil |
| `test_fromMarkdown_emptyString_returnsNil` | Empty string returns nil |
| `test_fromMarkdown_missingDates_usesCurrentDate` | Missing date line still parses (falls back to Date()) |
| `test_fromMarkdown_multilineAnswerText` | Answer text spanning multiple paragraphs preserved correctly |
| `test_fromMarkdown_specialCharactersInText` | Question text with quotes, em dashes, apostrophes roundtrips correctly |
| `test_toMarkdown_emptyAnswerText` | Empty answer text produces valid markdown with empty section between separators |

### Phase 2: Service Tests (Business Logic)

Services that can be tested with temporary directories or in-memory state.

**File: `StorageServiceTests.swift`**

| Test Method | What It Verifies |
|---|---|
| `test_setupDirectories_createsAllDirectories` | After `setupDirectories()`, models, system, answers directories exist |
| `test_writeReadQuestionBank_roundtrip` | Write markdown string, read it back, content matches |
| `test_writeReadRotationState_roundtrip` | Write `RotationState`, read it back, fields match |
| `test_writeReadConfig_roundtrip` | Write `UserConfig`, read it back, fields match |
| `test_readRotationState_missingFile_returnsDefault` | No file on disk returns `RotationState.default` |
| `test_readConfig_missingFile_returnsDefault` | No file on disk returns `UserConfig()` |
| `test_readRotationState_corruptedFile_returnsDefault` | Write garbage data, read returns default (not crash) |
| `test_readConfig_corruptedFile_returnsDefault` | Write garbage data, read returns default (not crash) |
| `test_saveAnswer_validID_writesFile` | Save answer with id "A1", verify file exists at `answers/A1.md` |
| `test_saveAnswer_invalidID_doesNotWrite` | Answer with id "../etc" does not create a file (path traversal guard) |
| `test_saveAnswer_pathTraversal_rejected` | IDs like "A1/../B1" are rejected by the regex guard |
| `test_listAnswerFiles_sortedAlphabetically` | Multiple answer files returned in sorted order |
| `test_atomicWrite_contentSurvivesCrash` | Verify `.atomic` write option is used (file either fully written or absent) |

**Approach:** Create a `StorageService` that operates on a temporary directory (override `appSupportDirectory`/`documentsDirectory` via a test subclass or by setting up a temp directory and pointing FileManager there).

**Expand `RotationEngineTests.swift`**

| Test Method | What It Verifies |
|---|---|
| `test_pickNext_emptyQuestionsArray_returnsNil` | Empty input returns nil |
| `test_pickNext_singleCategory_picksFirst` | Only one category with multiple questions, picks first unanswered |
| `test_pickNext_tiedCoverage_picksFirstInOrder` | Two categories at 0%, picks based on stable sort order |
| `test_pickNext_excluding_skipsExcluded` | `excluding: "A1"` skips A1 even if it's the best candidate |
| `test_pickNext_spotlightFrequencyZero_neverPicksSpotlight` | `spotlightFrequency = 0` never triggers spotlight turn |
| `test_markAnswered_incrementsCounters` | After marking, questionsAsked and questionsAnswered both increment by one |
| `test_markAnswered_setsLastAskedAt` | `lastAskedAt` is a valid ISO 8601 string after marking |

**Expand `QuestionBankParserTests.swift`**

| Test Method | What It Verifies |
|---|---|
| `test_parseQuestions_malformedLines_skipped` | Lines without checkbox pattern are silently skipped |
| `test_parseQuestions_extraWhitespace_handled` | Leading/trailing spaces on lines still parse correctly |
| `test_parseQuestions_unicodeInText` | Questions with Unicode characters (accents, em dashes, curly quotes) parse correctly |
| `test_parseCategories_duplicateLetter_lastWins` | Two `## A:` headers, second overwrites first |
| `test_parseCategories_noParenthetical_nameIsFullText` | `## F: The Problem` (no parenthetical) uses "The Problem" as name |
| `test_markAnswered_multipleMatches_marksFirst` | If somehow two `A1` lines exist, only the first is marked |
| `test_computeCoverage_emptyQuestions` | Empty questions array returns empty coverage map |

**File: `OnboardingTemplatesTests.swift`**

| Test Method | What It Verifies |
|---|---|
| `test_categories_memoir_returnsThreeCategories` | Memoir template has three categories (F, G, H) |
| `test_categories_founderStory_returnsFourCategories` | Founder Story has four (F, G, H, I) |
| `test_categories_unknownType_fallsBackToMemoir` | Unknown string returns memoir categories |
| `test_markdownSections_validFormat` | Output contains `## F:` headers and `- [ ] F1:` question lines |
| `test_markdownSections_allQuestionsUnanswered` | All checkboxes are `[ ]` (unchecked) |
| `test_allProjectTypes_haveCategories` | Every entry in `projectTypes` returns non-empty from `categories(for:)` |

**File: `TaskTimeoutTests.swift`**

| Test Method | What It Verifies |
|---|---|
| `test_withTimeout_operationCompletesBeforeTimeout` | Fast operation returns its result, no error |
| `test_withTimeout_operationExceedsTimeout_throwsTimeoutError` | Slow operation throws `TimeoutError.timeout` |
| `test_withTimeout_operationThrows_propagatesError` | Operation error propagates (not masked by timeout) |

### Phase 3: Pipeline Tests (Integration)

**File: `SentenceBufferTests.swift`**

The `SentenceBuffer` is a pure struct with no dependencies. It's the highest-value pipeline test target.

| Test Method | What It Verifies |
|---|---|
| `test_extractSentence_simplePeriod` | `"Hello world. Next"` extracts `"Hello world."` with `"Next"` remaining |
| `test_extractSentence_exclamationMark` | `"Wow! Really?"` extracts `"Wow!"` |
| `test_extractSentence_questionMark` | `"How? Let me explain."` extracts `"How?"` |
| `test_extractSentence_abbreviation_Dr` | `"Dr. Smith said hello."` does NOT split at `"Dr."` -- extracts full sentence |
| `test_extractSentence_abbreviation_Mrs` | `"Mrs. Jones arrived."` extracts full sentence, not split at `"Mrs."` |
| `test_extractSentence_abbreviation_US` | `"The U.S. policy changed."` does NOT split at `"U.S."` |
| `test_extractSentence_abbreviation_etc` | `"Dogs, cats, etc. are pets."` does NOT split at `"etc."` |
| `test_extractSentence_decimalNumber` | `"It cost 3.50 dollars."` does NOT split at `"3."` |
| `test_extractSentence_ellipsis` | `"Well... I think so."` does NOT split at first/second/third dot of ellipsis |
| `test_extractSentence_periodAtEndOfBuffer` | `"Hello world."` (no trailing space) extracts `"Hello world."` |
| `test_extractSentence_noTerminator` | `"Hello world"` returns nil (no sentence boundary) |
| `test_extractSentence_multipleSentences` | Calling `extractSentence` repeatedly drains the buffer one sentence at a time |
| `test_extractSentence_emptyBuffer` | Empty buffer returns nil |
| `test_append_accumulatesText` | Multiple `append` calls concatenate text |
| `test_flush_returnsRemainingText` | After partial input, `flush()` returns unterminated text |
| `test_flush_clearsBuffer` | After `flush()`, buffer is empty (next `extractSentence` returns nil) |
| `test_flush_emptyBuffer_returnsEmpty` | Flushing an empty buffer returns `""` |
| `test_extractSentence_shortFragment` | Very short sentence `"Hi."` extracts correctly |
| `test_extractSentence_newlineAfterPeriod` | `"End.\nStart"` splits at the newline boundary |
| `test_extractSentence_periodFollowedByNoSpace` | `"Hello.World"` does NOT split (no space after period) |

**File: `VoicePipelineTests.swift`**

Test the pure, non-hardware functions exposed on `VoicePipeline`.

| Test Method | What It Verifies |
|---|---|
| `test_stripTerminationPhrase_thatsMyAnswer` | `"I loved it that's my answer"` strips to `"I loved it "` |
| `test_stripTerminationPhrase_thatsAll` | `"That's all"` strips to `""` |
| `test_stripTerminationPhrase_imDone` | `"Great memories I'm done"` strips to `"Great memories "` |
| `test_stripTerminationPhrase_noMatch` | `"I'm not done yet"` returns unchanged |
| `test_stripTerminationPhrase_caseInsensitive` | `"THAT'S MY ANSWER"` strips correctly (lowercased comparison) |
| `test_stripTerminationPhrase_endSession` | `"... end session"` strips to `"... "` |
| `test_pipelineState_equatable` | `.idle == .idle`, `.idle != .listening` |

### Phase 4: View Model Tests (Optional)

**File: `SessionStateTests.swift`**

`SessionState` contains `compileAnswer()` and auto-save logic that can be tested if the class is instantiated in a test context.

| Test Method | What It Verifies |
|---|---|
| `test_compileAnswer_multipleUserTurns` | Two user turns joined with double newline |
| `test_compileAnswer_mixedRoles_onlyUserTurns` | Assistant turns excluded from compiled answer |
| `test_compileAnswer_noTurns_returnsEmpty` | Empty conversation returns empty string |
| `test_resetSession_clearsAllState` | After reset, question is nil, turns empty, recording false |

**File: `MemoryMonitorTests.swift`**

| Test Method | What It Verifies |
|---|---|
| `test_pressureThresholds_normal` | 500+ MB returns `.normal` |
| `test_pressureThresholds_elevated` | 300-499 MB returns `.elevated` |
| `test_pressureThresholds_critical` | 150-299 MB returns `.critical` |
| `test_pressureThresholds_emergency` | < 150 MB returns `.emergency` |
| `test_canLoadKokoro_normalAndElevated` | Returns true for `.normal` and `.elevated` |

Note: `MemoryMonitor` reads live system memory via `os_proc_available_memory()`, so threshold logic cannot be directly unit-tested without refactoring to inject the memory value. These tests would require extracting the threshold logic into a pure function that takes an `Int` parameter. Low priority.

**File: `LLMServiceTests.swift`**

| Test Method | What It Verifies |
|---|---|
| `test_cleanChunk_stripsSpecialTokens` | `"<|hello|>"` becomes `"hello"` |
| `test_cleanChunk_stripsCodeFences` | `` "```code```" `` becomes `"code"` |
| `test_cleanChunk_normalText_unchanged` | `"Hello world"` passes through unchanged |
| `test_memoirInterviewerPrompt_containsUserName` | Prompt includes the provided user name |
| `test_memoirInterviewerPrompt_containsQuestionText` | Prompt includes the provided question text |

Note: `cleanChunk` is `nonisolated static`, so it's directly callable from tests. `cleanResponse` is private, so it would need to be tested indirectly or made `internal` with `@testable`.

## Acceptance Criteria

- [ ] All model types have encode/decode roundtrip tests
- [ ] QuestionBankParser has comprehensive edge-case tests (malformed lines, Unicode, whitespace)
- [ ] RotationEngine has coverage for all rotation scenarios (empty input, single category, tie-breaking, exclusion)
- [ ] SentenceBuffer has tests for abbreviations, ellipsis, numbers, short fragments, flush behavior
- [ ] StorageService has tests for atomic writes, read fallbacks, path traversal rejection, corrupted file recovery
- [ ] VoicePipeline's `stripTerminationPhrase` has tests for all six phrase variants
- [ ] OnboardingTemplates has tests verifying all project types produce valid markdown
- [ ] TaskTimeout has tests for both completion and timeout paths
- [ ] Build and all tests pass on `xcodebuild test`

## Estimated Effort

| Phase | New Test Files | New Test Cases | Effort |
|---|---|---|---|
| Phase 1: Models | 4 new + 1 expanded | ~25 | ~2 hours |
| Phase 2: Services | 3 new + 2 expanded | ~30 | ~4 hours |
| Phase 3: Pipeline | 2 new | ~27 | ~2 hours |
| Phase 4: View Models | 3 new | ~12 | ~2 hours |
| **Total** | **12 new + 3 expanded** | **~94** | **~10 hours** |

Phases 1 and 3 are the highest-value targets -- they cover pure logic with no mocking required. Phase 2's `StorageServiceTests` requires a temp-directory test fixture but is critical for data integrity. Phase 4 is optional and can be deferred.
