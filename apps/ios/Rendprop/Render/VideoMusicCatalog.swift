import Foundation
import CryptoKit

/// Closed artist-posted CC0 catalog. Evidence is bundled with the tracks;
/// this is not a guarantee against mistaken third-party ownership claims.
enum VideoMusicCatalog {
    static let tracks: [VerifiedMusicTrack] = [
        .init(id: "calm", title: "Calm · First Light Particles", assetRelativePath: "Music/calm.m4a", assetSHA256: "9503b0d6d59cdc76f69f786b6f2fd2fb6f39a747e245e8f02dc358b7fd4dbb36", licenseID: "CC0-1.0", licenseEvidenceSHA256: "8a5d6e54d255e734a434dbb63abb7fbcf759eb619be6735c123f467d444a9074", commerciallyVerified: true, webAndSocialRedistributionVerified: true, attributionRequired: false, instrumentalVerified: true, measuredDurationS: 131.72),
        .init(id: "upbeat", title: "Upbeat · Scaling Up", assetRelativePath: "Music/upbeat.m4a", assetSHA256: "ce55346893354d49746c689b3dde135ec1f3d9299d22ef8ec26b27a022020375", licenseID: "CC0-1.0", licenseEvidenceSHA256: "fa5b82351abf48b8b0877b1c10ed5163f3243a2cd7781c3b02dcb72ae4d26e27", commerciallyVerified: true, webAndSocialRedistributionVerified: true, attributionRequired: false, instrumentalVerified: true, measuredDurationS: 273.488),
        .init(id: "cinematic", title: "Cinematic · At Home", assetRelativePath: "Music/cinematic.m4a", assetSHA256: "119eaedb3c58948d6f6b346ec61aac58fa28174658714e06a6a5b8d0ec11bdc8", licenseID: "CC0-1.0", licenseEvidenceSHA256: "5f83d54c6e0d67b855d772f12615fe668c6678dc551cf1a95f382e96d89e3a45", commerciallyVerified: true, webAndSocialRedistributionVerified: true, attributionRequired: false, instrumentalVerified: true, measuredDurationS: 74.318),
    ]
    static func localURL(for track: VerifiedMusicTrack, bundle: Bundle = .main) throws -> URL {
        guard tracks.contains(track), track.isEligible else { throw CocoaError(.fileReadCorruptFile) }
        let url = bundle.url(forResource: track.id, withExtension: "m4a", subdirectory: "Music")
            ?? bundle.url(forResource: track.id, withExtension: "m4a")
        guard let url, let data = try? Data(contentsOf: url),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == track.assetSHA256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return url
    }
}
