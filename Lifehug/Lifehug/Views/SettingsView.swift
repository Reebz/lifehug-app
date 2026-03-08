import SwiftUI
import UserNotifications

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
    @State private var showDeleteModelConfirmation = false
    @State private var showResetConfirmation = false
    @State private var showExportAlert = false
    @State private var exportAlertMessage = ""
    @State private var modelSizeMB: String = "---"
    @State private var storageSizeMB: String = "---"

    private let storage = StorageService()

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                notificationsSection
                privacySection
                kokoroSection
                modelSection
                dataSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.cream.ignoresSafeArea())
            .navigationTitle("Settings")
            .task {
                loadSettings()
                computeStorageSizes()
            }
            .confirmationDialog(
                "Delete Model Cache",
                isPresented: $showDeleteModelConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteModelCache() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove the downloaded model. You will need to re-download it to continue using Lifehug.")
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
                    .onSubmit { saveName() }
                    .onChange(of: userName) { _, _ in saveName() }
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
                    Text("On-device neural TTS (~175 MB download)")
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
            }

            if kokoroManager.phase == .loading {
                HStack {
                    Text("Loading voice model...")
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
                    ForEach(kokoroManager.availableVoices, id: \.self) { voice in
                        Text(voiceDisplayName(voice)).tag(voice)
                    }
                }
                .foregroundStyle(Theme.warmCharcoal)
                .onChange(of: selectedVoice) { _, newVoice in
                    KokoroManager.selectedVoice = newVoice
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

    private func voiceDisplayName(_ voiceID: String) -> String {
        let parts = voiceID.split(separator: "_")
        guard parts.count >= 2 else { return voiceID }
        let prefix = String(parts[0])
        let name = String(parts[1]).capitalized

        let gender: String
        if prefix.hasPrefix("a") { gender = "Female" }
        else if prefix.hasPrefix("b") { gender = "Male" }
        else { gender = "" }

        let accent = prefix.contains("f") ? "US" : "UK"

        if gender.isEmpty {
            return "\(name) (\(accent))"
        }
        return "\(name) (\(accent) \(gender))"
    }

    // MARK: - Model Section

    private var modelSection: some View {
        Section {
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
                    Image(systemName: "trash")
                    Text("Delete Model Cache")
                }
                .foregroundStyle(Theme.mutedRose)
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
        do {
            let config = try storage.readConfig()
            userName = config.name
        } catch {
            userName = "friend"
        }
    }

    private func saveName() {
        do {
            var config = try storage.readConfig()
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
        // Model size
        let modelsDir = storage.modelsDirectory
        modelSizeMB = formattedDirectorySize(modelsDir)

        // Answers size
        let answersDir = storage.answersDirectory
        storageSizeMB = formattedDirectorySize(answersDir)
    }

    private func formattedDirectorySize(_ url: URL) -> String {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return "0 MB"
        }
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
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
            exportAlertMessage = "Export failed: \(error.localizedDescription)"
            showExportAlert = true
        }
    }

    private func resetApp() {
        let fm = FileManager.default

        // Delete answers
        if let files = try? fm.contentsOfDirectory(at: storage.answersDirectory, includingPropertiesForKeys: nil) {
            for file in files { try? fm.removeItem(at: file) }
        }

        // Delete config
        try? fm.removeItem(at: storage.configURL)

        // Delete question bank (will be re-copied on next launch)
        try? fm.removeItem(at: storage.questionBankURL)

        // Delete rotation state
        try? fm.removeItem(at: storage.rotationURL)

        // Delete model cache
        deleteModelCache()

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

    static func requestPermission(completion: @escaping @Sendable (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    /// Async wrapper that avoids @Sendable closure issues with @State property mutation.
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
