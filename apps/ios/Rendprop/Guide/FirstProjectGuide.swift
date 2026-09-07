import Foundation

// MARK: - First-project guide
//
// PROJECT-FIRST onboarding for Home: five REQUIRED steps that mirror the loop
// every business type actually runs — start, film, tag, render, share — plus
// two optional "next wins". Every step's completion is read straight off
// real app state (a real listing, a captured asset, a room tag, a rendered
// tour, a published share link) — never a flag this guide sets when its own
// "Do it" button is tapped. The one exception is `Storage.hasAIPhotoEdit`,
// which is latched by the AI photo edit's OWN success handler in
// FlythroughDetailView.swift at the moment the edit actually succeeds — real
// completion, still never a tap on the guide itself.
//
// See `FirstProjectCard` (same folder) for the Home card that reads this,
// and RendpropApp.swift's `HomeDashboardView` for the one hook that shows it.

/// One of the five required steps, in the order they naturally happen.
enum FirstProjectGuideStep: Int, CaseIterable, Identifiable, Hashable {
    case start, film, tag, tour, share

    var id: Int { rawValue }
    /// 1-based, for the "N of 5" progress line.
    var stepNumber: Int { rawValue + 1 }
}

/// Two optional next steps, shown alongside the required five. Kept out of
/// `FirstProjectGuideStep` so "N of 5" only ever counts the required loop.
enum FirstProjectGuideWin: Int, CaseIterable, Identifiable, Hashable {
    case aiPhotoEdit, reel
    var id: Int { rawValue }
}

/// What tapping "Do it" on a step or a next win should run.
/// `HomeDashboardView` already owns the "which home?" gate
/// (`ProjectRoute` / `open(_:)` / `go(_:_:)`) — the card only ever hands one
/// of these back to it; it never navigates on its own.
enum FirstProjectGuideAction {
    /// No real project yet — the same "name it" gate every feature tile uses.
    case startProject
    /// A real project exists — open this feature on it.
    case open(ProjectRoute)
    /// Step 5 — land on the tour, where the share button lives.
    case share(Listing)
}

enum FirstProjectGuide {

    /// Which required steps, and which optional wins, are true right now.
    struct Progress {
        var completedSteps: Set<FirstProjectGuideStep>
        var completedWins: Set<FirstProjectGuideWin>

        var completedCount: Int { completedSteps.count }
        var isFullyDone: Bool { completedSteps.count == FirstProjectGuideStep.allCases.count }
        /// The first not-yet-done step, in order. nil once all five are real.
        var nextStep: FirstProjectGuideStep? {
            FirstProjectGuideStep.allCases.first { !completedSteps.contains($0) }
        }
        func isDone(_ step: FirstProjectGuideStep) -> Bool { completedSteps.contains(step) }
        func isDone(_ win: FirstProjectGuideWin) -> Bool { completedWins.contains(win) }
    }

    // MARK: - Reading real state

    /// Computed fresh every time Home draws — there is no cached "done" flag
    /// for the five steps, so the card can never show one as finished except
    /// by finding the real thing it stands for.
    @MainActor
    static func progress(model: AppModel) -> Progress {
        // Store screenshots only (`-uiTesting -ui.guideState N`): a fixed
        // progress so every card state can be captured on demand — the real
        // signals below are otherwise slow to set up from a clean simulator.
        // Never consulted outside a UI-test launch (Config.uiTestGuideState).
        if let forced = Config.uiTestGuideState {
            let n = max(0, min(forced, FirstProjectGuideStep.allCases.count))
            return Progress(completedSteps: Set(FirstProjectGuideStep.allCases.prefix(n)), completedWins: [])
        }

        let projects = model.realProjects
        var steps: Set<FirstProjectGuideStep> = []
        if !projects.isEmpty {
            steps.insert(.start)
        }
        if projects.contains(where: { model.assets[$0.id] != nil }) {
            steps.insert(.film)
        }
        if projects.contains(where: { !(model.assets[$0.id]?.roomTags.isEmpty ?? true) }) {
            steps.insert(.tag)
        }
        if projects.contains(where: { model.tours[$0.id] != nil }) {
            steps.insert(.tour)
        }
        if projects.contains(where: { $0.serverShareURL != nil }) {
            steps.insert(.share)
        }

        var wins: Set<FirstProjectGuideWin> = []
        if Storage.hasAIPhotoEdit {
            wins.insert(.aiPhotoEdit)
        }
        if projects.contains(where: { hasReel(for: $0.id) }) {
            wins.insert(.reel)
        }

        return Progress(completedSteps: steps, completedWins: wins)
    }

    /// The real project "Do it" should act on: the first of the user's real
    /// projects that hasn't reached this step yet, else their first project.
    /// nil only when there is no real project at all.
    @MainActor
    private static func target(for step: FirstProjectGuideStep, model: AppModel) -> Listing? {
        let projects = model.realProjects
        func notYet(_ l: Listing) -> Bool {
            switch step {
            case .start: return false
            case .film:  return model.assets[l.id] == nil
            case .tag:   return model.assets[l.id]?.roomTags.isEmpty ?? true
            case .tour:  return model.tours[l.id] == nil
            case .share: return l.serverShareURL == nil
            }
        }
        return projects.first(where: notYet) ?? projects.first
    }

    @MainActor
    private static func target(for win: FirstProjectGuideWin, model: AppModel) -> Listing? {
        let projects = model.realProjects
        switch win {
        case .aiPhotoEdit: return projects.first
        case .reel:         return projects.first(where: { !hasReel(for: $0.id) }) ?? projects.first
        }
    }

