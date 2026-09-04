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
        .task { await detectSourceIfNeeded() }
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
                    HStack(spacing: 8) {
                        Text(Formatters.bytes(asset.bytes))
                        if asset.hasGyro {
                            Label("Gyro sidecar", systemImage: "gyroscope")
                                .foregroundStyle(Theme.good)
                        }
                    }
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { tier = t }
            Haptics.selection()
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

    /// Prefill Handheld/Drone from the file: DJI/Autel/Skydio/Parrot in the
    /// container metadata (make/model/software) or a DJI-style filename.
    private func detectSourceIfNeeded() async {
        guard !didDetectSource else { return }
        didDetectSource = true
        if asset.isDrone { sourceKind = .drone; return }
        if await Self.looksLikeDrone(asset.localURL) { sourceKind = .drone }
    }

    static func looksLikeDrone(_ url: URL) async -> Bool {
        let makers = ["DJI", "AUTEL", "SKYDIO", "PARROT", "HASSELBLAD"]
        let name = url.lastPathComponent.uppercased()
        if makers.contains(where: { name.hasPrefix($0) }) { return true }
        let av = AVURLAsset(url: url)
        var strings: [String] = []
        if let items = try? await av.load(.metadata) {
            for item in items {
                if let s = try? await item.load(.stringValue), !s.isEmpty { strings.append(s) }
            }
        }
        let joined = strings.joined(separator: " ").uppercased()
        return makers.contains { joined.contains($0) }
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

struct RoomTaggerView: View {
    let videoURL: URL
    @Binding var tags: [RoomTag]
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var current: Double = 0
    @State private var isPlaying = false
    @State private var scrubbing = false
    @State private var customName = ""
    @State private var observer: Any?

    init(videoURL: URL, tags: Binding<[RoomTag]>) {
        self.videoURL = videoURL
        self._tags = tags
        _player = State(initialValue: AVPlayer(url: videoURL))
    }

    private var sortedTags: [RoomTag] { tags.sorted { $0.tMs < $1.tMs } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                PlayerLayerView(player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal)

                VStack(spacing: 4) {
                    Slider(value: $current, in: 0...max(duration, 0.1)) { editing in
                        scrubbing = editing
                        if editing { player.pause(); isPlaying = false }
                        else { seek(to: current) }
                    }
                    .tint(Theme.accent)
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
                .padding(.horizontal)

                Text("Scrub to where a room begins, then tap its name to drop a marker.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

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

                Divider()

                ScrollView {
                    VStack(spacing: 6) {
                        if sortedTags.isEmpty {
                            Text("No rooms tagged yet.")
                                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                                .padding(.top, 8)
                        }
                        ForEach(sortedTags) { tag in
                            HStack {
                                Button { seek(to: tag.tSeconds) } label: {
                                    HStack(spacing: 8) {
                                        Text(timeLabel(tag.tSeconds)).font(.rpMono).foregroundStyle(Theme.accent)
                                        Text(tag.name).foregroundStyle(Theme.ink)
                                    }
                                }
                                Spacer()
                                Button {
                                    tags.removeAll { $0.id == tag.id }
                                    Haptics.selection()
                                } label: {
                                    Image(systemName: "trash").foregroundStyle(Theme.inkDim)
                                }
                                .accessibilityLabel(Text("Remove \(tag.name) tag"))
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(.top)
            .background(Theme.bg)
            .navigationTitle(SpaceType.current == .realEstate ? "Tag rooms" : "Tag areas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: setup)
            .onDisappear(perform: teardown)
        }
    }

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

    private func teardown() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.pause()
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
    /// dot the player could never activate.
    private func addTag(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let tMs = Int((current * 1000).rounded())
        if let i = tags.firstIndex(where: { abs($0.tMs - tMs) < 500 }) {
            tags[i].name = name
        } else {
            tags.append(RoomTag(name: name, tMs: tMs))
        }
        Haptics.success()
    }

    private func timeLabel(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
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
