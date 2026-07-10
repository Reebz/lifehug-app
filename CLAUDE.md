# Lifehug — iOS Development

Native iOS client for Lifehug. Swift 6, iOS 18+, SwiftUI.

**For runtime AI assistant behavior in deployed Lifehug instances, see `AGENTS.md`.** This file covers iOS development of the Swift app only.

## Architecture

- **Target:** iOS 18+ (Swift 6 strict concurrency)
- **UI:** SwiftUI with `@Observable` (not Combine/@Published)
- **On-device ML:** Kokoro TTS (FluidAudio, CoreML), 3 user-selectable MLX LLM tiers — Gemma 3 1B QAT / SmolLM3 3B / Gemma 3 4B text, all 4-bit, RAM-tiered default (see Lifehug/Lifehug/App/ModelConfig.swift), WhisperKit small.en (STT)
- **Pipeline:** STT → LLM → TTS orchestrated by `VoicePipeline` with `PipelineState` enum (.idle/.listening/.processing/.speaking)
- **Key services:** StorageService (file I/O), RotationEngine (question selection), QuestionBankParser (markdown parsing)
- **Audio session:** owned app-side by `AudioSessionController` (single `setCategory`/`setActive` caller), sequenced around WhisperKit's internal reconfigure

> Note: `docs/solutions/ios-audio-pipeline/mlx-kokoro-crash-and-apple-stt-cutoff.md` still describes the superseded FluidAudio **Parakeet** STT approach; STT is now **WhisperKit** and TTS is **FluidAudio CoreML Kokoro**. A full solutions refresh is separate follow-up work.

## Build & Test

```bash
# Build & test (use explicit project — multiple .xcodeproj exist; run from nested Lifehug/)
cd Lifehug
xcodebuild build -project Lifehug.xcodeproj -scheme Lifehug -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -project Lifehug.xcodeproj -scheme Lifehug -destination 'platform=iOS Simulator,name=iPhone 17'

# Archive for TestFlight
xcodebuild archive -project Lifehug.xcodeproj -scheme Lifehug -archivePath /tmp/Lifehug.xcarchive -destination 'generic/platform=iOS' -allowProvisioningUpdates

# Upload to TestFlight (requires ExportOptions.plist with method=app-store-connect, teamID=PJHS9XQS6H)
xcodebuild -exportArchive -archivePath /tmp/Lifehug.xcarchive -exportOptionsPlist /tmp/ExportOptions.plist -allowProvisioningUpdates
```

## Release Workflow

1. Bump `CURRENT_PROJECT_VERSION` in both Release and Debug configs in `Lifehug.xcodeproj/project.pbxproj`
2. Archive, then export with upload (commands above)
3. Commit: `chore: Bump build number to N for TestFlight`

## Known Issues

- Release builds have stricter Swift 6 concurrency checking than Debug — always verify with archive before shipping
- Non-Sendable Apple framework types (AVAudioPlayerNode, AVAudioPCMBuffer, AVSpeechUtterance) crossing `@Sendable`/`sending` boundaries require `nonisolated(unsafe)` wrappers
- STTService's `nonisolated(unsafe) sharedRequest` is intentional — DO NOT add locks to the audio render thread (causes glitches/priority inversion)
- Task group `addTask` closures are `sending` — cannot capture MainActor-isolated self even with `@MainActor` annotation
