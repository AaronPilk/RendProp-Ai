import SwiftUI

struct VideoMusicPicker: View {
    @Binding var selection: VideoMusicSelection?
    var onPreview: (VerifiedMusicTrack) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background music · optional").font(.rpBody.weight(.semibold))
            Button { selection = nil } label: {
                Label("Off", systemImage: selection == nil ? "checkmark.circle.fill" : "circle")
            }.accessibilityIdentifier("video.music.off")
            ForEach(VideoMusicCatalog.tracks) { track in
                HStack {
                    Button {
                        selection = VideoMusicSelection(trackID: track.id, assetSHA256: track.assetSHA256,
                            licenseID: track.licenseID, licenseEvidenceSHA256: track.licenseEvidenceSHA256)
                    } label: { Label(track.title, systemImage: selection?.trackID == track.id ? "checkmark.circle.fill" : "music.note") }
                    Spacer()
                    Button { onPreview(track) } label: { Image(systemName: "play.circle") }
                        .accessibilityLabel("Preview \(track.title)")
                }.accessibilityIdentifier("video.music.\(track.id)")
            }
            Text("These tracks are offered under CC0. Music stays quieter beneath narration. Your choice is saved with this video.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }.foregroundStyle(Theme.ink)
    }
}
