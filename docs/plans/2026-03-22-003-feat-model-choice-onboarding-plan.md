---
title: "LLM model choice with device-aware onboarding"
type: feat
status: completed
date: 2026-03-22
deepened: 2026-03-22
---

# LLM Model Choice with Device-Aware Onboarding

## Enhancement Summary

**Deepened on:** 2026-03-22
**Research agents used:** SmolLM3 compatibility verifier, Architecture Strategist, Code Simplicity Reviewer

### Key Corrections from Deepening

1. **SmolLM3-3B-3bit confirmed compatible** with mlx-swift-lm. Architecture `smollm3` is registered, 3-bit quantization supported in Metal kernels, ChatML chat template works automatically.
2. **Collapsed 7 tasks to 4.** Dropped MemoryMonitor changes (runtime `os_proc_available_memory()` is already model-agnostic), dropped `canRunModel()` gating (Recommended badge is sufficient), folded Settings and ModelState changes into one-liners within existing tasks.
3. **Simplified default UX.** Auto-select recommended model and show a single Download button. The three-card picker is behind a "Change model" disclosure link — 90% of users just tap Download.
4. **Fixed stale `LLMService.modelID`** — was `static let` (captured once), must become dynamic to support model switching.
5. **`cleanChunk()` already handles SmolLM3.** The existing regex strips all `<|...|>` patterns, including `<|im_end|>`. No separate stop-token task needed — just verify during testing.
6. **No app restart for model switch.** Delete model + set `appState.activeScreen = .launch` from Settings navigates back to LaunchView in the same session.
7. **Replace "Not enough RAM"** with "Recommended for newer iPhones" or just the Recommended badge. Don't disable models — let users choose with informed descriptions.

---

## Overview

Replace the single hardcoded LLM (Llama 3.2 1B) with a choice of three models. The LaunchView download screen auto-selects the best option for the device with a "Change model" option for power users. Once downloaded, the picker doesn't show again unless the user deletes the model.

## Models

| ID | Label | HuggingFace ID | Disk | Runtime RAM | Best For |
|---|---|---|---|---|---|
| `llama-1b` | Llama 1B — Fast | `mlx-community/Llama-3.2-1B-Instruct-4bit` | 695 MB | ~800 MB | All devices, fastest responses |
| `smollm3-3b` | SmolLM3 3B — Balanced | `mlx-community/SmolLM3-3B-3bit` | 1.35 GB | ~1.6 GB | 6GB+ devices, good quality/size tradeoff |
| `llama-3b` | Llama 3B — Quality | `mlx-community/Llama-3.2-3B-Instruct-4bit` | 1.82 GB | ~2.0 GB | 8GB+ devices, best conversational quality |

**Compatibility confirmed:** All three models use architectures registered in mlx-swift-lm (`llama`, `smollm3`). 3-bit quantization is supported by MLX Metal kernels. Chat templates are handled automatically by swift-tokenizers.

## Device Recommendation Logic

```swift
let totalRAM = ProcessInfo.processInfo.physicalMemory
if totalRAM >= 8_000_000_000 { return .llama3B }
if totalRAM >= 6_000_000_000 { return .smollm3B }
return .llama1B
```

---

## Implementation

### Task 1: Define model catalog and update ModelConfig + ModelDownloader + LLMService

**Files:** `ModelConfig.swift`, `ModelDownloader.swift`, `LLMService.swift`, `ModelState.swift`

- [x] Replace `ModelConfig.LLM.modelID` with a `ModelOption` enum (three cases with `huggingFaceID`, `displayName`, `diskSizeMB`, `description` properties)
- [x] Add `selectedModel` static property persisted to UserDefaults (defaults to `recommendedModel`)
- [x] Add `recommendedModel` computed property based on device RAM
- [x] Keep `ModelConfig.LLM.modelID` as a computed property returning `selectedModel.huggingFaceID` for backward compatibility
- [x] In `ModelDownloader`: change `configuration` from `let` to computed `var` so it reads the current model ID dynamically
- [x] In `ModelDownloader`: update `checkDiskSpace()` to use `selectedModel.diskSizeMB`
- [x] In `ModelDownloader`: update `isModelCached` to check for the specific selected model directory (not just any `models--` prefix)
- [x] In `LLMService`: change `private static let modelID` (line 17) to read `ModelConfig.LLM.modelID` dynamically — the static let captures once and goes stale after model switch
- [x] In `ModelState.deleteModelCache()`: also clear the UserDefaults key so the picker re-appears
- [x] Existing `clearModelFiles()` already deletes the entire hub cache — no new delete method needed

