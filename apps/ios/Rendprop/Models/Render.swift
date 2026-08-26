import Foundation

/// Interior design style for AI virtual restaging. The pipeline re-styles
/// furniture, wall art, and decor while keeping architecture identical.
enum DesignStyle: String, Codable, CaseIterable, Identifiable {
    case asIs = "as_is"
    case modern, rustic, minimalist, scandinavian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .asIs:         return "As-is"
        case .modern:       return "Modern"
        case .rustic:       return "Rustic"
        case .minimalist:   return "Minimalist"
        case .scandinavian: return "Scandinavian"
        }
    }

    var blurb: String {
        switch self {
        case .asIs:         return "Keep the \(SpaceType.current.spaceNoun) exactly as filmed."
        case .modern:       return "Clean lines, bold contemporary furniture and art."
        case .rustic:       return "Warm woods, cozy textures, farmhouse character."
        case .minimalist:   return "Airy, decluttered, quiet neutral styling."
        case .scandinavian: return "Light woods, soft whites, hygge warmth."
        }
    }

    var systemImage: String {
        switch self {
        case .asIs:         return "house"
        case .modern:       return "square.on.square"
        case .rustic:       return "leaf"
        case .minimalist:   return "circle.dashed"
        case .scandinavian: return "snowflake"
        }
    }
}

/// AI enhancement add-ons applied by the render pipeline.
struct Enhancements: Codable, Hashable {
    /// Remove boxes, clutter, and mess — video inpainting with temporal consistency.
    var declutter: Bool = false
    /// Restage furniture/decor in a chosen style (architecture never changes).
    var style: DesignStyle = .asIs

    var isActive: Bool { declutter || style != .asIs }

    static let declutterPrice = Money.dollars(19)
    static let restagePrice = Money.dollars(49)

    var addOnTotal: Money {
        Money(cents: (declutter ? Self.declutterPrice.cents : 0)
                   + (style != .asIs ? Self.restagePrice.cents : 0))
    }
}

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

        /// Plain-agent-language copy (master spec Part 39). Honest: the AI tiers
        /// describe what actually runs today — Topaz motion smoothing + upscale
        /// on our render farm (/ai-video/drone).
        var blurb: String {
            switch self {
            case .smooth:
                return "A silky drone-style glide in HD. Perfect for most tours."
            case .premium4k:
                return "AI motion smoothing + true 4K upscale on our render farm — the premium look for standout spaces."
            case .cinematic:
                return "AI motion smoothing + 4K upscale at 60fps on our render farm. The scroll-stopping version for social."
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
    var enhancements = Enhancements()
    var status: String = "queued"
    var progress: Double = 0

    // Worker-path published tour (GET /renders/:id → `tour`). Nil for local and
    // app-published renders — those carry their public slug on the Listing.
    // Optional so renders persisted before these fields existed still decode.
    var shareSlug: String? = nil
    var shareURL: String? = nil
    var scrubURL: String? = nil
    var videoURL: String? = nil
    var posterURL: String? = nil

    /// Pipeline steps for this render (drives status UI). Enhancement steps
    /// appear only when purchased.
    var pipelineSteps: [String] {
        var steps = ["Validating", "Stabilizing", "Interpolating 60fps"]
        if enhancements.declutter { steps.append("Decluttering") }
        if enhancements.style != .asIs { steps.append("Restaging · \(enhancements.style.displayName)") }
        steps += ["Grading", "Encoding", "Packaging", "Publishing"]
        return steps
    }
}

// MARK: - Tolerant decoding (persistence forward/backward compatibility)
// Renders are persisted inside PersistentStore's snapshot and also decoded from
// server JSON (LiveAPIClient's RenderDTO.enhancements). Synthesized Codable
// would require every non-optional key and throw on unknown enum raw values —
// one miss and the user's whole saved state is discarded on update. These
// inits decode with decodeIfPresent + safe defaults. They live in extensions
// so the memberwise initializers stay synthesized; encoding stays synthesized
// → identical JSON shape.
extension Enhancements {
    enum CodingKeys: String, CodingKey { case declutter, style }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        declutter = try c.decodeIfPresent(Bool.self, forKey: .declutter) ?? false
        // Unknown style raw values (newer build / server) degrade to .asIs.
        let styleRaw = try c.decodeIfPresent(String.self, forKey: .style)
        style = styleRaw.flatMap(DesignStyle.init(rawValue:)) ?? .asIs
    }
}

extension Render {
    enum CodingKeys: String, CodingKey {
        case id, listingID, tier, durationS, enhancements, status, progress,
             shareSlug, shareURL, scrubURL, videoURL, posterURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        // A render missing its listing link decodes to an orphan id and is
        // filtered out on load — losing one render beats losing everything.
        listingID    = try c.decodeIfPresent(UUID.self, forKey: .listingID) ?? UUID()
        let tierRaw  = try c.decodeIfPresent(String.self, forKey: .tier)
        tier         = tierRaw.flatMap(Tier.init(rawValue:)) ?? .smooth
        durationS    = try c.decodeIfPresent(Double.self, forKey: .durationS) ?? 0
        enhancements = try c.decodeIfPresent(Enhancements.self, forKey: .enhancements) ?? Enhancements()
        status       = try c.decodeIfPresent(String.self, forKey: .status) ?? "queued"
        progress     = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        shareSlug    = try c.decodeIfPresent(String.self, forKey: .shareSlug)
        shareURL     = try c.decodeIfPresent(String.self, forKey: .shareURL)
        scrubURL     = try c.decodeIfPresent(String.self, forKey: .scrubURL)
        videoURL     = try c.decodeIfPresent(String.self, forKey: .videoURL)
        posterURL    = try c.decodeIfPresent(String.self, forKey: .posterURL)
    }
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
