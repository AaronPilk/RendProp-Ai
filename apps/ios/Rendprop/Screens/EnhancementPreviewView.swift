import SwiftUI

/// "See it before you buy it" — runs the native AI loop on one frame of the
/// user's actual video and shows before/after with quality scores.
struct EnhancementPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = EnhancementEngine()

    let asset: CaptureAsset
    let declutter: Bool
    let style: DesignStyle

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    switch engine.phase {
                    case .done:
                        if let r = engine.result { resultView(r) }
                    case .failed(let message):
                        failedView(message)
                    default:
                        progressView
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await engine.run(videoURL: asset.localURL,
                             atSecond: min(asset.durationS / 2, asset.durationS),
                             declutter: declutter,
                             style: style)
        }
    }

    // MARK: - States

    private var progressView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
                .padding(.top, 60)
            Text(engine.phase.label)
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("Usually takes under a minute.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func resultView(_ r: EnhancementEngine.Result) -> some View {
        VStack(spacing: Theme.spacing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("BEFORE").font(.rpKicker).foregroundStyle(Theme.inkDim)
                Image(uiImage: r.before)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("AFTER").font(.rpKicker).foregroundStyle(Theme.accent)
                    Spacer()
                    Text(r.roomType)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                }
                AsyncImage(url: r.afterURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 10) {
                    scoreBadge("Structure", r.structure)
                    scoreBadge("Complete", r.completeness)
                    scoreBadge("Clean", r.artifacts)
                }
                Text(r.attempts > 1
                     ? "Passed quality check after \(r.attempts) tries — the retry loop working for you."
                     : "Passed quality check on the first try.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                Text("AI cost for this preview: about \(Money(cents: r.spentCents).formatted)")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            Label("Your full video gets this treatment room-by-room when you create the tour.",
                  systemImage: "sparkles")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)
                .padding(.top, 40)
            Text("No preview this time")
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private func scoreBadge(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(value >= 80 ? Theme.good : Theme.warn)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 10))
    }
}
