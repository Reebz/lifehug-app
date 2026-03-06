import SwiftUI

@main
struct LifehugApp: App {
    @State private var appState = AppState()
    @State private var modelState = ModelState()
    @State private var sessionState = SessionState()
    @State private var llmService = LLMService()
    @State private var sttService = STTService()
    @State private var ttsService = TTSService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(modelState)
                .environment(sessionState)
                .environment(llmService)
                .environment(sttService)
                .environment(ttsService)
                .onChange(of: scenePhase) { _, newPhase in
                    modelState.handleScenePhaseChange(newPhase)
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
                    Tab("Today", systemImage: "sun.max.fill", value: 0) {
                        DailyQuestionView()
                    }

                    Tab("Coverage", systemImage: "chart.bar.fill", value: 1) {
                        CoverageView()
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
    }
}
