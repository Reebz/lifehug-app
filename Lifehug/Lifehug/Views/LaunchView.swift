import SwiftUI

struct LaunchView: View {
    @Environment(ModelState.self) private var modelState
    @Environment(AppState.self) private var appState

    // Design tokens
    private let creamBackground = Color(hex: 0xFBF8F3)
    private let terracotta = Color(hex: 0xC67B5C)
    private let warmGray = Color(hex: 0x8A8178)

    var body: some View {
        ZStack {
            creamBackground
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                headerSection

                Spacer()

                statusSection

                Spacer()
                    .frame(height: 40)
            }
            .padding(.horizontal, 32)
        }
        .task {
            await modelState.prepareOnLaunch()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Text("Lifehug")
                .font(.system(size: 40, weight: .regular, design: .serif))
                .foregroundStyle(Color(hex: 0x3A3632))

            Text("Thoughtful questions for a\nmore examined life")
                .font(.system(size: 17, weight: .regular, design: .serif))
                .foregroundStyle(warmGray)
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
                .foregroundStyle(warmGray)
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
                .background(terracotta, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download AI model, approximately 700 megabytes")

            Text("~700 MB over Wi-Fi")
                .font(.caption)
                .foregroundStyle(warmGray.opacity(0.7))
        }
    }

    // MARK: - Downloading

    private var downloadingView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                ProgressView(value: modelState.downloadProgress)
                    .tint(terracotta)
                    .scaleEffect(y: 2)
                    .clipShape(Capsule())

                HStack {
                    Text(progressLabel)
                        .font(.caption)
                        .foregroundStyle(warmGray)
                        .monospacedDigit()

                    Spacer()

                    Text("\(Int(modelState.downloadProgress * 100))%")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(terracotta)
                        .monospacedDigit()
                }
            }

            Text("Downloading model...")
                .font(.subheadline)
                .foregroundStyle(warmGray)
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
                .tint(terracotta)

            Text("Preparing Lifehug...")
                .font(.subheadline)
                .foregroundStyle(warmGray)
        }
    }

    // MARK: - Ready

    private var readyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(terracotta)

            Text("Ready")
                .font(.headline)
                .foregroundStyle(Color(hex: 0x3A3632))
        }
        .onAppear {
            // Transition to onboarding or main app after a brief moment
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
                .foregroundStyle(warmGray)
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
                .background(terracotta, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Color Extension

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

#Preview {
    LaunchView()
        .environment(ModelState())
        .environment(AppState())
}
