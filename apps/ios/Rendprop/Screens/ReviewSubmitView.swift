import SwiftUI

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
    @State private var showCellularPrompt = false
    @State private var showPreview = false
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
                PrimaryButton(title: "Create my tour · \(totalPrice.formatted)", systemImage: "sparkles") {
                    submit()
                }
                Text("Test mode — no real charge yet.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("Review & Submit")
        .navigationBarTitleDisplayMode(.inline)
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
        .sheet(isPresented: $showPreview) {
            EnhancementPreviewView(asset: asset,
                                   declutter: enhancements.declutter,
                                   style: enhancements.style)
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
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Formatters.duration(asset.durationS)) · \(asset.resolutionLabel) · \(Int(asset.fps.rounded())) fps")
                        .font(.rpHeadline)
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
            Text("ROOMS").font(.rpKicker).foregroundStyle(Theme.inkDim)
            if asset.roomTags.isEmpty {
                Text("Add room names so buyers can jump straight to the kitchen, primary, or backyard.")
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
            HStack {
                TextField("Add a room…", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let name = newTagName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    asset.roomTags.append(RoomTag(name: name, tMs: 0))
                    newTagName = ""
                    Haptics.selection()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
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
                    tier = t
                    Haptics.selection()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: t.systemImage)
                            .font(.system(size: 18))
                            .foregroundStyle(tier == t ? Theme.accent : Theme.inkDim)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.displayName).font(.rpHeadline)
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
                        Text("Clean up clutter · +\(Enhancements.declutterPrice.formatted)")
                            .font(.rpHeadline)
                        Text("We remove boxes and mess from the video. The home itself never changes.")
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
                        Text("+\(Enhancements.restagePrice.formatted)")
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
                if Secrets.aiEnabled {
                    Button {
                        showPreview = true
                        Haptics.selection()
                    } label: {
                        Label("Preview this look on my video", systemImage: "eye")
                            .font(.rpHeadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Label("Your shared tour will show a small \"Virtually staged\" label — real-estate rules require it for edited videos.",
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
                Text(price.formatted).foregroundStyle(Theme.inkDim)
            }
            if enhancements.declutter {
                HStack {
                    Text("Auto-declutter")
                    Spacer()
                    Text("+\(Enhancements.declutterPrice.formatted)").foregroundStyle(Theme.inkDim)
                }
            }
            if enhancements.style != .asIs {
                HStack {
                    Text("Restage · \(enhancements.style.displayName)")
                    Spacer()
                    Text("+\(Enhancements.restagePrice.formatted)").foregroundStyle(Theme.inkDim)
                }
            }
            Divider()
            HStack {
                Text("Total").font(.rpHeadline)
                Spacer()
                Text(totalPrice.formatted).font(.rpTitle).foregroundStyle(Theme.accent)
            }
        }
        .font(.rpBody)
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
        uploads.begin(fileURL: asset.localURL, cellularApproved: cellularApproved)
        model.setStatus(.uploading, for: listing.id)
        Task {
            let r = try? await model.api.createRender(listingID: listing.id,
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
