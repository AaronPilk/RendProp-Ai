import SwiftUI

// MARK: - Primary button (big, obvious, purple)
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .font(.body)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isDisabled ? Theme.accent.opacity(0.35) : Theme.accent)
            .foregroundStyle(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(isDisabled)
        .accessibilityLabel(Text(title))
    }
}

// MARK: - Card (white, soft shadow)
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.spacing)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.border)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 4)
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

// MARK: - Status chip
struct StatusChip: View {
    let status: Listing.Status

    var body: some View {
        Label(status.label, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.12), in: Capsule())
            .accessibilityLabel(Text("Status: \(status.label)"))
    }
}

// MARK: - Persistent upload mini-bar (shown across screens while uploading)
struct UploadMiniBar: View {
    @EnvironmentObject var uploads: UploadManager

    var body: some View {
        if let s = uploads.state, s.status == .uploading || s.status == .paused {
            HStack(spacing: 12) {
                Image(systemName: s.status == .paused ? "pause.circle.fill" : "arrow.up.circle.fill")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.status == .paused ? "Upload paused" : "Sending your video…")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    ProgressView(value: s.fractionComplete)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                }
                Text(s.fractionComplete.formatted(.percent.precision(.fractionLength(0))))
                    .font(.rpMono)
                    .foregroundStyle(Theme.inkDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.border)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 3)
            .padding(.horizontal)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Skeleton shimmer
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8).fill(Theme.fillSubtle)
                .frame(width: 64, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.08)).frame(width: 160, height: 12)
                RoundedRectangle(cornerRadius: 4).fill(Theme.fillSubtle).frame(width: 100, height: 10)
            }
            Spacer()
        }
        .redacted(reason: .placeholder)
    }
}
