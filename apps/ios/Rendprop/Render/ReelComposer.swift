import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore
import UIKit

// MARK: - Reel composer (the on-device edit: cut, pace, caption, export)
//
// Everything that turns a pile of finished clips into ONE video a realtor would
// actually post. It used to live inline in `ReelStudioView` as `stitch(clips:)`
// and did the minimum: equal-length clips back to back, one audio track at zero,
// hold the last frame if the voice ran long. That still happens — it is the
// default and it is bit-for-bit what it was — but the composer now also does the
// three things that separate a reel that looks made from one that looks
// generated:
//
//   1. BIG SHOT CAPTIONS. Three to five words, upper case, heavy, held for the
//      whole shot. NOT the word-by-word voiceover track (that is
//      `CaptionRenderer`, and both can run at once — see `buildOverlay`).
//   2. VARIED PACE. A hero shot holds, a detail flicks past. Per-shot on-screen
//      length and rate, done with `scaleTimeRange` on the composition track so
//      the retime happens in the composition's own time base and the voiceover —
//      which is NEVER retimed — stays exactly where it was mixed.
//   3. TRANSITIONS, GRUDGINGLY. A hard cut is right almost every time. There are
//      two alternatives and there will never be a third; read `Transition`.
//
// WHY IT IS A FILE AND NOT A VIEW MEMBER: an `AVMutableComposition` export has no
// business on the main actor, and `ReelStudioView` — like every SwiftUI `View` —
// is `@MainActor`. Every entry point here is a plain `enum` member at file scope,
// so it is non-isolated by construction and cannot accidentally be inferred onto
// the main actor the way a static on a `View` is. (That exact mistake has already
// broken this build once: `GearStore.normalizedASIN`.)
//
// NEW FILE — the Xcode project is generated from `apps/ios/project.yml`, whose
// `Rendprop` target takes the whole `Rendprop` folder, so this needs a
// `xcodegen generate` before it is in the target.

/// The text burned onto the front of a reel: the address, the facts line under
/// it, and the small corner mark. Plain `Sendable` strings resolved on the main
/// actor by the caller — the CALayers are built down here, right before the
/// export, and are never attached to a live view tree.
struct ReelTitleCard: Sendable, Hashable {
    /// Listing address (or a safe hook — never empty).
    let title: String
    /// Beds/baths/sqft or the tagline. "" hides the line entirely.
    let subtitle: String
    /// "Made with Rendprop".
    let watermark: String

    init(title: String, subtitle: String, watermark: String) {
        self.title = title
        self.subtitle = subtitle
        self.watermark = watermark
    }
}

enum ReelComposer {

    // MARK: - What the caller describes

    /// One shot in the reel.
    ///
    /// `ReelComposer.Shot(url: x)` and nothing else is EXACTLY the old
    /// behaviour: the whole clip, at its own length, at 1×, with no caption. Every
    /// other field is an opt-in, and the defaults are chosen so that a caller who
    /// knows nothing about pacing gets the reel it always got.
    struct Shot: Sendable, Hashable {
        /// A finished mp4 on disk.
        var url: URL
        /// How long this shot is ON SCREEN, in seconds. `nil` = the clip's own
        /// length, untouched.
        ///
        /// Shorter than the clip → the clip is TRIMMED (a cut is cleaner than a
        /// speed-up for a two-second beat). Longer → the clip is SLOWED with
        /// `scaleTimeRange` so it holds, clamped by `speedFloor` because a 5 s
        /// clip stretched to 20 s judders and looks broken, not luxurious.
        var seconds: Double?
        /// An explicit playback rate. `nil` = the composer picks one from
        /// `seconds`. 0.5 is half speed (a hold), 2 is double (a flick).
        /// Clamped to `speedFloor…speedCeiling`.
        var speed: Double?
        /// The big burned-in caption for this shot — three to five words, in the
        /// agent's own language ("CHEF'S KITCHEN", "WALK TO THE BEACH"). Upper-
        /// cased and word-capped by the renderer, so pass it as written.
        /// `nil` or blank = no caption on this shot.
        var caption: String?

        init(url: URL, seconds: Double? = nil, speed: Double? = nil, caption: String? = nil) {
            self.url = url
            self.seconds = seconds
            self.speed = speed
            self.caption = caption
        }
    }

    /// What goes BETWEEN two shots.
    ///
    /// READ THIS BEFORE ADDING A THIRD CASE. A hard cut is the correct answer
    /// most of the time. Every reel that reads as amateur is over-transitioned,
    /// not under-transitioned: the cut is what the eye reads as confidence, and a
    /// wipe/spin/cube between every room is the single loudest tell that a video
    /// was assembled by somebody who had the buttons rather than the eye. These
    /// two exist because a dissolve genuinely helps between two static interiors
    /// and a swipe genuinely helps when the pace is meant to snap. That is the
    /// whole list. Adding more will make the output WORSE, not richer.
    enum Transition: String, Sendable, CaseIterable {
        /// The default, and the right answer. No overlap, one video track.
        case cut
        /// A fast cross-dissolve. Short on purpose — a slow dissolve reads as a
        /// screensaver.
        case dissolve
        /// A horizontal swipe: the outgoing shot slides off left while the next
        /// one comes in from the right. Layer-instruction transform ramps cannot
        /// produce real motion blur, so this is the honest shape of a whip pan
        /// rather than a whip pan; kept very short so the eye reads speed.
        case whip

