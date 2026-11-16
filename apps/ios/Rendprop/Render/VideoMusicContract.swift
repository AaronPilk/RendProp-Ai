import Foundation

/// Closed catalog evidence is reviewed by the app operator; license claims
/// supplied by an end user cannot add a track. Off remains the default.
struct VerifiedMusicTrack: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let assetRelativePath: String
    let assetSHA256: String
    let licenseID: String
    let licenseEvidenceSHA256: String
    let commerciallyVerified: Bool
    let webAndSocialRedistributionVerified: Bool
    let attributionRequired: Bool
    let instrumentalVerified: Bool
    let measuredDurationS: Double
    var isEligible: Bool {
        !id.isEmpty && id.utf8.count <= 100 && !title.isEmpty &&
        assetRelativePath.hasPrefix("Music/") && !assetRelativePath.hasPrefix("/") &&
        !assetRelativePath.split(separator: "/").contains("..") &&
        [assetSHA256, licenseEvidenceSHA256].allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) } &&
        !licenseID.isEmpty && commerciallyVerified && webAndSocialRedistributionVerified && !attributionRequired && instrumentalVerified &&
        measuredDurationS.isFinite && measuredDurationS >= 5 && measuredDurationS <= 3600
    }
}
struct VideoMusicSelection: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case trackID = "track_id", assetSHA256 = "asset_sha256", licenseID = "license_id", licenseEvidenceSHA256 = "license_evidence_sha256"
        case gain, narrationDuckGain = "duck_gain"
    }
    let trackID: String
    let assetSHA256: String
    let licenseID: String
    let licenseEvidenceSHA256: String
    var gain: Double = 0.18
    var narrationDuckGain: Double = 0.07
    func checked(catalog: [VerifiedMusicTrack]) -> VerifiedMusicTrack? {
        guard gain.isFinite, narrationDuckGain.isFinite, (0...0.35).contains(gain),
              (0...gain).contains(narrationDuckGain),
              let track = catalog.first(where: { $0.id == trackID }), track.isEligible,
              track.assetSHA256 == assetSHA256, track.licenseID == licenseID,
              track.licenseEvidenceSHA256 == licenseEvidenceSHA256 else { return nil }
        return track
    }
}
struct VideoMusicLoop: Equatable, Sendable { let sourceStartS: Double, destinationStartS: Double, durationS: Double }
enum VideoMusicTimeline {
    /// Music never extends the final video. Duration is measured AFTER any
    /// existing narration hold; whole-loop trims end exactly on that timeline.
    static func loops(trackDurationS: Double, finalVideoDurationS: Double) -> [VideoMusicLoop]? {
        guard trackDurationS.isFinite, finalVideoDurationS.isFinite,
              trackDurationS >= 5, finalVideoDurationS > 0, finalVideoDurationS <= 600 else { return nil }
        var result: [VideoMusicLoop] = [], position = 0.0
        while position < finalVideoDurationS {
            let duration = min(trackDurationS, finalVideoDurationS - position)
            result.append(.init(sourceStartS: 0, destinationStartS: position, durationS: duration))
            position += duration
        }
        return result
    }
    static func gain(at time: Double, narrationDurationS: Double, selection: VideoMusicSelection) -> Double {
        time < narrationDurationS ? selection.narrationDuckGain : selection.gain
    }
}
