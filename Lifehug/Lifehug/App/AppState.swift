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

    init() {
        isOnboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
    }

    func completeOnboarding() {
        isOnboardingComplete = true
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
    }

    func resetOnboarding() {
        isOnboardingComplete = false
        UserDefaults.standard.set(false, forKey: "onboardingComplete")
    }
}
