import SwiftUI
import ImageIO

struct VideoFramingReviewSheet: View {
    let assessments: [VideoPhotoFramingAssessment]
    let aspect: Double
    var photoMotion = false
    var photoMotionScale: Double = 1.02
    var photoMotionDirection = "push_in"
    let changePhotos: () -> Void
    let proceed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page = 0
    @State private var endFrame = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Photo \(min(page + 1, assessments.count)) of \(assessments.count)")
                                .font(.rpTitle).foregroundStyle(Theme.ink)
                            Spacer(minLength: 8)
                            Text(aspect > 1 ? "Wide" : "Tall").font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                        if !assessments.isEmpty {
                            TabView(selection: $page) {
                                ForEach(Array(assessments.enumerated()), id: \.element.id) { index, row in
                                    FramingReviewPhoto(row: row, aspect: aspect, photoMotion: photoMotion,
                                        endFrame: endFrame, photoMotionScale: photoMotionScale, photoMotionDirection: photoMotionDirection, previewHeight: min(400, max(200, geometry.size.height * 0.56)))
                                        .tag(index).padding(.horizontal, 1)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .never))
                            .frame(height: min(400, max(200, geometry.size.height * 0.56)) + (dynamicTypeSize.isAccessibilitySize ? 110 : 54))
                            .accessibilityIdentifier("video.framing.pages")
                            if photoMotion { frameSelection }
                            if assessments.count > 1 { photoSelection }
                        }
                        Text(photoMotion
                            ? "Check the start and end of each photo. " + PhotoMotionPreviewFrame.caption(direction: photoMotionDirection, percent: Int(((photoMotionScale - 1) * 100).rounded())) + " Your saved photos stay unchanged."
                            : "This is the estimated center crop. AI motion can change the final framing; review the finished video before publishing.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                    }.padding(20).padding(.bottom, 16)
                }
            }
            .background(Theme.bg)
            .safeAreaInset(edge: .bottom, spacing: 0) { framingAction }
            .navigationTitle("Framing review").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss(); changePhotos() } label: {
                        if dynamicTypeSize.isAccessibilitySize { Image(systemName: "photo.stack") }
                        else { Text("Change photos") }
                    }
                    .accessibilityLabel("Change photos")
                    .accessibilityIdentifier("video.framing.changePhotos")
                }
            }
        }
    }

    private var frameSelection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { frameChoices }
            VStack(spacing: 10) { frameChoices }
        }
        .accessibilityIdentifier("video.framing.startEnd")
    }

    @ViewBuilder private var frameChoices: some View {
        ForEach([false, true], id: \.self) { end in
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { endFrame = end }
            } label: {
                Label(end ? "End" : "Start", systemImage: end ? "viewfinder" : "photo")
                    .font(.rpBody.weight(.semibold)).fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RendpropPillButtonStyle(selected: endFrame == end, compact: true, horizontalPadding: 14))
            .accessibilityLabel(end ? "End frame" : "Start frame")
            .accessibilityAddTraits(endFrame == end ? .isSelected : [])
        }
    }

    private var photoSelection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(assessments.indices, id: \.self) { index in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page = index }
                    } label: {
                        Text("\(index + 1)").font(.rpBody.weight(.semibold)).frame(minWidth: 24)
                    }
                    .buttonStyle(RendpropPillButtonStyle(selected: page == index, compact: true, horizontalPadding: 12))
                    .accessibilityLabel("Photo \(index + 1) of \(assessments.count)")
                    .accessibilityAddTraits(page == index ? .isSelected : [])
                }
            }.padding(.vertical, 2)
        }
    }

    private var framingAction: some View {
        PrimaryButton(title: "Create with this framing", systemImage: "checkmark") {
            dismiss(); proceed()
        }
        .accessibilityIdentifier("video.framing.use")
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
        .background(Theme.bg)
    }

}

private struct FramingReviewPhoto: View {
    let row: VideoPhotoFramingAssessment
    let aspect: Double
    var photoMotion = false
    let endFrame: Bool
    let photoMotionScale: Double
    let photoMotionDirection: String
    let previewHeight: CGFloat
    @State private var image: UIImage?
    @State private var previewFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                let width = min(geometry.size.width, geometry.size.height * aspect)
                ZStack {
                    if let image, let frame = photoMotion ? PhotoMotionPreviewFrame.frame(scale: photoMotionScale, direction: photoMotionDirection, end: endFrame) : PhotoMotionPreviewFrame(scale: 1, translationX: 0) {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: width, height: width / aspect)
                            .scaleEffect(frame.scale).offset(x: frame.translationX * width).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else if previewFailed {
                        Text("This preview could not be read. Return to photos to check this saved version.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim).padding()
                    } else { ProgressView("Reading selected photo…") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: previewHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(previewFailed ? "Photo preview unavailable" : (photoMotion && endFrame ? "End frame" : "Start frame in the final video shape"))
            Text("\(row.orientationLabel) photo · about \(Int((row.loss * 100).rounded()))% trimmed")
                .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: row.sourceURL) {
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
            guard !Task.isCancelled else { return }; image = preview; previewFailed = preview == nil
        }
    }
}
