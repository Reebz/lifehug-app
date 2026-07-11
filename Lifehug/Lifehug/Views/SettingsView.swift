import SwiftUI
import UserNotifications
import os

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ModelState.self) private var modelState
    @Environment(KokoroManager.self) private var kokoroManager

    @State private var userName: String = ""
    @State private var kokoroEnabled: Bool = KokoroManager.isEnabled
    @State private var selectedVoice: String = KokoroManager.selectedVoice
    @State private var reminderEnabled: Bool = false
    @State private var reminderTime: Date = defaultReminderTime()
    @State private var notificationDenied: Bool = false
    @State private var iCloudBackupEnabled: Bool = StorageService.iCloudBackupEnabled
    @State private var silenceTimeout: Double = StorageService.silenceTimeout
    @State private var showDeleteModelConfirmation = false
    @State private var showResetConfirmation = false
    @State private var showExportAlert = false
    @State private var exportAlertMessage = ""
    @State private var modelSizeMB: String = "---"
    @State private var storageSizeMB: String = "---"
    @State private var clipStorageMB: String = "---"
    @State private var orphanClipCount: Int = 0

    private let storage = StorageService()
    private let logger = Logger(subsystem: "com.lifehug.app", category: "Settings")

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                notificationsSection
                privacySection
                kokoroSection
                voiceSection
                modelSection
                dataSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.cream.ignoresSafeArea())
            .navigationTitle("Settings")
            .modifier(LifehugBarStyle())
            .task {
                loadSettings()
                computeStorageSizes()
            }
            .confirmationDialog(
                "Change AI Model",
                isPresented: $showDeleteModelConfirmation,
                titleVisibility: .visible
            ) {
                Button("Change Model", role: .destructive) { changeModel() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete \(ModelConfig.LLM.selectedModel.displayName) and take you back to the model picker. You'll need to download a new model.")
            }
            .confirmationDialog(
                "Reset Lifehug",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset Everything", role: .destructive) { resetApp() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all your answers, settings, and model data. This action cannot be undone.")
            }
            .alert("Export", isPresented: $showExportAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportAlertMessage)
            }
        }
    }

    // MARK: - Profile Section

    private var profileSection: some View {
        Section {
            HStack {
                Text("Name")
                    .foregroundStyle(Theme.warmCharcoal)
                Spacer()
                TextField("Your name", text: $userName)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Theme.warmCharcoal)
                    .onChange(of: userName) { _, newValue in
                        if newValue.count > 100 {
                            userName = String(newValue.prefix(100))
                        }
                    }
                    .onSubmit { saveName() }
            }
            .listRowBackground(Color.white)
        } header: {
            Text("Profile")
                .font(Theme.subheadlineSerifFont)
                .foregroundStyle(Theme.warmCharcoal)
        }
    }

    // MARK: - Notifications Section

    private var notificationsSection: some View {
        Section {
            Toggle(isOn: $reminderEnabled) {
                Text("Daily Reminder")
                    .foregroundStyle(Theme.warmCharcoal)
            }
            .tint(Theme.terracotta)
            .onChange(of: reminderEnabled) { _, enabled in
                if enabled {
                    requestNotificationPermission()
                } else {
                    NotificationService.cancelDailyReminder()
                }
            }
            .listRowBackground(Color.white)

            if reminderEnabled {
                DatePicker(
                    "Reminder Time",
                    selection: $reminderTime,
                    displayedComponents: .hourAndMinute
                )
                .foregroundStyle(Theme.warmCharcoal)
                .onChange(of: reminderTime) { _, newTime in
                    NotificationService.scheduleDailyReminder(at: newTime)
                }
                .listRowBackground(Color.white)
            }

            if notificationDenied {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.mutedRose)
                    Text("Notifications are disabled. Please enable them in Settings to receive daily reminders.")
                        .font(.caption)
                        .foregroundStyle(Theme.walnut)
                }
                .listRowBackground(Color.white)
            }
        } header: {
            Text("Reminders")
                .font(Theme.subheadlineSerifFont)
                .foregroundStyle(Theme.warmCharcoal)
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        Section {
            Toggle(isOn: $iCloudBackupEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Backup")
                        .foregroundStyle(Theme.warmCharcoal)
                    Text("Include answers in iCloud backups")
                        .font(.caption)
                        .foregroundStyle(Theme.walnut)
                }
            }
            .tint(Theme.terracotta)
            .onChange(of: iCloudBackupEnabled) { _, enabled in
                StorageService.iCloudBackupEnabled = enabled
                try? storage.setupDirectories()
            }
            .listRowBackground(Color.white)
        } header: {
            Text("Privacy")
                .font(Theme.subheadlineSerifFont)
                .foregroundStyle(Theme.warmCharcoal)
        }
    }

    // MARK: - Kokoro Natural Voice Section

    private var kokoroSection: some View {
        Section {
            Toggle(isOn: $kokoroEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Natural Voice")
                        .foregroundStyle(Theme.warmCharcoal)
                    Text("On-device neural TTS (~160 MB download)")
                        .font(.caption)
                        .foregroundStyle(Theme.walnut)
                }
            }
            .tint(Theme.terracotta)
            .onChange(of: kokoroEnabled) { _, enabled in
                KokoroManager.isEnabled = enabled
                if enabled && !kokoroManager.isModelDownloaded {
                    kokoroManager.downloadModel()
                } else if enabled && kokoroManager.isModelDownloaded {
                    Task { await kokoroManager.loadEngine() }
                } else if !enabled {
                    kokoroManager.unloadEngine()
                }
            }
            .listRowBackground(Color.white)

            if kokoroManager.phase == .downloading {
                HStack {
                    Text("Downloading...")
                        .foregroundStyle(Theme.walnut)
                    Spacer()
                    ProgressView(value: kokoroManager.downloadProgress)
                        .frame(width: 120)
                        .tint(Theme.terracotta)
                }
                .listRowBackground(Color.white)

                Button(role: .destructive) {
                    kokoroManager.cancelDownload()
                    kokoroEnabled = false
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Cancel Download")
                    }
                    .foregroundStyle(Theme.mutedRose)
                }
                .listRowBackground(Color.white)
            }

            if kokoroManager.phase == .compiling || kokoroManager.phase == .loading {
                HStack {
                    Text(kokoroManager.statusMessage ?? "Loading voice model...")
                        .foregroundStyle(Theme.walnut)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.terracotta)
                }
                .listRowBackground(Color.white)
            }

            if kokoroManager.isReady {
                Picker("Voice", selection: $selectedVoice) {
                    ForEach(curatedVoices, id: \.self) { voice in
                        Text(voiceDisplayName(voice)).tag(voice)
                    }
                }
                .foregroundStyle(Theme.warmCharcoal)
                .onChange(of: selectedVoice) { _, newVoice in
                    KokoroManager.selectedVoice = newVoice
                }
                .listRowBackground(Color.white)
            }

            if kokoroManager.phase == .failed {
                Button {
                    kokoroManager.downloadModel()
                    kokoroEnabled = true
                    KokoroManager.isEnabled = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry Download")
                    }
                    .foregroundStyle(Theme.terracotta)
                }
                .listRowBackground(Color.white)

                Button(role: .destructive) {
                    kokoroManager.deleteModel()
                    kokoroEnabled = false
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete Partial Files")
                    }
                    .foregroundStyle(Theme.mutedRose)
                }
                .listRowBackground(Color.white)
            }

            if kokoroManager.isModelDownloaded {
                Button {
                    kokoroManager.deleteModel()
                    kokoroEnabled = false
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete Voice Model")
                    }
                    .foregroundStyle(Theme.mutedRose)
                }
                .listRowBackground(Color.white)
            }

            if let error = kokoroManager.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.mutedRose)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.walnut)
                }
                .listRowBackground(Color.white)
            }
        } header: {
            Text("Natural Voice (Kokoro)")
                .font(Theme.subheadlineSerifFont)
                .foregroundStyle(Theme.warmCharcoal)
        }
    }

    /// Curated subset: 3 female + 3 male voices for simplicity
    private static let preferredVoiceIDs: [String] = [
        "af_heart", "af_nova", "af_sky",
        "am_adam", "am_michael", "am_echo"
    ]

    private var curatedVoices: [String] {
        let available = kokoroManager.availableVoices
        let curated = Self.preferredVoiceIDs.filter { available.contains($0) }
        // If none of the preferred voices exist, fall back to first 6
        return curated.isEmpty ? Array(available.prefix(6)) : curated
    }

    /// Format voice ID (e.g., "af_heart") into a display name ("Heart — US Female").
    private func voiceDisplayName(_ voiceID: String) -> String {
        let parts = voiceID.split(separator: "_")
        guard parts.count >= 2 else { return voiceID.capitalized }
        let prefix = String(parts[0])  // "af", "am", "bf", "bm"
        let name = String(parts[1]).capitalized

        // Second character: f = female, m = male
        let gender = prefix.hasSuffix("f") ? "Female" : "Male"
        // First character: a = American, b = British
        let accent = prefix.hasPrefix("a") ? "US" : "UK"

        return "\(name) — \(accent) \(gender)"
    }

    // MARK: - Voice Section

    private static let timeoutOptions: [(String, Double)] = [
        ("Off", 0), ("3s", 3), ("5s", 5), ("10s", 10), ("15s", 15)
    ]

    private var voiceSection: some View {
        Section {
            Picker("Silence Timeout", selection: $silenceTimeout) {
                ForEach(Self.timeoutOptions, id: \.1) { label, value in
                    Text(label).tag(value)
                }
            }
            .foregroundStyle(Theme.warmCharcoal)
            .onChange(of: silenceTimeout) { _, newValue in
                StorageService.silenceTimeout = newValue
            }
            .listRowBackground(Color.white)
        } header: {
            Text("Voice")
                .font(Theme.subheadlineSerifFont)
                .foregroundStyle(Theme.warmCharcoal)
        }
    }

    // MARK: - Model Section

    private var modelSection: some View {
        Section {
            HStack {
                Text("AI Model")
                    .foregroundStyle(Theme.warmCharcoal)
                Spacer()
                Text(ModelConfig.LLM.selectedModel.displayName)
                    .foregroundStyle(Theme.walnut)
            }
            .listRowBackground(Color.white)

            HStack {
                Text("Model Status")
                    .foregroundStyle(Theme.warmCharcoal)
                Spacer()
                Text(modelStatusText)
                    .foregroundStyle(Theme.walnut)
            }
            .listRowBackground(Color.white)

            HStack {
                Text("Model Size")
                    .foregroundStyle(Theme.warmCharcoal)
                Spacer()
                Text(modelSizeMB)
                    .foregroundStyle(Theme.walnut)
            }
            .listRowBackground(Color.white)

            HStack {
                Text("Answers Storage")
                    .foregroundStyle(Theme.warmCharcoal)
                Spacer()
                Text(storageSizeMB)
                    .foregroundStyle(Theme.walnut)
            }
            .listRowBackground(Color.white)

            HStack {
                Text("Voice Recordings")
                    .foregroundStyle(Theme.warmCharcoal)
                Spacer()
                Text(clipStorageMB)
                    .foregroundStyle(Theme.walnut)
            }
            .listRowBackground(Color.white)

            if orphanClipCount > 0 {
                HStack {
                    Text("Unlinked Recordings")
                        .foregroundStyle(Theme.warmCharcoal)
                    Spacer()
                    Text("\(orphanClipCount)")
                        .foregroundStyle(Theme.walnut)
                }
                .listRowBackground(Color.white)
            }

            if case .notDownloaded = modelState.status {
                Button {
                    modelState.triggerDownload()
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text("Re-download Model")
                    }
                    .foregroundStyle(Theme.terracotta)
                }
                .listRowBackground(Color.white)
            }

            Button {
                showDeleteModelConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Change AI Model")
                }
                .foregroundStyle(Theme.terracotta)
            }
            .listRowBackground(Color.white)
        } header: {
            Text("Storage")
                .font(Theme.subheadlineSerifFont)
                .foregroundStyle(Theme.warmCharcoal)
        }
    }

    // MARK: - Data Section

    private var dataSection: some View {
        Section {
            Button {
                exportAnswers()
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export Answers")
                }
                .foregroundStyle(Theme.terracotta)
            }
            .listRowBackground(Color.white)

            Button {
                showResetConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset Lifehug")
                }
                .foregroundStyle(Theme.mutedRose)
            }
            .listRowBackground(Color.white)
        } header: {
            Text("Data")
                .font(Theme.subheadlineSerifFont)
                .foregroundStyle(Theme.warmCharcoal)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .foregroundStyle(Theme.warmCharcoal)
                Spacer()
                Text(appVersion)
                    .foregroundStyle(Theme.walnut)
            }
            .listRowBackground(Color.white)
        } header: {
            Text("About")
                .font(Theme.subheadlineSerifFont)
                .foregroundStyle(Theme.warmCharcoal)
        }
    }

    // MARK: - Computed Properties

    private var modelStatusText: String {
        switch modelState.status {
        case .notDownloaded: "Not Downloaded"
        case .downloading: "Downloading..."
        case .loading: "Loading..."
        case .ready: "Ready"
        case .error(let msg): "Error: \(msg)"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - Actions

    private func loadSettings() {
        let config = storage.readConfig()
        userName = config.name
    }

    private func saveName() {
        do {
            var config = storage.readConfig()
            config.name = userName
            try storage.writeConfig(config)
        } catch {
            // Save failed
        }
    }

    private func requestNotificationPermission() {
        Task {
            let granted = await NotificationService.requestPermissionAsync()
            if granted {
                NotificationService.scheduleDailyReminder(at: reminderTime)
                notificationDenied = false
            } else {
                reminderEnabled = false
                notificationDenied = true
            }
        }
    }

    private func computeStorageSizes() {
        modelSizeMB = Self.formattedDirectorySize(storage.modelsDirectory)
        storageSizeMB = Self.formattedDirectorySize(storage.answersDirectory)

        // Clip size + orphan count off the main actor (U8) — the clips directory can grow
        // large, and an on-main allocated-size enumeration would hitch the settings screen.
        let clipsDir = storage.clipsDirectory
        Task {
            let (size, orphans) = await Task.detached {
                (Self.formattedDirectorySize(clipsDir), StorageService().clipStorageReport().orphanedClips)
            }.value
            clipStorageMB = size
            orphanClipCount = orphans
        }
    }

    /// Allocated on-disk size of a directory tree, formatted. `nonisolated static` so it can
    /// run off the main actor (U8).
    nonisolated static func formattedDirectorySize(_ url: URL) -> String {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else {
            return "0 MB"
        }
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            if let allocated = values?.totalFileAllocatedSize {
                totalSize += Int64(allocated)
            } else if let size = values?.fileSize {
                totalSize += Int64(size)
            }
        }
        let mb = Double(totalSize) / (1024 * 1024)
        if mb < 0.1 {
            let kb = Double(totalSize) / 1024
            return String(format: "%.0f KB", kb)
        }
        return String(format: "%.1f MB", mb)
    }

    private func deleteModelCache() {
        modelState.deleteModelCache()
        computeStorageSizes()
    }

    private func changeModel() {
        modelState.deleteModelCache()
        computeStorageSizes()
        // Navigate back to LaunchView to show the model picker
        appState.activeScreen = .launch
    }

    private func exportAnswers() {
        do {
            let answerFiles = try storage.listAnswerFiles()
            guard !answerFiles.isEmpty else {
                exportAlertMessage = "No answers to export yet."
                showExportAlert = true
                return
            }

            // Share the individual markdown files
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            guard let window = scene?.windows.first,
                  let rootVC = window.rootViewController else {
                exportAlertMessage = "Unable to present the share sheet. Please try again."
                showExportAlert = true
                return
            }

            let activityVC = UIActivityViewController(
                activityItems: answerFiles,
                applicationActivities: nil
            )

            // iPad popover anchor
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }

            rootVC.present(activityVC, animated: true)
        } catch {
            logger.error("Export failed: \(error)")
            exportAlertMessage = "Export failed. Please try again."
            showExportAlert = true
        }
    }

    private func resetApp() {
        let fm = FileManager.default

        // Delete answers
        if let files = try? fm.contentsOfDirectory(at: storage.answersDirectory, includingPropertiesForKeys: nil) {
            for file in files { try? fm.removeItem(at: file) }
        }

        // Delete voice recordings, staging, and the transcription retry queue
        if let clips = try? fm.contentsOfDirectory(at: storage.clipsDirectory, includingPropertiesForKeys: nil) {
            for file in clips { try? fm.removeItem(at: file) }
        }
        try? fm.removeItem(at: storage.clipsStagingDirectory)
        try? fm.removeItem(at: TranscriptionRetryStore(storage: storage).queueURL)

        // Delete config
        try? fm.removeItem(at: storage.configURL)

        // Delete question bank (will be re-copied on next launch)
        try? fm.removeItem(at: storage.questionBankURL)

        // Delete rotation state
        try? fm.removeItem(at: storage.rotationURL)

        // Delete model caches (LLM + Kokoro TTS)
        deleteModelCache()
        kokoroManager.deleteModel()

        // Cancel notifications
        NotificationService.cancelDailyReminder()

        // Re-trigger onboarding
        appState.resetOnboarding()
        appState.activeScreen = .launch
    }

    private static func defaultReminderTime() -> Date {
        var components = DateComponents()
        components.hour = 9
        components.minute = 0
        return Calendar.current.date(from: components) ?? Date()
    }
}

// MARK: - Notification Service

enum NotificationService {
    private static let dailyReminderID = "com.lifehug.dailyReminder"

    static func requestPermissionAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    static func scheduleDailyReminder(at time: Date) {
        let center = UNUserNotificationCenter.current()

        // Remove existing
        center.removePendingNotificationRequests(withIdentifiers: [dailyReminderID])

        let content = UNMutableNotificationContent()
        content.title = "Lifehug"
        content.body = "Your daily question is ready"
        content.sound = .default

        let calendar = Calendar.current
        var dateComponents = DateComponents()
        dateComponents.hour = calendar.component(.hour, from: time)
        dateComponents.minute = calendar.component(.minute, from: time)

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: dailyReminderID, content: content, trigger: trigger)

        center.add(request)
    }

    static func cancelDailyReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [dailyReminderID])
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
        .environment(ModelState())
        .environment(KokoroManager())
}
