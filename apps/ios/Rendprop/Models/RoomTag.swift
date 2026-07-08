import Foundation

/// A chapter marker: "Kitchen at 42.5s". Tagged live during capture or edited after.
struct RoomTag: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var tMs: Int

    var tSeconds: Double { Double(tMs) / 1000.0 }

    static let quickNames = [
        "Exterior", "Entry", "Living Room", "Kitchen", "Dining",
        "Primary", "Bedroom", "Bath", "Office", "Garage", "Backyard"
    ]
}
