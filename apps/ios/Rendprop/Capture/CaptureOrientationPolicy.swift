import Foundation

/// Next-candidate prototype only. No camera/API calls or original-file edits.
enum CaptureGuideIntent: String, Codable, Sendable {
    case listingPhotos, socialPhotos, optionalWalkthrough
    var title: String {
        switch self {
        case .listingPhotos: return "Hold your phone sideways"
        case .socialPhotos: return "Hold your phone upright"
        case .optionalWalkthrough: return "Film a slow, steady walkthrough"
        }
    }
    var instruction: String {
        switch self {
        case .listingPhotos: return "Hold your phone sideways. Use 0.5× whenever you need it to fit the room. Keep the phone level."
        case .socialPhotos: return "Portrait photos suit vertical social videos. Keep important features inside the shown frame."
        case .optionalWalkthrough: return "Move slowly, keep the phone level and turn gently around corners. A gimbal can help. You can also upload existing footage."
        }
    }
    var spokenInstruction: String {
        switch self {
        case .listingPhotos: return "Rotate the phone sideways for landscape property photos. Keep it level."
        case .socialPhotos: return "Keep the phone upright for portrait social photos. Keep it level."
        case .optionalWalkthrough: return "Walk slowly and steadily. Turn gently. Follow the orientation shown by the recorder."
        }
    }
    /// Existing optional walkthrough recorder is portrait. A future recorder
    /// may supply a different target, but the guide must not misrepresent it.
    var illustrativeRotationDegrees: Double { self == .listingPhotos ? 90 : 0 }
    var previewAspect: Double { self == .listingPhotos ? 16.0 / 9.0 : 9.0 / 16.0 }
}

struct CaptureGuideAnimationPolicy: Equatable, Sendable {
    let reduceMotion: Bool
    let sceneIsActive: Bool
    let userPaused: Bool
    var animates: Bool { !reduceMotion && sceneIsActive && !userPaused }
}

/// Source coordinates normalized to 0...1, with orientation already baked.
/// Mirrors one centered aspect-fill delivery crop; never rewrites a source.
struct DeliveryCrop: Equatable, Sendable {
    let x: Double, y: Double, width: Double, height: Double
    func centeredPush(scale: Double) -> DeliveryCrop {
        let w = width / scale, h = height / scale
        return DeliveryCrop(x: x + (width - w) / 2, y: y + (height - h) / 2, width: w, height: h)
    }
    static func centered(sourceWidth: Double, sourceHeight: Double, deliveryAspect: Double) -> DeliveryCrop? {
        guard sourceWidth.isFinite, sourceHeight.isFinite, deliveryAspect.isFinite,
              sourceWidth > 0, sourceHeight > 0, deliveryAspect > 0 else { return nil }
        let sourceAspect = sourceWidth / sourceHeight
        if sourceAspect > deliveryAspect {
            let width = deliveryAspect / sourceAspect
            return DeliveryCrop(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
        let height = sourceAspect / deliveryAspect
        return DeliveryCrop(x: 0, y: (1 - height) / 2, width: 1, height: height)
    }
}

/// Same closed endpoint geometry as the server Photo motion profiles. No image rewrite.
struct PhotoMotionPreviewFrame: Equatable, Sendable {
    let scale: Double
    let translationX: Double
    static func frame(scale: Double, direction: String, end: Bool) -> Self? {
        guard [1.02, 1.12].contains(scale), direction == "push_in" || (scale == 1.12 && ["pull_back", "slide_left", "slide_right"].contains(direction)) else { return nil }
        switch direction {
        case "push_in": return .init(scale: end ? scale : 1, translationX: 0)
        case "pull_back": return .init(scale: end ? 1 : scale, translationX: 0)
        case "slide_left": return .init(scale: scale, translationX: (end ? 1 : -1) * (scale - 1) / 2)
        case "slide_right": return .init(scale: scale, translationX: (end ? -1 : 1) * (scale - 1) / 2)
        default: return nil
        }
    }
    static func caption(direction: String, percent: Int) -> String {
        switch direction {
        case "pull_back": return "Starts \(percent)% closer. Pulls back to the center frame."
        case "slide_left": return "Glides left across a \(percent)% crop."
        case "slide_right": return "Glides right across a \(percent)% crop."
        default: return "Starts centered. Ends \(percent)% closer."
        }
    }
}
extension DeliveryCrop {
    func photoMotionFrame(scale: Double, direction: String, end: Bool) -> Self? {
        guard let frame = PhotoMotionPreviewFrame.frame(scale: scale, direction: direction, end: end) else { return nil }
        let w = width / frame.scale, h = height / frame.scale
        return .init(x: x + (width - w) / 2 - frame.translationX * w, y: y + (height - h) / 2, width: w, height: h)
    }
}
