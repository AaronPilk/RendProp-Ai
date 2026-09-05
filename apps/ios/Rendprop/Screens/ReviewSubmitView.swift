import SwiftUI
import UIKit
import AVFoundation

/// Review the capture, edit room tags, say whether it's handheld or drone
/// footage, pick a quality tier, and hand the render to the coordinator.
/// Early access: no prices anywhere on this screen while StoreKit is off
/// (App Store 3.1). AI tiers are gated by the plan's allowances from `/me` —
/// a locked tier reads "Team plan", never a dollar amount.
struct ReviewSubmitView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared

    let listing: Listing
    @State var asset: CaptureAsset

    @State private var tier: Render.Tier = .smooth
    @State private var sourceKind: SourceKind = .handheld
    @State private var didDetectSource = false
    @State private var showRoomTagger = false
    @State private var goToStatus = false
    @State private var render: Render?
    @State private var entitlements: Entitlements?
    @State private var entitlementsChecked = false
    @State private var showSignIn = false
    @State private var showRerenderConfirm = false

    /// Explicit footage type (decision A8). Prefilled by a metadata heuristic,
    /// always correctable — it decides stabilization + the retime factor.
    enum SourceKind: String, CaseIterable, Identifiable {
        case handheld, drone
        var id: String { rawValue }
        var label: String { self == .handheld ? "Handheld walkthrough" : "Drone footage" }
    }

    private var space: SpaceType { SpaceType.current }
    private var hasTour: Bool { model.tours[listing.id] != nil }
    private var isRendering: Bool { model.renderCoordinator.isRunning(listing.id) }

    /// The AI tiers need the plan's Topaz allowance. Unknown (signed out / not
    /// loaded) counts as locked — Smooth is always included.
    private var aiTiersLocked: Bool {
        guard Config.useLiveBackend else { return false }
        guard let entitlements else { return true }
        return !entitlements.canUseTopaz
    }

    private var lockReason: String {
        if Config.enableAuth && !auth.isSignedIn { return "Sign in to see which tiers your plan includes." }
        if entitlements == nil {
            return entitlementsChecked ? "Couldn't check your plan right now — Smooth is always included."
                                       : "Checking your plan…"
        }
        return "AI tiers are a Team plan add-on."
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                captureSummary
                roomTags
                tierPicker
                submitSection
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("Review & Submit")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRoomTagger) {
            RoomTaggerView(videoURL: asset.localURL, tags: $asset.roomTags)
        }
        .sheet(isPresented: $showSignIn) {
            SignInView()
        }
        .navigationDestination(isPresented: $goToStatus) {
            if let render {
                RenderStatusView(listing: listing, render: render)
            }
        }
        .confirmationDialog("Render this \(space.spaceNoun) again?",
                            isPresented: $showRerenderConfirm, titleVisibility: .visible) {
            Button("Render again") { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current tour with a new render using these settings. A published link keeps working until the new tour is published.")
        }
        .task(id: auth.isSignedIn) { await loadEntitlements() }
        .onAppear(perform: detectSourceIfNeeded)
        .aiConsentGate()
    }

    // MARK: - Sections

    private var captureSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR VIDEO").font(.rpKicker).foregroundStyle(Theme.inkDim)
            HStack(spacing: 14) {
                Image(systemName: sourceKind == .drone ? "airplane" : "video.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Formatters.duration(asset.durationS)) · \(asset.resolutionLabel) · \(Int(asset.fps.rounded())) fps")
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.ink)
                    // Size only. The "Gyro sidecar" chip that used to sit here
                    // advertised a capability nothing delivers: the motion
                    // sidecar is recorded but never read by the render engine
                    // and never uploaded (audit F-D-10). Put it back when
                    // something actually consumes it.
                    Text(Formatters.bytes(asset.bytes))
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                }
                Spacer()
            }

            Picker("Footage", selection: $sourceKind) {
                ForEach(SourceKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: sourceKind) { _ in Haptics.selection() }
            .accessibilityLabel(Text("Footage type"))

            Text(sourceKind == .drone
                 ? "Drone clips are already smooth: no stabilization, a gentle 1.25× glide."
                 : "Handheld walks get stabilized and retimed to a 2× glide.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var roomTags: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(space == .realEstate ? "ROOMS" : "AREAS")
                .font(.rpKicker).foregroundStyle(Theme.inkDim)
            if asset.roomTags.isEmpty {
                Text("Tag areas on the video so \(space.customerNoun) can tap a dot and jump straight to \(space.quickTags.prefix(2).map { $0.lowercased() }.joined(separator: " or ")).")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
            ForEach(asset.roomTags.sorted { $0.tMs < $1.tMs }) { tag in
                HStack {
                    Text(Formatters.duration(tag.tSeconds))
                        .font(.rpMono)
                        .foregroundStyle(Theme.accent)
                    Text(tag.name)
                    Spacer()
                    Button {
                        asset.roomTags.removeAll { $0.id == tag.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(Theme.inkDim)
                    }
                    .accessibilityLabel(Text("Remove \(tag.name)"))
                }
                .padding(.vertical, 2)
            }
            Button {
                showRoomTagger = true
            } label: {
                Label(asset.roomTags.isEmpty
                      ? (space == .realEstate ? "Tag rooms on the video" : "Tag areas on the video")
                      : (space == .realEstate ? "Edit room tags" : "Edit area tags"),
                      systemImage: "mappin.and.ellipse")
                    .font(.rpBody.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var tierPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PICK YOUR QUALITY").font(.rpKicker).foregroundStyle(Theme.inkDim)
            ForEach(Render.Tier.allCases) { t in
                tierRow(t)
            }
            if aiTiersLocked {
                HStack(spacing: 8) {
                    Text(lockReason)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                    if Config.enableAuth && !auth.isSignedIn {
                        Spacer(minLength: 4)
                        Button("Sign in") { showSignIn = true }
                            .font(.rpCaption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func tierRow(_ t: Render.Tier) -> some View {
        let locked = t.usesServerAI && aiTiersLocked
        let selected = tier == t
        return Button {
            guard !locked else { return }
            // Guideline 5.1.2(i): the AI tiers upload the finished master and
            // hand it to Topaz Labs for motion smoothing + upscale. Picking one
            // is the moment to ask; Smooth (on-device) never leaves the phone.
            guard t.usesServerAI else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { tier = t }
                Haptics.selection()
                return
            }
            Task {
                guard await AIConsent.shared.ensureGranted() else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { tier = t }
                Haptics.selection()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: t.systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Theme.accent : Theme.inkDim)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.displayName).font(.rpHeadline).foregroundStyle(Theme.ink)
                    Text(t.blurb)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if locked {
                    Text("Team plan")
                        .font(.rpCaption.weight(.semibold))
                        .foregroundStyle(Theme.inkDim)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.fillSubtle, in: Capsule())
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.rpHeadline)
                        .foregroundStyle(selected ? Theme.accent : Theme.inkDim)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.accentSoft : Theme.fillSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.border,
                                  lineWidth: selected ? 1.5 : 1)
            )
            .opacity(locked ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityLabel(Text(locked ? "\(t.displayName). Team plan." : t.displayName))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder private var submitSection: some View {
        if isRendering {
            VStack(spacing: 10) {
                PrimaryButton(title: "See progress", systemImage: "gearshape.2") {
                    render = model.renders[listing.id]
                        ?? Render(listingID: listing.id, tier: tier, durationS: asset.durationS)
                    goToStatus = true
                }
                Text("This \(space.spaceNoun) is rendering right now.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
        } else if hasTour {
            VStack(spacing: 10) {
                NavigationLink {
                    FlythroughDetailView(listing: listing)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("View tour").fontWeight(.semibold)
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accent)
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(ScalePressStyle())
                SecondaryButton(title: "Render again with these settings", systemImage: "arrow.clockwise") {
                    showRerenderConfirm = true
                }
                Text("This \(space.spaceNoun) already has a tour.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
        } else {
            VStack(spacing: 10) {
                PrimaryButton(title: "Create my tour", systemImage: "sparkles") { start() }
                Text("Renders right on your phone. Publishing the share link needs a free sign-in.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Data

    private func loadEntitlements() async {
        guard Config.useLiveBackend else { return }
        entitlementsChecked = false
        guard !Config.enableAuth || auth.isSignedIn else {
            entitlements = nil
            entitlementsChecked = true
            if tier != .smooth { tier = .smooth }
            return
        }
        let summary = try? await model.api.me()
        entitlements = summary?.entitlements
        entitlementsChecked = true
        if aiTiersLocked && tier != .smooth { tier = .smooth }
    }

    /// Prefill Handheld/Drone. The heuristic (DJI/Autel/Skydio/Parrot… in the
    /// container metadata or the file name) already ran in `MediaImporter` when
    /// the file was imported, so read its answer instead of loading the whole
    /// metadata of a multi-GB file a second time on this screen. Recorded takes
    /// come in as `isDrone: false`, which is simply correct.
    private func detectSourceIfNeeded() {
        guard !didDetectSource else { return }
        didDetectSource = true
        // Cheap belt-and-braces for assets stored before the importer looked at
        // the name (persisted from an earlier build).
        if asset.isDrone || MediaImporter.filenameLooksLikeDrone(asset.localURL) {
            sourceKind = .drone
        }
    }

    // MARK: - Submit

    /// Store the asset (with the explicit footage type), remember the render
    /// settings, and hand the work to the coordinator — it owns the task, so
    /// navigation can't cancel or restart it. Then show progress.
    private func start() {
        var a = asset
        a.isDrone = (sourceKind == .drone)
        asset = a
        model.assets[listing.id] = a               // so the flythrough plays YOUR video

        let chosenTier: Render.Tier = (tier.usesServerAI && aiTiersLocked) ? .smooth : tier
        // Decision A5: enhancements always default — nothing restages video.
        let r = Render(listingID: listing.id, tier: chosenTier, durationS: a.durationS, enhancements: Enhancements())
        model.renders[listing.id] = r
        render = r
        model.setLastError(nil, for: listing.id)
        model.renderCoordinator.start(listing: listing, asset: a)   // sets .processing
        goToStatus = true
    }
}

// MARK: - Room tagger (scrub the video, drop a tag at the playhead)
// Uploaded videos have no live room tags, so this lets the agent scrub through
// and mark where each room begins. Those timestamps drive the player's
// tap-to-jump dots.

/// Everything the tagger needs to ask the AI to watch this walkthrough. nil on
/// the pre-upload path (ReviewSubmitView): the video only exists on the phone
/// there, so the whole feature is absent and the tagger behaves exactly as it
/// did before.
struct RoomTagSuggestSource {
    let api: APIClient
    /// `listings.id` on the server (never the local id).
    let listingServerID: UUID
    /// `capture_assets.id` of the video the SERVER will watch.
    let assetID: UUID
    /// Multiply a suggestion's `start_s` by this to land on the CAPTURE
    /// timeline that `RoomTag.tMs` is written in. See
    /// `RoomTaggerView.captureMilliseconds` for the derivation.
    let assetSecondsToCaptureScale: Double
    /// True when `assetID` is the RENDERED (retimed) mp4 rather than the raw
    /// capture. Only a render needs rescaling.
    let isRenderAsset: Bool

    /// The scale actually applied. A CAPTURE asset is already on the capture
    /// timeline, so any factor but 1 there would be a wiring mistake, not a
    /// conversion — this makes that impossible rather than merely documented.
    var effectiveScale: Double { isRenderAsset ? assetSecondsToCaptureScale : 1 }
}

/// "Once per asset" (contract §5.1) has to outlive the sheet: the tagger is a
/// `.sheet` body, so its `@State` is thrown away every time it closes. This
/// remembers, for the life of the process, which assets already had their one
/// automatic attempt — including the ones that FAILED, so a 503 doesn't turn
/// into a call on every re-open.
@MainActor
enum RoomTagSuggestionMemory {
    private static var attempted: Set<UUID> = []

    static func hasAttempted(_ assetID: UUID) -> Bool { attempted.contains(assetID) }
    static func markAttempted(_ assetID: UUID) { attempted.insert(assetID) }
}

struct RoomTaggerView: View {
    let videoURL: URL
    @Binding var tags: [RoomTag]
    /// nil = no "Suggest room names" anywhere on this screen.
    let suggest: RoomTagSuggestSource?
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var current: Double = 0
    @State private var isPlaying = false
    @State private var scrubbing = false
    @State private var customName = ""
    @State private var observer: Any?

    // Auto room chapters
    @State private var isSuggesting = false
    /// Only ever set by the BUTTON path. The automatic path fails silently
    /// (contract §5.5) — nobody who didn't ask for AI gets an error.
    @State private var suggestError: String?
    /// Server strings, shown verbatim (contract §5.4).
    @State private var suggestWarnings: [String] = []
    @State private var suggestNote: String?
    @State private var didAutoRun = false

    init(videoURL: URL, tags: Binding<[RoomTag]>, suggest: RoomTagSuggestSource? = nil) {
        self.videoURL = videoURL
        self._tags = tags
        self.suggest = suggest
        _player = State(initialValue: AVPlayer(url: videoURL))
    }

    private var sortedTags: [RoomTag] { tags.sorted { $0.tMs < $1.tMs } }

    private var aiTagCount: Int { tags.filter { $0.isFromAI }.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                playerCard
                scrubberBlock
                hintText
                suggestionBlock
                quickTagStrip
                customNameRow
                Divider()
                tagListBlock
            }
            .padding(.top)
            .background(Theme.bg)
            .navigationTitle(SpaceType.current == .realEstate ? "Tag rooms" : "Tag areas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Discard BEFORE `dismiss()`, not only in `onDisappear`:
                    // the host's `.sheet(onDismiss:)` is what PATCHes chapters,
                    // and SwiftUI does not promise that a sheet's `onDisappear`
                    // runs before it. Doing it here makes the binding already
                    // clean on the Done path regardless of that order.
                    Button("Done") {
                        discardUnconfirmedAITags()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: setup)
            .onDisappear(perform: teardown)
            .task { await autoSuggestIfNeeded() }
        }
        // Guideline 5.1.2(i): the disclosure has to be able to draw INSIDE this
        // sheet, because that is where the AI call is made from.
        .aiConsentGate()
    }

    // MARK: Player + scrubber

    private var playerCard: some View {
        PlayerLayerView(player: player)
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
    }

    private var scrubberBlock: some View {
        VStack(spacing: 4) {
            Slider(value: $current, in: 0...max(duration, 0.1)) { editing in
                scrubbing = editing
                if editing { player.pause(); isPlaying = false }
                else { seek(to: current) }
            }
            .tint(Theme.accent)
            transportRow
        }
        .padding(.horizontal)
    }

    private var transportRow: some View {
        HStack {
            Text(timeLabel(current)).font(.rpMono).foregroundStyle(Theme.inkDim)
            Spacer()
            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityLabel(Text(isPlaying ? "Pause" : "Play"))
            Spacer()
            Text(timeLabel(duration)).font(.rpMono).foregroundStyle(Theme.inkDim)
        }
    }

    private var hintText: some View {
        Text("Scrub to where a room begins, then tap its name to drop a marker.")
            .font(.rpCaption)
            .foregroundStyle(Theme.inkDim)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }

    // MARK: "Suggest room names"

    @ViewBuilder
    private var suggestionBlock: some View {
        if suggest != nil {
            VStack(alignment: .leading, spacing: 8) {
                suggestButtonRow
                suggestStatusLines
                aiBanner
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var suggestButtonRow: some View {
        if isSuggesting {
            HStack(spacing: 10) {
                ProgressView()
                Text("Watching your walkthrough… about 10 seconds")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button { Task { await runSuggest(automatic: false) } } label: {
                Label(aiTagCount > 0 ? "Suggest room names again" : "Suggest room names",
                      systemImage: "sparkles")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    @ViewBuilder
    private var suggestStatusLines: some View {
        if let suggestError {
            Text(suggestError)
                .font(.rpCaption)
                .foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let suggestNote {
            Text(suggestNote)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(suggestWarnings.enumerated()), id: \.offset) { pair in
            Text(pair.element)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The accept step. Nothing the AI proposed reaches the hosted tour until
    /// it passes through here or through an individual edit/keep, so this
    /// banner is not decoration — it is the consent.
    ///
    /// "Use these names" accepts the whole set in one tap (the common case: the
    /// names are right). "Clear these" removes them in one tap. Doing neither
    /// is also an answer: an untouched suggestion is dropped on the way out,
    /// which is what the third line says out loud so nobody is surprised.
    @ViewBuilder
    private var aiBanner: some View {
        if aiTagCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.aiBannerText(aiTagCount))
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button("Use these names") { acceptAITags() }
                        .font(.rpCaption.weight(.semibold))
                    Button("Clear these") { clearAITags() }
                        .font(.rpCaption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                Text(Self.aiDiscardWarning)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Quick tags / custom name

    private var quickTagStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RoomTag.quickNames, id: \.self) { name in
                    Button { addTag(name) } label: {
                        Text(name)
                            .font(.rpCaption.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Theme.accentSoft, in: Capsule())
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var customNameRow: some View {
        HStack {
            TextField("Custom room name", text: $customName)
                .textFieldStyle(.roundedBorder)
            Button { addTag(customName); customName = "" } label: {
                Image(systemName: "plus.circle.fill").font(.title3)
            }
            .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel(Text("Add custom room tag"))
        }
        .padding(.horizontal)
    }

    // MARK: The tag list

    private var tagListBlock: some View {
        ScrollView {
            VStack(spacing: 6) {
                if sortedTags.isEmpty {
                    Text("No rooms tagged yet.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .padding(.top, 8)
                }
                ForEach(sortedTags) { tag in
                    tagRow(tag)
                }
            }
        }
    }

    private func tagRow(_ tag: RoomTag) -> some View {
        HStack {
            Button { seek(to: tag.tSeconds) } label: {
                tagRowLabel(tag)
            }
            Spacer()
            if tag.isFromAI { keepButton(tag) }
            deleteButton(tag)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private func tagRowLabel(_ tag: RoomTag) -> some View {
        HStack(spacing: 8) {
            Text(timeLabel(tag.tSeconds)).font(.rpMono).foregroundStyle(Theme.accent)
            Text(tag.name).foregroundStyle(Theme.ink)
            if tag.isFromAI { aiChip }
        }
        .opacity(tag.isLowConfidence ? 0.6 : 1)
    }

    private var aiChip: some View {
        Text("AI suggested")
            .font(.rpCaption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Theme.accentSoft, in: Capsule())
    }

    private func keepButton(_ tag: RoomTag) -> some View {
        Button {
            confirmTag(tag)
        } label: {
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.good)
        }
        .accessibilityLabel(Text("Keep \(tag.name)"))
    }

    private func deleteButton(_ tag: RoomTag) -> some View {
        Button {
            tags.removeAll { $0.id == tag.id }
            Haptics.selection()
        } label: {
            Image(systemName: "trash").foregroundStyle(Theme.inkDim)
        }
        .accessibilityLabel(Text("Remove \(tag.name) tag"))
    }

    // MARK: Player plumbing (unchanged)

    private func setup() {
        Task {
            let d = (try? await AVURLAsset(url: videoURL).load(.duration))?.seconds ?? 0
            await MainActor.run { duration = d.isFinite ? d : 0 }
        }
        guard observer == nil else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
            guard !scrubbing else { return }
            current = t.seconds.isFinite ? t.seconds : 0
        }
    }

    /// Player teardown, plus the AI discard for every way out that is NOT the
    /// Done button — a swipe-down on the sheet, or a parent that dismisses it.
    /// `onDisappear` is the only hook those paths pass through. It is safe to
    /// run twice: `discardUnconfirmedAITags` is idempotent.
    private func teardown() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.pause()
        discardUnconfirmedAITags()
    }

    private func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        Haptics.selection()
    }

    private func seek(to t: Double) {
        player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        current = t
    }

    /// Drop a marker at the playhead. A second tap at the same moment (within
    /// half a second) renames the existing marker instead of stacking a second
    /// dot the player could never activate. Renaming an AI suggestion is the
    /// person touching it, so the "AI suggested" mark comes off.
    private func addTag(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let tMs = Int((current * 1000).rounded())
        if let i = tags.firstIndex(where: { abs($0.tMs - tMs) < 500 }) {
            tags[i].name = name
            tags[i].isAISuggested = nil
            tags[i].aiConfidence = nil
        } else {
            tags.append(RoomTag(name: name, tMs: tMs))
        }
        Haptics.success()
    }

    private func confirmTag(_ tag: RoomTag) {
        guard let i = tags.firstIndex(where: { $0.id == tag.id }) else { return }
        tags[i].isAISuggested = nil
        tags[i].aiConfidence = nil
        Haptics.selection()
    }

    /// "Use these names": the whole set at once, which is the same act as
    /// tapping the tick on every row. Clearing `isAISuggested` IS the
    /// acceptance — `isFromAI` means "still exactly what the AI proposed, and
    /// nobody has looked", and that is the flag the publish path reads.
    private func acceptAITags() {
        for i in tags.indices where tags[i].isFromAI {
            tags[i].isAISuggested = nil
            tags[i].aiConfidence = nil
        }
        suggestNote = nil
        Haptics.success()
    }

    private func clearAITags() {
        tags.removeAll { $0.isFromAI }
        suggestNote = nil
        suggestWarnings = []
        Haptics.selection()
    }

    /// THE SAFETY RULE. Every way out of this sheet runs this, and it deletes
    /// every tag still marked `isAISuggested == true`.
    ///
    /// Why it has to be a delete and not a filter later: closing the tagger
    /// after the tags changed PATCHes chapters onto the hosted tour
    /// (`FlythroughDetailView.roomTaggerDismissed`), and the next publish
    /// rebuilds chapters from these same tags (`AppModel.publishTour`). An
    /// auto-filled tagger that someone opened and closed without reading would
    /// otherwise put a model's guesses at room names in front of buyers with no
    /// human ever having seen them. Suggestions the person accepted ("Use these
    /// names"), renamed, or ticked have already had `isAISuggested` cleared, so
    /// they are not in this set and survive untouched.
    ///
    /// Discarding here also means the tags never reach the model, so there is
    /// nothing for a later publish to leak — the fix is at the source, not at
    /// each write.
    private func discardUnconfirmedAITags() {
        guard tags.contains(where: { $0.isFromAI }) else { return }
        tags.removeAll { $0.isFromAI }
    }

    private func timeLabel(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Auto room chapters

    /// One automatic attempt per asset per process, only on an EMPTY tagger,
    /// and only when the person has already agreed to third-party AI
    /// processing. Consent is never *asked for* here: an unprompted disclosure
    /// sheet on a screen someone opened to type room names is not a request
    /// they made. The button asks properly.
    @MainActor
    private func autoSuggestIfNeeded() async {
        guard let source = suggest, !didAutoRun else { return }
        didAutoRun = true
        guard tags.isEmpty else { return }
        guard !RoomTagSuggestionMemory.hasAttempted(source.assetID) else { return }
        guard AIConsent.shared.isGranted else { return }
        await runSuggest(automatic: true)
    }

    /// `automatic == false` is the button: it asks for consent if needed and
    /// shows the server's own message on failure. `automatic == true` is
    /// silent on every failure (contract §5.5).
    @MainActor
    private func runSuggest(automatic: Bool) async {
        guard let source = suggest, !isSuggesting else { return }
        if !automatic {
            guard await AIConsent.shared.ensureGranted() else { return }
        }
        RoomTagSuggestionMemory.markAttempted(source.assetID)
        isSuggesting = true
        // A new attempt owns the status area outright — a stale warning from
        // the last run under a fresh set of names would be a lie.
        suggestError = nil
        suggestNote = nil
        suggestWarnings = []
        defer { isSuggesting = false }
        do {
            let result = try await source.api.aiChapters(
                listingServerID: source.listingServerID,
                assetID: source.assetID,
                maxChapters: 12,
                // ONE UUID PER TAP: a retry of the same tap is 409'd
                // server-side rather than billed twice (contract §1).
                idempotencyKey: UUID().uuidString)
            apply(result, automatic: automatic)
        } catch {
            if error is CancellationError { return }
            guard !automatic else { return }
            suggestError = UserFacingError.message(
                error, fallback: "Couldn't read the walkthrough just now. Tag the rooms yourself and try again later.")
        }
    }

    @MainActor
    private func apply(_ result: AIChaptersResult, automatic: Bool) {
        suggestWarnings = result.warnings
        guard result.hasSuggestions else {
            suggestNote = automatic ? nil : "The AI didn't find any rooms it was sure about. Tag them yourself below."
            return
        }
        let added = merge(result.chapters)
        suggestNote = Self.appliedNote(added: added, total: result.chapters.count)
        if added > 0 { Haptics.success() }
    }

    /// Add each suggestion as a normal, editable tag. A moment already carrying
    /// a tag is left alone — a suggestion never overwrites something a person
    /// put there (same half-second rule `addTag` uses).
    @MainActor
    private func merge(_ chapters: [AIChapter]) -> Int {
        guard let source = suggest else { return 0 }
        var next = tags
        var added = 0
        for chapter in chapters {
            let tMs = Self.captureMilliseconds(assetSeconds: chapter.startSeconds,
                                               scale: source.effectiveScale)
            if next.contains(where: { abs($0.tMs - tMs) < 500 }) { continue }
            var tag = RoomTag(name: chapter.roomLabel, tMs: tMs)
            tag.isAISuggested = true
            tag.aiConfidence = chapter.confidenceScore
            next.append(tag)
            added += 1
        }
        guard added > 0 else { return 0 }
        tags = next.sorted { $0.tMs < $1.tMs }
        return added
    }

    // MARK: The time base (get this wrong and every dot is in the wrong room)
    //
    // `start_s` is seconds from t=0 of the asset we SUBMITTED — the server
    // never rescales anything (`time_base: "asset_seconds"`,
    // docs/AI-CHAPTERS-CONTRACT.md §3).
    //
    // Rendprop has two timelines for one walk:
    //   • CAPTURE  — the raw video. `RoomTag.tMs` and this scrubber live here.
    //   • RENDERED — the on-device render, retimed by `speedFactor`. The
    //     published mp4 and `capture_chapters.t_ms` live here.
    //
    // `AppModel.chapters(from:speedFactor:)` and
    // `FlythroughDetailView.playbackTags` both go capture → rendered by
    // DIVIDING by speedFactor:
    //
    //     render_s = capture_s / speedFactor
    //  ⇒  capture_s = render_s × speedFactor
    //
    // So the scale from submitted-asset seconds to capture seconds is
    // `speedFactor` when we submitted the RENDER, and 1 when we submitted the
    // capture itself. Worked example, speedFactor 2.0 (a 2× glide):
    //
    //     a room the walker entered at CAPTURE  41.0 s
    //       sits in the render at 41.0 / 2.0 =  20.5 s
    //     the model watches the render and returns start_s = 20.5
    //       → 20.5 × 2.0 × 1000 = 41 000 ms  → the scrubber lands on 41.0 s ✓
    //     Done → publish divides by 2.0 again → 20 500 ms on the hosted tour ✓

    /// Suggestion seconds → `RoomTag.tMs` on the capture timeline.
    static func captureMilliseconds(assetSeconds: Double, scale: Double) -> Int {
        guard assetSeconds.isFinite, assetSeconds > 0 else { return 0 }
        let factor = (scale.isFinite && scale > 0) ? scale : 1.0
        let ms = (assetSeconds * factor * 1000).rounded()
        guard ms.isFinite, ms > 0 else { return 0 }
        // A degenerate duration must not overflow the Int conversion (F-A-26).
        return Int(min(ms, 24 * 60 * 60 * 1000))
    }

    // MARK: Copy

    private static func aiBannerText(_ count: Int) -> String {
        count == 1
            ? "AI suggested 1 room name — tap Use these to keep it, or edit it."
            : "AI suggested \(count) room names — tap Use these to keep them, or edit any."
    }

    /// Said out loud, because doing nothing is a real choice here and its
    /// consequence must not be a surprise.
    private static let aiDiscardWarning =
        "Names still marked \u{201C}AI suggested\u{201D} are dropped when you close this — nothing "
        + "the AI wrote reaches your tour until you keep it."

    private static func appliedNote(added: Int, total: Int) -> String? {
        if added == 0 { return "Your own markers are already at those moments — nothing was changed." }
        if added == total { return nil }
        return "\(added) of \(total) suggestions were added; the rest landed on markers you'd already placed."
    }
}

/// AVPlayerLayer-backed view — a bare video frame with no default controls
/// (the scrubber above is ours).
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainer {
        let v = PlayerContainer()
        v.playerLayer?.player = player
        v.playerLayer?.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PlayerContainer, context: Context) {
        uiView.playerLayer?.player = player
    }

    final class PlayerContainer: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        /// Always an AVPlayerLayer thanks to `layerClass`; optional cast keeps
        /// the file free of force-unwraps.
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    }
}
