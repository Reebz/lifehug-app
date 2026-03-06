import SwiftUI

@main
struct LifehugApp: App {
    @State private var appState = AppState()
    @State private var modelState = ModelState()
    @State private var sessionState = SessionState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(modelState)
                .environment(sessionState)
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: Int = 0

    private let terracotta = Color(hex: UInt(0xC67B5C))

    var body: some View {
        if appState.isOnboardingComplete {
            TabView(selection: $selectedTab) {
                Tab("Today", systemImage: "sun.max.fill", value: 0) {
                    DailyQuestionView()
                }

                Tab("Coverage", systemImage: "chart.bar.fill", value: 1) {
                    PlaceholderTabView(title: "Coverage", icon: "chart.bar.fill")
                }

                Tab("Answers", systemImage: "book.fill", value: 2) {
                    PlaceholderTabView(title: "Answers", icon: "book.fill")
                }

                Tab("Settings", systemImage: "gearshape.fill", value: 3) {
                    PlaceholderTabView(title: "Settings", icon: "gearshape.fill")
                }
            }
            .tint(terracotta)
        } else {
            OnboardingView()
        }
    }
}

/// Placeholder view for tabs not yet implemented by other agents.
struct PlaceholderTabView: View {
    let title: String
    let icon: String

    private let cream = Color(hex: UInt(0xFBF8F3))
    private let warmGray = Color(hex: UInt(0x6B5E54))

    var body: some View {
        ZStack {
            cream.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundStyle(warmGray.opacity(0.4))
                Text(title)
                    .font(.title2)
                    .fontDesign(.serif)
                    .foregroundStyle(warmGray)
                Text("Coming soon")
                    .font(.subheadline)
                    .foregroundStyle(warmGray.opacity(0.6))
            }
        }
    }
}
