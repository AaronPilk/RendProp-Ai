import CoreGraphics
import Foundation

// MARK: - Shared voiceover types
//
// Frozen by docs/VOICEOVER-CONTRACT.md. Agent B (ai-voice edge function + API
// client) and agent C (ReelStudioView stitch) both compile against these exact
// names and member order — change nothing here without changing the contract.
//
// Everything is value-type and `Sendable` so a Voiceover can cross actors
// freely (recorded on the main actor, transcribed off it, stitched in a
// `nonisolated` export path).

/// One caption word with its place on the timeline, relative to the START of
/// the voiceover audio (not the reel).
struct CaptionWord: Codable, Equatable, Sendable {
    let text: String
    let start: Double      // seconds
    let end: Double        // seconds

    init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A finished voiceover: an audio file on disk plus its word timings.
struct Voiceover: Identifiable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case myVoice, aiVoice }
    let id: UUID
    let audioURL: URL          // Documents/Voiceovers/<listing>-<stamp>.m4a|mp3
    let duration: Double       // seconds
    let transcript: String
    let words: [CaptionWord]   // may be empty — captions then simply don't render
    let source: Source
    let voiceName: String?     // AI voice label, nil for myVoice

    /// Same parameter order as the implicit memberwise init (so contract
    /// call-sites keep compiling); `id`, `words` and `voiceName` get defaults.
    init(id: UUID = UUID(), audioURL: URL, duration: Double, transcript: String,
         words: [CaptionWord] = [], source: Source, voiceName: String? = nil) {
        self.id = id
        self.audioURL = audioURL
        self.duration = duration
        self.transcript = transcript
        self.words = words
        self.source = source
        self.voiceName = voiceName
    }
}

extension Voiceover {

    /// `Documents/Voiceovers/` — created on demand. The recorder hands back a
    /// TEMP file (it may be thrown away); this is where a voiceover the agent
    /// decided to keep belongs, so it survives relaunch like every other
    /// listing asset. Mirrors `FileStore.subdir` behaviour deliberately rather
    /// than editing FileStore, which this agent does not own.
    static var voiceoversDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Voiceovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Move a recorded/downloaded audio file into `Documents/Voiceovers/` as
    /// `<listing>-<unixstamp>.<ext>`. Falls back to a copy when the source is
    /// on another volume, and returns the source URL untouched if even that
    /// fails — a voiceover that cannot be filed is still playable from temp for
    /// this session, which beats throwing away a recording the agent just made.
    static func persistAudio(from source: URL, listingID: String) -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let safeListing = listingID.isEmpty ? "listing" : listingID
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let dest = voiceoversDirectory.appendingPathComponent("\(safeListing)-\(stamp).\(ext)")
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: source, to: dest)
            return dest
        } catch {
            do {
                try fm.copyItem(at: source, to: dest)
                return dest
            } catch {
                return source
            }
        }
    }
}

/// Caption styling. C reads it; A owns the defaults.
struct CaptionStyle: Equatable, Sendable {
    var enabled: Bool
    var maxWordsPerLine: Int   // default 4
    var fontSize: CGFloat      // points at 1080-wide render, default 64
    var highlightActiveWord: Bool

    init(enabled: Bool = true, maxWordsPerLine: Int = 4,
         fontSize: CGFloat = 64, highlightActiveWord: Bool = true) {
        self.enabled = enabled
        self.maxWordsPerLine = maxWordsPerLine
        self.fontSize = fontSize
        self.highlightActiveWord = highlightActiveWord
    }

    /// The shipping default: on, 4 words a line, 64 pt at a 1080-wide render,
    /// active word highlighted. Social captions are read at arm's length on a
    /// phone in a feed — small and subtle loses.
    static let standard = CaptionStyle()

    /// Captions off. `CaptionRenderer.layer` still returns a valid empty layer
    /// for this, so the export path needs no special case.
    static let off = CaptionStyle(enabled: false)
}
