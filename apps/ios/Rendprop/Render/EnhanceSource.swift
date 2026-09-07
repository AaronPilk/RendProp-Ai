import AVFoundation
import CoreGraphics
import Foundation

/// The file the AI-enhance stage actually uploads to the public renders bucket,
/// plus the numbers `/ai-video/drone` needs to size the upscale correctly.
///
/// WHY THIS EXISTS — the 4,000 sq ft field test. `RenderCoordinator.enhance`
/// used to upload `tour.url` — the finished on-device master — straight to
/// `/ai-video/drone`. That route is a Topaz UPSCALE: its entire job is to make
/// a smaller frame bigger. Handing it the largest frame we have is backwards
/// three times over:
///
///   1. BYTES. A 4K master is ~4× the pixels of a 1080p one, so ~4× the upload
///      over a phone connection. The field test spent 22 minutes on a 343 MB
///      upload, on 5G, walking a house — and never finished.
///   2. COST. Topaz bills per OUTPUT second and fal charges for the transfer;
///      none of the extra input pixels buy anything.
///   3. UPSCALE FACTOR — the one that actually degrades the result. The server
///      derives the factor from the SOURCE's long edge
///      (services/supabase/functions/ai-video/index.ts, POST /drone):
///
///          upscale = clamp(round(tierLongEdge / srcLongEdge), 1, 4)
///
///      Both 4K tiers target a 3840 long edge, so a source that is ALREADY at
///      3840 gets upscale 1 — a paid round trip through an upscaler that is
///      told not to upscale. A 1920-wide source gets a clean 2×, which is the
///      shape the model is tuned for.
///
/// WHAT IT DOES. `prepare(master:listingID:)` probes the master. At or below
/// 1080p it hands the master straight back and does no work at all. Above
/// 1080p it exports a 1080p-max H.264 intermediate and hands that back instead,
/// along with the probed dimensions and frame rate of whichever file it chose.
///
/// WHAT IT MUST NOT BREAK. `enhance()` swaps the Topaz result in under the
/// SAME `durationS`/`speedFactor` as the master, and the published tour's
/// chapters are room-tag timestamps rescaled onto that timeline
/// (`AppModel.chapters(from:speedFactor:)`). The comment in `enhance()` —
/// "same duration/speed — Topaz preserves duration, so chapter timestamps stay
/// valid" — therefore has to stay true of the file we hand Topaz as well.
/// `AVAssetExportSession` re-encodes frames; it does not retime them. Every
/// sample keeps its presentation timestamp, the track keeps its cadence, and
/// audio (if the file has any — today's RenderEngine output does not) is
/// carried through. Duration in equals duration out.
///
/// THIS IS AN OPTIMISATION, NEVER A NEW FAILURE MODE. Every failure path — an
/// unreadable master, no exporter for the preset, not enough free disk, a
/// failed or cancelled export — returns the master unchanged, so the enhance
/// behaves exactly as it did before this file existed.
///
/// Deliberately a plain, NON-ISOLATED value type. It is called from the
/// `@MainActor` RenderCoordinator but does all of its work off the main actor,
/// and it touches no app state — so nothing here may acquire a global actor
/// (a `@MainActor` static helper reached from a non-isolated context is exactly
/// the mistake that broke an earlier build).
struct EnhanceSource: Sendable {

    /// The file to upload to the renders bucket.
    let url: URL

    /// True when `url` is a temp intermediate this helper wrote.
    ///
    /// Two obligations for the caller, both load-bearing:
    ///  • `cleanUp()` it once the upload finishes, success or failure.
    ///  • NEVER hand its server asset id back as the master's. It is a
    ///    DIFFERENT file: `RenderCoordinator.enhance` returns the uploaded
    ///    asset id as `masterAssetID` so a fallback publish can reuse it
    ///    instead of re-uploading, and reusing the intermediate's id would
    ///    publish the 1080p intermediate in place of the master the user
    ///    rendered.
    let isIntermediate: Bool

    /// `url`'s DISPLAY-oriented pixel size and frame rate (preferredTransform
    /// applied, so a portrait capture reports 1080×1920, not 1920×1080).
    ///
    /// These are threaded into the upload metadata → `capture_assets.width /
    /// height / fps` → the drone route's `upscale` factor and its "does this
    /// need frame interpolation" decision. Before this, `enhance` sent duration
    /// and bytes only: with no dimensions the server falls back to a flat
    /// upscale of 2 for the 4K tiers, which on the app's own render master
    /// lands at 2560 — the "4K Premium" tier quietly delivering less than 4K.
    /// Nil when the file could not be probed; the server then keeps that same
    /// fallback, i.e. exactly today's behaviour.
    let width: Int?
    let height: Int?
    let fps: Double?

