import SwiftUI
import os

@main
struct LifehugApp: App {
    @State private var appState = AppState()
    @State private var modelState = ModelState()
    @State private var sessionState = SessionState()
    @State private var llmService = LLMService()
    @State private var sttService = STTService()
    @State private var ttsService = TTSService()
    @State private var kokoroManager = KokoroManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Check for crash breadcrumb from previous session
        let breadcrumbURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pipeline-breadcrumb.txt")
        if let breadcrumb = try? String(contentsOf: breadcrumbURL, encoding: .utf8) {
            let logger = Logger(subsystem: "com.lifehug.app", category: "CrashDetection")
            logger.error("⚠️ PREVIOUS SESSION CRASH DETECTED — last breadcrumb: \(breadcrumb)")
            // Clean up so we don't re-report
            try? FileManager.default.removeItem(at: breadcrumbURL)
        }

        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(Theme.terracotta)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor(Theme.walnut)], for: .normal)

        // Tab bar — opaque cream to prevent iOS 26 liquid glass flickering
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor(Theme.cream)
        // CRITICAL: Set BOTH to prevent black/clear flickering on scroll transitions
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(modelState)
                .environment(sessionState)
                .environment(llmService)
                .environment(sttService)
                .environment(ttsService)
                .environment(kokoroManager)
                .task {
                    ttsService.setKokoroManager(kokoroManager)
                    // DIAGNOSTIC: Skip Kokoro model loading entirely to free ~80MB RAM.
                    // This tests whether the crash is caused by memory pressure.
                    // if KokoroManager.isEnabled && kokoroManager.isModelDownloaded {
                    //     await kokoroManager.loadEngine()
                    // }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    modelState.handleScenePhaseChange(newPhase)
                    switch newPhase {
                    case .background:
                        sessionState.flushAutoSave()
                        ttsService.stop()
                        kokoroManager.unloadEngine()
                        llmService.unloadModel()
                    case .active:
                        Task {
                            // Reload LLM if it was previously loaded
                            if !llmService.isLoaded {
                                try? await llmService.loadModel()
                            }
                            // DIAGNOSTIC: Skip Kokoro reload to test memory hypothesis
                            // if KokoroManager.isEnabled && kokoroManager.isModelDownloaded {
                            //     ttsService.forceDegradedToSystem = false
                            //     if !kokoroManager.isReady {
                            //         await kokoroManager.loadEngine()
                            //     }
                            // }
                        }
                    default:
                        break
                    }
                }
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: Int = 0

    var body: some View {
        ZStack {
            Theme.cream
                .ignoresSafeArea()

            switch appState.activeScreen {
            case .launch:
                LaunchView()
            case .onboarding:
                OnboardingView()
            default:
                TabView(selection: $selectedTab) {
                    Tab("Today", systemImage: "quote.bubble.fill", value: 0) {
                        DailyQuestionView()
                    }

                    Tab("Coverage", systemImage: "chart.bar.fill", value: 1) {
                        CoverageView(selectedTab: $selectedTab)
                    }

                    Tab("Answers", systemImage: "book.fill", value: 2) {
                        AnswersBrowserView()
                    }

                    Tab("Settings", systemImage: "gearshape.fill", value: 3) {
                        SettingsView()
                    }
                }
                .tint(Theme.terracotta)
            }
        }
        .preferredColorScheme(.light)
    }
}

struct LifehugBarStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackground(Theme.cream, for: .navigationBar)
            .toolbarBackground(Theme.cream, for: .tabBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbarColorScheme(.light, for: .tabBar)
    }
}
