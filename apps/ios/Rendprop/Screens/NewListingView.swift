import SwiftUI

/// Stupid-simple: type the address, then one of two big buttons —
/// Record or Upload. Everything else is optional and out of the way.
struct NewListingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var beds = 3
    @State private var baths = 2.0
    @State private var sqft = ""
    @State private var priceDollars = ""

    @State private var showCapture = false
    @State private var showUploadChoice = false
    @State private var showPhotoPicker = false
    @State private var showFilesPicker = false
    @State private var importIsDrone = false
    @State private var pendingAsset: CaptureAsset?
    @State private var goToReview = false
    @State private var createdListing: Listing?

    private var formValid: Bool { !address.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                // Step 1 — address
                VStack(alignment: .leading, spacing: 10) {
                    Label("Step 1 · The home", systemImage: "house.fill")
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.ink)
                    TextField("Type the home's address", text: $address)
                        .textContentType(.fullStreetAddress)
                        .font(.body)
                        .padding(14)
                        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                // Step 2 — video (two big buttons)
                VStack(alignment: .leading, spacing: 12) {
                    Label("Step 2 · The video", systemImage: "video.fill")
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.ink)

                    bigActionButton(
                        title: "Record a walkthrough",
                        subtitle: "Walk at your normal pace — we handle the rest",
                        icon: "record.circle.fill",
                        filled: true
                    ) {
                        guard prepareListing() else { return }
                        showCapture = true
                    }

                    bigActionButton(
                        title: "Use a video I already have",
                        subtitle: "From your Photos or a drone clip",
                        icon: "square.and.arrow.up.fill",
                        filled: false
                    ) {
                        guard prepareListing() else { return }
                        showUploadChoice = true
                    }

                    if !formValid {
                        Label("Type the address first, then pick one.", systemImage: "info.circle")
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                // Optional details — tucked away
                DisclosureGroup {
                    VStack(spacing: 14) {
                        Stepper("Bedrooms: \(beds)", value: $beds, in: 0...12)
                        Stepper(String(format: "Bathrooms: %g", baths), value: $baths, in: 0...12, step: 0.5)
                        TextField("Square feet", text: $sqft)
                            .keyboardType(.numberPad)
                            .padding(12)
                            .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        TextField("Asking price", text: $priceDollars)
                            .keyboardType(.numberPad)
                            .padding(12)
                            .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Home details (optional)", systemImage: "list.bullet")
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.ink)
                }
                .tint(Theme.inkDim)
                .card()
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("New Listing")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCapture) {
            CaptureView { asset in
                receive(asset)
            }
        }
        .confirmationDialog("Where is your video?", isPresented: $showUploadChoice, titleVisibility: .visible) {
            Button("My Photos") {
                importIsDrone = false
                showPhotoPicker = true
            }
            Button("A file or drone clip") {
                importIsDrone = true
                showFilesPicker = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoVideoPicker { url in
                Task {
                    let asset = await MediaImporter.makeAsset(from: url, isDrone: false)
                    await MainActor.run { receive(asset) }
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFilesPicker) {
            FilesVideoPicker { url in
                Task {
                    let asset = await MediaImporter.makeAsset(from: url, isDrone: importIsDrone)
                    await MainActor.run { receive(asset) }
                }
            }
            .ignoresSafeArea()
        }
        .navigationDestination(isPresented: $goToReview) {
            if let listing = createdListing, let asset = pendingAsset {
                ReviewSubmitView(listing: listing, asset: asset)
            }
        }
    }

    private func bigActionButton(title: String, subtitle: String, icon: String,
                                 filled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(filled ? Color.white : Theme.accent)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(filled ? Color.white : Theme.ink)
                    Text(subtitle)
                        .font(.rpCaption)
                        .foregroundStyle(filled ? Color.white.opacity(0.85) : Theme.inkDim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(filled ? Color.white.opacity(0.7) : Theme.inkDim)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(filled ? Theme.accent : Theme.accentSoft)
            )
            .opacity(formValid ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!formValid)
        .accessibilityLabel(Text("\(title). \(subtitle)"))
    }

    @discardableResult
    private func prepareListing() -> Bool {
        guard formValid else { return false }
        if createdListing == nil {
            let listing = Listing(address: address.trimmingCharacters(in: .whitespaces),
                                  beds: beds,
                                  baths: baths,
                                  sqft: Int(sqft) ?? 0,
                                  price: .dollars(Int(priceDollars) ?? 0),
                                  status: .draft)
            createdListing = listing
            model.add(listing)
        }
        return true
    }

    private func receive(_ asset: CaptureAsset) {
        pendingAsset = asset
        goToReview = true
    }
}
