import SwiftUI

/// Review the capture, edit room tags, pick a tier — price shown by duration
/// band (master spec Part 20: never flat-price a render).
struct ReviewSubmitView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var uploads: UploadManager

    let listing: Listing
    @State var asset: CaptureAsset

    @State private var tier: Render.Tier = .smooth
    @State private var newTagName = ""
    @State private var showCellularPrompt = false
    @State private var goToStatus = false
    @State private var render: Render?

    private var band: PricingBand.Band { PricingBand.band(forDuration: asset.durationS) }
    private var price: Money { band.prices[tier] ?? .dollars(0) }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                captureSummary
                roomTags
                tierPicker
                priceSummary
                PrimaryButton(title: "Submit render · \(price.formatted)", systemImage: "paperplane.fill") {
                    submit()
                }
                Text("Mock checkout — Apple In-App Purchase (StoreKit 2) lands in Phase 2.")
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
    }

    // MARK: - Sections

    private var captureSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WALKTHROUGH").font(.rpKicker).foregroundStyle(Theme.inkDim)
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
                Text("No rooms tagged. Add them so viewers can jump to any room.")
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
            Text("RENDER TIER").font(.rpKicker).foregroundStyle(Theme.inkDim)
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
                            .fill(tier == t ? Theme.accent.opacity(0.10) : Color.white.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tier == t ? Theme.accent : Color.white.opacity(0.08),
                                          lineWidth: tier == t ? 1.5 : 1)
                    )
                }
                .buttonStyle(.plain)
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
                Text("Tier")
                Spacer()
                Text(tier.displayName).foregroundStyle(Theme.inkDim)
            }
            Divider().overlay(Color.white.opacity(0.1))
            HStack {
                Text("Total").font(.rpHeadline)
                Spacer()
                Text(price.formatted).font(.rpTitle).foregroundStyle(Theme.accent)
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
        uploads.begin(fileURL: asset.localURL, cellularApproved: cellularApproved)
        model.setStatus(.uploading, for: listing.id)
        Task {
            let r = try? await model.api.createRender(listingID: listing.id,
                                                      tier: tier,
                                                      durationS: asset.durationS)
            await MainActor.run {
                self.render = r ?? Render(listingID: listing.id, tier: tier, durationS: asset.durationS)
                model.setStatus(.processing, for: listing.id)
                goToStatus = true
            }
        }
    }
}
