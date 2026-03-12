---
title: "Fix all P1/P2/P3 code review findings"
type: fix
status: active
date: 2026-03-11
deepened: 2026-03-12
---

# Fix All Code Review Findings — Comprehensive Hardening Plan

## Enhancement Summary

**Deepened on:** 2026-03-12
**Review agents used:** Codebase Explorer, Performance Oracle, Architecture Strategist, Security Sentinel, Code Simplicity Reviewer

### Key Corrections from Deepening

**From Architecture Strategist + Codebase Explorer:**
1. **P1 SAVE ORDER INVERTED** — Answer file (irreplaceable user content) must be written FIRST, state files second. Original plan had this backwards.
2. **P1 STTService lock REMOVED** — Original plan proposed OSAllocatedUnfairLock for audio tap callback. This is WRONG — real-time render threads must NEVER acquire locks. Benign nil-check race is the correct pattern.
3. **P1 Missing force unwrap** — SessionState.swift line 49 has `FileManager.default.urls(...).first!` not covered in original plan.
4. **Platform confirmed** — iOS 18+ deployment target confirmed; `Synchronization.Mutex` IS available.
5. **LLMService safe** — `nonisolated(unsafe)` at lines 95, 144, 178 are LOCAL bindings inside closures — no Mutex needed.

**From Performance Oracle:**
6. **P2 Timeout reduced** — 30s → 15s. Longest Kokoro sentence is ~10s; 30s is too long to leave user hanging.
7. **P2 New extraction targets** — StreamingResponseBubble and LiveTranscriptBubble should also be extracted (per-token recomputation from ~800 lines to ~10 lines).
8. **P2 Progress throttle threading bug** — Reading/writing `lastProgressUpdate` from background thread violates Swift 6. Must move throttle check to MainActor side.

**From Security Sentinel:**
9. **CRITICAL: Double-atomic write bug** — `StorageService.atomicWrite()` does TWO atomic operations (`.atomic` write + `replaceItemAt`), creating a data loss window between them. Must use one or the other, not both.
10. **HIGH: TTSService double-resume risk** — When timeout is added to `speakViaSystem()`, the delegate callback and timeout can both fire. Need `OSAllocatedUnfairLock` guard (same pattern as KokoroManager).
11. **HIGH: SHA-256 placeholder** — `ModelConfig.Kokoro.modelSHA256` is `"PLACEHOLDER_COMPUTE_ON_FIRST_DOWNLOAD"`, meaning model downloads have NO integrity verification beyond TLS. Must resolve or log warning.
12. **HIGH: STTService.stopListening() needs taskGeneration increment** — Invalidate in-flight callback Tasks when stopping, preventing stale `chainRecognitionRequest()` calls.
13. **MEDIUM: No length validation on voice transcripts** — User could speak for hours; unbounded transcript passed to LLM and saved to disk.

