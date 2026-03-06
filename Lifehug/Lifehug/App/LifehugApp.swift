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

    var body: some View {
        Text("Lifehug")
            .font(.largeTitle)
            .fontDesign(.serif)
    }
}
