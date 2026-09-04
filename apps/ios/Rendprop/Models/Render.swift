import Foundation

/// Interior design style for AI virtual restaging. Kept for JSON back-compat
/// (persisted renders + server DTOs decode it); the tour flow no longer offers
/// it — no video restage pipeline exists yet (2026-09-03 audit, decision A5).
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

/// AI enhancement add-ons. The tour flow ALWAYS sends the defaults
/// (`declutter: false`, `style: .asIs`) — nothing in the render path restages
/// or declutters video, and a non-default value only made the hosted page stamp
/// an untouched video "Virtually staged" (decision A5). The type stays so
/// persisted renders and server DTOs keep decoding.
struct Enhancements: Codable, Hashable {
    var declutter: Bool = false
    var style: DesignStyle = .asIs

    var isActive: Bool { declutter || style != .asIs }
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

        /// Plain-agent-language copy. Honest: the AI tiers describe what actually
        /// runs today — Topaz motion smoothing + upscale on our render farm
        /// (/ai-video/drone) of the on-device master; 30 fps vs 60 fps is the
        /// real difference between them.
        var blurb: String {
            switch self {
            case .smooth:
                return "A silky drone-style glide in HD. Perfect for most tours."
            case .premium4k:
                return "AI motion smoothing + upscale (up to 4K, 30 fps) on our render farm — the premium look for standout spaces."
            case .cinematic:
                return "AI motion smoothing + upscale (up to 4K, 60 fps) on our render farm. The scroll-stopping version for social."
            }
        }

        var systemImage: String {
            switch self {
            case .smooth:    return "wind"
            case .premium4k: return "4k.tv"
            case .cinematic: return "sparkles"
            }
        }

        /// The AI tiers run the server pass; Smooth publishes the on-device render.
        var usesServerAI: Bool { self != .smooth }

        /// `/ai-video/drone` tier parameter + target fps. 4K Premium = 30 fps,
        /// Cinematic = 60 fps — the two tiers used to send identical requests.
        var droneTierParam: String { self == .premium4k ? "4k30" : "4k60" }
        var droneTargetFPS: Int { self == .premium4k ? 30 : 60 }
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

    /// Pipeline steps for this render (drives the Mock status simulation).
    /// No enhancement steps — nothing declutters/restages video (decision A5).
    var pipelineSteps: [String] {
        ["Validating", "Stabilizing", "Interpolating 60fps", "Grading", "Encoding", "Packaging", "Publishing"]
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