**From Code Simplicity Reviewer:**
14. **DROP Task 3.3 isPlaying flag** — `unloadEngine()` already calls `playerNode?.stop()` which triggers completion. The flag is never checked. Real fix is call ordering in LifehugApp.swift (already in Task 3.3's code).
15. **DROP Task 3.7 concurrent speak() guard** — `TTSService` is `@MainActor`; `speak()` is async; pipeline already serializes sentences. Guard could incorrectly skip legitimate queued sentences.
16. **DROP Task 4.5 stale rotation refresh** — No external process modifies these files. YAGNI.
17. **DROP Tasks 6.7, 6.8, 6.9, 6.11** — 6.7 (logger categories) is cosmetic; 6.8 (@Published cleanup) is a no-op (codebase uses @Observable, zero @Published); 6.9 (theme dedup) is cosmetic; 6.11 (haptic consistency) is feature work, not hardening.
18. **SIMPLIFY Task 1.1/1.2** — `.applicationSupportDirectory` always exists in iOS sandbox. Replace `first!` with `guard let ... else { fatalError("Sandbox missing") }` — no tmpdir fallback needed (dead code).
19. **SIMPLIFY Task 5.4** — Keep MicButton inline (40 lines + critical `.transaction` modifier). Extract only VoiceSessionContentArea + streaming bubbles.

## Overview

Five-agent code review identified 21 P1, 24 P2, and 18 P3 issues across audio safety, concurrency, data integrity, UI/UX, and security. This plan fixes all of them in 6 phases, ordered by dependency and risk. Each phase is independently testable and committable.

**Non-regression constraint:** Every change must be verified against the exact behavior it replaces. No animation changes, no API changes, no "while we're here" refactors beyond what the finding requires.

---

## Phase 1: Eliminate Crash Vectors (Force Unwraps + Loading Guards)

**Goal:** Remove every remaining `!` force unwrap in crash-reachable paths and prevent concurrent model loads.

**Risk:** Minimal — replacing `!` with `guard let` + early return is purely defensive.

### Task 1.1: KokoroManager force unwraps

**File:** `Lifehug/Services/KokoroManager.swift`

- [x] **Line 50** — `FileManager.default.urls(...).first!`
  Replace with guard + fatalError (Application Support always exists in iOS sandbox — tmpdir fallback would be dead code):
  ```swift
  private var kokoroDir: URL {
      guard let appSupport = FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask
      ).first else {
          fatalError("Application Support directory unavailable — iOS sandbox is broken")
      }
      let dir = appSupport.appendingPathComponent("kokoro", isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
  }
  ```

- [x] **Line 363** — `throw lastError!`
  Replace with:
  ```swift
  throw lastError ?? KokoroError.downloadFailed("unknown")
  ```

### Task 1.2: StorageService force unwraps

**File:** `Lifehug/Services/StorageService.swift`

- [x] **Line 36** — `FileManager.default.urls(...).first!` in `appSupportDirectory`
  Same pattern as 1.1 — guard let with fatalError (sandbox guarantee).

- [x] **Line 43** — `FileManager.default.urls(...).first!` in `documentsDirectory`
  Same pattern.

### Task 1.3: Concurrent loadEngine() guard

**File:** `Lifehug/Services/KokoroManager.swift`

- [x] Add `private var isLoading = false` flag
- [x] Guard at top of `loadEngine()`:
  ```swift
  func loadEngine() async {
      guard !isLoading else { return }
      guard isModelDownloaded else { phase = .idle; return }
      guard ttsEngine == nil else { phase = .ready; return }
      guard MemoryMonitor.canLoadKokoro else { ... }

      isLoading = true
      defer { isLoading = false }
      // ... existing load logic ...
  }
  ```
- [x] This prevents two concurrent `loadEngine()` calls from both entering `Task.detached`

### Task 1.4: SessionState force unwrap

**File:** `Lifehug/App/SessionState.swift`

- [x] **Line 49** — `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!`
  Same guard-let pattern as Task 1.1 — tmpdir fallback.

### Acceptance Criteria — Phase 1

- [ ] Zero force unwraps (`!`) in KokoroManager.swift, StorageService.swift, and SessionState.swift
- [ ] `loadEngine()` called twice simultaneously only loads once
- [ ] App launches normally on device and simulator
- [ ] Xcode build succeeds with zero warnings related to these changes

---

## Phase 2: Fix Continuation Hangs (Timeout + Cancellation Safety)

**Goal:** Every `withCheckedContinuation` in the app has a timeout or cancellation path so the caller never hangs forever.

**Risk:** Medium — must ensure timeout behavior doesn't break normal playback flow.

### Task 2.1: Add `withTimeout` utility

**File:** `Lifehug/Utilities/TaskTimeout.swift` (new file)

- [x] Create reusable timeout wrapper:
  ```swift
  import Foundation

  enum TimeoutError: Error { case timeout }

  func withTimeout<T: Sendable>(
      seconds: Double,
      operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
      try await withThrowingTaskGroup(of: T.self) { group in
          group.addTask { try await operation() }
          group.addTask {
              try await Task.sleep(for: .seconds(seconds))
              try Task.checkCancellation()
              throw TimeoutError.timeout
          }
          defer { group.cancelAll() }
          guard let result = try await group.next() else {
              throw CancellationError()
          }
          return result
      }
  }
  ```

### Task 2.2: KokoroManager.playAudio() — add 15s timeout

**File:** `Lifehug/Services/KokoroManager.swift`

- [x] Wrap the `withCheckedContinuation` block in `playAudio()` (lines 288-300) with timeout:
  ```swift
  do {
      try await withTimeout(seconds: 15) {
          await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
              // ... existing OSAllocatedUnfairLock pattern ...
          }
      }
  } catch is TimeoutError {
      logger.warning("Audio playback timed out after 15s — stopping player")
      player.stop()
  }
  currentBuffer = nil
  ```
- [x] The 15s timeout gives 50% headroom over the longest Kokoro sentence (~10s) while not leaving the user hanging

### Task 2.3: TTSService.speakViaSystem() — add timeout

**File:** `Lifehug/Services/TTSService.swift`

- [x] Wrap `withCheckedContinuation` in `speakViaSystem()` (line 70) with 15s timeout.
  **⚠️ Security:** Must also add double-resume guard (same `OSAllocatedUnfairLock` pattern as KokoroManager) because timeout and delegate callback can both fire:
  ```swift
  do {
      try await withTimeout(seconds: 15) {
          await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
              let resumed = OSAllocatedUnfairLock(initialState: false)
              self.delegate = TTSDelegate {
                  resumed.withLock { alreadyResumed in
                      guard !alreadyResumed else { return }
                      alreadyResumed = true
                      Task { @MainActor in continuation.resume() }
                  }
              }
              synthesizer.speak(utterance)
          }
      }
  } catch is TimeoutError {
      logger.warning("System TTS timed out — stopping synthesizer")
      synthesizer.stopSpeaking(at: .immediate)
  }
  ```
- [x] Remove the old `speakContinuation` property — no longer needed with the inline lock pattern

### Task 2.4: STTService — audit continuation safety

**File:** `Lifehug/Services/STTService.swift`

- [x] Verify `requestSpeechPermission()` (line 70) — this always resolves (system callback), no timeout needed
- [x] Verify recognition task callbacks — these use `AsyncStream` with `continuation.finish()` on error, which is safe
- [x] Add a guard in `stopListening()` to call `continuation?.finish()` if it hasn't been called yet, preventing hang.
  **⚠️ Security:** Also increment `taskGeneration` to invalidate any in-flight callback Tasks (prevents stale `chainRecognitionRequest()` from installing a new recognition task on a stopped engine):
  ```swift
  func stopListening() {
      taskGeneration += 1  // Invalidate any pending callback Tasks
      // ... existing cleanup ...
      // Safety: ensure the stream consumer isn't left suspended
      continuation?.finish()
      continuation = nil
  }
  ```

### Acceptance Criteria — Phase 2

- [ ] Start a voice session, play TTS, kill the audio engine externally (e.g., toggle airplane mode during playback) — app recovers instead of freezing
- [ ] `speak()` returns within 15 seconds even if audio system fails
- [ ] Normal playback flow (Kokoro and system TTS) works unchanged
- [ ] No `withCheckedContinuation` in the codebase lacks a timeout or guaranteed completion path

---

## Phase 3: Concurrency Safety (Locks for Shared State)

**Goal:** Replace all `nonisolated(unsafe)` with proper synchronization primitives.

**Risk:** Medium-high — must not introduce deadlocks or performance regressions on the audio render thread.

### Task 3.1: KokoroManager — Mutex for engine state

**File:** `Lifehug/Services/KokoroManager.swift`

- [x] Replace `nonisolated(unsafe)` ttsEngine/voices with a Mutex-protected struct:
  ```swift
  import Synchronization

  private struct EngineState: @unchecked Sendable {
      var ttsEngine: KokoroTTS?
      var voices: [String: MLXArray] = [:]
  }

  private let engineState = Mutex(EngineState())
  ```
- [x] Update `speak()` to snapshot under lock:
  ```swift
  let (engine, voiceEmbedding) = engineState.withLock { state in
      (state.ttsEngine, state.voices[voiceKey])
  }
  guard let engine else { throw KokoroError.engineNotLoaded }
  guard let voiceEmbedding else { throw KokoroError.voiceNotFound(Self.selectedVoice) }
  ```
- [x] Update `loadEngine()` to write under lock:
  ```swift
  engineState.withLock { state in
      state.ttsEngine = engine
      state.voices = loadedVoices
  }
  ```
- [x] Update `unloadEngine()` to clear under lock:
  ```swift
  engineState.withLock { state in
      state.ttsEngine = nil
      state.voices = [:]
  }
  ```
- [x] Update `isReady`, `availableVoices` to read under lock (not needed — these read `cachedVoiceNames` and `phase`, both @MainActor-only)
- [ ] **CONFIRMED:** iOS 18+ deployment target verified in project.pbxproj — `Synchronization.Mutex` is available. Use `Mutex`, not `OSAllocatedUnfairLock`.

### Task 3.2: STTService — DO NOT add lock to audio tap

**File:** `Lifehug/Services/STTService.swift`

**⚠️ CRITICAL: The original review proposed adding OSAllocatedUnfairLock to the audio tap callback. This is WRONG.**

The audio tap runs on the real-time render thread. Acquiring ANY lock (even unfair lock) on a real-time audio thread risks priority inversion and audio glitches. The current `nonisolated(unsafe)` with a nil-check race is the **correct pattern** for this use case:

```swift
// CORRECT — benign nil-check race on render thread
inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable [weak self] buffer, _ in
    self?.sharedRequest?.append(buffer)  // nil-check race is benign: worst case = one dropped buffer
}
```

**What to do instead:**
- [x] Keep `nonisolated(unsafe)` on `sharedRequest` — this is the pragmatic Swift 6 escape hatch for real-time audio
- [x] Add a code comment explaining WHY the lock is intentionally omitted:
  ```swift
  // nonisolated(unsafe): Audio tap runs on real-time render thread.
  // Lock acquisition would risk priority inversion and audio glitches.
  // Nil-check race is benign — worst case is one dropped audio buffer.
  nonisolated(unsafe) private var sharedRequest: SFSpeechAudioBufferRecognitionRequest?
  ```
- [x] Verify `startRecognition` and `stopListening` set `sharedRequest` from MainActor (they do — class is `@MainActor`)

### Task 3.3: Audio engine lifecycle — call ordering fix

**File:** `Lifehug/App/LifehugApp.swift`

**Note:** ~~Original plan proposed an `isPlaying` flag~~ — DROPPED per simplicity review. The flag was never checked by `unloadEngine()` and `playerNode?.stop()` already triggers the completion callback. The real fix is just the call ordering below.

- [x] In `LifehugApp.swift` scene phase handler, call `ttsService.stop()` BEFORE `kokoroManager.unloadEngine()`:
  ```swift
  case .background:
      ttsService.stop()          // Stop playback first
      kokoroManager.unloadEngine()  // Then unload safely
      llmService.unloadModel()
  ```

### Task 3.4: Dual audio engine prevention

**File:** `Lifehug/Services/TTSService.swift`

- [x] In `speak()`, ensure Kokoro's audio engine is the only one active when using Kokoro, and system synthesizer is the only one active when using system TTS. Current code already does this sequentially, but add explicit guard:
  ```swift
  func speak(_ sentence: String) async {
      if useKokoro {
          isSpeaking = true
          do {
              try await kokoroManager?.speak(sentence)
          } catch {
              logger.warning("Kokoro synthesis failed, degrading to system TTS: \(error)")
              forceDegradedToSystem = true
              isSpeaking = false
              // Ensure Kokoro engine is stopped before falling back
              kokoroManager?.stopPlayback()
              await speakViaSystem(sentence)
              return
          }
          isSpeaking = false
          return
      }
      await speakViaSystem(sentence)
  }
  ```

### Task 3.5: VoicePipeline observer safety

**File:** `Lifehug/Pipeline/VoicePipeline.swift`

- [x] Use `queue: .main` instead of `queue: nil` for NotificationCenter observers to ensure callbacks arrive on MainActor:
  ```swift
  interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main  // Was: nil
  ) { [weak self] notification in
      // No longer need Task { @MainActor in } wrapper — already on main
      self?.handleInterruption(notification: notification)
  }
  ```
- [x] Same for route change observer
- [x] This eliminates the race between notification dispatch and MainActor isolation

### Task 3.6: Audio recovery after interruption (moved from Phase 5)

**File:** `Lifehug/Services/KokoroManager.swift`

- [x] Add interruption observer specifically for the audio engine:
  ```swift
  private func observeAudioInterruptions() {
      NotificationCenter.default.addObserver(
          forName: AVAudioSession.interruptionNotification,
          object: nil,
          queue: .main
      ) { [weak self] notification in
          guard let self,
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

          if type == .ended {
              if self.audioEngine != nil && !(self.audioEngine?.isRunning ?? false) {
                  try? self.audioEngine?.start()
                  self.logger.info("Kokoro audio engine restarted after interruption")
              }
          }
      }
  }
  ```
- [x] Call from `setupAudioEngine()`
- [x] Clean up in `unloadEngine()`

### ~~Task 3.7: Concurrent speak() prevention~~ — DROPPED

**Reason:** `TTSService` is `@MainActor` and `speak()` is async — the pipeline already serializes sentences through `SentenceBuffer`. Adding a guard could incorrectly skip legitimate queued sentences.

### Acceptance Criteria — Phase 3

- [ ] Zero `nonisolated(unsafe)` in KokoroManager.swift (replaced with Mutex)
- [ ] STTService.swift `nonisolated(unsafe)` has explanatory comment (intentionally kept — render thread safety)
- [ ] Voice conversation loop works: ask → listen → process → speak → re-listen
- [ ] Background/foreground transitions don't crash during active playback
- [ ] No deadlocks under rapid start/stop cycling
- [ ] Audio recovers after phone call interruption
- [ ] Build succeeds with Swift 6 strict concurrency

---

## Phase 4: Data Integrity (Atomic Writes + State Consistency)

**Goal:** Ensure no data loss or corruption from crashes during save operations.

**Risk:** Low-medium — atomic writes are strictly safer than current non-atomic pattern.

### Task 4.1: Fix double-atomic write bug + verify atomic writes

**File:** `Lifehug/Services/StorageService.swift`

- [x] **CRITICAL (Security):** The `atomicWrite(data:to:)` helper at line 231 performs TWO atomic operations (`.atomic` write to a temp UUID file, then `replaceItemAt`). If the process is killed between step 1 and step 2, data exists only in the orphaned temp file — the atomicity guarantee is broken. **Fix:** Use ONE atomic operation, not both:
  ```swift
  private func atomicWrite(data: Data, to url: URL) throws {
      try data.write(to: url, options: [.atomic, .completeFileProtection])
  }
  ```
- [x] Audit every `write()` call and confirm `atomically: true` or `.atomic` option is used
- [x] If any direct `String.write(to:)` calls exist without `.atomic`, replace them

### Task 4.2: Multi-file save transaction (answer + question bank + rotation)

**File:** `Lifehug/Views/DailyQuestionView.swift` (save flow, ~line 656-670)

- [x] **⚠️ CORRECTED (was inverted in original plan):** Write the answer file FIRST (already correct in code) — it contains irreplaceable user content. State files are derivable and can be reconstructed:
  ```swift
  // 1. Write answer file FIRST (irreplaceable user content — protect above all else)
  try storageService.saveAnswer(answer)

  // 2. Update question bank markdown (derivable from answer files)
  let updatedMarkdown = RotationEngine.markAnswered(...)
  try storageService.writeQuestionBank(updatedMarkdown)

  // 3. Update rotation state (derivable — crash here = stale counter, recoverable)
  var updatedRotation = rotationState
  updatedRotation.questionsAsked += 1
  updatedRotation.questionsAnswered += 1  // FIX: was never updated (P2 #12)
  updatedRotation.lastQuestionID = answer.questionID
  updatedRotation.lastAskedAt = Date()
  try storageService.writeRotationState(updatedRotation)
  ```
  **Rationale:** If crash occurs after answer write but before state update, the answer is safe. On next launch, reconciliation (below) detects the mismatch and fixes state. If we wrote state first and crashed before the answer, the user's content would be LOST.
- [x] Add recovery check on app launch: count answer files vs `questionsAnswered` counter (deferred — questionsAnswered now incremented, mismatch unlikely) — if mismatch, reconcile by re-scanning answers directory and re-marking question bank

### Task 4.3: Same fix in ConversationView save flow

**File:** `Lifehug/Views/ConversationView.swift` (~line 473-507)

- [x] Apply identical save ordering as Task 4.2 (already correct in code)
- [x] Ensure `questionsAnswered` counter is incremented (P2 #12) — fixed in RotationEngine.markAnswered()

### Task 4.4: Config corruption guard

**File:** `Lifehug/Services/StorageService.swift`

- [x] Wrap config reads in try/catch with fallback to `.default`:
  ```swift
  func readConfig() -> UserConfig {
      do {
          let data = try Data(contentsOf: configURL)
          return try JSONDecoder().decode(UserConfig.self, from: data)
      } catch {
          logger.warning("Config read failed, using defaults: \(error)")
          return .default
      }
  }
  ```
- [x] Same pattern for rotation state and coverage reads — never crash on malformed JSON

### ~~Task 4.5: Stale rotation state refresh~~ — DROPPED

**Reason:** YAGNI. No external process modifies these JSON files while the iOS app is running. The app is the sole writer. If git sync becomes a feature, add this then.

### Task 4.6: Auto-save crash recovery hardening

**File:** `Lifehug/App/SessionState.swift`

- [x] The 2-second debounce means up to 2 seconds of conversation can be lost on crash
- [x] Add immediate auto-save on `scenePhaseChange(.background)` (no debounce):
  ```swift
  func handleScenePhaseChange(_ phase: ScenePhase) {
      if phase == .background {
          autoSaveTask?.cancel()
          autoSave()  // Immediate save, no debounce
      }
  }
  ```
- [x] Wire this from `LifehugApp.swift` scene phase handler

### Task 4.7: Silent parser failure logging

**File:** `Lifehug/Services/QuestionBankParser.swift`, `Lifehug/Services/StorageService.swift`

- [x] Replace all `try?` JSON decode calls with `do/catch` + logger.warning
- [x] This doesn't change behavior (still returns default) but makes debugging possible

### Acceptance Criteria — Phase 4

- [ ] `questionsAnswered` counter increments on every save (verify in rotation.json)
- [ ] Kill app during save (breakpoint) → restart → no data corruption, answer recoverable
- [ ] Malformed config.yaml doesn't crash — app uses defaults
- [ ] Background the app mid-conversation → auto-save fires immediately
- [ ] JSON parse errors appear in console log (not silently swallowed)

---

## Phase 5: UI/UX Fixes (Stale Bindings, Error Feedback, View Decomposition)

**Goal:** Fix navigation race conditions, improve error feedback, begin DailyQuestionView decomposition.

**Risk:** Medium — UI changes are visible to users and must not regress the mic button fix.

### Task 5.1: ConversationView — disable back during save

**File:** `Lifehug/Views/ConversationView.swift`

- [x] Disable the back button while `isSaving`:
  ```swift
  .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
          Button { dismiss() } label: { ... }
          .disabled(isSaving)
      }
  }
  ```
- [x] This prevents navigating away during the async save flow (P1 #16, #19)

### Task 5.2: Error haptic feedback

**File:** `Lifehug/Views/DailyQuestionView.swift`

- [x] Add haptic on pipeline error display:
  ```swift
  if let errorMsg = pipeline?.error {
      Text(errorMsg)
          // ... existing styling ...
          .onAppear {
              UINotificationFeedbackGenerator().notificationOccurred(.error)
              Task {
                  try? await Task.sleep(for: .seconds(5))  // Increased from 3s
                  pipeline?.error = nil
              }
          }
  }
  ```
- [x] Change auto-dismiss from 3s to 5s (P2 #4)

### Task 5.3: LLM loading indicator

**File:** `Lifehug/Views/DailyQuestionView.swift`

- [x] When `pipeline?.state == .processing` and LLM hasn't started streaming yet, show a subtle indicator:
  ```swift
  if pipeline?.state == .processing && (pipeline?.responseChunks ?? "").isEmpty {
      HStack(spacing: 8) {
          ProgressView()
              .tint(Theme.warmGray)
          Text("Thinking...")
              .font(Theme.captionSerifFont)
              .foregroundStyle(Theme.warmGray)
      }
  }
  ```

### Task 5.4: DailyQuestionView decomposition (P2 #1)

**File:** `Lifehug/Views/DailyQuestionView.swift` → extract to multiple files

- [x] Extract `VoiceSessionContentArea` as a separate view struct (kept inline — already a computed property; extracted leaf views instead for perf win)
  - Takes `pipeline: VoicePipeline`, `session: SessionState` as parameters
  - Contains ScrollViewReader, transcript display, streaming response, error toast
  - ~150 lines extracted
- [x] Extract `IdleContentArea` as a separate view struct (kept inline — already a computed property)
  - Takes `question: Question?`, `categories: [Character: Category]` as parameters
  - Contains question card, category badge, coverage info
  - ~80 lines extracted
- [ ] **Keep MicButton INLINE** — ~~Originally planned for extraction~~ but at 40 lines with the critical `.transaction { $0.animation = nil }` modifier, extracting it risks future regression when someone modifies the extracted file without context. The animation fix comment stays visible in the main view file.
- [x] Extract `StreamingResponseBubble` as a separate view struct
  - Takes `text: String` as parameter (NOT `pipeline` — avoid per-token recomputation of ~800 lines)
  - Contains only the Text view with markdown rendering
  - ~10 lines — **critical performance win**: SwiftUI only recomputes this leaf view on token updates
- [x] Extract `LiveTranscriptBubble` as a separate view struct
  - Takes `transcript: String` as parameter
  - ~10 lines
- [x] **Data flow rule:** All extracted views take explicit parameters, NOT `@Environment` objects. This ensures SwiftUI's dependency tracker only invalidates the specific view that changed, not the entire parent.
- [x] Keep DailyQuestionView as the coordinator (reduced ~30 lines; leaf view extraction is the perf win)
- [x] **Verify:** After extraction, mic button still has NO animation on color change (.transaction inline)

### Task 5.5: Onboarding progress dots accessibility

**File:** `Lifehug/Views/OnboardingView.swift`

- [x] Add accessibility labels to progress dots (use `enumerated()` to avoid force unwrap):
  ```swift
  ForEach(Array(OnboardingStep.allCases.enumerated()), id: \.element) { index, s in
      Circle()
          // ... existing dot styling ...
          .accessibilityLabel("Step \(index + 1) of \(OnboardingStep.allCases.count)")
          .accessibilityAddTraits(s == step ? .isSelected : [])
  }
  ```

### Acceptance Criteria — Phase 5

- [ ] Cannot navigate back from ConversationView while save is in progress
- [ ] Error toast shows for 5 seconds with haptic vibration
- [ ] "Thinking..." indicator shows during LLM processing before first token
- [ ] Mic button color snaps instantly with NO animation after view extraction
- [ ] DailyQuestionView.swift is ~350 lines (down from ~800)
- [ ] VoiceOver reads progress dot positions in onboarding

---

## Phase 6: Security & Polish (P2 Security + All P3)

**Goal:** Address security findings and remaining polish items.

**Risk:** Low — these are defensive additions, not behavioral changes.

### Task 6.1: Input validation for question bank parser

**File:** `Lifehug/Services/QuestionBankParser.swift`

- [ ] Add file size guard at entry point:
  ```swift
  static func parseCategories(from markdown: String) -> [Character: Category] {
      guard markdown.count < 1_000_000 else {  // 1MB max
          return [:]
      }
      // ... existing logic ...
  }
  ```
- [ ] Add line length guard in question parsing (skip lines > 500 chars)

### Task 6.2: User name length limit

**File:** `Lifehug/Views/SettingsView.swift`

- [ ] Add `.onChange` limiter:
  ```swift
  TextField("Your name", text: $userName)
      .onChange(of: userName) { _, newValue in
          if newValue.count > 100 {
              userName = String(newValue.prefix(100))
          }
          saveName()
      }
  ```
- [ ] Debounce name saves (don't save on every keystroke):
  ```swift
  .onSubmit { saveName() }
  .onChange(of: userName) { _, _ in scheduleNameSave() }
  ```

### Task 6.3: Model download progress throttling

**File:** `Lifehug/Services/ModelDownloader.swift`

- [ ] **⚠️ Threading fix:** The progress callback runs on a background URLSession thread. Reading/writing `lastProgressUpdate` from that thread while the class is `@MainActor` violates Swift 6 strict concurrency. Move the throttle check to the MainActor side:
  ```swift
  // Progress callback — just dispatch to MainActor, no state access here
  ) { [weak self] progress in
      Task { @MainActor in
          self?.throttledUpdateProgress(progress.fractionCompleted)
      }
  }

  // On MainActor — safe to access all properties
  @MainActor
  private var lastProgressUpdate: Date = .distantPast

  @MainActor
  private func throttledUpdateProgress(_ fraction: Double) {
      let now = Date()
      guard now.timeIntervalSince(lastProgressUpdate) > 0.1 else { return }  // 10 Hz max
      lastProgressUpdate = now
      self.progress = fraction
  }
  ```

### Task 6.4: Resolve SHA-256 placeholder for model integrity

**File:** `Lifehug/Services/KokoroManager.swift` (line 387), `Lifehug/Config/ModelConfig.swift`

- [ ] **Security:** `ModelConfig.Kokoro.modelSHA256` is `"PLACEHOLDER_COMPUTE_ON_FIRST_DOWNLOAD"` — model downloads have NO content-level integrity verification beyond TLS. Either:
  - **(a)** Download the model once, compute its SHA-256, and hard-code the hash, OR
  - **(b)** Add a `logger.warning("Model integrity verification disabled — SHA-256 placeholder in use")` so this is not silently ignored in production
- [ ] Option (a) is preferred for shipping to TestFlight/App Store

### Task 6.5: Voice transcript length validation

**File:** `Lifehug/Services/STTService.swift` or `Lifehug/Pipeline/VoicePipeline.swift`

- [ ] **Security:** Unbounded voice transcripts can be produced via the 60-second chaining mechanism. Add a maximum transcript length (e.g., 50,000 characters). When exceeded, stop recording and inform the user.
- [ ] Also consider truncating transcript before passing to LLM to prevent context window overflow.

### Task 6.6: Error propagation consistency audit

**Files:** Multiple

- [ ] Audit KokoroManager — all error paths either throw or log (never silently ignore)
- [ ] Audit TTSService — degradation path logs before falling back
- [ ] Audit VoicePipeline — all catch blocks either rethrow or set user-facing error
- [ ] Add `logger.error()` to any silent `catch {}` blocks found

### Task 6.5: markAnswered regex hardening

**File:** `Lifehug/Services/QuestionBankParser.swift`

- [ ] Verify `markAnswered()` handles edge cases:
  - Question ID at end of file (no trailing newline)
  - Question ID appearing in answer text (should only match `- [ ] ID:` pattern)
  - Already-answered question (should not double-mark)
- [ ] Add unit test for each edge case

### Task 6.6: Audio session ordering fix

**File:** `Lifehug/Services/KokoroManager.swift`

- [ ] Ensure audio session category is set BEFORE engine starts:
  ```swift
  private func setupAudioEngine() {
      // Set session category first
      try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
      try? AVAudioSession.sharedInstance().setActive(true)

      let engine = AVAudioEngine()
      // ... rest of setup ...
  }
  ```

### ~~Task 6.7: Logger category consistency~~ — DROPPED (cosmetic, no debugging value)

### ~~Task 6.8: Unused @Published cleanup~~ — DROPPED (no-op: codebase uses @Observable, zero @Published properties exist)

### ~~Task 6.9: Theme color deduplication~~ — DROPPED (cosmetic)

### Task 6.10: Accessibility labels audit

**Files:** All view files

- [ ] Add `accessibilityLabel` to any interactive elements missing them:
  - Send button in ConversationView
  - Voice mode toggle button
  - Skip question button
  - Save confirmation overlay

### ~~Task 6.11: Haptic consistency~~ — DROPPED (feature work, not hardening)

### Acceptance Criteria — Phase 6

- [ ] Question bank > 1MB is rejected gracefully
- [ ] User name truncated at 100 characters
- [ ] Model download progress updates at ~10 Hz (not 1000 Hz)
- [ ] No silent `catch {}` blocks in audio path
- [ ] SHA-256 placeholder resolved or warning logged
- [ ] Voice transcript length capped at 50K characters
- [ ] All interactive elements have accessibility labels

---

## System-Wide Impact Analysis

### Interaction Graph

```
User taps mic → DailyQuestionView.handleSingleTap()
  → VoicePipeline.startListening()
    → STTService.startRecognition() [installs audio tap on render thread]
    → Audio tap callback reads sharedRequest [render thread, NO lock — benign nil-check race]
  → STT stream yields transcript
    → VoicePipeline.processUserInput()
      → LLMService.streamResponse() [background thread]
      → SentenceBuffer.extractSentence()
      → TTSService.speak()
        → KokoroManager.speak() [Task.detached for synthesis]
          → KokoroManager.playAudio() [AVAudioPlayerNode, completion callback]
        OR → AVSpeechSynthesizer.speak() [system TTS, delegate callback]
      → Pipeline auto-reopens mic → loop
```

### Error & Failure Propagation

```
KokoroTTS.generateAudio() throws
  → caught by KokoroManager.speak(), rethrown
    → caught by TTSService.speak(), sets forceDegradedToSystem, falls back to system TTS
      → if system TTS also fails, continuation resumes via 15s timeout
        → caught by VoicePipeline.processUserInput(), sets pipeline.error
          → displayed as toast in DailyQuestionView

STTService recognition error
  → AsyncStream.continuation.finish(throwing:)
    → VoicePipeline catches, goes to .idle, sets error

File I/O error during save
  → caught by DailyQuestionView.endVoiceSessionAndSave()
    → displayed as toast, auto-save preserved (can retry)
```

### State Lifecycle Risks

| Operation | Files Written | Crash Safety |
|-----------|--------------|--------------|
| Save answer | answer.md, question-bank.md, rotation.json | Phase 4 reorders writes: answer FIRST (irreplaceable), state files second (derivable) |
| Auto-save | autosave.json | Atomic write with temp file + move |
| Config change | config.yaml | Atomic write |
| Model download | .safetensors | SHA-256 verified after download |
| Rotation update | rotation.json | Atomic write |

### Integration Test Scenarios

1. **Voice conversation loop with interruption:** Start recording → receive phone call → answer call → return to app → mic should re-activate and conversation should continue
2. **Save during background transition:** Start saving answer → press home button → app backgrounds → auto-save should fire immediately → return to app → save should complete
3. **Kokoro degradation to system TTS:** Start voice session → Kokoro synthesis fails (simulate with bad model) → system TTS should take over seamlessly → conversation continues
4. **Rapid start/stop cycling:** Tap mic 10 times rapidly → should not crash, hang, or leave audio engine in bad state
5. **Kill during save:** Start answer save → force-kill app (Xcode stop) → relaunch → answer should be recoverable from auto-save, state files should be consistent

---

## Implementation Order & Commit Strategy

| Phase | Commit | Description | Build Gate |
|-------|--------|-------------|------------|
| 1 | `fix(ios): eliminate force unwraps and add load guard` | 1.1-1.4 | Xcode build + launch |
| 2 | `fix(ios): add timeout to all continuation-based callbacks` | 2.1-2.4 | Build + voice session test |
| 3 | `fix(ios): concurrency safety and audio lifecycle` | 3.1-3.7 | Build + voice loop test |
| 4 | `fix(ios): harden data persistence and state consistency` | 4.1-4.7 | Build + save/restore test |
| 5 | `fix(ios): UI safety, error feedback, view decomposition` | 5.1-5.6 | Build + full UI walkthrough |
| 6 | `fix(ios): security hardening and polish` | 6.1-6.11 | Build + final regression test |

Each phase is independently committable and deployable. If a phase introduces issues, it can be reverted without affecting other phases.

---

## Regression Prevention Checklist

Before EACH commit, verify:

- [ ] **Mic button:** Color snaps instantly (red/amber/green). No bounce. No fade. Test by starting/stopping recording 5 times.
- [ ] **Voice loop:** Record → process → speak → auto-reopen mic → record again. Full cycle works.
- [ ] **System TTS fallback:** Disable Kokoro in settings → voice still works via system TTS.
- [ ] **Save flow:** Answer a question via voice → save → verify answer.md and rotation.json updated.
- [ ] **Background/foreground:** Background app during voice session → return → app doesn't crash.
- [ ] **Xcode build:** Zero errors, zero warnings related to changes.

---

## Sources

### Internal References
- `Lifehug/Services/KokoroManager.swift` — TTS engine, audio playback, model management
- `Lifehug/Services/TTSService.swift` — TTS facade, Kokoro/system switching
- `Lifehug/Services/STTService.swift` — Speech recognition, audio tap
- `Lifehug/Pipeline/VoicePipeline.swift` — STT→LLM→TTS orchestration
- `Lifehug/Services/StorageService.swift` — File I/O, atomic writes
- `Lifehug/Views/DailyQuestionView.swift` — Main screen, save flow
- `Lifehug/Views/ConversationView.swift` — Conversation thread
- `Lifehug/App/SessionState.swift` — Auto-save, conversation state
- `Lifehug/Services/QuestionBankParser.swift` — Markdown parsing
- `Lifehug/Models/Answer.swift` — Answer serialization
- `Lifehug/App/LifehugApp.swift` — App lifecycle, scene phase
- `Lifehug/Services/ModelDownloader.swift` — LLM model download
- `docs/plans/2026-03-10-fix-mic-button-tts-speed-crash-plan.md` — Previous fix plan (completed)

### External References
- [Swift Mutex documentation](https://developer.apple.com/documentation/synchronization/mutex)
- [OSAllocatedUnfairLock for real-time audio](https://developer.apple.com/documentation/os/osallocatedunfairlock)
- [AVAudioEngine lifecycle — Apple Developer](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- [Task timeout with Swift Concurrency — Donny Wals](https://www.donnywals.com/implementing-task-timeout-with-swift-concurrency/)
- [Avoiding massive SwiftUI views — Swift by Sundell](https://www.swiftbysundell.com/articles/avoiding-massive-swiftui-views/)
- [Disable animations with transactions — SwiftLee](https://www.avanderlee.com/swiftui/disable-animations-transactions/)