        /// How long the overlap runs. Both are deliberately under a third of a
        /// second.
        var seconds: Double {
            switch self {
            case .cut:      return 0
            case .dissolve: return 0.28
            case .whip:     return 0.18
            }
        }
    }

    /// How the big shot captions look. Three, because a realtor picking a look
    /// wants to see the difference at a glance; more than three is a settings
    /// screen, and a settings screen is where features go to be ignored.
    enum ShotCaptionStyle: String, Sendable, CaseIterable {
        /// No shot captions at all (the voiceover's word captions, if any, are
        /// unaffected).
        case off
        /// Clean bold lower-third: heavy white type on the left, a short accent
        /// bar beside it, black halo so it reads over anything.
        case lowerThird
        /// A centred punch card — the biggest type, middle of frame, the way a
        /// hook lands on the first shot of a feed video.
        case punchCard
        /// Highlight box: each row sits in a filled brand-purple slab. The most
        /// legible of the three over bright or busy footage, because it does not
        /// depend on the halo at all.
        case highlightBox

        var isOn: Bool { self != .off }
    }

    /// Everything optional about a compose. An `Options()` with nothing set is,
    /// deliberately and exactly, the old `stitch()`.
    struct Options: Sendable {
        /// Intro title card + the persistent corner mark. `nil` = neither.
        var titleCard: ReelTitleCard?
        /// Mixed onto its own audio track at time ZERO. See `holdLastFrame` for
        /// the video-length-wins guarantee.
        var voiceover: Voiceover?
        /// The word-by-word spoken captions drawn by `CaptionRenderer`. `.off`
        /// draws none.
        var captionStyle: CaptionStyle = .off
        /// The big per-shot captions drawn by this file. `.off` draws none.
        var shotCaptionStyle: ShotCaptionStyle = .off
        /// Defaults to `.cut`, and should usually stay there.
        var transition: Transition = .cut

        init(titleCard: ReelTitleCard? = nil, voiceover: Voiceover? = nil,
             captionStyle: CaptionStyle = .off,
             shotCaptionStyle: ShotCaptionStyle = .off,
             transition: Transition = .cut) {
            self.titleCard = titleCard
            self.voiceover = voiceover
            self.captionStyle = captionStyle
            self.shotCaptionStyle = shotCaptionStyle
            self.transition = transition
        }
    }

