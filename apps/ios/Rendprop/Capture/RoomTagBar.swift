import SwiftUI

/// Floating room-tag buttons shown during capture. Tapping one timestamps a
/// chapter marker at the current recording time (master spec 4.2).
struct RoomTagBar: View {
    let elapsed: TimeInterval
    let isRecording: Bool
    @Binding var tags: [RoomTag]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RoomTag.quickNames, id: \.self) { name in
                    Button {
                        guard isRecording else { return }
                        tags.append(RoomTag(name: name, tMs: Int(elapsed * 1000)))
                        Haptics.selection()
                    } label: {
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
                    }
                    .disabled(!isRecording)
                    .opacity(isRecording ? 1 : 0.45)
                    .accessibilityLabel(Text("Tag \(name) at \(Formatters.duration(elapsed))"))
                }
            }
            .padding(.horizontal)
        }
    }
}
