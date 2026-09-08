import AVFoundation
import Foundation
import UIKit

// The quality gate, on the client side of it.
//
// THE DEFECT the audit named: `POST /ai-video/drift` exists, is fully built,
// runs `judge.qc_drift` over five axes, records a compliance row and returns a
// verdict — and NOTHING IN THIS APP HAS EVER CALLED IT. The status route
// reports every clip as `drift: { status: "unchecked", publishable: false }`,
// exactly and honestly, and the app downloaded and used the clip anyway. A
// judge with no door in front of it is a comment with a database bill.
//
// That gate was written for the owner's own report: "the photo to reel
// generator is changing how the house looks and that's false advertising — it
// has AI slop left over." On a real listing that is a CA AB 723 / MLS / HUD
// problem before it is an aesthetic one. Shipping the judge and not calling it
// left the problem exactly where it was.
//
// WHAT THIS FILE IS. The two things the client owes the server: the frames
// (an edge function cannot decode an mp4 — see the QUALITY GATE note in
// ai-video/index.ts) and the decision to actually ask. Everything else — the
// rubric, the model, the thresholds, the retry accounting, the audit row —
// stays server-side, which is the only place a tenant cannot write a passing
// verdict about their own listing media.
//
// FAIL CLOSED, DELIBERATELY. A check that could not run is `.unavailable`, and
// `.unavailable` is NOT a pass. The caller holds the clip rather than
// publishing it, because "we could not tell whether the AI changed the house"
// and "the AI did not change the house" are not the same sentence to a broker.

/// Three frames of a finished clip, as the drift route wants them.
enum ClipFrames {
    /// first / middle / last, JPEG, long edge 768.
    ///
    /// 768 rather than full size on purpose: the judge is looking for
    /// architecture that moved, contents that appeared and warped geometry,
    /// all of which survive a downscale — and three full-resolution frames of
    /// base64 is megabytes of upload from a phone for no extra signal.
    ///
    /// Tolerances are asymmetric at the ends: the first frame asks for 0.1 s
    /// (never 0, which some decoders answer with a black frame) and the last
    /// asks a tenth of a second BEFORE the end, because generated clips
    /// routinely finish on a partial frame.
    static func extract(from url: URL) async -> [(at: String, jpeg: Data)] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.seconds.isFinite, duration.seconds > 0.3 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 768, height: 768)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        let d = duration.seconds
        let marks: [(String, Double)] = [
            ("first",  min(0.1, d * 0.05)),
            ("middle", d * 0.5),
            ("last",   max(0.1, d - 0.1)),
        ]
        var out: [(at: String, jpeg: Data)] = []
        for (name, seconds) in marks {
            let t = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let result = try? await gen.image(at: t) else { continue }
            let cg = result.image
            let data: Data? = await Task.detached(priority: .userInitiated) {
                UIImage(cgImage: cg).jpegData(compressionQuality: 0.72)
            }.value
            if let data { out.append((at: name, jpeg: data)) }
        }
        return out
    }
}

/// What the server decided. Mirrors the `drift` block of
/// `POST /ai-video/drift` (services/supabase/functions/ai-video/index.ts) and
/// `_shared/drift.ts`, decoded tolerantly: an unknown status is treated as
/// `.unavailable`, which holds — never as a pass.
struct DriftVerdict: Sendable, Equatable {
    enum Status: String, Sendable {
        case pass, fail, unavailable
    }
    let status: Status
    /// The server's own answer, never derived here. A client that computed its
    /// own `publishable` from the scores would be a second policy to keep in
    /// step with the first.
    let publishable: Bool
    /// Closed vocabulary from the server ("publish", "retry", "reject", "hold").
    let action: String
    /// The sentence to show the agent. Already written for a person.
    let message: String
    let reason: String?

    /// The one thing every caller asks. A verdict that is not an explicit pass
    /// does not open the door.
    var mayUse: Bool { status == .pass && publishable }

    /// What to say when it did not pass. The server's message when there is
    /// one, because it names the actual failure ("the roofline changed"), and a
    /// plain fallback when there is not.
    var refusal: String {
        if !message.isEmpty { return message }
        switch status {
        case .fail:
            return "The AI changed how the house looks, so this clip wasn't kept. "
                 + "Your photo is untouched — try again, or use the still."
        case .unavailable, .pass:
            return "The quality check couldn't run, so this clip is being held rather than published. "
                 + "Your photo is untouched. Try again in a moment."
        }
    }
}

/// What the drift route needs. `sourceBase64` and `frames` are the only
/// required fields — the still that is the ground truth, and the frames on
/// trial. Everything else sharpens the rubric or files the audit row.
struct DriftCheckRequest: Sendable {
    var requestID: String
    /// "reel" | "aerial"
    var kind: String
    var sourceBase64: String
    var sourceMime: String = "image/jpeg"
    var frames: [(at: String, jpeg: Data)]
    var seconds: Int?
    var motion: String?
    var room: String?
    var spaceType: String?
    var listingServerID: UUID?
    var provenanceID: String?
    var attempt: Int = 1
}
