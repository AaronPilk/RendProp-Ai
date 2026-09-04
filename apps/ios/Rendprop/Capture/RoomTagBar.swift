import SwiftUI

/// Floating room-tag buttons shown during capture. Tapping one timestamps a
/// chapter marker at the current recording time (master spec 4.2).
///
/// The time comes from `currentTime()` — the movie output's own recorded
/// duration at the moment of the tap — not the 250 ms UI timer, so a marker
/// lands where the finger landed (audit F-D-26). Accidental taps are handled:
/// the same tag twice within 2 s is ignored, a DIFFERENT tag within 2 s
/// replaces the previous one ("oops, wrong room"), and "Undo" removes the last.
struct RoomTagBar: View {
    let isRecording: Bool
    @Binding var tags: [RoomTag]
    /// Seconds of the take recorded so far, read at tap time.
    var currentTime: () -> TimeInterval

    /// Two taps closer than this are one tap: a correction, not two chapters.
    static let collapseWindowMs = 2000

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if isRecording, let last = tags.last {
                    Button {
                        tags.removeLast()
                        Haptics.selection()
                    } label: {
                        Label("Undo \(last.name)", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.accent.opacity(0.85), in: Capsule())
                    }
                    .accessibilityLabel(Text("Undo last tag, \(last.name) at \(Formatters.duration(last.tSeconds))"))
                }
                ForEach(RoomTag.quickNames, id: \.self) { name in
                    Button {
                        tap(name)
                    } label: {
                        // Explicit white — this rides the camera feed, where the
                        // chrome is dark in both app appearances.
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
                    }
                    .disabled(!isRecording)
                    .opacity(isRecording ? 1 : 0.45)
                    .accessibilityLabel(Text(isRecording ? "Tag \(name) now" : "\(name) — available while recording"))
                }
            }
            .padding(.horizontal)
        }
    }

    private func tap(_ name: String) {
        guard isRecording else { return }
        let tMs = max(0, Int((currentTime() * 1000).rounded()))
        if let last = tags.last, tMs - last.tMs < Self.collapseWindowMs {
            if last.name == name { return }                       // double tap → one tag
            tags[tags.count - 1] = RoomTag(name: name, tMs: last.tMs)   // wrong room → replace
            Haptics.selection()
            return
        }
        tags.append(RoomTag(name: name, tMs: tMs))
        Haptics.selection()
    }
}