### Task 2: Redesign LaunchView with model picker

**File:** `LaunchView.swift`

The default UX: auto-select the recommended model, show a single "Download" button with the model name and size. A "Change model" link reveals the full picker.

- [x] In the `.notDownloaded` case, replace the current single-button view with:
  - Title: "Lifehug runs entirely on your device"
  - Recommended model card (pre-selected): shows name, description, and download size
  - "Download [Model Name]" button (terracotta capsule, like existing)
  - Small "Change model" text button below that reveals the three-card picker
- [x] When "Change model" is tapped, expand to show all three model cards:
  - Each card: display name, description, download size
  - Recommended model has a "Recommended" badge
  - Radio-button style selection (no disabled state — let users choose any model)
  - "Download" button updates to show the selected model name
- [x] Track selection with `@State private var selectedModel`, initialized to `ModelConfig.LLM.recommendedModel`
- [x] On "Download" tap: persist `ModelConfig.LLM.selectedModel = selectedModel`, then `modelState.triggerDownload()`
- [x] In the `.downloading` state: show "Downloading [Model Name]..." with progress
- [x] In the `.error` state: keep "Try Again" button AND add "Choose a different model" link that returns to picker
- [x] `.loading` and `.ready` states remain the same

### Task 3: Add model info and "Change Model" to Settings

**File:** `SettingsView.swift`

- [x] In the Storage section, show the current model name (e.g., "AI Model: Llama 3B — Quality")
- [x] Change "Delete Model Cache" button to "Change AI Model"
- [x] On tap: show a confirmation alert — "This will delete [Model Name] ([size]) and require a new download. Continue?"
- [x] On confirm: call `modelState.deleteModelCache()` (which now also clears the UserDefaults key), then set `appState.activeScreen = .launch` to navigate back to LaunchView with the picker — no app restart needed

### Task 4: Verify SmolLM3 stop token handling

**File:** `LLMService.swift`

- [x] Verify that existing `cleanChunk()` strips SmolLM3's `<|im_end|>` and `<|endoftext|>` tokens (the current regex strips all `<|...|>` patterns — likely already works)
- [x] If not, add SmolLM3 stop tokens to the cleaning list
- [x] Test all three models produce clean, complete responses without trailing stop tokens

---

## Acceptance Criteria

### Functional
- [x] First launch: recommended model auto-selected, single "Download" button visible
- [x] "Change model" reveals three-card picker with Recommended badge
- [x] All three models download and load successfully
- [x] All three models produce coherent voice conversation responses
- [x] After download, subsequent launches skip directly to main app (no picker)
- [x] Settings shows current model name and "Change AI Model" button
- [x] "Change AI Model" deletes model and navigates to LaunchView picker (same session, no restart)
- [x] Model choice persists across app launches
- [x] Download failure shows "Try Again" + "Choose a different model"
- [x] Only one model on disk at a time (old model deleted before new download)

### Non-Functional
- [x] Picker UI matches Lifehug theme (cream/terracotta/walnut)
- [x] Build succeeds with `xcodebuild archive` (Release, Swift 6 strict concurrency)
- [x] No regression in voice conversation pipeline

---

## Sources & References

### Model Compatibility (verified)
- SmolLM3: `smollm3` architecture registered in `LLMModelFactory.swift`, 3-bit supported in Metal kernels, ChatML chat template
- Llama 3.2: `llama` architecture, 4-bit, standard Llama chat template
- All models auto-download from HuggingFace via `LLMModelFactory.shared.loadContainer()`

### Internal
- `Lifehug/Views/LaunchView.swift` — current `.notDownloaded` view (lines 70-120)
- `Lifehug/App/ModelConfig.swift` — single model ID (line 9)
- `Lifehug/Services/ModelDownloader.swift` — `clearModelFiles()` (line 198), `isModelCached` (line 52)
- `Lifehug/Services/LLMService.swift` — stale `static let modelID` (line 17), `cleanChunk()` (line 201)
- `Lifehug/App/ModelState.swift` — `deleteModelCache()` (line 74)
- [dev.to: Running LLMs on iPhone](https://dev.to/alichherawalla/how-to-run-llms-locally-on-your-iphone-in-2026-completely-offline-no-subscription-4b3a)