    /// Delete the temp intermediate. No-op when `url` IS the master (deleting
    /// that would take the user's tour with it), and safe to call repeatedly —
    /// the caller deletes eagerly after the upload and again on the way out.
    func cleanUp() {
        guard isIntermediate else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Preparation

    /// A 1080p ceiling, in DISPLAY orientation: long edge ≤ 1920 AND short edge
    /// ≤ 1080. Both 4K drone tiers target a 3840 long edge, so 1920 is the
    /// source size that yields a clean 2× upscale.
    private static let maxLongEdge: CGFloat = 1920
    private static let maxShortEdge: CGFloat = 1080

    /// Pick (and if necessary produce) the file to send to `/ai-video/drone`.
    /// Never throws: on any problem it returns the master unchanged.
    static func prepare(master: URL, listingID: UUID) async -> EnhanceSource {
        let asset = AVURLAsset(url: master)

        guard let source = await probe(asset) else {
            // Unreadable or odd file. Upload it exactly as before, declaring
            // nothing we did not measure.
            return EnhanceSource(url: master, isIntermediate: false,
                                 width: nil, height: nil, fps: nil)
        }

        // Whatever happens below, THIS is the safe answer.
        let masterUnchanged = EnhanceSource(url: master, isIntermediate: false,
                                            width: Int(source.size.width.rounded()),
                                            height: Int(source.size.height.rounded()),
                                            fps: source.fps)

        let longEdge = max(source.size.width, source.size.height)
        let shortEdge = min(source.size.width, source.size.height)
        // Already 1080p or smaller → no export, no temp file, no extra disk.
        // (This is the common case for today's RenderEngine, whose master is
        // capped at a 1280 long edge — see `encodeLongEdge`. The downscale
        // below only ever runs if that ceiling is raised, or if a future master
        // arrives from somewhere else.)
        guard longEdge > maxLongEdge || shortEdge > maxShortEdge else { return masterUnchanged }

        // Room to write it? The export is at worst the size of the master.
        // Running out of disk mid-export would fail the enhance for a saving —
        // exactly the trade this helper must never make.
        let masterBytes = FileStore.fileSize(master)
        guard FileStore.freeSpaceBytes() > masterBytes + 250_000_000 else { return masterUnchanged }

        let out = intermediateURL(for: listingID)
        try? FileManager.default.removeItem(at: out)   // a leftover from a killed run

        // H.264, not HEVC: fal fetches this over plain HTTP and hands it to a
        // provider we do not control. H.264 in an mp4 is the one combination
        // every decoder in that chain reads. The preset scales to FIT
        // 1920×1080 preserving aspect ratio (a portrait master lands at
        // 1080×1920) and leaves timing alone.
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPreset1920x1080) else {
            return masterUnchanged
        }
        export.outputURL = out
        export.outputFileType = .mp4
        // fal streams this from our bucket: moov atom at the front so the
        // provider can start reading without pulling the whole file first.
        export.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }

        guard export.status == .completed, FileStore.fileSize(out) > 0 else {
            try? FileManager.default.removeItem(at: out)   // never leave a partial file behind
            return masterUnchanged
        }

        // Declare the dimensions of the file we are ACTUALLY uploading. If the
        // written file can't be re-probed, fall back to the master's frame rate
        // (the export preserves cadence) and send no dimensions rather than
        // numbers we did not measure.
        let written = await probe(AVURLAsset(url: out))
        return EnhanceSource(url: out, isIntermediate: true,
                             width: written.map { Int($0.size.width.rounded()) },
                             height: written.map { Int($0.size.height.rounded()) },
                             fps: written?.fps ?? source.fps)
    }

    /// `Recordings/enhanced-<listingID>-source.mp4`.
    ///
    /// Under DOCUMENTS, not Caches, and that is load-bearing: `UploadManager`
    /// persists an upload's path RELATIVE TO DOCUMENTS
    /// (`FileStore.relativePath(for:)`) and rebuilds it as
    /// `FileStore.documents/<relPath>` on every resume and relaunch. A file
    /// outside Documents relativizes to its bare filename and would resume
    /// against a path that does not exist.
    ///
    /// The `enhanced-<id>` prefix is deliberate too — `FileStore
    /// .deleteListingFiles` sweeps that prefix out of Recordings, so deleting
    /// the listing mid-enhance cannot strand a few hundred MB. The `-source`
    /// suffix keeps it distinct from the enhanced RESULT
    /// (`enhanced-<id>.mp4`), which `enhance()` writes and must never clobber.
    private static func intermediateURL(for listingID: UUID) -> URL {
        FileStore.recordingsDir.appendingPathComponent("enhanced-\(listingID.uuidString)-source.mp4")
    }

    // MARK: - Probe

    private struct Probe: Sendable {
        let size: CGSize      // display-oriented (preferredTransform applied)
        let fps: Double?
    }

    /// Display size + nominal frame rate, or nil when the file has no readable
    /// video track. Same shape as `FlythroughDetailView.isPortraitVideo`.
    private static func probe(_ asset: AVURLAsset) async -> Probe? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        guard let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let w = abs(rect.width), h = abs(rect.height)
        guard w.isFinite, h.isFinite, w >= 2, h >= 2 else { return nil }
        var fps: Double? = nil
        if let nominal = try? await track.load(.nominalFrameRate), nominal.isFinite, nominal > 0 {
            fps = Double(nominal)
        }
        return Probe(size: CGSize(width: w, height: h), fps: fps)
    }
}