    /// What running this step should do. Falls back to `.startProject`
    /// whenever there is no real project yet — matches Home's own gate,
    /// which asks for a name before it will run any feature.
    @MainActor
    static func action(for step: FirstProjectGuideStep, model: AppModel) -> FirstProjectGuideAction {
        guard let listing = target(for: step, model: model) else { return .startProject }
        return step == .share ? .share(listing) : .open(ProjectRoute(listing: listing, feature: .tour))
    }

    @MainActor
    static func action(for win: FirstProjectGuideWin, model: AppModel) -> FirstProjectGuideAction {
        guard let listing = target(for: win, model: model) else { return .startProject }
        return .open(ProjectRoute(listing: listing, feature: win == .aiPhotoEdit ? .photos : .reel))
    }

    /// `Documents/reels/<listingID>-*.mp4` — the same convention
    /// `ReelStudioView` writes to (FlythroughDetailView.swift), read directly
    /// rather than reaching into that file for a one-line existence check.
    private static func hasReel(for listingID: UUID) -> Bool {
        let dir = FileStore.documents.appendingPathComponent("reels", isDirectory: true)
        let prefix = "\(listingID.uuidString)-".lowercased()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { $0.lowercased().hasPrefix(prefix) }
    }

    // MARK: - Persisted flags (UserDefaults — same convention as AIConsent / Analytics)

    enum Storage {
        private static let dismissedForeverKey = "guide.firstProject.dismissedForever"
        private static let aiPhotoEditKey = "guide.firstProject.aiPhotoEditDone"

        /// Latched true the first time all five required steps are real.
        /// Never reset — deleting the listing that finished step 5 afterwards
        /// must not bring a graduated user's card back (set by
        /// `FirstProjectCard`).
        static var dismissedForever: Bool {
            get { UserDefaults.standard.bool(forKey: dismissedForeverKey) }
            set { UserDefaults.standard.set(newValue, forKey: dismissedForeverKey) }
        }

        /// Set once, by the AI photo edit's own success handler. There is no
        /// per-listing file marker for "this photo went through the AI" (an
        /// AI-edited photo and a plain imported one are saved the same way —
        /// see `EnhancedPhoto` in FlythroughDetailView.swift), so this is the
        /// one flag the guide keeps for itself.
        static var hasAIPhotoEdit: Bool {
            get { UserDefaults.standard.bool(forKey: aiPhotoEditKey) }
            set { UserDefaults.standard.set(newValue, forKey: aiPhotoEditKey) }
        }
    }

    /// Home's gate for whether the card should ever mount. Session-only
    /// hiding ("Hide") lives in `FirstProjectCard`'s own view state instead —
    /// this is the permanent, cross-launch one.
    static var isHiddenForever: Bool {
        // Store screenshots force a progress value regardless of real state
        // (see `progress(model:)`) — the permanent-hide flag must not hide
        // the very card that override exists to show.
        if Config.uiTestGuideState != nil { return false }
        return Storage.dismissedForever
    }

    /// Called once, right where an AI photo edit actually succeeds — real
    /// completion, not a tap on the guide itself.
    static func recordAIPhotoEditCompleted() {
        guard !Storage.hasAIPhotoEdit else { return }
        Storage.hasAIPhotoEdit = true
    }
}

// MARK: - Per-industry copy
// Every fact below is said elsewhere in the app already (How it works, the
// capture pace ring, the room tagger, the render tiers, the photo studio's
// own edit buttons) — nothing here is invented.
extension FirstProjectGuideStep {
    private var space: SpaceType { SpaceType.current }

    var title: String {
        switch self {
        case .start: return "Start your first \(space.spaceNoun)"
        case .film:  return "Film or upload the walkthrough"
        case .tag:   return "Tag the \(space.areaNounPlural)"
        case .tour:  return "Create the tour"
        case .share: return "Share the link"
        }
    }

    var tip: String {
        switch self {
        case .start:
            return "Give it a name or address — everything you make from here is saved to it."
        case .film:
            return "Walk it at a normal, steady pace on the 0.5× wide lens, or upload a clip you already have. The render retimes it into a glide, so there's no need to move slowly."
        case .tag:
            let toolName = space == .realEstate ? "Tag rooms" : "Tag areas"
            return "Tap a \(space.areaNoun) name as you film it, or use \(toolName) on the finished video to add them after."
        case .tour:
            return "Smooth renders a silky glide in HD — the way most tours look best. The 4K AI tiers add motion smoothing and upscaling for a \(space.spaceNoun) that should stand out."
        case .share:
            return "One link or QR code is all it takes — \(space.customerNoun) scroll it, and their questions land in your Leads."
        }
    }

    var systemImage: String {
        switch self {
        case .start: return "plus.circle.fill"
        case .film:  return "video.fill"
        case .tag:   return "tag.fill"
        case .tour:  return "play.rectangle.fill"
        case .share: return "square.and.arrow.up"
        }
    }
}

extension FirstProjectGuideWin {
    private var space: SpaceType { SpaceType.current }

    var title: String {
        switch self {
        case .aiPhotoEdit: return "Try an AI photo edit"
        case .reel:         return "Make a reel"
        }
    }

    var tip: String {
        switch self {
        case .aiPhotoEdit:
            return space == .realEstate
                ? "Make it twilight, make the sky blue, or try virtual staging — one tap, right on your own photo."
                : "Make it twilight, make the sky blue, or furnish it — one tap, right on your own photo."
        case .reel:
            return "Pick two or more photos and Rendprop stitches them into one video made for social."
        }
    }

    var systemImage: String {
        switch self {
        case .aiPhotoEdit: return "wand.and.stars"
        case .reel:         return "film.stack"
        }
    }
}
