import SwiftUI

// coach — the ASK AI button, in the top-right corner of every screen.
//
// THE DEFECT, in the owner's words: "at all parts of the app at the top right
// there should be the ask AI feature… it should be context aware to what the
// person is doing on that page."
//
// Before this, the coach had exactly two doors: a card on Home and a row in
// Settings. An agent standing in the middle of a floor-plan scan, a reel, or a
// staging batch — which is precisely when a person has a question — had to back
// all the way out to Home to ask it. The help was real and it was two screens
// away from every moment that needed it.
//
// WHAT THIS IS. One view modifier. `.askAI("photo_studio", listing: listing)`
// puts the button in `.navigationBarTrailing` and owns the sheet. Nothing else
// about the coach changes: same `CoachView`, same `CoachModel`, same
// `POST /coach`, same consent gate, same on-device fallback when the call can't
// be made. The screen name it carries was ALREADY on the wire
// (`CoachRequest.Context.screen`) and already sent as `originScreen` — it was
// just never filled in by anything but Home and Settings.
//
// WHY A MODIFIER AND NOT A FLOATING BUTTON. A floating button has to dodge
// every screen's own controls, and this app's screens end in tall action
// buttons ("Share all photos", "Publish", "Apply to 14 photos"). The nav bar's
// trailing slot is the one place that is empty on nearly every screen, never
// scrolls away, and reads as the same control everywhere — same look, same
// behaviour, same place, which is what makes a control learnable at all.

/// Where the person is standing. Sent as `context.screen` and used to pick the
/// starter questions, so "Ask AI" on the floor-plan screen opens on floor-plan
/// questions rather than "Start my first tour".
///
/// The raw values are the wire strings. They are a HINT on the server — the
/// prompt is free to ignore an unknown one — so adding a case here can never
/// break `POST /coach`.
enum AskAIScreen: String {
    case home
    case settings
    case listing
    case photos
    case photoStudio     = "photo_studio"
    case reelStudio      = "reel_studio"
    case floorPlan       = "floor_plan"
    case aerial
    case tourCapture     = "tour_capture"
    case roomTagger      = "room_tagger"
    case agentCard       = "agent_card"
    case files
    case compliance
    case plan

    /// Four questions this screen actually raises. Kept in the person's own
    /// words, not ours — "why does it look fake" is what an agent types, and
    /// "drift threshold" is not.
    var starters: [String] {
        switch self {
        case .home:
            return ["Start my first tour",
                    "What should I do first?",
                    "How do I share to the MLS?",
                    "What does this cost me?"]
        case .settings, .plan:
            return ["What am I paying for?",
                    "Cancel or change my plan",
                    "How many edits do I have left?",
                    "Contact a human"]
        case .listing:
            return ["What should I make for this home next?",
                    "How do I share this to the MLS?",
                    "Where did my photos and videos go?",
                    "How do I change the cover photo?"]
        case .photos:
            return ["What happens to a photo when I add it?",
                    "How do I set the cover photo?",
                    "How many photos should a listing have?",
                    "Do I need a real camera for this?"]
        case .photoStudio:
            return ["What does Declutter actually do?",
                    "What is virtual staging and do I have to disclose it?",
                    "Which change should I use on a dark room?",
                    "Can I do all my photos at once?"]
        case .reelStudio:
            return ["What makes a reel people actually watch?",
                    "How long should my reel be?",
                    "Should I use my own voice?",
                    "What do I post this to?"]
        case .floorPlan:
            return ["How do I scan a second floor?",
                    "Why did it miss a room?",
                    "How slowly should I walk?",
                    "Can I upload a plan I already have?"]
        case .aerial:
            return ["What is an aerial intro for?",
                    "Do I need a drone?",
                    "Can I use my own drone footage?",
                    "How long does it take?"]
        case .tourCapture:
            return ["How should I walk a big house?",
                    "How do I hold the phone?",
                    "How long should the walk be?",
                    "Can I stop and start again?"]
        case .roomTagger:
            return ["What should I tag?",
                    "Do buyers actually use the room list?",
                    "Can I rename a room?",
                    "How many rooms is too many?"]
        case .agentCard:
            return ["What shows on my card?",
                    "Where do buyers see this?",
                    "Do I need my brokerage on it?",
                    "How do I change my photo?"]
        case .files:
            return ["Where did my photos and videos go?",
                    "How do I save a video to my camera roll?",
                    "Can I delete something and get it back?",
                    "How do I send these to my client?"]
        case .compliance:
            return ["What do I have to disclose?",
                    "Where do buyers see the original photo?",
                    "Will my broker be OK with this?",
                    "What are the fair-housing rules here?"]
        }
    }
}

extension View {
    /// Put ASK AI in this screen's top-right corner.
    ///
    /// Use it on the screen's own root content, INSIDE whatever
    /// `NavigationStack` / `NavigationLink` destination it lives in — a
    /// toolbar item only renders when there is a nav bar above it.
    func askAI(_ screen: AskAIScreen) -> some View {
        modifier(AskAIModifier(screen: screen))
    }
}

private struct AskAIModifier: ViewModifier {
    let screen: AskAIScreen
    @EnvironmentObject private var model: AppModel
    @State private var showCoach = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    AskAIButton { showCoach = true }
                }
            }
            .sheet(isPresented: $showCoach) {
                CoachView(model: model, originScreen: screen.rawValue,
                          starters: screen.starters)
            }
    }
}

/// The control itself. A word AND a glyph, because an unlabelled sparkle in a
/// nav bar is a guess — and this is the one control on the screen whose whole
/// job is to be found by somebody who is stuck.
struct AskAIButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                Text("Ask AI")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.accentSoft, in: Capsule())
        }
        .buttonStyle(ScalePressStyle())
        .accessibilityLabel(Text("Ask AI — questions about this screen"))
        .accessibilityIdentifier("askAI")
    }
}
