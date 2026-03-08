import Foundation
import os

enum MemoryMonitor {
    private static let logger = Logger(subsystem: "com.lifehug.app", category: "Memory")

    enum Pressure: Comparable {
        case normal      // > 500MB available
        case elevated    // 300-500MB — degrade TTS to system
        case critical    // 150-300MB — unload Kokoro entirely
        case emergency   // < 150MB — unload everything possible
    }

    static var currentPressure: Pressure {
        let mb = availableMB
        switch mb {
        case 500...:
            return .normal
        case 300..<500:
            return .elevated
        case 150..<300:
            return .critical
        default:
            return .emergency
        }
    }

    static var availableMB: Int {
        Int(os_proc_available_memory() / 1_000_000)
    }

    /// Log current memory state at the specified level.
    static func logCurrentState() {
        let mb = availableMB
        let pressure = currentPressure
        switch pressure {
        case .normal:
            logger.info("Memory OK: \(mb)MB available")
        case .elevated:
            logger.warning("Memory elevated: \(mb)MB available — consider degrading TTS")
        case .critical:
            logger.error("Memory critical: \(mb)MB available — should unload Kokoro")
        case .emergency:
            logger.critical("Memory emergency: \(mb)MB available — risk of OS termination")
        }
    }

    /// Returns true if there is enough memory to safely load Kokoro TTS (~80MB).
    static var canLoadKokoro: Bool {
        currentPressure == .normal || currentPressure == .elevated
    }
}
