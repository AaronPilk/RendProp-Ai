import SwiftUI
import UIKit

/// The host presents this before requesting camera access and
/// passes onContinue to its existing capture workflow. No permissions here.
struct CaptureOrientationGuide: View {
    let intent: CaptureGuideIntent
    var onContinue: () -> Void
    var onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var paused = false
    @State private var demonstrated = false
    private var policy: CaptureGuideAnimationPolicy {
        .init(reduceMotion: reduceMotion, sceneIsActive: scenePhase == .active, userPaused: paused)
    }
    private var angle: Double {
        policy.animates ? (demonstrated ? intent.illustrativeRotationDegrees : (intent == .socialPhotos ? 90 : 0)) : intent.illustrativeRotationDegrees
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Text(intent.title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                illustrativePhone
                    .frame(height: 210)
                    .accessibilityHidden(true)
                Text(intent.instruction).font(.body).multilineTextAlignment(.center)
                if intent == .optionalWalkthrough {
                    Text("Optional: your photo-based listing video works without a recorded walkthrough.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !reduceMotion && intent == .listingPhotos {
                    Button(paused ? "Replay the guide" : "Pause animation") {
                        paused.toggle(); demonstrated = false
                    }.buttonStyle(.bordered)
                }
                Button("Open camera", action: onContinue).buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity).accessibilityHint("Opens the camera. Camera permission is requested only if needed.")
                Button("Not now", action: onCancel).buttonStyle(.plain)
                Text("The illustration is guidance. The real camera preview shows your framing; original photos are kept.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(24).frame(maxWidth: 560)
        }
        .transaction { if !policy.animates { $0.animation = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(intent.spokenInstruction)
        .task(id: policy.animates) {
            guard policy.animates else { demonstrated = false; return }
            demonstrated = false
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 1.1)) { demonstrated = true }
        }
    }
    private var illustrativePhone: some View {
        RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.purple.opacity(0.45), lineWidth: 2))
            .overlay {
                Image(systemName: "house.fill").font(.system(size: 52)).foregroundStyle(Color.purple)
                    .rotationEffect(.degrees(-angle))
            }
            .overlay(alignment: .top) { Capsule().fill(Color.primary.opacity(0.45)).frame(width: 26, height: 5).padding(.top, 10) }
            .frame(width: 110, height: 184)
            .rotationEffect(.degrees(angle))
    }
}

/// Preview actual supplied image pixels in the selected final canvas. UIKit
/// honors UIImage orientation; the host supplies a downsampled display copy.
/// For finished clips, supply a decoded frame from the actual provider clip.
struct DeliveryFramingPreview: View {
    let image: UIImage
    let aspect: Double
    var isGeneratedFrame = false
    var photoMotion = false
    var photoMotionScale: Double = 1.02
    var photoMotionDirection = "push_in"
    @State private var endFrame = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                if let frame = photoMotion ? PhotoMotionPreviewFrame.frame(scale: photoMotionScale, direction: photoMotionDirection, end: endFrame) : PhotoMotionPreviewFrame(scale: 1, translationX: 0) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(frame.scale).offset(x: frame.translationX * geometry.size.width).clipped()
                }
            }
            .aspectRatio(CGFloat(aspect), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel(isGeneratedFrame ? "Actual generated clip frame in the final video canvas" : "Selected photo in the final video canvas")
            if photoMotion {
                HStack(spacing: 10) {
                    Button("Start frame") { endFrame = false }.buttonStyle(RendpropPillButtonStyle(selected: !endFrame, compact: true))
                    Button("End frame") { endFrame = true }.buttonStyle(RendpropPillButtonStyle(selected: endFrame, compact: true))
                }
            }
            Text(photoMotion ? PhotoMotionPreviewFrame.caption(direction: photoMotionDirection, percent: Int(((photoMotionScale - 1) * 100).rounded())) + " The saved photo stays unchanged." : isGeneratedFrame ? "Final framing from this generated clip. Review the complete video before publishing." : "Framing preview from your selected photo. AI motion may change the final crop; your saved photo stays unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
