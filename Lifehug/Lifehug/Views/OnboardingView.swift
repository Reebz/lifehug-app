import SwiftUI
import os

struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    @State private var step: OnboardingStep = .welcome
    @State private var userName: String = ""
    @State private var selectedProjectType: String = "Memoir"
    @State private var importantPeople: String = ""
    @State private var isProcessing: Bool = false
    @State private var errorMessage: String?

    private let storage = StorageService()
    private let logger = Logger(subsystem: "com.lifehug.app", category: "Onboarding")

    enum OnboardingStep: CaseIterable {
        case welcome
        case name
        case projectType
        case importantPeople
        case completion
    }

    var body: some View {
        ZStack {
            Theme.cream.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Group {
                    switch step {
                    case .welcome:
                        welcomeContent
                    case .name:
                        nameContent
                    case .projectType:
                        projectTypeContent
                    case .importantPeople:
                        importantPeopleContent
                    case .completion:
                        completionContent
                    }
                }
                .padding(.horizontal, Theme.horizontalPadding + 8)

                Spacer()

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedRose)
                        .padding(.horizontal, Theme.horizontalPadding + 8)
                        .padding(.bottom, 8)
                }

                continueButton
                    .padding(.horizontal, Theme.horizontalPadding + 8)
                    .padding(.bottom, 48)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: step)
    }

    // MARK: - Step Content

    private var welcomeContent: some View {
        VStack(spacing: 24) {
            Text("Welcome to Lifehug")
                .font(Theme.titleFont)
                .fontWeight(.bold)
                .foregroundStyle(Theme.walnut)
                .multilineTextAlignment(.center)

            Text("Capture your life story through daily questions and voice conversations.")
                .font(Theme.bodySerifFont)
                .foregroundStyle(Theme.warmGray)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }

    private var nameContent: some View {
        VStack(spacing: 24) {
            Text("What should we call you?")
                .font(Theme.title2Font)
                .fontWeight(.bold)
                .foregroundStyle(Theme.walnut)
                .multilineTextAlignment(.center)

            TextField("Your name", text: $userName)
                .font(.title3)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .fill(Theme.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .autocorrectionDisabled()

            Text("Leave blank and we'll call you \"friend\"")
                .font(.caption)
                .foregroundStyle(Theme.softGray)
        }
    }

    private var projectTypeContent: some View {
        VStack(spacing: 24) {
            Text("What do you want to write?")
                .font(Theme.title2Font)
                .fontWeight(.bold)
                .foregroundStyle(Theme.walnut)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                ForEach(OnboardingTemplates.projectTypes, id: \.self) { type in
                    Button {
                        selectedProjectType = type
                    } label: {
                        HStack {
                            Text(type)
                                .font(Theme.bodySerifFont)
                                .foregroundStyle(selectedProjectType == type ? .white : Theme.warmCharcoal)
                            Spacer()
                            if selectedProjectType == type {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.white)
                                    .fontWeight(.semibold)
                            }
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 20)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                .fill(selectedProjectType == type ? Theme.terracotta : Theme.cardBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                .stroke(
                                    selectedProjectType == type ? Color.clear : Color.gray.opacity(0.2),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var importantPeopleContent: some View {
        VStack(spacing: 24) {
            Text("Who are important people in your story?")
                .font(Theme.title2Font)
                .fontWeight(.bold)
                .foregroundStyle(Theme.walnut)
                .multilineTextAlignment(.center)

            TextField("e.g. Mom, Uncle Ray, Coach Kim", text: $importantPeople, axis: .vertical)
                .font(.body)
                .lineLimit(3...5)
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .fill(Theme.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .autocorrectionDisabled()

            Text("Comma-separated names. You can skip this for now.")
                .font(.caption)
                .foregroundStyle(Theme.softGray)
                .multilineTextAlignment(.center)
        }
    }

    private var completionContent: some View {
        VStack(spacing: 24) {
            Text("You're all set!")
                .font(Theme.titleFont)
                .fontWeight(.bold)
                .foregroundStyle(Theme.walnut)
                .multilineTextAlignment(.center)

            Text("Let's start with your first question.")
                .font(Theme.bodySerifFont)
                .foregroundStyle(Theme.warmGray)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }

    // MARK: - Continue Button

    private var continueButton: some View {
        Button {
            handleContinue()
        } label: {
            Group {
                if isProcessing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(step == .completion ? "Start Writing" : "Continue")
                        .font(.headline)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Theme.terracotta)
            )
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
    }

    // MARK: - Navigation

    private func handleContinue() {
        errorMessage = nil

        switch step {
        case .welcome:
            step = .name
        case .name:
            step = .projectType
        case .projectType:
            step = .importantPeople
        case .importantPeople:
            step = .completion
        case .completion:
            completeOnboarding()
        }
    }

    // MARK: - Completion

    private func completeOnboarding() {
        isProcessing = true
        do {
            try finalizeOnboarding()
            appState.completeOnboarding()
            appState.activeScreen = .dailyQuestion
        } catch {
            logger.error("Onboarding failed: \(error.localizedDescription)")
            errorMessage = "Something went wrong. Please try again."
            isProcessing = false
        }
    }

    private func finalizeOnboarding() throws {
        let resolvedName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = resolvedName.isEmpty ? "friend" : resolvedName

        let peopleList = importantPeople
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var config = UserConfig()
        config.name = finalName
        config.projects = [
            UserConfig.Project(name: selectedProjectType, type: selectedProjectType)
        ]

        try storage.writeConfig(config)
        logger.info("Config saved: name=\(finalName), project=\(selectedProjectType)")

        try storage.copyBundledQuestionBankIfNeeded()

        var markdown = try storage.readQuestionBank()

        let placeholderPattern = "## Project Categories\n\n*Categories F-J are added during setup based on your specific projects. The AI will generate these after learning what you want to write about.*"
        markdown = markdown.replacingOccurrences(of: placeholderPattern, with: "")

        let templateMarkdown = OnboardingTemplates.markdownSections(for: selectedProjectType)

        if let spotlightsRange = markdown.range(of: "## Spotlights") {
            markdown.insert(contentsOf: templateMarkdown + "\n\n", at: spotlightsRange.lowerBound)
        } else {
            markdown += "\n\n" + templateMarkdown + "\n"
        }

        if !peopleList.isEmpty {
            let peopleNote = "\n\n*Pending spotlights: \(peopleList.joined(separator: ", "))*"
            markdown += peopleNote
        }

        try storage.writeQuestionBank(markdown)
        logger.info("Question bank updated with \(selectedProjectType) categories")

        let rotationState = RotationState()
        try storage.writeRotationState(rotationState)
        logger.info("Rotation state initialized")
    }
}

#Preview {
    OnboardingView()
        .environment(AppState())
}
