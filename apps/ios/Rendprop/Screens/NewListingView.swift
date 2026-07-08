import SwiftUI

struct NewListingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var beds = 3
    @State private var baths = 2.0
    @State private var sqft = ""
    @State private var priceDollars = ""

    @State private var showCapture = false
    @State private var showPhotoPicker = false
    @State private var showFilesPicker = false
    @State private var importIsDrone = false
    @State private var pendingAsset: CaptureAsset?
    @State private var goToReview = false
    @State private var createdListing: Listing?

    private var formValid: Bool { !address.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            Section("Property") {
                TextField("Street address", text: $address)
                    .textContentType(.fullStreetAddress)
                Stepper("Beds: \(beds)", value: $beds, in: 0...12)
                Stepper(String(format: "Baths: %g", baths), value: $baths, in: 0...12, step: 0.5)
                TextField("Square feet", text: $sqft)
                    .keyboardType(.numberPad)
                TextField("Price (USD)", text: $priceDollars)
                    .keyboardType(.numberPad)
            }

            Section("Walkthrough") {
                Button {
                    guard prepareListing() else { return }
                    showCapture = true
                } label: {
                    Label("Record now", systemImage: "record.circle")
                        .fontWeight(.semibold)
                }
                .disabled(!formValid)

                Button {
                    guard prepareListing() else { return }
                    importIsDrone = false
                    showPhotoPicker = true
                } label: {
                    Label("Import from Photos", systemImage: "photo.on.rectangle")
                }
                .disabled(!formValid)

                Button {
                    guard prepareListing() else { return }
                    importIsDrone = true
                    showFilesPicker = true
                } label: {
                    Label("Import from Files (drone clip)", systemImage: "folder")
                }
                .disabled(!formValid)
            } footer: {
                Text("One continuous take works best. Walk slow, keep the phone level at chest height, and end on the best exterior.")
            }
        }
        .navigationTitle("New Listing")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCapture) {
            CaptureView { asset in
                receive(asset)
            }
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
