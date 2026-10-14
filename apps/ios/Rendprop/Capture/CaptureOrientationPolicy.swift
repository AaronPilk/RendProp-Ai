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
