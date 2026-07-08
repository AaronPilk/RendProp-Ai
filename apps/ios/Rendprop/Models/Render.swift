import Foundation

struct Render: Identifiable, Codable, Hashable {
    enum Tier: String, Codable, CaseIterable, Identifiable {
        case smooth, premium4k, cinematic

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .smooth:    return "Smooth"
            case .premium4k: return "4K Premium"
            case .cinematic: return "Cinematic AI"
            }
        }

        /// Plain-agent-language copy (master spec Part 39).
        var blurb: String {
            switch self {
            case .smooth:
                return "A silky drone-style glide in HD. Perfect for most listings."
            case .premium4k:
                return "Ultra-crisp 4K glide — the premium look for luxury listings."
            case .cinematic:
                return "Adds an AI aerial opener and cinematic transitions. The scroll-stopping version for social."
            }
        }

        var systemImage: String {
            switch self {
            case .smooth:    return "wind"
            case .premium4k: return "4k.tv"
            case .cinematic: return "sparkles"
            }
        }
    }

    var id = UUID()
    var listingID: UUID
    var tier: Tier
    var durationS: Double
    var status: String = "queued"
    var progress: Double = 0
}

/// Duration-band pricing (master spec Part 20.4). A flat price loses money on
/// long, popular flythroughs — price by output length band.
enum PricingBand {
    struct Band {
        let name: String
        let prices: [Render.Tier: Money]
    }

    static func band(forDuration s: Double) -> Band {
        switch s {
        case ..<95:
            return Band(name: "Up to 90 seconds",
                        prices: [.smooth: .dollars(29), .premium4k: .dollars(49), .cinematic: .dollars(99)])
        case ..<185:
            return Band(name: "90 seconds – 3 minutes",
                        prices: [.smooth: .dollars(49), .premium4k: .dollars(79), .cinematic: .dollars(149)])
        case ..<365:
            return Band(name: "3 – 6 minutes",
                        prices: [.smooth: .dollars(79), .premium4k: .dollars(119), .cinematic: .dollars(199)])
        default:
            return Band(name: "6 – 10 minutes",
                        prices: [.smooth: .dollars(119), .premium4k: .dollars(169), .cinematic: .dollars(279)])
        }
    }
}
