import Foundation

/// Semantic setup shared with Studio. Device URLs, upload capabilities and paid
/// generation requests never enter this document. Unsupported local media is
/// represented explicitly, so another device cannot invent a matching shot.
struct NativeReelDraft: Codable, Hashable, Sendable {
    struct Photo: Codable, Hashable, Sendable { let localId: String; let sourcePhotoId: UUID? }
    let schema: Int
    let kind: String
    let portrait: Bool
    let titleCard: Bool
    let shotCaptions: Bool
    let captionStyle: String
    let transition: String
    let motionPrompt: String
    let script: String
    let tone: String
    let wordCaptions: Bool
    let voiceMode: String
    let voiceResultId: UUID?
    let localNarration: Bool
    let photos: [Photo]
    let localExtraClipCount: Int
    let updatedAt: String

    func checked() throws -> Self {
        guard schema == 1, kind == "native-reel-setup", ["off", "lowerThird", "punchCard", "highlightBox"].contains(captionStyle),
              ["cut", "dissolve", "whip"].contains(transition), ["warm", "punchy", "luxury"].contains(tone),
              ["off", "myVoice", "aiVoice"].contains(voiceMode), motionPrompt.count <= 4000, script.count <= 100_000,
              photos.count <= 100, Set(photos.map(\.localId)).count == photos.count,
              photos.allSatisfy({ !$0.localId.isEmpty && $0.localId.count <= 120 && !$0.localId.contains("/") && !$0.localId.contains("\\") && !$0.localId.contains(":") }),
              localExtraClipCount >= 0, localExtraClipCount <= 100, CloudListingMerge.date(updatedAt) != nil else { throw CloudSyncError.invalidResponse }
        return self
    }
}

struct CloudNativeReelDocument: Decodable {
    let listing_id: UUID
    let revision: Int
    let payload: NativeReelDraft
    func checked(listingID: UUID) throws -> Self {
        guard listing_id == listingID, revision > 0, revision < 2_147_483_647 else { throw CloudSyncError.invalidResponse }
        _ = try payload.checked()
        return self
    }
}
