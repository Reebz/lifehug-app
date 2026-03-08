import Foundation

/// Centralized configuration for all on-device model identifiers and download URLs.
/// Update values here when models are upgraded or URLs change.
enum ModelConfig {
    // MARK: - LLM (Llama 3.2 1B)

    enum LLM {
        static let modelID = "mlx-community/Llama-3.2-1B-Instruct-4bit"
    }

    // MARK: - TTS (Kokoro)

    enum Kokoro {
        static let modelFileName = "kokoro-v1_0.safetensors"
        static let voicesFileName = "voices.npz"

        static let modelDownloadURL = URL(string:
            "https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/main/kokoro-v1_0.safetensors"
        )!

        static let voicesDownloadURL = URL(string:
            "https://media.githubusercontent.com/media/mlalma/KokoroTestApp/main/Resources/voices.npz"
        )!
    }
}