    /// Failures a person reads. The wording of the first three is unchanged from
    /// the inline `stitch()` they replace — these strings have already been in
    /// front of users.
    enum ComposeError: LocalizedError {
        case badRenderSize
        case noComposition
        case noClips
        case noExporter
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .badRenderSize: return "Couldn't work out the video size."
            case .noComposition: return "Couldn't start the video composition."
            case .noClips:       return "No usable clips to stitch."
            case .noExporter:    return "Couldn't create the video exporter."
            case .exportFailed:  return "Couldn't export the stitched reel."
            }
        }
    }

    // MARK: Tunables

    /// A clip slowed past this judders — AVFoundation is repeating frames, not
    /// interpolating them.
    private static let speedFloor: Double = 0.4
    /// Past this a 5 s clip is a blur with no shot in it.
    private static let speedCeiling: Double = 2.5
    /// Output cadence. 30, as it has always been — the AI clips arrive at 24–30
    /// and re-timing them to 60 buys nothing but file size.
    private static let frameDuration = CMTime(value: 1, timescale: 30)
    /// Everything computed in seconds lands on this timescale. Durations we did
    /// NOT compute (a clip used whole) keep the source's own timescale, so the
    /// no-options path re-quantises nothing.
    private static let timescale: CMTimeScale = 600

    // MARK: - Entry points

    /// Source-compatible with the `stitch(clips:renderSize:captions:voiceover:captionStyle:output:)`
    /// this file replaced, and it produces the identical file: equal-length
    /// clips back to back, hard cuts, the voiceover at zero, the last frame held
    /// if the voice runs long, nothing retimed.
    static func stitch(clips: [URL], renderSize: CGSize,
                       titleCard: ReelTitleCard?, voiceover: Voiceover?,
                       captionStyle: CaptionStyle, output: URL) async throws {
        try await compose(shots: clips.map { Shot(url: $0) },
                          renderSize: renderSize,
                          options: Options(titleCard: titleCard, voiceover: voiceover,
                                           captionStyle: captionStyle),
                          output: output)
    }

    /// Build the reel and export it to `output` (mp4, overwritten).
    ///
    /// Every clip is aspect-FILLED (scale to cover + centre-crop) with a layer
    /// instruction transform computed from its track's naturalSize +
    /// preferredTransform, so portrait / rotated sources render upright.
    ///
    /// THE GUARANTEE THE OLD `stitch()` DOCUMENTED, KEPT WORD FOR WORD:
    /// `voiceover` is mixed onto a new AUDIO track at time zero. VIDEO LENGTH
    /// WINS — if the voiceover runs longer than the stitched clips the last video
    /// frame is HELD for the remainder (never truncating the speaker); if it runs
    /// shorter the reel ends with silence. Neither is ever speed-changed. All
    /// three states export cleanly: no voiceover; voiceover with words; voiceover
    /// with empty words (no captions).
    ///
    /// The per-shot retiming added here does NOT touch that: retiming is applied
    /// to the VIDEO track only, before the voiceover is mixed, so "video length"
    /// simply means the length after the shots were paced. The voice always plays
    /// at its true rate.
    static func compose(shots: [Shot], renderSize: CGSize,
                        options: Options = Options(), output: URL) async throws {
        guard renderSize.width.isFinite, renderSize.height.isFinite,
              renderSize.width >= 16, renderSize.height >= 16 else {
            throw ComposeError.badRenderSize
        }

        let prepared = await prepare(shots, renderSize: renderSize)
        guard !prepared.isEmpty else { throw ComposeError.noClips }

        // A/B layout first when transitions were asked for; hard cuts otherwise,
        // and hard cuts again if the A/B layout couldn't be built. The fallback
        // starts from a FRESH composition so a half-built two-track layout can
        // never leak into the file the agent gets.
        var composition = AVMutableComposition()
        var attempt: Layout? = nil
        if options.transition != .cut, prepared.count >= 2 {
            attempt = layoutTransitions(prepared, transition: options.transition,
                                        renderSize: renderSize, into: composition)
        }
        if attempt == nil {
            composition = AVMutableComposition()
            attempt = layoutCuts(prepared, into: composition)
        }
        guard let laidOut = attempt, laidOut.videoDuration > .zero, !laidOut.segments.isEmpty else {
            throw ComposeError.noClips
        }
        var layout = laidOut

        // ---- Voiceover audio track (optional) ----
        // Its OWN track, at time zero; the clips carry no audio of their own on
        // this path, so nothing is being displaced. A voiceover whose file can't
        // be read must NOT sink the reel — it just exports silent, exactly as if
        // none had been chosen.
        let audio = await mixVoiceover(options.voiceover, into: composition)

        // ---- Video length wins ----
        if audio.inserted, audio.duration > layout.videoDuration {
            holdLastFrame(&layout, upTo: audio.duration, track: audio.track)
        }

        // ---- Instructions ----
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for segment in layout.segments {
            guard segment.end > segment.start else { continue }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: segment.start,
                                                duration: CMTimeSubtract(segment.end, segment.start))
            instruction.layerInstructions = segment.layers as [AVVideoCompositionLayerInstruction]
            instructions.append(instruction)
        }
        guard !instructions.isEmpty else { throw ComposeError.noClips }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration
        videoComposition.instructions = instructions

        if let overlay = buildOverlay(options: options, captions: layout.captions,
                                      renderSize: renderSize, hasAudio: audio.inserted) {
            videoComposition.animationTool = overlay
        }

        try await export(composition: composition, videoComposition: videoComposition, to: output)
    }

    // MARK: - Pass 1: read every clip, resolve its length and its rate

    /// One clip, read and resolved. Non-isolated value work plus AVFoundation
    /// loads; no UI, no main actor.
    private struct Prepared {
        let track: AVAssetTrack
        /// The slice of the SOURCE we insert.
        let srcRange: CMTimeRange
        /// How long that slice is on screen after `speed`.
        let onScreen: CMTime
        let speed: Double
        let transform: CGAffineTransform
        let caption: String?
    }

    private static func prepare(_ shots: [Shot], renderSize: CGSize) async -> [Prepared] {
        var out: [Prepared] = []
        for shot in shots {
            do {
                let asset = AVURLAsset(url: shot.url)
                guard let src = try await asset.loadTracks(withMediaType: .video).first else { continue }
                let (naturalSize, preferredTransform) = try await src.load(.naturalSize, .preferredTransform)
                let full = try await src.load(.timeRange)
                let sourceSeconds = full.duration.seconds
                guard full.duration > .zero, sourceSeconds.isFinite, sourceSeconds > 0.01 else { continue }

                // Resolve rate and slice. The ONLY branch that leaves both alone
                // is "no seconds, no speed" — the default — and it keeps the
                // source's own CMTime untouched rather than re-deriving it from
                // a Double, so a clip used whole is inserted at exactly the
                // duration AVFoundation reported.
                var speed: Double = 1
                var useSeconds = sourceSeconds
                if let target = shot.seconds, target.isFinite, target > 0.05 {
                    if let explicit = shot.speed, explicit.isFinite, explicit > 0 {
                        speed = clampSpeed(explicit)
                        useSeconds = min(sourceSeconds, target * speed)
                    } else if target < sourceSeconds {
                        useSeconds = target                                 // trim: a cut, not a speed-up
                    } else {
                        speed = clampSpeed(sourceSeconds / target)          // hold: slow it down
                    }
                } else if let explicit = shot.speed, explicit.isFinite, explicit > 0 {
                    speed = clampSpeed(explicit)
                }

                var srcDuration = full.duration
                if useSeconds < sourceSeconds - 0.001 {
                    srcDuration = CMTime(seconds: useSeconds, preferredTimescale: timescale)
                }
                guard srcDuration > .zero else { continue }
                let onScreen = speed == 1
                    ? srcDuration
                    : CMTime(seconds: srcDuration.seconds / speed, preferredTimescale: timescale)
                guard onScreen > .zero else { continue }

                let caption = shot.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(Prepared(track: src,
                                    srcRange: CMTimeRange(start: full.start, duration: srcDuration),
                                    onScreen: onScreen,
                                    speed: speed,
                                    transform: fillTransform(naturalSize: naturalSize,
                                                             preferredTransform: preferredTransform,
                                                             renderSize: renderSize),
                                    caption: (caption?.isEmpty == false) ? caption : nil))
            } catch {
                continue   // unreadable clip — skip it; the reel uses the rest
            }
        }
        return out
    }

    private static func clampSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(speedCeiling, max(speedFloor, value))
    }

    // MARK: - Pass 2: place the shots

    /// One stretch of the timeline and the layers visible across it. The
    /// segments must TILE `[0, total]` exactly — a gap renders as black frames
    /// and an overlap is undefined — so every boundary below is derived from the
    /// one before it rather than recomputed.
    private struct Segment {
        var start: CMTime
        var end: CMTime
        var layers: [AVMutableVideoCompositionLayerInstruction]
    }

    /// Where a shot's caption sits on the finished timeline.
    struct ShotCaption: Sendable, Hashable {
        let text: String
        let start: Double
        let duration: Double
    }

    private struct Layout {
        var videoDuration: CMTime = .zero
        var segments: [Segment] = []
        var captions: [ShotCaption] = []
        /// The composition track the reel ENDS on, and the source slice of its
        /// final shot — everything the freeze-frame hold needs.
        var tailTrack: AVMutableCompositionTrack?
        var lastSrcTrack: AVAssetTrack?
        var lastSrcRange: CMTimeRange = .zero
    }

    /// Hard cuts: ONE video track, ONE instruction, and a single layer
    /// instruction whose transform is re-keyed at each clip boundary. This is
    /// the old `stitch()` body, and with no per-shot options set it does exactly
    /// what it did — insert, key the transform, advance. It is kept structurally
    /// separate from the A/B path on purpose: the default output must not
    /// inherit the risk of a layout it never uses.
    private static func layoutCuts(_ prepared: [Prepared],
                                   into composition: AVMutableComposition) -> Layout? {
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)

        var layout = Layout()
        var cursor = CMTime.zero
        var inserted = 0
        for p in prepared {
            do {
                try videoTrack.insertTimeRange(p.srcRange, of: p.track, at: cursor)
            } catch {
                continue   // unreadable clip — skip it; the reel uses the rest
            }
            // Only ever called when a rate was actually asked for, so the
            // untouched path never goes near the composition's time mapping.
            if p.speed != 1 {
                videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: p.srcRange.duration),
                                          toDuration: p.onScreen)
            }
            layerInstruction.setTransform(p.transform, at: cursor)
            if let caption = p.caption {
                layout.captions.append(ShotCaption(text: caption, start: cursor.seconds,
                                                   duration: p.onScreen.seconds))
            }
            cursor = CMTimeAdd(cursor, p.onScreen)
            layout.lastSrcTrack = p.track
            layout.lastSrcRange = p.srcRange
            inserted += 1
        }
        guard inserted > 0, cursor > .zero else { return nil }
        layout.videoDuration = cursor
        layout.tailTrack = videoTrack
        layout.segments = [Segment(start: .zero, end: cursor, layers: [layerInstruction])]
        return layout
    }

    /// A/B tracks with overlapping shots. Returns nil if anything at all goes
    /// wrong, and the caller then rebuilds the reel with hard cuts — a reel that
    /// ships without its dissolve beats a reel that does not ship.
    private static func layoutTransitions(_ prepared: [Prepared], transition: Transition,
                                          renderSize: CGSize,
                                          into composition: AVMutableComposition) -> Layout? {
        guard prepared.count >= 2, transition != .cut else { return nil }
        guard let trackA = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let trackB = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let tracks = [trackA, trackB]

        // How much each pair overlaps. Capped at a third of EITHER neighbour so
        // a short detail shot can never be swallowed whole by its two
        // transitions — that cap is also what guarantees every shot keeps a
        // non-empty stretch of screen to itself below.
        let nominal = transition.seconds
        var overlaps: [CMTime] = []
        for i in 0..<(prepared.count - 1) {
            let seconds = min(nominal,
                              prepared[i].onScreen.seconds / 3,
                              prepared[i + 1].onScreen.seconds / 3)
            overlaps.append(seconds > 0.06 ? CMTime(seconds: seconds, preferredTimescale: timescale) : .zero)
        }

        // Place: shot i starts where shot i-1 ends MINUS their overlap.
        var starts: [CMTime] = []
        var cursor = CMTime.zero
        for (i, p) in prepared.enumerated() {
            let track = tracks[i % 2]
            do {
                try track.insertTimeRange(p.srcRange, of: p.track, at: cursor)
            } catch {
                return nil   // fall back to cuts rather than ship a hole
            }
            if p.speed != 1 {
                track.scaleTimeRange(CMTimeRange(start: cursor, duration: p.srcRange.duration),
                                     toDuration: p.onScreen)
            }
            starts.append(cursor)
            let overlap = i < overlaps.count ? overlaps[i] : .zero
            cursor = CMTimeSubtract(CMTimeAdd(cursor, p.onScreen), overlap)
        }
        guard let lastStart = starts.last, let lastShot = prepared.last else { return nil }
        let total = CMTimeAdd(lastStart, lastShot.onScreen)
        guard total > .zero else { return nil }

        var layout = Layout()
        layout.videoDuration = total
        layout.tailTrack = tracks[(prepared.count - 1) % 2]
        layout.lastSrcTrack = lastShot.track
        layout.lastSrcRange = lastShot.srcRange

        let slideOut = CGAffineTransform(translationX: -renderSize.width, y: 0)
        let slideIn = CGAffineTransform(translationX: renderSize.width, y: 0)

        for (i, p) in prepared.enumerated() {
            let track = tracks[i % 2]
            let incomingOverlap = i > 0 ? overlaps[i - 1] : .zero
            let outgoingOverlap = i < overlaps.count ? overlaps[i] : .zero
            let bodyStart = CMTimeAdd(starts[i], incomingOverlap)
            let bodyEnd = CMTimeSubtract(CMTimeAdd(starts[i], p.onScreen), outgoingOverlap)

            if bodyEnd > bodyStart {
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                li.setTransform(p.transform, at: bodyStart)
                li.setOpacity(1, at: bodyStart)
                layout.segments.append(Segment(start: bodyStart, end: bodyEnd, layers: [li]))
            }
            if let caption = p.caption {
                layout.captions.append(ShotCaption(text: caption, start: starts[i].seconds,
                                                   duration: p.onScreen.seconds))
            }

            // The overlap itself: BOTH tracks visible, outgoing first. The first
            // layer instruction in an AVFoundation instruction is the frontmost
            // one, which is why the outgoing shot is the one that fades (or
            // slides) and the incoming shot simply sits behind it.
            guard i < prepared.count - 1, outgoingOverlap > .zero else { continue }
            let next = prepared[i + 1]
            let nextTrack = tracks[(i + 1) % 2]
            let range = CMTimeRange(start: bodyEnd, duration: outgoingOverlap)

            let out = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            let into = AVMutableVideoCompositionLayerInstruction(assetTrack: nextTrack)
            switch transition {
            case .cut:
                continue
            case .dissolve:
                out.setTransform(p.transform, at: bodyEnd)
                out.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: range)
                into.setTransform(next.transform, at: bodyEnd)
                into.setOpacity(1, at: bodyEnd)
            case .whip:
                // Pure translation, post-multiplied onto the fill transform, so
                // only tx/ty change: AVFoundation interpolates the matrix
                // component-wise, and a ramp that also changed scale or rotation
                // would shear a rotated source part-way through.
                out.setTransformRamp(fromStart: p.transform,
                                     toEnd: p.transform.concatenating(slideOut),
                                     timeRange: range)
                out.setOpacity(1, at: bodyEnd)
                into.setTransformRamp(fromStart: next.transform.concatenating(slideIn),
                                      toEnd: next.transform,
                                      timeRange: range)
                into.setOpacity(1, at: bodyEnd)
            }
            layout.segments.append(Segment(start: bodyEnd,
                                           end: CMTimeAdd(bodyEnd, outgoingOverlap),
                                           layers: [out, into]))
        }

        layout.segments.sort { $0.start < $1.start }
        guard let first = layout.segments.first, first.start == .zero else { return nil }
        return layout
    }

    // MARK: - Voiceover

    private struct MixedAudio {
        var inserted = false
        var duration = CMTime.zero
        var track: AVMutableCompositionTrack?
    }

    private static func mixVoiceover(_ voiceover: Voiceover?,
                                     into composition: AVMutableComposition) async -> MixedAudio {
        var mixed = MixedAudio()
        guard let voiceover else { return mixed }
        do {
            let audioAsset = AVURLAsset(url: voiceover.audioURL)
            guard let audioSrc = try await audioAsset.loadTracks(withMediaType: .audio).first,
                  let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return mixed
            }
            let audioRange = try await audioSrc.load(.timeRange)
            guard audioRange.duration > .zero else { return mixed }
            try audioTrack.insertTimeRange(
                CMTimeRange(start: audioRange.start, duration: audioRange.duration),
                of: audioSrc, at: .zero)
            mixed.inserted = true
            mixed.duration = audioRange.duration
            mixed.track = audioTrack
        } catch {
            return MixedAudio()   // silent reel rather than a failed one
        }
        return mixed
    }

    /// The voiceover runs longer than the pictures. Take the last shot's final
    /// frame (a ~1-frame source slice), insert it once at the end, then scale
    /// THAT single still to fill the remainder. Scaling one static frame is a
    /// freeze-frame hold — no motion is sped up or slowed, and the spoken audio
    /// still plays at its true rate.
    ///
    /// If the hold can't be made — the still slice came out empty, the insert
    /// threw, or there is no source track to freeze — the video CANNOT be
    /// stretched to meet the audio, so the audio is TRIMMED back to meet the
    /// video instead. Leaving both alone would end the reel on a stretch of
    /// uncovered video: black frames with a voice still talking over them.
    /// Losing the last words of a take is bad; shipping black video is worse,
    /// and this path only runs when the freeze-frame already failed.
    private static func holdLastFrame(_ layout: inout Layout, upTo audioDuration: CMTime,
                                      track audioTrack: AVMutableCompositionTrack?) {
        let videoDuration = layout.videoDuration
        if let tailTrack = layout.tailTrack, let lastSrcTrack = layout.lastSrcTrack {
            let freezeDuration = CMTimeSubtract(audioDuration, videoDuration)
            let srcEnd = CMTimeAdd(layout.lastSrcRange.start, layout.lastSrcRange.duration)
            let lastFrameStart = CMTimeMaximum(layout.lastSrcRange.start,
                                               CMTimeSubtract(srcEnd, frameDuration))
            let stillRange = CMTimeRange(start: lastFrameStart,
                                         duration: CMTimeSubtract(srcEnd, lastFrameStart))
            if stillRange.duration > .zero, freezeDuration > .zero {
                do {
                    try tailTrack.insertTimeRange(stillRange, of: lastSrcTrack, at: videoDuration)
                    tailTrack.scaleTimeRange(
                        CMTimeRange(start: videoDuration, duration: stillRange.duration),
                        toDuration: freezeDuration)
                    // The tail segment already carries the last shot's transform
                    // (keyed at its own start, and nothing is keyed after it), so
                    // extending its end is all the hold needs to be covered.
                    let total = CMTimeAdd(videoDuration, freezeDuration)
                    if !layout.segments.isEmpty {
                        layout.segments[layout.segments.count - 1].end = total
                    }
                    layout.videoDuration = total
                    return
                } catch {
                    // fall through to the trim
                }
            }
        }
        // Remove [videoDuration, audioDuration) from the audio track. That range
        // runs to the END of the track, so nothing shifts left behind it: the
        // track simply ends at videoDuration, and video and audio finish
        // together.
        audioTrack?.removeTimeRange(CMTimeRange(start: videoDuration,
                                                duration: CMTimeSubtract(audioDuration, videoDuration)))
    }

    // MARK: - Overlay (title card + shot captions + spoken-word captions)

    /// ONE `AVVideoCompositionCoreAnimationTool` for up to three independent
    /// contributors, so none of them replaces another:
    ///   1. the intro title card + persistent Rendprop mark (`titleCard`),
    ///   2. the BIG shot captions (this file), and
    ///   3. the word-by-word spoken captions from the voiceover
    ///      (`CaptionRenderer`), which need audio, words, and an enabled style.
    ///
    /// The tool wants a video layer + a parent layer (video below, overlay
    /// above), every frame equal to the render rect. It applies on EXPORT ONLY
    /// (never AVPlayer playback) — and this path only exports.
    private static func buildOverlay(options: Options, captions: [ShotCaption],
                                     renderSize: CGSize,
                                     hasAudio: Bool) -> AVVideoCompositionCoreAnimationTool? {
        let wantsWordCaptions = hasAudio && options.captionStyle.enabled
            && !(options.voiceover?.words.isEmpty ?? true)
        let shotCaptions = options.shotCaptionStyle.isOn ? captions : []
        guard options.titleCard != nil || wantsWordCaptions || !shotCaptions.isEmpty else { return nil }

        let renderRect = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = renderRect
        let overlayLayer = CALayer()
        overlayLayer.frame = renderRect
        overlayLayer.masksToBounds = true

        if let titleCard = options.titleCard {
            addTitleCardLayers(titleCard, renderSize: renderSize, to: overlayLayer)
        }
        if !shotCaptions.isEmpty {
            // `raised` lifts them out of the lower third when the spoken captions
            // are also running, because both default to the same band and two
            // stacks of heavy type on top of each other is unreadable.
            //
            // `titleCardUntil` keeps the FIRST shot's caption off the intro card.
            // The centred punch-card style sits at the same height as the
            // address, so without this the very first frame of a reel would show
            // two blocks of heavy type on each other — and the first frame is the
            // one the feed uses as the thumbnail.
            let titleCardUntil: Double = (options.titleCard == nil) ? 0 : titleCardEndsAt
            overlayLayer.addSublayer(shotCaptionLayer(shotCaptions,
                                                      style: options.shotCaptionStyle,
                                                      renderSize: renderSize,
                                                      raised: wantsWordCaptions,
                                                      titleCardUntil: titleCardUntil))
        }
        if wantsWordCaptions, let voiceover = options.voiceover {
            // The voiceover starts at reel time zero, so offset 0. CaptionRenderer
            // leaves its own root un-flipped to inherit the parent flip below.
            overlayLayer.addSublayer(CaptionRenderer.layer(words: voiceover.words, offset: 0,
                                                          renderSize: renderSize,
                                                          style: options.captionStyle))
        }

        let parentLayer = CALayer()
        parentLayer.frame = renderRect
        // Core Animation's export space is bottom-left; flipping the parent makes
        // the whole tree read top-left (UIKit-style) so the text renders upright
        // and our y-from-top layout math is literal.
        parentLayer.isGeometryFlipped = true
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(overlayLayer)
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer,
                                                   in: parentLayer)
    }

    // MARK: Big shot captions

    /// Brand purple, the brighter dark-mode variant (#9B6DFF) — the same colour
    /// `CaptionRenderer` uses for its active word, and for the same reason: it
    /// holds up against arbitrary footage far better than the light-mode purple.
    private static let accent = UIColor(red: 155 / 255, green: 109 / 255, blue: 255 / 255, alpha: 1)
    /// Never more than this many words on a shot caption. Five is the number a
    /// person reads at a glance while scrolling; a sentence is a subtitle, and a
    /// subtitle is what the voiceover captions are for.
    private static let maxCaptionWords = 5
    private static let captionFade: Double = 0.22
    /// When the intro title card has finished fading out (its fade begins at 1.6
    /// and runs 0.4 — see `addTitleCardLayers`). Nothing else may draw over that
    /// band before this.
    private static let titleCardEndsAt: Double = 2.0
    /// A caption on screen for less than this after the title card has had its
    /// turn is a flash, not a caption — it is dropped instead.
    private static let minimumCaptionOnScreen: Double = 0.5

    /// One layer holding every shot caption, each keyed to its own window. Built
    /// with `CaptionRenderer`'s primitives — the same halo-behind-white text, the
    /// same `AVCoreAnimationBeginTimeAtZero` opacity keyframe with `.both` fill
    /// and `isRemovedOnCompletion = false` — so there is one text-rendering
    /// approach in this app, not two.
    private static func shotCaptionLayer(_ captions: [ShotCaption], style: ShotCaptionStyle,
                                         renderSize: CGSize, raised: Bool,
                                         titleCardUntil: Double) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        root.masksToBounds = false
        root.isGeometryFlipped = false      // inherit the parent flip, like CaptionRenderer

        let margin = renderSize.width * 0.07
        let maxTextWidth = max(renderSize.width - margin * 2, 40)
        let nominal: CGFloat = (style == .punchCard) ? 96 : 78
        let baseSize = CaptionRenderer.scaledFontSize(nominal: nominal, renderSize: renderSize,
                                                      maxHeightFraction: 0.115)

        for caption in captions {
            let allWords = caption.text
                .uppercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            let words = Array(allWords.prefix(maxCaptionWords))
            guard !words.isEmpty, caption.duration > 0.2, caption.duration.isFinite,
                  caption.start.isFinite else { continue }

            // Shrink-to-fit, same loop CaptionRenderer uses: heavy type at five
            // words can overrun 1080 px, and a truncated caption is worse than a
            // slightly smaller one.
            var size = baseSize
            var font = UIFont.systemFont(ofSize: size, weight: .heavy)
            var rows = CaptionRenderer.wrapWords(words, font: font, maxWidth: maxTextWidth)
            var attempts = 0
            while rows.count > 2, attempts < 4, size > baseSize * 0.55 {
                size = max(size * 0.86, baseSize * 0.55)
                font = UIFont.systemFont(ofSize: size, weight: .heavy)
                rows = CaptionRenderer.wrapWords(words, font: font, maxWidth: maxTextWidth)
                attempts += 1
            }
            guard !rows.isEmpty else { continue }

            let container = CALayer()
            container.frame = CGRect(origin: .zero, size: renderSize)
            container.masksToBounds = false
            container.opacity = 0          // invisible unless its own window says otherwise

            let rowHeight = size * 1.22
            let blockHeight = rowHeight * CGFloat(rows.count)
            let blockTop: CGFloat
            switch style {
            case .punchCard:
                // Centred, a touch above the middle — the eye reads a hook there,
                // and it stays clear of the caption/username furniture Instagram
                // and TikTok paint over the bottom of the frame.
                blockTop = renderSize.height * (raised ? 0.36 : 0.42) - blockHeight / 2
            case .off, .lowerThird, .highlightBox:
                // Lower third, above the home indicator and above that same
                // furniture. Raised when the spoken captions own the usual band.
                blockTop = renderSize.height * (raised ? 0.62 : 0.80) - blockHeight
            }

            let pad = max(2, size * 0.06)   // guards against measurement rounding
            for (rowIndex, row) in rows.enumerated() {
                let text = row.joined(separator: " ")
                let width = CaptionRenderer.measure(text, font: font)
                let y = blockTop + CGFloat(rowIndex) * rowHeight
                let x: CGFloat = (style == .punchCard) ? (renderSize.width - width) / 2 : margin
                let frame = CGRect(x: x - pad, y: y, width: width + pad * 2, height: rowHeight)

                switch style {
                case .highlightBox:
                    // A filled slab behind each row. The most legible option over
                    // bright or busy footage because it does not rely on the halo
                    // at all — white on solid purple always wins.
                    let box = CALayer()
                    box.frame = frame.insetBy(dx: -size * 0.10, dy: -size * 0.06)
                    box.backgroundColor = accent.cgColor
                    box.cornerRadius = size * 0.16
                    box.masksToBounds = true
                    container.addSublayer(box)
                    let pair = CaptionRenderer.haloedText(text, font: font, size: size,
                                                          color: .white, frame: frame,
                                                          halo: false)
                    pair.text.alignmentMode = .left
                    container.addSublayer(pair.text)
                case .lowerThird:
                    // A short accent bar beside the first row: the one piece of
                    // furniture that makes plain white type read as designed
                    // rather than as a default.
                    if rowIndex == 0 {
                        let bar = CALayer()
                        bar.frame = CGRect(x: max(0, x - pad - size * 0.30), y: y + size * 0.16,
                                           width: max(3, size * 0.09), height: blockHeight - size * 0.32)
                        bar.backgroundColor = accent.cgColor
                        bar.cornerRadius = bar.frame.width / 2
                        container.addSublayer(bar)
                    }
                    let pair = CaptionRenderer.haloedText(text, font: font, size: size,
                                                          color: .white, frame: frame, halo: true)
                    pair.halo?.alignmentMode = .left
                    pair.text.alignmentMode = .left
                    if let halo = pair.halo { container.addSublayer(halo) }
                    container.addSublayer(pair.text)
                case .off, .punchCard:
                    let pair = CaptionRenderer.haloedText(text, font: font, size: size,
                                                          color: .white, frame: frame, halo: true)
                    if let halo = pair.halo { container.addSublayer(halo) }
                    container.addSublayer(pair.text)
                }
            }

            // Held for the SHOT, not for a word: in a hold, and out as the shot
            // ends. `t0` never runs before the title card is gone; `t3` is the
            // shot's own end either way, so waiting for the card shortens the
            // caption rather than pushing it onto the next picture.
            let shotStart = max(0, caption.start)
            let t3 = shotStart + max(caption.duration, 0.4)
            let t0 = max(shotStart, titleCardUntil)
            guard t3 - t0 >= minimumCaptionOnScreen else { continue }
            let window = CaptionRenderer.Window(t0: t0,
                                                t1: min(t0 + captionFade, t3),
                                                t2: max(t0, t3 - captionFade),
                                                t3: t3)
            container.add(CaptionRenderer.opacityAnimation(window), forKey: "shotCaptionOpacity")
            root.addSublayer(container)
        }
        return root
    }

    // MARK: Title card

    /// (a) an intro title card — address (bold) over the facts/tagline line,
    /// centred, shown ~2 s then faded out — and (b) a small bottom-right
    /// "Made with Rendprop" mark at 55% opacity for the full duration.
    /// Coordinates are TOP-LEFT (the parent layer is geometry-flipped); sizes
    /// scale with min(renderSize) so 9:16 and 16:9 exports match.
    ///
    /// Moved verbatim from `ReelStudioView.addCaptionLayers` — the numbers in
    /// here were tuned against real exports, so nothing was "tidied" on the way.
    private static func addTitleCardLayers(_ card: ReelTitleCard, renderSize: CGSize,
                                           to overlay: CALayer) {
        let w = renderSize.width, h = renderSize.height
        let unit = min(w, h)                 // 1080 in both 9:16 and 16:9
        let margin = unit * 0.07             // safe-area-ish inset
        let textWidth = w - margin * 2

        func makeText(_ text: String, size: CGFloat, weight: UIFont.Weight,
                      alignment: CATextLayerAlignmentMode) -> (CATextLayer, CGFloat) {
            let font = UIFont.systemFont(ofSize: size, weight: weight)
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil)
            let layer = CATextLayer()
            layer.string = text
            layer.font = font
            layer.fontSize = size
            layer.foregroundColor = UIColor.white.cgColor
            layer.alignmentMode = alignment
            layer.isWrapped = true
            layer.truncationMode = .end
            layer.contentsScale = 2
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.6
            layer.shadowRadius = max(2, size * 0.08)
            layer.shadowOffset = CGSize(width: 0, height: max(1, size * 0.03))
            return (layer, ceil(measured.height) + size * 0.25)
        }

        let intro = CALayer()
        intro.frame = CGRect(origin: .zero, size: renderSize)

        let gap = unit * 0.010
        let (titleLayer, titleH) = makeText(card.title, size: unit * 0.058,
                                            weight: .bold, alignment: .center)
        var blockH = titleH
        var subLayer: CATextLayer?
        var subH: CGFloat = 0
        if !card.subtitle.isEmpty {
            let (sl, sh) = makeText(card.subtitle, size: unit * 0.036,
                                    weight: .semibold, alignment: .center)
            subLayer = sl
            subH = sh
            blockH += gap + sh
        }
        let blockTop = h * 0.42 - blockH / 2       // a touch above center
        titleLayer.frame = CGRect(x: margin, y: blockTop, width: textWidth, height: titleH)
        intro.addSublayer(titleLayer)
        if let subLayer {
            subLayer.frame = CGRect(x: margin, y: blockTop + titleH + gap,
                                    width: textWidth, height: subH)
            intro.addSublayer(subLayer)
        }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.beginTime = AVCoreAnimationBeginTimeAtZero + 1.6   // NEVER 0 (0 = "now")
        fade.duration = 0.4
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        intro.add(fade, forKey: "introFade")
        overlay.addSublayer(intro)

        // ~10 pt equivalent: 10 / 390 (pt screen width) × 1080 ≈ 28 px.
        let (wm, wmH) = makeText(card.watermark, size: unit * 0.026,
                                 weight: .semibold, alignment: .right)
        wm.opacity = 0.55
        wm.shadowOpacity = 0.5
        wm.frame = CGRect(x: margin, y: h - margin - wmH, width: textWidth, height: wmH)
        overlay.addSublayer(wm)
    }

    // MARK: - Geometry

    /// Raw buffer space → `renderSize`, aspect-FILL. Applies the source's
    /// preferredTransform first (normalized back to a (0,0) origin — 90°/270°
    /// portrait transforms land the displayed rect at a negative origin), then
    /// scales to cover the render size and centers the overflow (center-crop).
    static func fillTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform,
                              renderSize: CGSize) -> CGAffineTransform {
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displayW = abs(displayRect.width)
        let displayH = abs(displayRect.height)
        guard displayW > 0, displayH > 0, displayW.isFinite, displayH.isFinite else { return .identity }

        var t = preferredTransform
        t.tx -= displayRect.minX
        t.ty -= displayRect.minY

        let scale = max(renderSize.width / displayW, renderSize.height / displayH)
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(
            translationX: (renderSize.width - displayW * scale) / 2,
            y: (renderSize.height - displayH * scale) / 2))
        return t
    }

    // MARK: - Export

    private static func export(composition: AVMutableComposition,
                               videoComposition: AVMutableVideoComposition,
                               to output: URL) async throws {
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw ComposeError.noExporter
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        guard export.status == .completed else {
            throw export.error ?? ComposeError.exportFailed
        }
    }
}
