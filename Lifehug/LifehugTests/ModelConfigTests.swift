import Testing
import Foundation
@testable import Lifehug

/// Serialized because every selection test mutates the shared UserDefaults key.
@Suite("ModelConfig", .serialized)
struct ModelConfigTests {

    private static let selectionKey = "llm_selected_model"

    /// Runs body with the stored selection saved and restored afterwards,
    /// so the suite never corrupts real app state.
    private func withSavedSelection(_ body: () throws -> Void) rethrows {
        let prior = UserDefaults.standard.string(forKey: Self.selectionKey)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: Self.selectionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectionKey)
            }
        }
        try body()
    }

    // MARK: - Legacy migration

    @Test("Legacy rawValues map to the same tier and rewrite the stored value", arguments: [
        ("llama-1b", ModelConfig.LLM.ModelOption.fast),
        ("smollm3-3b", ModelConfig.LLM.ModelOption.balanced),
        ("llama-3b", ModelConfig.LLM.ModelOption.quality),
    ])
    func legacyRawValueMigrates(legacy: String, expected: ModelConfig.LLM.ModelOption) {
        withSavedSelection {
            UserDefaults.standard.set(legacy, forKey: Self.selectionKey)

            #expect(ModelConfig.LLM.selectedModel == expected)
            #expect(UserDefaults.standard.string(forKey: Self.selectionKey) == expected.rawValue)
        }
    }

    @Test("Unknown stored string falls back to recommendedModel")
    func unknownStringFallsBack() {
        withSavedSelection {
            UserDefaults.standard.set("not-a-model", forKey: Self.selectionKey)

            #expect(ModelConfig.LLM.selectedModel == ModelConfig.LLM.recommendedModel)
        }
    }

    @Test("New rawValues round-trip through selectedModel", arguments: ModelConfig.LLM.ModelOption.allCases)
    func selectionRoundTrip(option: ModelConfig.LLM.ModelOption) {
        withSavedSelection {
            ModelConfig.LLM.selectedModel = option

            #expect(ModelConfig.LLM.selectedModel == option)
            #expect(UserDefaults.standard.string(forKey: Self.selectionKey) == option.rawValue)
        }
    }

    // MARK: - Model metadata

    @Test("huggingFaceID returns the verified repo per tier")
    func huggingFaceIDs() {
        #expect(ModelConfig.LLM.ModelOption.fast.huggingFaceID == "mlx-community/gemma-3-1b-it-qat-4bit")
        #expect(ModelConfig.LLM.ModelOption.balanced.huggingFaceID == "mlx-community/SmolLM3-3B-4bit")
        #expect(ModelConfig.LLM.ModelOption.quality.huggingFaceID == "mlx-community/gemma-3-text-4b-it-4bit")
    }

    @Test("diskSizeMB and download label match the verified sizes")
    func diskSizes() {
        #expect(ModelConfig.LLM.ModelOption.fast.diskSizeMB == 771)
        #expect(ModelConfig.LLM.ModelOption.balanced.diskSizeMB == 1747)
        #expect(ModelConfig.LLM.ModelOption.quality.diskSizeMB == 2599)
        #expect(ModelConfig.LLM.ModelOption.quality.downloadSizeLabel == "2.6 GB download")
        #expect(ModelConfig.LLM.ModelOption.fast.downloadSizeLabel == "771 MB download")
    }

    @Test("RAM gates are monotonic across tiers")
    func ramGatesMonotonic() {
        let fast = ModelConfig.LLM.ModelOption.fast
        let balanced = ModelConfig.LLM.ModelOption.balanced
        let quality = ModelConfig.LLM.ModelOption.quality

        #expect(fast.minimumRAM <= balanced.minimumRAM)
        #expect(balanced.minimumRAM <= quality.minimumRAM)
        #expect(fast.recommendedRAM <= balanced.recommendedRAM)
        #expect(balanced.recommendedRAM <= quality.recommendedRAM)
    }
}
