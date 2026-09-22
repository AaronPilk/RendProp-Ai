import Foundation
import AVFoundation

@main
struct VideoProbe {
    static func dropOwner(_ url: URL) async throws -> (AVAssetTrack, CMTimeRange) {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        return (track, try await track.load(.timeRange))
    }

    static func main() async {
        do {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let (orphan, orphanRange) = try await dropOwner(url)
        let broken = AVMutableComposition()
        let brokenDest = broken.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        print("Unretained track parent alive: \(orphan.asset != nil)")
        do {
            try brokenDest.insertTimeRange(orphanRange, of: orphan, at: .zero)
            print("Unretained insertion happened to succeed on this runtime")
        } catch { print("Unretained insertion failed: \((error as NSError).code)") }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw NSError(domain: "No video", code: 1) }
        let range = try await track.load(.timeRange)
        let composition = AVMutableComposition()
        let dest = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try dest.insertTimeRange(range, of: track, at: .zero)
        print("AVFoundation source duration \(range.duration.seconds); inserted successfully")
        withExtendedLifetime(asset) {}
        } catch {
            let e = error as NSError
            print("AVFoundation probe failed: \(e.domain) \(e.code)")
            exit(1)
        }
    }
}
