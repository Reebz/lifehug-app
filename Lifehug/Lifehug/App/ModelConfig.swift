import Foundation

/// Centralized configuration for all on-device model identifiers and download URLs.
enum ModelConfig {
    // MARK: - LLM

    enum LLM {
        /// Available LLM models the user can choose from.
        /// Cases are tier-named (not model-named) so a future model swap
        /// doesn't invalidate persisted selections again.
        enum ModelOption: String, CaseIterable, Codable, Sendable {
            case fast = "fast"
            case balanced = "balanced"
            case quality = "quality"

            var huggingFaceID: String {
                switch self {
                case .fast: "mlx-community/gemma-3-1b-it-qat-4bit"
                case .balanced: "mlx-community/SmolLM3-3B-4bit"
                case .quality: "mlx-community/gemma-3-text-4b-it-4bit"
                }
            }

            var displayName: String {
                switch self {
                case .fast: "Gemma 1B — Fast"
                case .balanced: "SmolLM3 3B — Balanced"
                case .quality: "Gemma 4B — Quality"
                }
            }

            var diskSizeMB: Int {
                switch self {
                case .fast: 771
                case .balanced: 1747
                case .quality: 2599
                }
            }

            var description: String {
                switch self {
                case .fast: "Fastest responses, works on all devices"
                case .balanced: "Better quality, fits most modern iPhones"
                case .quality: "Best conversational quality, recommended for newer iPhones"
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
                case .fast: 4_000_000_000      // 4 GB — runs on anything
                case .balanced: 6_000_000_000  // 6 GB — needs iPhone 15+
                case .quality: 8_000_000_000   // 8 GB — needs iPhone 15 Pro+
                }
            }

            /// Recommended minimum RAM — below this the model runs but may be tight.
            var recommendedRAM: UInt64 {
                switch self {
                case .fast: 4_000_000_000
                case .balanced: 7_000_000_000  // Tight on 6 GB
                case .quality: 8_000_000_000
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
                case .fast: "Fast"
                case .balanced: "Balanced"
                case .quality: "Quality"
                }
            }
        }

        /// Pre-rename persisted rawValues (model-named) mapped to their tier.
        private static let legacyRawValueMapping: [String: ModelOption] = [
            "llama-1b": .fast,
            "smollm3-3b": .balanced,
            "llama-3b": .quality,
        ]

        /// The user's selected model, persisted to UserDefaults.
        static var selectedModel: ModelOption {
            get {
                guard let raw = UserDefaults.standard.string(forKey: "llm_selected_model") else {
                    return recommendedModel
                }
                if let option = ModelOption(rawValue: raw) {
                    return option
                }
                // Legacy model-named rawValue — map to the same tier and rewrite
                // the stored value so this migration fires only once.
                if let migrated = legacyRawValueMapping[raw] {
                    UserDefaults.standard.set(migrated.rawValue, forKey: "llm_selected_model")
                    return migrated
                }
                return recommendedModel
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
            if totalRAM >= 8_000_000_000 { return .quality }
            if totalRAM >= 6_000_000_000 { return .balanced }
            return .fast
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
