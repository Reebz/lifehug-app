import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ModelState.self) private var modelState

    @State private var userName: String = ""
    @State private var reminderEnabled: Bool = false
    @State private var reminderTime: Date = defaultReminderTime()
    @State private var notificationDenied: Bool = false
    @State private var showDeleteModelConfirmation = false
    @State private var showResetConfirmation = false
    @State private var modelSizeMB: String = "---"
    @State private var storageSizeMB: String = "---"

    private let storage = StorageService()

    // MARK: - Colors

    private let creamBackground = Color(red: 0xFB / 255, green: 0xF8 / 255, blue: 0xF3 / 255)
    private let warmCharcoal = Color(red: 0x2C / 255, green: 0x24 / 255, blue: 0x20 / 255)
    private let warmGray = Color(red: 0x6B / 255, green: 0x5E / 255, blue: 0x54 / 255)
    private let terracotta = Color(red: 0xC6 / 255, green: 0x7B / 255, blue: 0x5C / 255)
    private let mutedRose = Color(red: 0xC4 / 255, green: 0x70 / 255, blue: 0x70 / 255)

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                notificationsSection
                modelSection
                dataSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(creamBackground.ignoresSafeArea())
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
        }
    }

    // MARK: - Profile Section

    private var profileSection: some View {
        Section {
            HStack {
                Text("Name")
                    .foregroundStyle(warmCharcoal)
                Spacer()
                TextField("Your name", text: $userName)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(warmCharcoal)
                    .onSubmit { saveName() }
                    .onChange(of: userName) { _, _ in saveName() }
            }
            .listRowBackground(Color.white)
        } header: {
            Text("Profile")
                .font(.subheadline)
                .fontDesign(.serif)
                .foregroundStyle(warmCharcoal)
        }
    }

    // MARK: - Notifications Section

    private var notificationsSection: some View {
        Section {
            Toggle(isOn: $reminderEnabled) {
                Text("Daily Reminder")
                    .foregroundStyle(warmCharcoal)
            }
            .tint(terracotta)
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
                .foregroundStyle(warmCharcoal)
                .onChange(of: reminderTime) { _, newTime in
                    NotificationService.scheduleDailyReminder(at: newTime)
                }
                .listRowBackground(Color.white)
            }

            if notificationDenied {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(mutedRose)
                    Text("Notifications are disabled. Please enable them in Settings to receive daily reminders.")
                        .font(.caption)
                        .foregroundStyle(warmGray)
                }
                .listRowBackground(Color.white)
            }
        } header: {
            Text("Reminders")
                .font(.subheadline)
                .fontDesign(.serif)
                .foregroundStyle(warmCharcoal)
        }
    }

    // MARK: - Model Section

    private var modelSection: some View {
        Section {
            HStack {
                Text("Model Status")
                    .foregroundStyle(warmCharcoal)
                Spacer()
                Text(modelStatusText)
                    .foregroundStyle(warmGray)
            }
            .listRowBackground(Color.white)

            HStack {
                Text("Model Size")
                    .foregroundStyle(warmCharcoal)
                Spacer()
                Text(modelSizeMB)
                    .foregroundStyle(warmGray)
            }
            .listRowBackground(Color.white)

            HStack {
                Text("Answers Storage")
                    .foregroundStyle(warmCharcoal)
                Spacer()
                Text(storageSizeMB)
                    .foregroundStyle(warmGray)
            }
            .listRowBackground(Color.white)

            Button {
                showDeleteModelConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Delete Model Cache")
                }
                .foregroundStyle(mutedRose)
            }
            .listRowBackground(Color.white)
        } header: {
            Text("Storage")
                .font(.subheadline)
                .fontDesign(.serif)
                .foregroundStyle(warmCharcoal)
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
                .foregroundStyle(terracotta)
            }
            .listRowBackground(Color.white)

            Button {
                showResetConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset Lifehug")
                }
                .foregroundStyle(mutedRose)
            }
            .listRowBackground(Color.white)
        } header: {
            Text("Data")
                .font(.subheadline)
                .fontDesign(.serif)
                .foregroundStyle(warmCharcoal)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .foregroundStyle(warmCharcoal)
                Spacer()
                Text(appVersion)
                    .foregroundStyle(warmGray)
            }
            .listRowBackground(Color.white)
        } header: {
            Text("About")
                .font(.subheadline)
                .fontDesign(.serif)
                .foregroundStyle(warmCharcoal)
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
        NotificationService.requestPermission { granted in
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
        let modelsDir = storage.modelsDirectory
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil) {
            for file in contents {
                try? fm.removeItem(at: file)
            }
        }
        computeStorageSizes()
    }

    private func exportAnswers() {
        do {
            let answerFiles = try storage.listAnswerFiles()
            guard !answerFiles.isEmpty else { return }

            // Share the individual markdown files
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            guard let window = scene?.windows.first,
                  let rootVC = window.rootViewController else { return }

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
            // Export failed
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
}
