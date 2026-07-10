import SwiftUI
import UIKit
import CoreLocation

/// Stupid-simple: type the address, then one of two big buttons —
/// Record or Upload. Everything else is optional and out of the way.
struct NewListingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var locator = OneShotLocation()
    @State private var locating = false
    @State private var pendingCoord: CLLocationCoordinate2D?

    @State private var address = ""
    @State private var beds = 3
    @State private var baths = 2.0
    @State private var sqft = ""
    @State private var priceDollars = ""
    @State private var tagline = ""
    @State private var pendingDetails: [String: String] = [:]

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
                    Label("Step 1 · The \(SpaceType.current.spaceNoun)", systemImage: SpaceType.current.systemImage)
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.ink)
                    TextField(SpaceType.current.showsPropertyDetails
                              ? "Type the home's address"
                              : "Name or address of your \(SpaceType.current.spaceNoun)", text: $address)
                        .textContentType(.fullStreetAddress)
                        .font(.body)
                        .padding(14)
                        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        useCurrentLocation()
                    } label: {
                        HStack(spacing: 8) {
                            if locating { ProgressView() }
                            else { Image(systemName: "location.fill") }
                            Text(locating ? "Finding you…" : "Use current location")
                        }
                        .font(.rpBody.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .disabled(locating)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                // Step 2 — video (two big buttons)
                VStack(alignment: .leading, spacing: 12) {
                    Label("Step 2 · The video", systemImage: "video.fill")
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.ink)

                    bigActionButton(
                        title: "Upload a video",
                        subtitle: "Use a clip from your Photos or a drone — the easiest way",
                        icon: "square.and.arrow.up.fill",
                        filled: true
                    ) {
                        guard prepareListing() else { return }
                        showUploadChoice = true
                    }

                    bigActionButton(
                        title: "Record a walkthrough",
                        subtitle: "Prefer to film now? We'll coach your pace",
                        icon: "record.circle.fill",
                        filled: false
                    ) {
                        guard prepareListing() else { return }
                        showCapture = true
                    }

                    if !formValid {
                        Label("Type the address first, then pick one.", systemImage: "info.circle")
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                // Optional details — real estate gets beds/baths/sqft/price;
                // other businesses get a short description instead.
                if SpaceType.current.showsPropertyDetails {
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
                        Label("\(SpaceType.current.spaceNounCap) details (optional)", systemImage: "list.bullet")
                            .font(.rpHeadline)
                            .foregroundStyle(Theme.ink)
                    }
                    .tint(Theme.inkDim)
                    .card()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Description (optional)", systemImage: "text.alignleft")
                            .font(.rpHeadline)
                            .foregroundStyle(Theme.ink)
                        TextField("e.g. Rooftop cocktail bar with skyline views", text: $tagline)
                            .font(.body)
                            .padding(14)
                            .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()

                    DisclosureGroup {
                        DetailFieldsEditor(fields: SpaceType.current.detailFields, values: $pendingDetails)
                            .padding(.top, 10)
                    } label: {
                        Label("\(SpaceType.current.displayName) details (optional)", systemImage: "list.bullet")
                            .font(.rpHeadline)
                            .foregroundStyle(Theme.ink)
                    }
                    .tint(Theme.inkDim)
                    .card()
                }
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle(SpaceType.current.newItemTitle)
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
            let trimmedTagline = tagline.trimmingCharacters(in: .whitespaces)
            let listing = Listing(address: address.trimmingCharacters(in: .whitespaces),
                                  beds: beds,
                                  baths: baths,
                                  sqft: Int(sqft) ?? 0,
                                  price: .dollars(Int(priceDollars) ?? 0),
                                  status: .draft,
                                  latitude: pendingCoord?.latitude,
                                  longitude: pendingCoord?.longitude,
                                  tagline: trimmedTagline.isEmpty ? nil : trimmedTagline,
                                  details: pendingDetails.isEmpty ? nil : pendingDetails)
            createdListing = listing
            model.add(listing)
        }
        return true
    }

    private func useCurrentLocation() {
        locating = true
        locator.request { loc in
            guard let loc else { locating = false; return }
            pendingCoord = loc.coordinate
            CLGeocoder().reverseGeocodeLocation(loc) { placemarks, _ in
                if let p = placemarks?.first {
                    address = Self.formatAddress(p)
                }
                locating = false
            }
        }
    }

    private static func formatAddress(_ p: CLPlacemark) -> String {
        var parts: [String] = []
        let line1 = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
        if !line1.isEmpty { parts.append(line1) }
        if let city = p.locality { parts.append(city) }
        let stateZip = [p.administrativeArea, p.postalCode].compactMap { $0 }.joined(separator: " ")
        if !stateZip.isEmpty { parts.append(stateZip) }
        return parts.joined(separator: ", ")
    }

    private func receive(_ asset: CaptureAsset) {
        pendingAsset = asset
        goToReview = true
    }
}

