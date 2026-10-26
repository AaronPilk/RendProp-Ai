import SwiftUI

/// Shared adaptive surface. Materials are decorative: hierarchy, borders and
/// explicit labels remain available with transparency or motion reduced.
struct RendpropGlassSurface: ViewModifier {
    var selected = false
    var capsule = false
    var interactive = false
    var tint: Color? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if capsule { surface(content, in: Capsule()) }
        else { surface(content, in: RoundedRectangle(cornerRadius: 24, style: .continuous)) }
    }

    @ViewBuilder private func surface<S: Shape>(_ content: Content, in shape: S) -> some View {
        Group {
            if reduceTransparency {
                content.background { shape.fill(Theme.card).overlay(shape.fill(selected ? Theme.accentSoft : Color.clear)) }
            } else if #available(iOS 26.0, *) {
                content.glassEffect(.regular.tint(tint ?? (selected ? Theme.accent.opacity(0.10) : nil)).interactive(interactive), in: shape)
            } else {
                content.background { shape.fill(.ultraThinMaterial).overlay(shape.fill(selected ? Theme.accentSoft : Color.clear)) }
            }
        }
        .overlay(shape.stroke(selected ? Theme.accent : Theme.border,
                              lineWidth: selected || contrast == .increased ? 1.5 : 0.75).allowsHitTesting(false))
        .shadow(color: Theme.ink.opacity(selected ? 0.08 : 0.035), radius: selected ? 10 : 5, y: 3)
    }
}

/// For existing Button, NavigationLink and ShareLink label builders. The
/// caller keeps its original action, padding, availability and identity.
struct RendpropActionLabelSurface: ViewModifier {
    var primary = true
    var selected = false
    var primaryFill: Color? = nil
    var primaryInk: Color? = nil
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .frame(minHeight: 44)
            .foregroundStyle(!isEnabled ? Theme.disabledInk : primary ? (primaryInk ?? Color.white) : Theme.accent)
            .background {
                if !isEnabled { Capsule().fill(Theme.disabledFill) }
                else if primary { Capsule().fill(primaryFill ?? Theme.actionFill) }
            }
            .modifier(RendpropGlassSurface(selected: selected && isEnabled, capsule: true, interactive: isEnabled,
                                           tint: primary && isEnabled ? (primaryFill ?? Theme.actionFill) : nil))
    }
}

/// Selection pills and the material fallback for primary/secondary actions.
/// Disabled appearance follows both the caller and inherited environment.
struct RendpropPillButtonStyle: ButtonStyle {
    var selected = false
    var prominent = false
    var compact = false
    var horizontalPadding: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, horizontalPadding).padding(.vertical, compact ? 10 : 14)
            .modifier(RendpropActionLabelSurface(primary: prominent, selected: selected))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct RendpropActionAppearance: ViewModifier {
    var primary = true
    var compact = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            if primary {
                content.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                    .controlSize(compact ? .regular : .large).tint(Theme.actionFill)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.capsule)
                    .controlSize(compact ? .regular : .large).tint(Theme.accent)
            }
        } else {
            content.buttonStyle(RendpropPillButtonStyle(prominent: primary, compact: compact))
        }
    }
}

/// Content stays on an opaque, adaptive surface. Glass is reserved for the
/// floating actions and navigation rather than placed behind dense forms/media.
struct RendpropContentSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        content
            .background(Theme.card, in: shape)
            .overlay(shape.strokeBorder(Theme.border, lineWidth: contrast == .increased ? 1.5 : 0.75))
            .shadow(color: Theme.ink.opacity(0.045), radius: 12, y: 4)
    }
}

// MARK: - Primary action
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isDisabled = false
    var isCompact = false
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
            .font(isCompact ? .subheadline : .body)
            .frame(maxWidth: .infinity)
            .frame(minHeight: isCompact ? 24 : 28)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(RendpropActionAppearance(compact: isCompact))
        .disabled(isDisabled)
        .accessibilityLabel(Text(title))
    }
}

// MARK: - Content surface (media keeps its own image/video shape)
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.spacing)
            .modifier(RendpropContentSurface())
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .modifier(RendpropGlassSurface())
            .padding(.horizontal)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - "Needs attention" chip (render/publish failed or was interrupted)
struct AttentionChip: View {
    var body: some View {
        Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.warn)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.warn.opacity(0.12), in: Capsule())
            .accessibilityLabel(Text("Needs attention"))
    }
}

// MARK: - Secondary action
struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isDisabled = false
    var isLoading = false
    var isCompact = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(isDisabled ? Theme.disabledInk : Theme.accent)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).fontWeight(.semibold)
            }
            .font(isCompact ? .subheadline : .rpBody)
            .frame(maxWidth: .infinity)
            .frame(minHeight: isCompact ? 24 : 26)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(RendpropActionAppearance(primary: false, compact: isCompact))
        .disabled(isDisabled || isLoading)
        .accessibilityLabel(Text(title))
    }
}
