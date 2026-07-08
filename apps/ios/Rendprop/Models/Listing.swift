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
    var createdAt = Date()

    var metaLine: String {
        let bathsText = baths.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(baths)) : String(baths)
        return "\(beds) bd · \(bathsText) ba · \(sqft.formatted()) sqft"
    }
}
