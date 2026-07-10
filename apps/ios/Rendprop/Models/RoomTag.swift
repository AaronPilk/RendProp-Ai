import Foundation

/// A chapter marker: "Kitchen at 42.5s". Tagged live during capture or edited after.
struct RoomTag: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var tMs: Int

    var tSeconds: Double { Double(tMs) / 1000.0 }

    /// Quick tags adapt to the selected business type (homes → rooms, a bar →
    /// Dining/Bar/Patio, a store → Aisles/Checkout, etc.).
    static var quickNames: [String] { SpaceType.current.quickTags }
}
