import SwiftUI
import ImageIO

struct VideoFramingReviewSheet: View {
    let assessments: [VideoPhotoFramingAssessment]
    let aspect: Double
    let proceed: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text("Check the framing").font(.title2.bold())
                    Text("\(assessments.count) selected photo\(assessments.count == 1 ? "" : "s") will lose a large part of the frame in this video shape. Your saved photos stay unchanged.")
                        .foregroundStyle(.secondary)
                    ForEach(assessments) { row in
                        FramingReviewPhoto(row: row, aspect: aspect)
                    }
                    Text("This is an estimated center crop. AI motion can change the final framing; review the finished video before publishing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Use this framing") { dismiss(); proceed() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("video.framing.use")
                    Button("Back to photos or format") { dismiss() }.buttonStyle(.bordered)
                }.padding()
            }
            .navigationTitle("Framing review").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } } }
        }
    }
}

private struct FramingReviewPhoto: View {
    let row: VideoPhotoFramingAssessment
    let aspect: Double
    @State private var image: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(row.orientationLabel) photo · about \(Int((row.loss * 100).rounded()))% trimmed")
                .font(.caption.weight(.semibold))
            if let image { DeliveryFramingPreview(image: image, aspect: aspect) }
            else { ProgressView("Reading selected photo…") }
        }.task(id: row.sourceURL) {
            let preview = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithURL(row.sourceURL as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1200,
                        kCGImageSourceShouldCacheImmediately: true,
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            guard !Task.isCancelled else { return }; image = preview
        }
    }
}
