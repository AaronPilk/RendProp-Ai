import SwiftUI
import AVFoundation

// MARK: - Camera preview layer
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Level bubble (gravity-driven)
struct LevelBubble: View {
    let roll: Double     // radians
    let pitch: Double

    private var isLevel: Bool { abs(roll) < 0.06 && abs(pitch) < 0.18 }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
                .frame(width: 64, height: 64)
            Circle()
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                .frame(width: 18, height: 18)
            Circle()
                .fill(isLevel ? Theme.good : Theme.warn)
                .frame(width: 12, height: 12)
                .offset(x: CGFloat(max(-1, min(1, roll / 0.5))) * 24,
                        y: CGFloat(max(-1, min(1, pitch / 0.5))) * 24)
                .animation(.linear(duration: 0.08), value: roll)
        }
        .accessibilityLabel(Text(isLevel ? "Level" : "Tilt the phone to level"))
    }
}

// MARK: - Pace ring (motion-magnitude-driven metronome)
struct PaceRing: View {
    let pace: Double        // 0 still … 1+ too fast
    let isRecording: Bool

    private var status: (color: Color, label: String) {
        // Normal walking pace is fine — the render retimes it into a glide.
        // Only fast spins and rushing hurt quality.
        if pace < 0.65 { return (Theme.good, "Good pace") }
        if pace < 1.1  { return (Theme.warn, "Ease off") }
        return (Theme.bad, "Too fast")
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, pace)))
                    .stroke(status.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.15), value: pace)
                Image(systemName: "figure.walk")
                    .font(.system(size: 18))
                    .foregroundStyle(status.color)
            }
            .frame(width: 52, height: 52)
            if isRecording {
                Text(status.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(status.color)
                    .shadow(radius: 3)
            }
        }
        .accessibilityLabel(Text(status.label))
    }
}

// MARK: - Light warning
struct LightWarning: View {
    let luminance: Double   // 0–1

    var body: some View {
        if luminance < 0.18 {
            Label("Too dark — open blinds or turn on lights", systemImage: "lightbulb")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.warn.opacity(0.9), in: Capsule())
                .foregroundStyle(.black)
                .transition(.opacity)
        }
    }
}

// MARK: - Rule-of-thirds grid
struct ThirdsGrid: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    p.move(to: CGPoint(x: w * CGFloat(i) / 3, y: 0))
                    p.addLine(to: CGPoint(x: w * CGFloat(i) / 3, y: h))
                    p.move(to: CGPoint(x: 0, y: h * CGFloat(i) / 3))
                    p.addLine(to: CGPoint(x: w, y: h * CGFloat(i) / 3))
                }
            }
            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}
