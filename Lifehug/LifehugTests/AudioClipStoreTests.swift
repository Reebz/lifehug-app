import Testing
import AVFoundation
import Foundation
@testable import Lifehug

@Suite("AudioClipStore")
struct AudioClipStoreTests {

    private func sine(seconds: Double, freq: Double = 220, rate: Double = 16_000) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            Float(0.25 * sin(2.0 * Double.pi * freq * Double(i) / rate))
        }
    }

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acs-\(UUID().uuidString).\(ext)")
    }

    // MARK: - Chunking (pure)

    @Test("Chunk sizes cover exact multiples")
    func chunkExactMultiple() {
        #expect(AudioClipStore.chunkSizes(total: 48_000, chunk: 16_000) == [16_000, 16_000, 16_000])
    }

    @Test("Chunk sizes cover a remainder")
    func chunkRemainder() {
        #expect(AudioClipStore.chunkSizes(total: 40_000, chunk: 16_000) == [16_000, 16_000, 8_000])
    }

    @Test("Chunk sizes handle small and degenerate inputs")
    func chunkEdgeCases() {
        #expect(AudioClipStore.chunkSizes(total: 5, chunk: 16_000) == [5])
        #expect(AudioClipStore.chunkSizes(total: 0, chunk: 16_000) == [])
        #expect(AudioClipStore.chunkSizes(total: 100, chunk: 0) == [])
    }

    // MARK: - Encode / decode round-trip

    @Test("Encode then decode preserves duration within tolerance")
    func encodeDecodeDuration() throws {
        let url = tempURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = sine(seconds: 5)

        try AudioClipStore.encode(samples: samples, to: url)
        #expect(AudioClipStore.clipExists(at: url))

        let duration = try #require(AudioClipStore.duration(of: url))
        #expect(abs(duration - 5.0) < 0.3)  // AAC priming/padding drift

        let decoded = try AudioClipStore.decodeSamples(from: url)
        let decodedSeconds = Double(decoded.count) / AudioClipStore.sampleRate
        #expect(abs(decodedSeconds - 5.0) < 0.3)
    }

    @Test("Below-floor buffer is rejected without writing a file")
    func shortBufferRejected() {
        let url = tempURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let tooShort = sine(seconds: 0.2)  // 3200 samples < 8000 floor

        #expect(throws: AudioClipStore.ClipError.self) {
            try AudioClipStore.encode(samples: tooShort, to: url)
        }
        #expect(!AudioClipStore.clipExists(at: url))
    }

    @Test("Encode to an unwritable directory throws and leaves no partial file")
    func encodeBadDirectoryThrows() {
        let badDir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/clip.m4a")
        #expect(throws: (any Error).self) {
            try AudioClipStore.encode(samples: sine(seconds: 5), to: badDir)
        }
        #expect(!FileManager.default.fileExists(atPath: badDir.path))
    }

    // MARK: - Raw dump

    @Test("Raw dump round-trips exact samples")
    func rawDumpRoundtrip() throws {
        let url = tempURL("raw")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = sine(seconds: 1)

        try AudioClipStore.writeRawDump(samples, to: url)
        let read = try AudioClipStore.readRawDump(at: url)

        #expect(read.count == samples.count)
        #expect(read.first == samples.first)
        #expect(read.last == samples.last)
    }

    // MARK: - Deletion

    @Test("Delete is idempotent")
    func deleteIdempotent() throws {
        let url = tempURL("m4a")
        try AudioClipStore.encode(samples: sine(seconds: 5), to: url)
        #expect(AudioClipStore.clipExists(at: url))
        try AudioClipStore.deleteClip(at: url)
        #expect(!AudioClipStore.clipExists(at: url))
        try AudioClipStore.deleteClip(at: url)  // no throw on missing
    }
}
