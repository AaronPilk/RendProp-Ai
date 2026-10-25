import Foundation

/// The same three recipe IDs used by Studio. These describe the intended edit;
/// they never certify that a photo contains a particular room or is usable.
enum ProductionRecipe: String, Codable, CaseIterable, Identifiable {
    case listingHighlight = "listing-highlight"
    case agentTour = "agent-tour"
    case marketUpdate = "market-update"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .listingHighlight: return "Listing highlight"
        case .agentTour: return "Agent-led tour"
        case .marketUpdate: return "Market update"
        }
    }
    var subtitle: String {
        switch self {
        case .listingHighlight: return "Show the property’s best features. Speaking is optional."
        case .agentTour: return "Guide viewers through the home, on camera or with narration."
        case .marketUpdate: return "Explain one useful local insight, with facts you can verify."
        }
    }
    var symbol: String {
        switch self {
        case .listingHighlight: return "house.fill"
        case .agentTour: return "person.crop.rectangle"
        case .marketUpdate: return "chart.line.uptrend.xyaxis"
        }
    }
}

enum ProductionPresentation: String, Codable, CaseIterable, Identifiable {
    case music, voiceover, onCamera = "on-camera"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: return "Footage + text"
        case .voiceover: return "Add narration later"
        case .onCamera: return "Speak on camera"
        }
    }
    var tip: String {
        switch self {
        case .music: return "Record the property and add short captions in Studio. You can add licensed music in your social app after exporting."
        case .voiceover: return "Capture the visuals now. Record your explanation somewhere quiet when you’re ready."
        case .onCamera: return "Record one clear thought at a time in a quiet spot. Play it back and check that every word is easy to hear."
        }
    }
}

struct ProductionShotGuide: Identifiable, Equatable {
    let id: String
    let title: String
    let instruction: String
    let suggestedSeconds: String
    let roomHints: [String]
    var required: Bool = true
}

enum ProductionGuidance {
    static func shots(for recipe: ProductionRecipe) -> [ProductionShotGuide] {
        switch recipe {
        case .listingHighlight:
            return [
                .init(id: "exterior", title: "A strong first impression", instruction: "Show the exterior or the home’s strongest feature. Hold the frame briefly before and after one slow movement.", suggestedSeconds: "5–8 sec", roomHints: ["exterior", "front", "entrance"]),
                .init(id: "entry", title: "Welcome inside", instruction: "Show how the entrance connects to the main living space. Move slowly and keep the phone level.", suggestedSeconds: "5–8 sec", roomHints: ["entry", "entrance", "foyer"]),
                .init(id: "living", title: "The main living space", instruction: "From a doorway or corner, show how the room connects to the next space. Keep vertical lines straight.", suggestedSeconds: "5–8 sec", roomHints: ["living", "lounge", "family"]),
                .init(id: "kitchen", title: "The kitchen", instruction: "Record one wide view and one detail. Avoid pointing straight into bright windows.", suggestedSeconds: "5–8 sec each", roomHints: ["kitchen"]),
                .init(id: "primary-bedroom", title: "Primary bedroom", instruction: "Show the room and its connection to adjacent spaces without stretching the perspective.", suggestedSeconds: "5–8 sec", roomHints: ["bedroom", "primary"], required: false),
                .init(id: "bathroom", title: "Bathroom", instruction: "Choose a clear angle and check whether you or the phone appear in a mirror.", suggestedSeconds: "5–8 sec", roomHints: ["bathroom", "bath"], required: false),
                .init(id: "standout-feature", title: "A reason to remember it", instruction: "Choose a real feature: a bedroom, garden, view or detail. Only describe what the property actually has.", suggestedSeconds: "5–8 sec", roomHints: ["bedroom", "primary", "garden", "patio", "backyard"]),
                .init(id: "closing", title: "A clean ending", instruction: "Get a steady final view with space for the agent’s contact details or showing invitation.", suggestedSeconds: "5–8 sec", roomHints: [])
            ]
        case .agentTour:
            return [.init(id: "introduction", title: "Introduce this home", instruction: "State one specific reason to keep watching. You can film yourself or record this as narration later.", suggestedSeconds: "5–10 sec", roomHints: ["exterior", "front", "entrance"])] + shots(for: .listingHighlight)
        case .marketUpdate:
            return [
                .init(id: "hook", title: "One useful question", instruction: "Open with the question your update answers. Use one short sentence, either on camera or as narration.", suggestedSeconds: "5–10 sec", roomHints: []),
                .init(id: "explanation", title: "Your explanation", instruction: "Explain one local insight in plain language. Note the source, area and date of every market number you plan to use.", suggestedSeconds: "15–30 sec", roomHints: []),
                .init(id: "supporting-visuals", title: "Supporting visuals", instruction: "Record two relevant location or property views you have permission to use. These can cover pauses while your explanation continues.", suggestedSeconds: "5–8 sec each", roomHints: [], required: false),
                .init(id: "takeaway", title: "A useful takeaway", instruction: "Explain what your audience can do with this information. Avoid predictions stated as guarantees.", suggestedSeconds: "5–10 sec", roomHints: []),
                .init(id: "closing", title: "A helpful next step", instruction: "Give viewers one practical next step or a short invitation to ask you a question.", suggestedSeconds: "5–10 sec", roomHints: [])
            ]
        }
    }

    /// A chapter name is a lead to review, not proof of visual coverage. Ignore
    /// impossible timestamps and unconfirmed AI suggestions when offering it.
    static func matchingChapters(_ guide: ProductionShotGuide, names: [(name: String, seconds: Double, suggested: Bool)], duration: Double) -> [String] {
        guard duration.isFinite, duration > 0 else { return [] }
        var seen = Set<String>()
        return names.compactMap { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.suggested, item.seconds.isFinite, item.seconds >= 0, item.seconds < duration,
                  !name.isEmpty, guide.roomHints.contains(where: { name.localizedCaseInsensitiveContains($0) }),
                  seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
    }
}
