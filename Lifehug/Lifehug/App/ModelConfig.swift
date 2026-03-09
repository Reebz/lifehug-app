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

        /// SHA-256 hash for download integrity verification.
        /// Replace with actual hash after first successful download:
        ///   shasum -a 256 <file>
        static let modelSHA256 = "PLACEHOLDER_COMPUTE_ON_FIRST_DOWNLOAD"

        // This URL is a compile-time string constant guaranteed to be valid,
        // so force-unwrap is safe and intentional.
        static let modelDownloadURL = URL(string:
            "https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/main/kokoro-v1_0.safetensors"
        )!

        // voices.npz is bundled in the app — no download URL needed
    }
}
