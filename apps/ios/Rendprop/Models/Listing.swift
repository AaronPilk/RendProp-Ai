import Foundation

struct Listing: Identifiable, Codable, Hashable {
    enum Status: String, Codable, CaseIterable {
        case draft, uploading, processing, ready, expired
    }

    var id = UUID()
    var address: String
    var beds: Int
    var baths: Double
    var sqft: Int
    var price: Money
    var status: Status = .draft
    /// Seeded demo listings show sample stats; real listings never do.
    var isSample = false
    var createdAt = Date()

    var metaLine: String {
        let bathsText = baths.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(baths)) : String(baths)
        var parts = ["\(beds) bd", "\(bathsText) ba"]
        if sqft > 0 { parts.append("\(sqft.formatted()) sqft") }
        return parts.joined(separator: " · ")
    }
}
