import Foundation
import os

final class StorageService {
    private let logger = Logger(subsystem: "com.lifehug.app", category: "Storage")
    private let fileManager = FileManager.default

    // MARK: - Directory Paths

    /// Application Support — models and state (not visible in Files app)
    var appSupportDirectory: URL {
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Documents — user content (visible in Files app)
    var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    var modelsDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("models", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var stateDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("system", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var answersDirectory: URL {
        let url = documentsDirectory.appendingPathComponent("answers", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var questionBankURL: URL {
        documentsDirectory.appendingPathComponent("question-bank.md")
    }

    var rotationURL: URL {
        stateDirectory.appendingPathComponent("rotation.json")
    }

    var configURL: URL {
        documentsDirectory.appendingPathComponent("config.json")
    }

    // MARK: - Setup

    func setupDirectories() throws {
        // Create directories
        let dirs = [modelsDirectory, stateDirectory, answersDirectory]
        for dir in dirs {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // NSFileProtectionComplete on user data directories
        let protectedPaths = [
            answersDirectory.path,
            questionBankURL.deletingLastPathComponent().path,
            configURL.deletingLastPathComponent().path,
            stateDirectory.path,
        ]
        for path in protectedPaths {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: path
            )
        }

        // Exclude models from iCloud backup
        var modelsURL = modelsDirectory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try modelsURL.setResourceValues(resourceValues)

        logger.info("Storage directories configured")
    }

    // MARK: - First Launch

    func copyBundledQuestionBankIfNeeded() throws {
        guard !fileManager.fileExists(atPath: questionBankURL.path) else { return }
        guard let bundledURL = Bundle.main.url(forResource: "question-bank", withExtension: "md") else {
            logger.error("Bundled question-bank.md not found")
            return
        }
        try fileManager.copyItem(at: bundledURL, to: questionBankURL)
        logger.info("Copied bundled question-bank.md to Documents")
    }

    // MARK: - Question Bank I/O

    func readQuestionBank() throws -> String {
        try String(contentsOf: questionBankURL, encoding: .utf8)
    }

    func writeQuestionBank(_ content: String) throws {
        try atomicWrite(content: content, to: questionBankURL)
    }

    // MARK: - Rotation State I/O

    func readRotationState() throws -> RotationState {
        guard fileManager.fileExists(atPath: rotationURL.path) else {
            return .default
        }
        let data = try Data(contentsOf: rotationURL)
        return try JSONDecoder().decode(RotationState.self, from: data)
    }

    func writeRotationState(_ state: RotationState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try atomicWrite(data: data, to: rotationURL)
    }

    // MARK: - Config I/O

    func readConfig() throws -> UserConfig {
        guard fileManager.fileExists(atPath: configURL.path) else {
            return UserConfig()
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(UserConfig.self, from: data)
    }

    func writeConfig(_ config: UserConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try atomicWrite(data: data, to: configURL)
    }

    // MARK: - Answer File I/O

    func saveAnswer(_ answer: Answer) throws {
        let filename = "\(answer.questionID).md"
        let url = answersDirectory.appendingPathComponent(filename)
        let content = answer.toMarkdown()
        try atomicWrite(content: content, to: url)
        logger.info("Saved answer for \(answer.questionID)")
    }

    func listAnswerFiles() throws -> [URL] {
        let contents = try fileManager.contentsOfDirectory(
            at: answersDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func readAnswer(at url: URL) throws -> Answer? {
        let content = try String(contentsOf: url, encoding: .utf8)
        return Answer.fromMarkdown(content)
    }

    // MARK: - Atomic Write

    private func atomicWrite(content: String, to url: URL) throws {
        guard let data = content.data(using: .utf8) else {
            throw StorageError.encodingFailed
        }
        try atomicWrite(data: data, to: url)
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: tempURL, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: url)
        }
    }
}

enum StorageError: Error {
    case encodingFailed
    case fileNotFound(String)
}
