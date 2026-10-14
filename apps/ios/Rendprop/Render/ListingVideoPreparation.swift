import Foundation
import AVFoundation

enum ListingVideoPreparation {
    /// Called after encoding and before retiring the paid clips/recipe. Actual
    /// encoded dimensions and duration, plus a streamed digest, identify output.
    static func retain(output: URL, listingID: UUID, ownerID: String?, workspaceID: UUID?, serverListingID: UUID?,
                       purpose: VideoAspectChoice, sources: [ListingVideoSource], includesOpeningClip: Bool, brandingPolicy: String? = nil) async throws -> ListingVideoRecord {
        let asset = AVURLAsset(url: output)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ListingVideoStore.Failure.invalidRecord }
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let display = CGRect(origin: .zero, size: size).applying(transform)
        let duration = try await asset.load(.duration).seconds
        let width = Int(abs(display.width).rounded()), height = Int(abs(display.height).rounded())
        guard width > 0, height > 0, duration.isFinite, duration > 0 else { throw ListingVideoStore.Failure.invalidRecord }
        let documents = FileStore.documents
        return try await Task.detached(priority: .utility) {
            let bytes = FileStore.fileSize(output)
            let record = ListingVideoRecord(id: UUID(), listingID: listingID, ownerID: ownerID, workspaceID: workspaceID,
                serverListingID: serverListingID, relativePath: FileStore.relativePath(for: output), purpose: purpose,
                width: width, height: height, durationS: duration, bytes: bytes, sha256: try ListingVideoStore.digest(output),
                sources: sources, includesOpeningClip: includesOpeningClip, createdAt: Date(), brandingPolicy: brandingPolicy)
            try ListingVideoStore.save(record, documents: documents)
            return record
        }.value
    }
}
