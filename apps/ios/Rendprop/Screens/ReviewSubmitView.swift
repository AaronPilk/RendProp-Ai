import SwiftUI
import UIKit
import AVFoundation

/// Review the capture, edit room tags, pick a tier — price shown by duration
/// band (master spec Part 20: never flat-price a render).
struct ReviewSubmitView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var uploads: UploadManager

    let listing: Listing
    @State var asset: CaptureAsset

    @State private var tier: Render.Tier = .smooth
    @State private var enhancements = Enhancements()
    @State private var newTagName = ""
    @State private var showRoomTagger = false
    @State private var showCellularPrompt = false
    @State private var goToStatus = false
    @State private var render: Render?

    private var band: PricingBand.Band { PricingBand.band(forDuration: asset.durationS) }
    private var price: Money { band.prices[tier] ?? .dollars(0) }
    private var totalPrice: Money { Money(cents: price.cents + enhancements.addOnTotal.cents) }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                captureSummary
                roomTags
                tierPicker
                enhancementsCard
                priceSummary
                // No dollar amounts anywhere in the UI while enableIAP is false —
                // quoting USD prices with no purchase mechanism is an App Store
                // 3.1.1/2.3.1 rejection risk (2026-08-26 audit P0-3).
                PrimaryButton(title: "Create my tour", systemImage: "sparkles") {
                    submit()
                }
                Text("Included with your plan during early access.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("Review & Submit")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRoomTagger) {
            RoomTaggerView(videoURL: asset.localURL, tags: $asset.roomTags)
        }
        .confirmationDialog("Large upload on cellular",
                            isPresented: $showCellularPrompt,
                            titleVisibility: .visible) {
            Button("Continue on cellular") { start(cellularApproved: true) }
            Button("Wait for Wi-Fi") { start(cellularApproved: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This walkthrough is \(Formatters.bytes(asset.bytes)). Upload now on cellular, or queue it for Wi-Fi?")
        }
        .navigationDestination(isPresented: $goToStatus) {
            if let render {
                RenderStatusView(listing: listing, render: render)
            }
        }
    }

    // MARK: - Sections

    private var captureSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR VIDEO").font(.rpKicker).foregroundStyle(Theme.inkDim)
            HStack(spacing: 14) {
                Image(systemName: asset.isDrone ? "airplane" : "video.fill")
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
                        if asset.isDrone {
                            Text("Drone — skips stabilization")
                        }
                    }
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var roomTags: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(SpaceType.current == .realEstate ? "ROOMS" : "AREAS")
                .font(.rpKicker).foregroundStyle(Theme.inkDim)
            if asset.roomTags.isEmpty {
                Text("Tag areas on the video so \(SpaceType.current.customerNoun) can tap a dot and jump straight to \(SpaceType.current.quickTags.prefix(2).map { $0.lowercased() }.joined(separator: " or ")).")
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
                      ? (SpaceType.current == .realEstate ? "Tag rooms on the video" : "Tag areas on the video")
                      : (SpaceType.current == .realEstate ? "Edit room tags" : "Edit area tags"),
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
                Button {
                    // Match the design-style picker below: the fill/border glide
                    // between rows instead of snapping.
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { tier = t }
                    Haptics.selection()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: t.systemImage)
                            .font(.system(size: 18))
                            .foregroundStyle(tier == t ? Theme.accent : Theme.inkDim)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.displayName).font(.rpHeadline).foregroundStyle(Theme.ink)
                            Text(t.blurb)
                                .font(.rpCaption)
                                .foregroundStyle(Theme.inkDim)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Text((band.prices[t] ?? .dollars(0)).formatted)
                            .font(.rpHeadline)
                            .foregroundStyle(tier == t ? Theme.accent : Theme.ink)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(tier == t ? Theme.accentSoft : Theme.fillSubtle)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tier == t ? Theme.accent : Theme.border,
                                          lineWidth: tier == t ? 1.5 : 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var enhancementsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EXTRAS").font(.rpKicker).foregroundStyle(Theme.inkDim)

            // Declutter toggle
            Toggle(isOn: $enhancements.declutter.animation()) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 18))
                        .foregroundStyle(enhancements.declutter ? Theme.accent : Theme.inkDim)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        // Honest copy: today's AI declutter runs on listing PHOTOS
                        // (ai-photo). Full-video declutter isn't wired into the tour
                        // flow yet (Bria caps video input at <5 s) — no future
                        // promises in user-facing copy (App Store 2.3.1).
                        Text("AI declutter (photos)")
                            .font(.rpHeadline)
                        Text("Removes clutter and personal items from your listing photos with AI.")
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                    }
                }
            }
            .tint(Theme.accent)
            .onChange(of: enhancements.declutter) { _ in Haptics.selection() }

            Divider()

            // Design style picker
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Design style")
                        .font(.rpHeadline)
                    Spacer()
                    if enhancements.style != .asIs {
                        Text("Included")
                            .font(.rpCaption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text("Give the rooms new furniture and decor in a style you pick. Walls and windows stay exactly the same.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(DesignStyle.allCases) { style in
                            Button {
                                withAnimation(.spring(response: 0.3)) { enhancements.style = style }
                                Haptics.selection()
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: style.systemImage)
                                        .font(.system(size: 20))
                                        .foregroundStyle(enhancements.style == style ? Theme.accent : Theme.inkDim)
                                    Text(style.displayName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(enhancements.style == style ? Theme.ink : Theme.inkDim)
                                }
                                .frame(width: 92, height: 74)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(enhancements.style == style ? Theme.accentSoft : Theme.fillSubtle)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(enhancements.style == style ? Theme.accent : Theme.border,
                                                      lineWidth: enhancements.style == style ? 1.5 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("\(style.displayName) style. \(style.blurb)"))
                        }
                    }
                    .padding(.vertical, 2)
                }
                if let selected = DesignStyle.allCases.first(where: { $0 == enhancements.style }), selected != .asIs {
                    Text(selected.blurb)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                }
            }

            if enhancements.isActive {
                // AI preview/enhancement runs server-side after upload (see
                // RenderStatusView). No provider keys ship in the app binary.
                Label(SpaceType.current == .realEstate
                      ? "Your shared tour will show a small \"Virtually staged\" label — real-estate rules require it for edited videos."
                      : "Your shared tour will show a small \"Virtually staged\" label so viewers know the video was edited.",
                      systemImage: "info.circle")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var priceSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Length band")
                Spacer()
                Text(band.name).foregroundStyle(Theme.inkDim)
            }
            HStack {
                Text("Tier · \(tier.displayName)")
                Spacer()
                Text("Included").foregroundStyle(Theme.inkDim)
            }
            if enhancements.declutter {
                HStack {
                    Text("AI declutter (photos)")
                    Spacer()
                    Text("Included").foregroundStyle(Theme.inkDim)
                }
            }
            if enhancements.style != .asIs {
                HStack {
                    Text("Restage · \(enhancements.style.displayName)")
                    Spacer()
                    Text("Included").foregroundStyle(Theme.inkDim)
                }
            }
            Divider()
            HStack {
                Text("Your plan").font(.rpHeadline)
                Spacer()
                Text("Early access").font(.rpHeadline).foregroundStyle(Theme.accent)
            }
        }
        .font(.rpBody)
        .foregroundStyle(Theme.ink)
        .card()
    }

    // MARK: - Submit

    private func submit() {
        if uploads.shouldWarnCellular(bytes: asset.bytes) {
            showCellularPrompt = true
        } else {
            start(cellularApproved: false)
        }
    }

    private func start(cellularApproved: Bool) {
        model.assets[listing.id] = asset            // so the flythrough plays YOUR video

        // LIVE (local-first + cloud-publish): the on-device render IS the tour.
        // Do NOT upload the raw capture and do NOT create a server render job here
        // (that was the Python-worker path). Rendering + publishing happen in
        // RenderStatusView → AppModel.publishTour after the on-device render.
        if Config.useLiveBackend {
            self.render = Render(listingID: listing.id, tier: tier,
                                 durationS: asset.durationS, enhancements: enhancements)
            model.setStatus(.processing, for: listing.id)
            goToStatus = true
            return
        }

        // OFFLINE / worker path (unchanged): upload the raw capture + create the
        // render job so the simulated pipeline can track it.
        let meta = UploadMetadata(durationS: asset.durationS, fps: asset.fps,
                                  width: asset.width, height: asset.height,
                                  isDrone: asset.isDrone, hasGyro: asset.hasGyro,
                                  bytes: asset.bytes)
        uploads.begin(fileURL: asset.localURL, listingID: listing.id,
                      metadata: meta, cellularApproved: cellularApproved)
        model.setStatus(.uploading, for: listing.id)
        Task {
            // Contract requires asset_id on POST /renders. We pass the local
            // CaptureAsset.id today; TODO thread the server asset_id returned by
            // createUpload once upload→render sequencing is wired for live.
            let r = try? await model.api.createRender(listingID: listing.id,
                                                      assetID: asset.id,
                                                      tier: tier,
                                                      durationS: asset.durationS,
                                                      enhancements: enhancements)
            await MainActor.run {
                self.render = r ?? Render(listingID: listing.id, tier: tier,
                                          durationS: asset.durationS, enhancements: enhancements)
                model.setStatus(.processing, for: listing.id)
                goToStatus = true
            }
        }
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

    private func addTag(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        tags.append(RoomTag(name: name, tMs: Int(current * 1000)))
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
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PlayerContainer, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerContainer: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
