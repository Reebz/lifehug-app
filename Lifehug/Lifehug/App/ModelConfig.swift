import Foundation

/// Centralized configuration for all on-device model identifiers and download URLs.
enum ModelConfig {
    // MARK: - LLM

    enum LLM {
        /// Available LLM models the user can choose from.
        enum ModelOption: String, CaseIterable, Codable, Sendable {
            case llama1B = "llama-1b"
            case smollm3B = "smollm3-3b"
            case llama3B = "llama-3b"

            var huggingFaceID: String {
                switch self {
                case .llama1B: "mlx-community/Llama-3.2-1B-Instruct-4bit"
                case .smollm3B: "mlx-community/SmolLM3-3B-3bit"
                case .llama3B: "mlx-community/Llama-3.2-3B-Instruct-4bit"
                }
            }

            var displayName: String {
                switch self {
                case .llama1B: "Llama 1B — Fast"
                case .smollm3B: "SmolLM3 3B — Balanced"
                case .llama3B: "Llama 3B — Quality"
                }
            }

            var diskSizeMB: Int {
                switch self {
                case .llama1B: 700
                case .smollm3B: 1350
                case .llama3B: 1820
                }
            }

            var description: String {
                switch self {
                case .llama1B: "Fastest responses, works on all devices"
                case .smollm3B: "Better quality, fits most modern iPhones"
                case .llama3B: "Best conversational quality, recommended for newer iPhones"
                }
            }

            /// Formatted download size string for UI display.
            var downloadSizeLabel: String {
                if diskSizeMB >= 1000 {
                    return String(format: "%.1f GB download", Double(diskSizeMB) / 1000)
                }
                return "\(diskSizeMB) MB download"
            }

            /// Minimum RAM in bytes to run this model (with Kokoro TTS alongside).
            var minimumRAM: UInt64 {
                switch self {
                case .llama1B: 4_000_000_000   // 4 GB — runs on anything
                case .smollm3B: 6_000_000_000  // 6 GB — needs iPhone 15+
                case .llama3B: 8_000_000_000   // 8 GB — needs iPhone 15 Pro+
                }
            }

            /// Recommended minimum RAM — below this the model runs but may be tight.
            var recommendedRAM: UInt64 {
                switch self {
                case .llama1B: 4_000_000_000
                case .smollm3B: 7_000_000_000  // Tight on 6 GB
                case .llama3B: 8_000_000_000
                }
            }

            /// Device fitness for this model.
            enum Fitness { case good, caution, incompatible }

            var deviceFitness: Fitness {
                let ram = ProcessInfo.processInfo.physicalMemory
                if ram < minimumRAM { return .incompatible }
                if ram < recommendedRAM { return .caution }
                return .good
            }

            /// Short label for the download button (e.g., "Fast", "Balanced", "Quality").
            var shortLabel: String {
                switch self {
                case .llama1B: "Fast"
                case .smollm3B: "Balanced"
                case .llama3B: "Quality"
                }
            }
        }

        /// The user's selected model, persisted to UserDefaults.
        static var selectedModel: ModelOption {
            get {
                guard let raw = UserDefaults.standard.string(forKey: "llm_selected_model"),
                      let option = ModelOption(rawValue: raw) else {
                    return recommendedModel
                }
                return option
            }
            set {
                UserDefaults.standard.set(newValue.rawValue, forKey: "llm_selected_model")
            }
        }

        /// Whether a model has been explicitly selected (vs. defaulting to recommended).
        static var hasSelectedModel: Bool {
            UserDefaults.standard.string(forKey: "llm_selected_model") != nil
        }

        /// Clear the selection so the picker re-appears.
        static func clearSelection() {
            UserDefaults.standard.removeObject(forKey: "llm_selected_model")
        }

        /// Device-aware recommendation based on total RAM.
        static var recommendedModel: ModelOption {
            let totalRAM = ProcessInfo.processInfo.physicalMemory
            if totalRAM >= 8_000_000_000 { return .llama3B }
            if totalRAM >= 6_000_000_000 { return .smollm3B }
            return .llama1B
        }

        /// The HuggingFace model ID for the currently selected model.
        /// Used by ModelDownloader and LLMService — reads dynamically, not captured once.
        static var modelID: String { selectedModel.huggingFaceID }
    }

    // MARK: - TTS (Kokoro via FluidAudio)
    // Kokoro model download and management is handled by FluidAudio's TtsModels API.
    // Models are downloaded from HuggingFace (FluidInference/kokoro-82m-coreml) and
    // cached in the app's Caches directory. No manual URL or hash configuration needed.
}