/// One-shot Core Location fetch: asks permission if needed, returns a single fix.
final class OneShotLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((CLLocation?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request(_ completion: @escaping (CLLocation?) -> Void) {
        self.completion = completion
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()   // fix arrives via the delegate callback
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            finish(nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if completion != nil { manager.requestLocation() }
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.first)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    private func finish(_ location: CLLocation?) {
        let c = completion
        completion = nil
        DispatchQueue.main.async { c?(location) }
    }
}

// MARK: - Dynamic detail fields editor
// Renders a business type's `detailFields` as the right control for each type
// and writes into a [String:String] values map.
struct DetailFieldsEditor: View {
    let fields: [DetailField]
    @Binding var values: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(fields) { field in
                fieldRow(field)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: DetailField) -> some View {
        switch field.type {
        case .toggle:
            Toggle(field.label, isOn: boolBinding(field.key)).tint(Theme.accent)

        case .priceRange:
            labeled(field.label) {
                Picker("", selection: strBinding(field.key)) {
                    Text("—").tag("")
                    ForEach(["$", "$$", "$$$", "$$$$"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }

        case .singleSelect(let options):
            labeled(field.label) {
                Menu {
                    Button("None") { values[field.key] = "" }
                    ForEach(options, id: \.self) { opt in
                        Button(opt) { values[field.key] = opt }
                    }
                } label: { selectLabel(values[field.key] ?? "") }
            }

        case .multiSelect(let options):
            labeled(field.label) {
                Menu {
                    ForEach(options, id: \.self) { opt in
                        Button { toggleMulti(field.key, opt) } label: {
                            if multiContains(field.key, opt) { Label(opt, systemImage: "checkmark") }
                            else { Text(opt) }
                        }
                    }
                } label: { selectLabel(values[field.key] ?? "") }
            }

        case .multilineText:
            labeled(field.label) {
                TextField(field.label, text: strBinding(field.key), axis: .vertical)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

        default: // text, number, price, hours, url
            labeled(field.label) {
                TextField(field.label, text: strBinding(field.key))
                    .keyboardType(keyboard(field.type))
                    .textInputAutocapitalization(field.type == .url ? .never : .sentences)
                    .autocorrectionDisabled(field.type == .url)
                    .padding(12)
                    .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.rpCaption).foregroundStyle(Theme.inkDim)
            content()
        }
    }

    private func selectLabel(_ value: String) -> some View {
        HStack {
            Text(value.isEmpty ? "Select" : value)
                .foregroundStyle(value.isEmpty ? Theme.inkDim : Theme.ink)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Theme.inkDim)
        }
        .padding(12)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func strBinding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { values[key] == "true" }, set: { values[key] = $0 ? "true" : "false" })
    }
    private func multiContains(_ key: String, _ opt: String) -> Bool {
        (values[key]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []).contains(opt)
    }
    private func toggleMulti(_ key: String, _ opt: String) {
        var set = (values[key]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [])
            .filter { !$0.isEmpty }
        if let i = set.firstIndex(of: opt) { set.remove(at: i) } else { set.append(opt) }
        values[key] = set.joined(separator: ", ")
    }
    private func keyboard(_ type: FieldInputType) -> UIKeyboardType {
        switch type {
        case .number, .price: return .numbersAndPunctuation
        case .url: return .URL
        default: return .default
        }
    }
}
