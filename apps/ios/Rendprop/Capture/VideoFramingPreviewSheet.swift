import SwiftUI
import ImageIO

struct VideoFramingPreviewSheet: View {
    let url: URL
    let aspect: Double
    var photoMotion = false
    var photoMotionScale: Double = 1.02
    var photoMotionDirection = "push_in"
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var previewFailed = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let image { DeliveryFramingPreview(image: image, aspect: aspect, photoMotion: photoMotion, photoMotionScale: photoMotionScale, photoMotionDirection: photoMotionDirection) }
                    else if previewFailed { Text("This preview could not be read. Your saved photo is unchanged.") }
                    else { ProgressView("Preparing framing preview…") }
                    Text(aspect > 1 ? "Landscape · listing video" : "Portrait · social media")
                        .font(.headline)
                    Text("For wide property views, capture landscape. For a full-screen social video, capture portrait. This preview changes no saved photo.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Video framing").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            let preview = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                        kCGImageSourceShouldCacheImmediately: true,
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            guard !Task.isCancelled else { return }; image = preview; previewFailed = preview == nil
        }
    }
}
