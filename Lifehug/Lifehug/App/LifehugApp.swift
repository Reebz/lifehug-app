import SwiftUI

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
                    // Single-owner LLM container: LLMService borrows ModelState's
                    // container instead of loading its own (U7 / R6).
                    llmService.configureContainerProvider(
                        get: { modelState.modelContainer },
                        load: { await modelState.ensureModelLoaded() }
                    )
                    kokoroManager.cleanupLegacyFilesIfNeeded()
                    // Load ASR and Kokoro in parallel — neither blocks the other.
                    let shouldLoadKokoro = KokoroManager.isEnabled && kokoroManager.isModelDownloaded
                    async let asrLoad: () = sttService.loadASRModel()
                    async let kokoroLoad: () = {
                        if shouldLoadKokoro {
                            await kokoroManager.loadEngine()
                        }
                    }()
                    _ = await (asrLoad, kokoroLoad)

                    // Launch maintenance: assert clip/answer directory protection, reconcile
                    // orphaned clip storage (U7), then rebuild and drain the empty-transcript
                    // retry queue once ASR is ready (U5). Off the UI-critical path.
                    let storage = StorageService()
                    try? storage.setupDirectories()
                    storage.reconcileClipStorage(protectingStagingSession: sessionState.recordingSessionID.uuidString)
                    let retryCoordinator = TranscriptionRetryCoordinator(storage: storage, stt: sttService)
                    retryCoordinator.syncFromAnswers()
                    await retryCoordinator.drainPending()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    modelState.handleScenePhaseChange(newPhase)
                    switch newPhase {
                    case .background:
                        sessionState.flushAutoSave()
                        // Release the mic on background — UIBackgroundModes=[audio]
                        // otherwise keeps the recorder hot (privacy/battery), and a
                        // stale recorder can linger on return (U12).
                        sttService.stopListening()
                        ttsService.stop()
                        kokoroManager.unloadEngine()
                        llmService.unloadModel()
                    case .active:
                        // Drop the cached system voice so a newly-installed/higher-quality
                        // voice is picked up (system-voice quality only, U12).
                        ttsService.invalidateVoiceCache()
                        Task {
                            // LLM reload is driven in exactly one place — ModelState's
                            // scene handler above (single-owner: no separate LLMService
                            // load path, U7). The LLM session rematerializes lazily on
                            // first use once the shared container is back.
                            // Retry ASR load if it never succeeded (no-op if ready/in flight).
                            if !sttService.isASRReady {
                                await sttService.loadASRModel()
                            }
                            if KokoroManager.isEnabled && kokoroManager.isModelDownloaded {
                                ttsService.forceDegradedToSystem = false
                                if !kokoroManager.isReady {
                                    await kokoroManager.loadEngine()
                                }
                            }
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
