---
title: "Fix STT cutoff, LLM token limit, and TTS voice quality"
type: fix
status: completed
date: 2026-03-22
---

# Fix STT Cutoff, LLM Token Limit, and TTS Voice Quality

## Overview
Five issues with the voice pipeline affecting recording completeness, response quality, and speech naturalness.

## Issues and Fixes

### Task 1: Add diagnostic logging to STT chaining and error paths
**File:** Lifehug/Services/STTService.swift

The STT recording cuts off at ~2/3 of user speech even with silence timer disabled. Root cause unclear -- need logging to diagnose. The 60-second Apple Speech chaining, recognition errors, or audio session state could be the culprit.

- [x] Add logger.info in chainRecognitionRequest() before and after each step (create new request, swap, tear down old, install new)
- [x] Add logger.warning in the recognition error callback (line 348) with the full NSError domain and code, not just the error description
- [x] Add logger.info when isFinal result arrives (line 311) showing shouldKeepListening state
- [x] Add logger.info at the start of stopListening() showing who called it (add a `reason: String` parameter)
- [x] Add a guard in chainRecognitionRequest() -- if the new recognizer fails to start, log and fall back to finishing the stream gracefully instead of silently dropping audio

### Task 2: Increase LLM maxTokens from 200 to 500
**File:** Lifehug/Services/LLMService.swift

200 tokens is too low for conversational responses. The LLM gets cut off mid-thought, producing incomplete sentences that the SentenceBuffer flushes as gibberish fragments.

- [x] Change `private let maxTokens = 200` to `private let maxTokens = 500` (line 23)
- [x] This is a one-line change but has the highest impact on response quality

### Task 3: Reduce voiceSpeed from 1.1 to 1.0
**File:** Lifehug/Services/KokoroManager.swift

Kokoro's speed parameter is a divisor for phoneme duration prediction. 1.1x compresses ALL durations by 10%, including pause durations at commas and periods. The recommended range per Kokoro docs is 0.95-1.05.

- [x] Change `voiceSpeed: 1.1` to `voiceSpeed: 1.0` in the synthesize() call in speak()

### Task 4: Batch 2-3 sentences per TTS call
**File:** Lifehug/Pipeline/VoicePipeline.swift

Kokoro has documented quality degradation on short utterances -- the prosody predictor needs 2-3 sentences for natural intonation. Currently each sentence is synthesized independently with no prosodic context.

- [x] In the consumer loop in processUserInput(), instead of speaking each sentence individually, accumulate 2-3 sentences (or ~50+ words) into a batch before calling ttsService.speak()
- [x] The last batch may be smaller -- that's fine, flush whatever remains
- [x] Example approach:
  ```swift
  var batch = ""
  var sentenceCount = 0
  for sentence in sentences {
      guard !Task.isCancelled else { break }
      batch += (batch.isEmpty ? "" : " ") + sentence
      sentenceCount += 1
      if sentenceCount >= 3 || batch.split(separator: " ").count >= 50 {
          state = .speaking
          await ttsService.speak(batch)
          guard !Task.isCancelled else { break }
          batch = ""
          sentenceCount = 0
      }
  }
  // Speak remaining batch
  if !batch.isEmpty && !Task.isCancelled {
      state = .speaking
      await ttsService.speak(batch)
  }
  ```

### Task 5: Set variantPreference to .fifteenSecond
**File:** Lifehug/Services/KokoroManager.swift

FluidAudio has 5-second and 15-second CoreML model variants. Without explicit preference, short sentences may route to the 5-second model which has less prosodic range. Forcing the 15-second model gives better quality, especially with batched sentences.

- [x] Add `variantPreference: .fifteenSecond` to the synthesize() call in speak():
  ```swift
  let audioData = try await unsafeManager.synthesize(
      text: text,
      voice: voice,
      voiceSpeed: 1.0,
      variantPreference: .fifteenSecond,
      deEss: true
  )
  ```

## Acceptance Criteria
- [x] STT chaining and error paths have diagnostic logging (visible in Console.app)
- [x] LLM responses are 2-4 sentences, not cut off mid-thought
- [x] TTS has natural pauses at commas and periods
- [x] TTS intonation sounds conversational, not robotic
- [x] Build succeeds with xcodebuild archive (Release, Swift 6 strict concurrency)
