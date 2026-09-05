import Foundation

/// A chapter marker: "Kitchen at 42.5s". Tagged live during capture or edited after.
struct RoomTag: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var tMs: Int

    // MARK: - router additions
    /// Set when this tag was pre-filled from `POST /ai-chapters`; cleared when
    /// the person edits or confirms it. Optional + defaulted → older snapshots
    /// decode and `RoomTag(name:tMs:)` still compiles.
    var isAISuggested: Bool? = nil
    /// The suggestion's 0…1 confidence, when the model gave one.
    var aiConfidence: Double? = nil
    // MARK: - end router additions

    var tSeconds: Double { Double(tMs) / 1000.0 }

    /// Quick tags adapt to the selected business type (homes → rooms, a bar →
    /// Dining/Bar/Patio, a store → Aisles/Checkout, etc.).
    static var quickNames: [String] { SpaceType.current.quickTags }
}

// MARK: - router additions
// Auto room chapters (docs/AI-CHAPTERS-CONTRACT.md §5.2): a tag the AI proposed
// is marked until the person touches it, so nothing typed by a human is ever
// dressed up as a suggestion and nothing suggested is ever mistaken for typed.
//
// Both fields are Optional with a default, so:
//   • a snapshot written by any earlier build still decodes (the synthesized
//     `init(from:)` uses decodeIfPresent for Optionals), and
//   • `RoomTag(name:tMs:)` — the memberwise init every existing call site uses
//     — still compiles unchanged.
// Neither field goes on the wire: `ChapterInput` is built from `name`/`tMs`
// only, so the published tour's JSON is byte-identical.
extension RoomTag {
    /// True while this tag is still exactly what the AI proposed. Cleared the
    /// moment the person renames it or confirms it.
    var isFromAI: Bool { isAISuggested == true }

    /// The model's own 0…1 confidence, when it sent one. A soft cue only —
    /// never a gate (contract §5.2).
    var isLowConfidence: Bool {
        guard let c = aiConfidence, c.isFinite else { return false }
        return c < 0.5
    }
}
// MARK: - end router additions
