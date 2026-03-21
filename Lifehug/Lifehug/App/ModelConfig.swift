import Foundation

/// Centralized configuration for all on-device model identifiers and download URLs.
/// Update values here when models are upgraded or URLs change.
enum ModelConfig {
    // MARK: - LLM (Llama 3.2 1B)

    enum LLM {
        static let modelID = "mlx-community/Llama-3.2-1B-Instruct-4bit"
    }

    // MARK: - TTS (Kokoro via FluidAudio)
    // Kokoro model download and management is handled by FluidAudio's TtsModels API.
    // Models are downloaded from HuggingFace (FluidInference/kokoro-82m-coreml) and
    // cached in the app's Caches directory. No manual URL or hash configuration needed.
}
