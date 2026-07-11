import AVFoundation
import Foundation
import os

/// Encodes captured 16kHz mono Float audio to AAC-LC `.m4a` clips and reads them back for
/// playback (U6) and re-transcription (U5). All encode/decode/chunking logic is
/// `nonisolated static` so it is unit-testable with synthesized buffers — no microphone,
/// no CoreML (KTD1). The store never places files itself: it encodes to a temp URL and the
/// caller routes the result through `StorageService.durablePlace`.
enum AudioClipStore {
    /// The capture source is 16kHz mono Float32 (WhisperKit's `audioSamples`) — no resample.
    static let sampleRate: Double = 16_000

    /// ~0.5s floor (matches `STTService.finalTranscriptionMinSamples`): a shorter turn is
    /// not worth a clip and would round-trip to near-silence.
    static let minimumSamples = 8_000

    /// Frames per PCM buffer handed to the encoder. A full 180s clip is ~2.88M frames and
    /// must not be written as a single buffer (KTD1); 1s chunks keep peak memory bounded.
    static let framesPerChunk = 16_000

    private static let logger = Logger(subsystem: "com.lifehug.app", category: "AudioClip")

    enum ClipError: Error, Equatable {
        case bufferTooShort(Int)
        case formatUnavailable
        case bufferAllocationFailed
        case encodeFailed(String)
        case decodeFailed(String)
    }

    // MARK: - Chunking (pure)

    /// Frame counts for the successive bounded writes covering `total` frames. Pure so the
    /// exact-multiple and remainder cases are directly testable.
    nonisolated static func chunkSizes(total: Int, chunk: Int) -> [Int] {
        guard total > 0, chunk > 0 else { return [] }
        var sizes: [Int] = []
        var remaining = total
        while remaining > 0 {
            let n = min(chunk, remaining)
            sizes.append(n)
            remaining -= n
        }
        return sizes
    }

    // MARK: - Encode

    /// Encode `samples` (16kHz mono Float) to an AAC-LC `.m4a` at `url`, writing in bounded
    /// chunks. Throws `bufferTooShort` for sub-floor input and leaves no partial file on
    /// failure. `url` should be a temp path; callers durably place the finished file.
    nonisolated static func encode(samples: [Float], to url: URL) throws {
        guard samples.count >= minimumSamples else { throw ClipError.bufferTooShort(samples.count) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        // AVAudioFile(forWriting:) will not truncate an existing file cleanly — start fresh.
        try? FileManager.default.removeItem(at: url)

        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            // Buffers must be in the file's processingFormat (deinterleaved Float32 at the
            // clip's sample rate/channels), which matches the 16kHz mono Float source (KTD1).
            let format = file.processingFormat
            try samples.withUnsafeBufferPointer { ptr in
                var offset = 0
                for count in chunkSizes(total: samples.count, chunk: framesPerChunk) {
                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: format,
                        frameCapacity: AVAudioFrameCount(count)
                    ), let channel = buffer.floatChannelData else {
                        throw ClipError.bufferAllocationFailed
                    }
                    buffer.frameLength = AVAudioFrameCount(count)
                    memcpy(channel[0], ptr.baseAddress! + offset, count * MemoryLayout<Float>.size)
                    try file.write(from: buffer)
                    offset += count
                }
            }
        } catch let error as ClipError {
            try? FileManager.default.removeItem(at: url)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ClipError.encodeFailed(error.localizedDescription)
        }
    }

    // MARK: - Decode

    /// Decode a clip to 16kHz mono Float samples (for re-transcription), reading in chunks.
    /// AAC is lossy and adds priming/padding, so the returned count differs slightly from
    /// the encoded input — callers compare durations with tolerance, never exactly.
    nonisolated static func decodeSamples(from url: URL) throws -> [Float] {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard file.length > 0 else { return [] }
            var samples: [Float] = []
            samples.reserveCapacity(Int(file.length))
            while file.framePosition < file.length {
                let remaining = AVAudioFrameCount(file.length - file.framePosition)
                let toRead = min(AVAudioFrameCount(framesPerChunk), remaining)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else {
                    throw ClipError.bufferAllocationFailed
                }
                try file.read(into: buffer, frameCount: toRead)
                let n = Int(buffer.frameLength)
                if n == 0 { break }
                if let channel = buffer.floatChannelData {
                    samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: n))
                }
            }
            return samples
        } catch let error as ClipError {
            throw error
        } catch {
            throw ClipError.decodeFailed(error.localizedDescription)
        }
    }

    /// Decoded duration in seconds, without materializing samples (playback/UI helper).
    nonisolated static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    // MARK: - Raw dump (capture durability point)

    /// The canonical raw-dump byte format (native-endian Float32). The capture path writes
    /// this through `StorageService.durableWrite` (fsync = the durability point, KTD2);
    /// `readRawDump` reads it back for recovery. Not an audio container.
    nonisolated static func rawDumpData(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Non-durable convenience writer over `rawDumpData` (tests / non-critical paths). The
    /// capture path uses `durableWrite` instead so the dump is fsync'd.
    nonisolated static func writeRawDump(_ samples: [Float], to url: URL) throws {
        try rawDumpData(samples).write(to: url)
    }

    /// Read a raw Float32 dump written by `writeRawDump`.
    nonisolated static func readRawDump(at url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(
                start: raw.baseAddress!.assumingMemoryBound(to: Float.self),
                count: count
            ))
        }
    }

    // MARK: - Existence / deletion

    nonisolated static func clipExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Delete a clip if present. Idempotent — a missing clip is not an error.
    nonisolated static func deleteClip(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
