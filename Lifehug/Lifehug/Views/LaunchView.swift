import SwiftUI

struct LaunchView: View {
    @Environment(ModelState.self) private var modelState
    @Environment(AppState.self) private var appState

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

    // MARK: - Not Downloaded

    private var needsDownloadView: some View {
        VStack(spacing: 20) {
            Text("Lifehug runs entirely on your device.\nA one-time download is needed.")
                .font(.subheadline)
                .foregroundStyle(Theme.walnut)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Button {
                modelState.triggerDownload()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                    Text("Download Model")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.terracotta, in: RoundedRectangle(cornerRadius: Theme.buttonCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download AI model, approximately 700 megabytes")

            Text("~700 MB over Wi-Fi")
                .font(.caption)
                .foregroundStyle(Theme.softGray)
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

            Text("Downloading model...")
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

            Text("Ready")
                .font(Theme.headlineFont)
                .foregroundStyle(Theme.walnut)
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
        }
    }
}

#Preview {
    LaunchView()
        .environment(ModelState())
        .environment(AppState())
}
