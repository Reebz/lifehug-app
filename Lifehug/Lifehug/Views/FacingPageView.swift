import SwiftUI

/// Facing-page verbatim view (U12/R13): chapter prose paired with the person's exact source
/// words. Not a true two-column split (no precedent, and too cramped on phones) — a simple
/// synchronized pairing per passage: the prose, its validated verbatim pull-quotes, then the
/// source segments it was written from. Passages with no anchor show prose only.
struct FacingPageView: View {
    let provenance: ChapterProvenance
    let answers: [Answer]
    let storage: StorageService

    @State private var clipPlayer = AudioClipPlayer()
    @Environment(STTService.self) private var sttService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(provenance.passages, id: \.id) { passage in
                    passageCard(passage)
                }
            }
            .padding()
        }
        .background(Theme.cream.ignoresSafeArea())
        .navigationTitle("In Their Words")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(LifehugBarStyle())
        .onAppear {
            clipPlayer.recordingActive = { [weak sttService] in sttService?.isRecording ?? false }
        }
        .onDisappear {
            clipPlayer.stop()
        }
    }

    @ViewBuilder
    private func passageCard(_ passage: ChapterProvenance.PassageProvenance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Right side (conceptually): the chapter prose.
            Text(passage.text)
                .font(Theme.bodySerifFont)
                .foregroundStyle(Theme.warmCharcoal)

            // Validated verbatim pull-quotes, marked as the person's exact words.
            ForEach(passage.pullQuotes, id: \.self) { quote in
                pullQuote(quote)
            }

            // Left side (conceptually): the source segments this passage came from.
            if !passage.links.isEmpty {
                Rectangle().fill(Theme.warmGray.opacity(0.15)).frame(height: 1)
                Text("Their words")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.walnut)
                ForEach(Array(passage.links.enumerated()), id: \.offset) { _, link in
                    sourceSegment(link)
                }
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .fill(Theme.cardBackground)
                .shadow(color: Theme.cardShadow, radius: 4, y: 2)
        )
    }

    private func pullQuote(_ quote: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Their exact words", systemImage: "quote.opening")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.terracotta)
            Text("“\(quote)”")
                .font(Theme.bodySerifFont.italic())
                .foregroundStyle(Theme.warmCharcoal)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.terracotta.opacity(0.08))
        )
    }

    @ViewBuilder
    private func sourceSegment(_ link: ChapterProvenance.SegmentLink) -> some View {
        let segment = segment(for: link)
        HStack(alignment: .top, spacing: 10) {
            if let clip = link.clipFilename, let url = try? storage.clipURL(filename: clip) {
                Button {
                    clipPlayer.play([(clip, url)])
                } label: {
                    Image(systemName: clipPlayer.currentClipName == clip && clipPlayer.state == .playing
                          ? "waveform.circle.fill" : "play.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.terracotta)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(segment?.text ?? link.quote.exact)
                    .font(Theme.captionSerifFont)
                    .foregroundStyle(Theme.walnut)
                if segment?.isEdited == true {
                    Text("Edited")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.walnut)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.walnut.opacity(0.12)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    /// The source segment behind a link (original transcript text for the facing page).
    private func segment(for link: ChapterProvenance.SegmentLink) -> Answer.Segment? {
        guard let answer = answers.first(where: { $0.questionID == link.questionID }),
              link.segmentIndex >= 0, link.segmentIndex < answer.segments.count else { return nil }
        return answer.segments[link.segmentIndex]
    }
}
