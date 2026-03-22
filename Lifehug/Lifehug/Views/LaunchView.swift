import SwiftUI

struct LaunchView: View {
    @Environment(ModelState.self) private var modelState
    @Environment(AppState.self) private var appState

    @State private var selectedModel: ModelConfig.LLM.ModelOption = ModelConfig.LLM.recommendedModel
    @State private var showModelPicker = false

    var body: some View {
        ZStack {
            Theme.cream
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                headerSection

                Spacer()

                statusSection

                Spacer()
                    .frame(height: 40)
            }
            .padding(.horizontal, Theme.horizontalPadding + 8)
        }
        .task {
            await modelState.prepareOnLaunch()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Text("Lifehug")
                .font(Theme.displayFont)
                .foregroundStyle(Theme.walnut)

            Text("Thoughtful questions for a\nmore examined life")
                .font(Theme.bodySerifFont)
                .foregroundStyle(Theme.walnut)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        switch modelState.status {
        case .notDownloaded:
            needsDownloadView

        case .downloading:
            downloadingView

        case .loading:
            loadingView

        case .ready:
            readyView

        case .error(let message):
            errorView(message: message)
        }
    }

    // MARK: - Model Selection + Download

    private var needsDownloadView: some View {
        VStack(spacing: 20) {
            Text("Lifehug runs entirely on your device.\nChoose an AI model to download.")
                .font(.subheadline)
                .foregroundStyle(Theme.walnut)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            if showModelPicker {
                // Expanded picker — three model cards
                VStack(spacing: 12) {
                    ForEach(ModelConfig.LLM.ModelOption.allCases, id: \.self) { option in
                        ModelPickerCard(
                            option: option,
                            isSelected: selectedModel == option,
                            isRecommended: option == ModelConfig.LLM.recommendedModel
                        )
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.2)) {
                                selectedModel = option
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                // Collapsed — show recommended model card only
                ModelPickerCard(
                    option: selectedModel,
                    isSelected: true,
                    isRecommended: true
                )
            }

            // Download button
            Button {
                ModelConfig.LLM.selectedModel = selectedModel
                modelState.triggerDownload()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                    Text("Download \(selectedModel.displayName)")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.terracotta, in: RoundedRectangle(cornerRadius: Theme.buttonCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download \(selectedModel.displayName), \(selectedModel.downloadSizeLabel)")

            // Change model link
            if !showModelPicker {
                Button {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showModelPicker = true
                    }
                } label: {
                    Text("Change model")
                        .font(.caption)
                        .foregroundStyle(Theme.terracotta)
                }
            }
        }
    }

    // MARK: - Downloading

    private var downloadingView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                ProgressView(value: modelState.downloadProgress)
                    .tint(Theme.terracotta)
                    .scaleEffect(y: 2)
                    .clipShape(Capsule())

                HStack {
                    Text(progressLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.walnut)
                        .monospacedDigit()

                    Spacer()

                    Text("\(Int(modelState.downloadProgress * 100))%")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.terracotta)
                        .monospacedDigit()
                }
            }

            Text("Downloading \(ModelConfig.LLM.selectedModel.displayName)...")
                .font(.subheadline)
                .foregroundStyle(Theme.walnut)
        }
    }

    private var progressLabel: String {
        let downloaded = modelState.downloadedMB
        let total = modelState.totalMB
        if total > 0 {
            return String(format: "%.0f / %.0f MB", downloaded, total)
        }
        return String(format: "%.0f MB", downloaded)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.terracotta)

            Text("Preparing Lifehug...")
                .font(.subheadline)
                .foregroundStyle(Theme.walnut)
        }
    }

    // MARK: - Ready

    private var readyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.terracotta)
                .scaleEffect(1.0)
                .animation(.easeOut(duration: 0.4), value: true)

            Text("Lifehug")
                .font(Theme.displayFont)
                .foregroundStyle(Theme.walnut)
                .transition(.opacity)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    if appState.isOnboardingComplete {
                        appState.activeScreen = .dailyQuestion
                    } else {
                        appState.activeScreen = .onboarding
                    }
                }
            }
        }
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.walnut)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Button {
                modelState.triggerDownload()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Try Again")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.terracotta, in: RoundedRectangle(cornerRadius: Theme.buttonCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                // Return to model picker to choose a different model
                ModelConfig.LLM.clearSelection()
                modelState.deleteModelCache()
                showModelPicker = true
            } label: {
                Text("Choose a different model")
                    .font(.caption)
                    .foregroundStyle(Theme.terracotta)
            }
        }
    }
}

// MARK: - Model Picker Card

private struct ModelPickerCard: View {
    let option: ModelConfig.LLM.ModelOption
    let isSelected: Bool
    let isRecommended: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Radio button
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Theme.terracotta : Theme.softGray)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(option.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.warmCharcoal)

                    if isRecommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.sageGreen, in: Capsule())
                    }
                }

                Text(option.description)
                    .font(.caption)
                    .foregroundStyle(Theme.walnut)

                Text(option.downloadSizeLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.softGray)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Theme.terracotta.opacity(0.06) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Theme.terracotta.opacity(0.3) : Theme.softGray.opacity(0.3), lineWidth: 1)
        )
    }
}

#Preview {
    LaunchView()
        .environment(ModelState())
        .environment(AppState())
}
