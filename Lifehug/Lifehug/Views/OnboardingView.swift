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

    private let creamBackground = Color(red: 251 / 255, green: 248 / 255, blue: 243 / 255)
    private let terracotta = Color(red: 198 / 255, green: 123 / 255, blue: 92 / 255)

    enum OnboardingStep: CaseIterable {
        case welcome
        case name
        case projectType
        case importantPeople
        case completion
    }

    var body: some View {
        ZStack {
            creamBackground.ignoresSafeArea()

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
                .padding(.horizontal, 32)

                Spacer()

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 8)
                }

                continueButton
                    .padding(.horizontal, 32)
                    .padding(.bottom, 48)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: step)
    }

    // MARK: - Step Content

    private var welcomeContent: some View {
        VStack(spacing: 24) {
            Text("Welcome to Lifehug")
                .font(.title.bold())
                .fontDesign(.serif)
                .multilineTextAlignment(.center)

            Text("Capture your life story through daily questions and voice conversations.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }

    private var nameContent: some View {
        VStack(spacing: 24) {
            Text("What should we call you?")
                .font(.title2.bold())
                .fontDesign(.serif)
                .multilineTextAlignment(.center)

            TextField("Your name", text: $userName)
                .font(.title3)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .autocorrectionDisabled()

            Text("Leave blank and we'll call you \"friend\"")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var projectTypeContent: some View {
        VStack(spacing: 24) {
            Text("What do you want to write?")
                .font(.title2.bold())
                .fontDesign(.serif)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                ForEach(OnboardingTemplates.projectTypes, id: \.self) { type in
                    Button {
                        selectedProjectType = type
                    } label: {
                        HStack {
                            Text(type)
                                .font(.body)
                                .foregroundStyle(selectedProjectType == type ? .white : .primary)
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
                            RoundedRectangle(cornerRadius: 16)
                                .fill(selectedProjectType == type ? terracotta : .white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
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
                .font(.title2.bold())
                .fontDesign(.serif)
                .multilineTextAlignment(.center)

            TextField("e.g. Mom, Uncle Ray, Coach Kim", text: $importantPeople, axis: .vertical)
                .font(.body)
                .lineLimit(3...5)
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .autocorrectionDisabled()

            Text("Comma-separated names. You can skip this for now.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var completionContent: some View {
        VStack(spacing: 24) {
            Text("You're all set!")
                .font(.title.bold())
                .fontDesign(.serif)
                .multilineTextAlignment(.center)

            Text("Let's start with your first question.")
                .font(.body)
                .foregroundStyle(.secondary)
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
                    .fill(terracotta)
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
        // Step 1: Create config
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

        // Step 2: Append template categories to question-bank.md
        try storage.copyBundledQuestionBankIfNeeded()

        var markdown = try storage.readQuestionBank()

        // Remove the placeholder project categories section
        let placeholderPattern = "## Project Categories\n\n*Categories F-J are added during setup based on your specific projects. The AI will generate these after learning what you want to write about.*"
        markdown = markdown.replacingOccurrences(of: placeholderPattern, with: "")

        // Generate and insert template sections before the Spotlights section
        let templateMarkdown = OnboardingTemplates.markdownSections(for: selectedProjectType)

        if let spotlightsRange = markdown.range(of: "## Spotlights") {
            markdown.insert(contentsOf: templateMarkdown + "\n\n", at: spotlightsRange.lowerBound)
        } else {
            // Append at end if no Spotlights section found
            markdown += "\n\n" + templateMarkdown + "\n"
        }

        // If there are important people, add a note in the spotlights section
        if !peopleList.isEmpty {
            let peopleNote = "\n\n*Pending spotlights: \(peopleList.joined(separator: ", "))*"
            markdown += peopleNote
        }

        try storage.writeQuestionBank(markdown)
        logger.info("Question bank updated with \(selectedProjectType) categories")

        // Step 3: Initialize rotation state
        let rotationState = RotationState()
        try storage.writeRotationState(rotationState)
        logger.info("Rotation state initialized")
    }
}

#Preview {
    OnboardingView()
        .environment(AppState())
}
