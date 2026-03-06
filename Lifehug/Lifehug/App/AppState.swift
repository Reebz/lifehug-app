import SwiftUI

@Observable
@MainActor
final class AppState {
    var isOnboardingComplete: Bool = false
    var activeScreen: ActiveScreen = .launch

    enum ActiveScreen {
        case launch
        case onboarding
        case dailyQuestion
        case conversation
        case coverage
        case answersBrowser
        case settings
    }
}
