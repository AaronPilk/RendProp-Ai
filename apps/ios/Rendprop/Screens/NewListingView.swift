import SwiftUI
import UIKit
import CoreLocation

// MARK: - Form data shared by New Listing and Edit

/// Everything the owner types about a space, independent of the screen that
/// collects it. Real estate: address + beds/baths/sqft/price; every other
/// type: name/address + tagline + the industry's `detailFields`.
struct ListingFormData: Equatable {
    var address = ""
    /// 0 = unknown for beds/baths (shown as "—"). Never publish invented facts.
    var beds = 0
    var baths = 0.0
    var sqft = ""
    var priceDollars = ""
    var tagline = ""
    var details: [String: String] = [:]
    var spaceType: SpaceType = SpaceType.current

    init() {}

    init(listing: Listing) {
        address = listing.address
        beds = listing.beds
        baths = listing.baths
        sqft = listing.sqft > 0 ? String(listing.sqft) : ""
        priceDollars = listing.price.cents > 0 ? String(listing.price.cents / 100) : ""
        tagline = listing.tagline ?? ""
        details = listing.details ?? [:]
        spaceType = listing.spaceType
    }

    var isRealEstate: Bool { spaceType.showsPropertyDetails }
    var isValid: Bool { !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTagline: String? {
        let t = tagline.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    private var cleanedDetails: [String: String]? {
        let kept = details.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return kept.isEmpty ? nil : kept
    }
    /// "2,850" / "2850 sq ft" → 2850.
    private var sqftValue: Int {
        let digits = sqft.filter { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return 0 }
        return Int(digits) ?? 0
    }

    /// Write the form into a listing (edit path). Beds/baths/sqft/price are
    /// real-estate concepts — never store the steppers on a venue/gym listing.
    func apply(to l: inout Listing) {
        l.address = trimmedAddress
        l.beds = isRealEstate ? beds : 0
        l.baths = isRealEstate ? baths : 0
        l.sqft = isRealEstate ? sqftValue : 0
        l.price = .dollars(isRealEstate ? (Money.parseDollars(priceDollars) ?? 0) : 0)
        l.tagline = isRealEstate ? nil : trimmedTagline
        l.details = isRealEstate ? nil : cleanedDetails
    }

    /// A brand-new listing from the form (create path).
    func makeListing(coordinate: CLLocationCoordinate2D?) -> Listing {
        var l = Listing(address: trimmedAddress,
                        beds: 0, baths: 0, sqft: 0,
                        price: Money(cents: 0),
                        status: .draft,
                        spaceTypeRaw: spaceType.rawValue,   // stamp the industry
                        latitude: coordinate?.latitude,
                        longitude: coordinate?.longitude)
        apply(to: &l)
        return l
    }
}

// MARK: - The form itself (address → [middle] → optional details)

/// The listing fields, reused by New Listing (with the video step in the
/// middle) and by the edit sheet (no middle). Per-type placeholders and
/// content types: street-address autofill only for real estate.
struct ListingFieldsForm<Middle: View>: View {
    @Binding var form: ListingFormData
    var locationAction: (() -> Void)? = nil
    var locating = false
    @ViewBuilder var middle: () -> Middle

    private var space: SpaceType { form.spaceType }

    /// What the agent pasted, and what came out of it. Local to this card:
    /// nothing about a link is persisted, because the ADDRESS is the outcome
    /// and the link was only ever the way to type it quickly.
    @State private var pastedLink = ""
    @State private var linkResult: ListingLink?
    @State private var linkFailed = false

    @EnvironmentObject private var model: AppModel
    /// The public-record lookup for whatever is in the address field.
    @State private var lookingUp = false
    @State private var lookupFacts: PropertyFacts?
    @State private var lookupFilled = 0
    @State private var lookupNote: String?
    /// nil until the first lookup answers. False means this deploy has no
    /// provider credential, and the whole control hides rather than offering
    /// something that cannot work.
    @State private var lookupAvailable: Bool?

    var body: some View {
        VStack(spacing: Theme.spacing) {
            // FIRST, above the address field, for real homes. Typing a full
            // street address on a phone while standing in a driveway is the
            // friction; "4 beds" is not.
            if space.showsPropertyDetails { listingLinkCard }
            addressCard
            middle()
            if space.showsPropertyDetails {
                propertyDetailsCard
            } else {
                taglineCard
                businessDetailsCard
            }
        }
    }

    /// Paste a Zillow / Redfin / Realtor.com link and the address fills itself.
    ///
    /// NOTHING IS FETCHED. `ListingLink.parse` reads the address out of the URL
    /// STRING — a listing URL carries it in its own path — and no request ever
    /// reaches those sites. That is deliberate and it is the difference between
    /// a convenience and a lawsuit: Zillow's terms prohibit automated queries,
    /// and listing photos belong to the photographer or the MLS rather than to
    /// the portal or the agent. These tours republish publicly, so an automated
    /// pull would land the exposure on this company.
    ///
    /// The rest of the fields therefore stay empty, and this card says so
    /// rather than leaving four blanks after a button labelled "pull the data".
    private var listingLinkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Paste a listing link", systemImage: "link")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
            Text("Zillow, Redfin or Realtor.com. The address fills itself in \u{2014} no typing.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("zillow.com/homedetails/\u{2026}", text: $pastedLink)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit { applyPastedLink() }
                    .font(.body)
                    .padding(14)
                    .background(Theme.fillSubtle,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("Use") { applyPastedLink() }
                    .font(.rpBody.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .buttonStyle(ScalePressStyle())
                    .disabled(pastedLink.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("newListing.useLink")
            }

            if let linkResult {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Address filled from the \(linkResult.source.label) link.",
                          systemImage: "checkmark.circle.fill")
                        .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.good)
                    Text("Beds, baths, size, price and photos aren\u{2019}t pulled \u{2014} those come from your MLS feed once it\u{2019}s connected. Add what you want below.")
                        .font(.caption2).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if linkFailed {
                Text("That doesn\u{2019}t look like a Zillow, Redfin or Realtor.com listing link. Type the address below instead \u{2014} it works exactly the same.")
                    .font(.rpCaption).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Read the link, fill the address, say which it was. A failed parse is a
    /// dead end by design — the manual field is directly below and guessing a
    /// wrong address onto a real listing is worse than typing the right one.
    private func applyPastedLink() {
        guard let parsed = ListingLink.parse(pastedLink) else {
            linkResult = nil
            linkFailed = true
            Haptics.warning()
            return
        }
        form.address = parsed.formatted
        linkResult = parsed
        linkFailed = false
        Haptics.success()
        Analytics.track("listing_link_used", ["source": parsed.source.rawValue])
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(locationAction == nil ? "The \(space.spaceNoun)" : "Step 1 · The \(space.spaceNoun)",
                  systemImage: space.systemImage)
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            TextField(space.showsPropertyDetails
                      ? "Type the home's address"
                      : "Name or address of your \(space.spaceNoun)", text: $form.address)
                .textContentType(space.showsPropertyDetails ? .fullStreetAddress : .organizationName)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .font(.body)
                .padding(14)
                .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if space.showsPropertyDetails, lookupAvailable != false {
                propertyLookupRow
            }

            if let locationAction {
                Button {
                    locationAction()
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// "Fill the rest from public records."
    ///
    /// Beds, baths, size, year built and lot size are county public record, and
    /// a licensed vendor has them nationwide — no MLS membership, no scraping a
    /// portal. One tap on whatever address is in the field above.
    ///
    /// IT ONLY FILLS WHAT IS EMPTY. Overwriting a number the agent typed would
    /// be the worst kind of helpful: they typed it because they know the house
    /// and the county record is a year behind, or wrong. So anything already
    /// filled is left exactly alone, and the result line says HOW MANY fields
    /// it filled — "0 of 4" has to be visible, not look like nothing happened.
    @ViewBuilder private var propertyLookupRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await runPropertyLookup() }
            } label: {
                HStack(spacing: 8) {
                    if lookingUp { ProgressView() }
                    else { Image(systemName: "doc.text.magnifyingglass") }
                    Text(lookingUp ? "Checking the records\u{2026}" : "Fill the rest from public records")
                }
                .font(.rpBody.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
            .disabled(lookingUp || form.address.trimmingCharacters(in: .whitespaces).count < 6)
            .accessibilityIdentifier("newListing.propertyLookup")

            if let f = lookupFacts {
                VStack(alignment: .leading, spacing: 3) {
                    Label(lookupFilled > 0
                          ? "Filled \(lookupFilled) field\(lookupFilled == 1 ? "" : "s") from the record."
                          : "Found the record \u{2014} everything was already filled in.",
                          systemImage: "checkmark.circle.fill")
                        .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.good)
                    if let matched = f.matchedAddress, !matched.isEmpty {
                        Text("Matched: \(matched)")
                            .font(.caption2).foregroundStyle(Theme.inkDim)
                            .lineLimit(2)
                    }
                    if let cents = f.lastSalePriceCents, cents > 0 {
                        // SHOWN, never auto-filled. This is what the house last
                        // SOLD for, which is not what it is listed at, and a
                        // 2019 sale price quietly sitting in the price field of
                        // a live listing is a wrong number on a public page.
                        Text("Last sold for \(Money.dollars(cents))\(f.lastSaleDate.map { " (\($0.prefix(4)))" } ?? "") \u{2014} not the asking price.")
                            .font(.caption2).foregroundStyle(Theme.inkDim)
                    }
                    Text("Photos aren\u{2019}t part of any records feed \u{2014} add your own below.")
                        .font(.caption2).foregroundStyle(Theme.inkDim)
                }
            } else if let note = lookupNote {
                Text(note)
                    .font(.rpCaption).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Ask once per tap, fill only the blanks, and never retry on its own —
    /// every call is metered on the server and a retry is a second charge.
    @MainActor
    private func runPropertyLookup() async {
        let address = form.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.count >= 6, !lookingUp else { return }
        lookingUp = true
        lookupNote = nil
        defer { lookingUp = false }
        do {
            let result = try await model.api.propertyLookup(address: address)
            lookupAvailable = result.configured
            guard result.configured else { return }
            guard let f = result.facts else {
                lookupFacts = nil
                lookupNote = "No public record came back for that address. Type what you know below \u{2014} it works the same."
                return
            }
            var filled = 0
            if form.beds == 0, let b = f.beds, b > 0 { form.beds = b; filled += 1 }
            if form.baths == 0, let b = f.baths, b > 0 { form.baths = b; filled += 1 }
            if form.sqft.isEmpty, let s = f.sqft, s > 0 { form.sqft = String(s); filled += 1 }
            if let y = f.yearBuilt, y > 1700,
               (form.details["yearBuilt"] ?? "").isEmpty {
                form.details["yearBuilt"] = String(y); filled += 1
            }
            lookupFilled = filled
            lookupFacts = f
            Haptics.success()
            Analytics.track("property_lookup", ["ok": "true", "filled": String(filled),
                                                "cached": result.cached ? "true" : "false"])
        } catch {
            lookupFacts = nil
            lookupNote = "Couldn\u{2019}t reach the records service. Type what you know below."
            Analytics.track("property_lookup", ["ok": "false"])
        }
    }

    private var propertyDetailsCard: some View {
        DisclosureGroup {
            VStack(spacing: 14) {
                Stepper(form.beds > 0 ? "Bedrooms: \(form.beds)" : "Bedrooms: —",
                        value: $form.beds, in: 0...12)
                Stepper(form.baths > 0 ? String(format: "Bathrooms: %g", form.baths) : "Bathrooms: —",
                        value: $form.baths, in: 0...12, step: 0.5)
                TextField("Square feet", text: $form.sqft)
                    .keyboardType(.numberPad)
                    .padding(12)
                    .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                TextField("Asking price", text: $form.priceDollars)
                    .keyboardType(.numberPad)
                    .padding(12)
                    .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("Leave anything you don't know blank — only real facts show on the tour.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 8)
        } label: {
            Label("\(space.spaceNounCap) details (optional)", systemImage: "list.bullet")
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
        }
        .tint(Theme.inkDim)
        .card()
    }

    private var taglineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Description (optional)", systemImage: "text.alignleft")
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            TextField(Self.taglinePlaceholder(for: space), text: $form.tagline)
                .font(.body)
                .padding(14)
                .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var businessDetailsCard: some View {
        DisclosureGroup {
            DetailFieldsEditor(fields: space.detailFields, values: $form.details)
                .padding(.top, 10)
        } label: {
            Label("\(space.displayName) details (optional)", systemImage: "list.bullet")
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
        }
        .tint(Theme.inkDim)
        .card()
    }

    static func taglinePlaceholder(for type: SpaceType) -> String {
        switch type {
        case .realEstate: return "e.g. Sun-filled craftsman near the park"
        case .venue:      return "e.g. Historic ballroom · Seats 220"
        case .restaurant: return "e.g. Rooftop cocktail bar with skyline views"
        case .retail:     return "e.g. Neighborhood grocery · Open daily 7am–9pm"
        case .fitness:    return "e.g. Strength gym · Open 24/7 · Classes daily"
        case .other:      return "e.g. Creative studio & community space"
        }
    }
}

// MARK: - New listing (address → video → review)

/// Stupid-simple: type the address, then one of two big buttons — Record or
/// Upload. Everything else is optional and out of the way. The listing is
/// created ONLY once a usable video exists (decision A4) — cancelling a
/// picker never leaves a "Not finished" card behind.
struct NewListingView: View {
    @EnvironmentObject var model: AppModel

    @StateObject private var locator = OneShotLocation()
    @State private var locating = false
    @State private var pendingCoord: CLLocationCoordinate2D?

    @State private var form = ListingFormData()
    @State private var pendingAsset: CaptureAsset?
    @State private var createdListing: Listing?
    @State private var goToReview = false

    var body: some View {
        ScrollView {
            ListingFieldsForm(form: $form, locationAction: { useCurrentLocation() }, locating: locating) {
                videoCard
            }
            .padding()
        }
        .background(Theme.bg)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(SpaceType.current.newItemTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $goToReview) {
            if let listing = createdListing, let asset = pendingAsset {
                ReviewSubmitView(listing: listing, asset: asset)
            }
        }
    }

    // Step 2 — video (two big buttons, shared with AddVideoFlowView)
    private var videoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Step 2 · The video", systemImage: "video.fill")
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)

            VideoSourcePicker(enabled: form.isValid) { asset in
                receive(asset)
            }

            if !form.isValid {
                Label("Type the \(form.isRealEstate ? "address" : "name") first, then pick one.", systemImage: "info.circle")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func useCurrentLocation() {
        locating = true
        locator.request { loc in
            guard let loc else { locating = false; return }
            // Keep only a ~110 m coarse fix (3 decimals) — the precise fix is
            // used transiently below to resolve the street address, never stored.
            pendingCoord = CLLocationCoordinate2D(latitude: coarseCoordinate(loc.coordinate.latitude),
                                                  longitude: coarseCoordinate(loc.coordinate.longitude))
            CLGeocoder().reverseGeocodeLocation(loc) { placemarks, _ in
                if let p = placemarks?.first {
                    form.address = Self.formatAddress(p)
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

    /// A usable video exists → NOW create the listing (once) with everything
    /// typed so far, incl. the location fix, and go to Review.
    private func receive(_ asset: CaptureAsset) {
        guard form.isValid else { return }
        let listing: Listing
        // Re-point an existing listing at a new video ONLY while it is still an
        // unfinished draft from this screen. Once it has a rendered tour, doing
        // that would delete the raw video of a finished (possibly published)
        // listing and leave its tour + room tags describing a file that no
        // longer exists — so a new video after a finished render starts its own
        // listing instead.
        if let existing = createdListing,
           model.listings.contains(where: { $0.id == existing.id }),
           model.tours[existing.id] == nil {
            // Came back from Review and picked a different video: keep the
            // listing, refresh its fields, drop the previous file.
            model.modify(existing.id, sync: false) {
                form.apply(to: &$0)
                // A location fix taken AFTER the listing was created used to be
                // dropped here (audit F-B-06).
                if let coordinate = pendingCoord {
                    $0.latitude = coordinate.latitude
                    $0.longitude = coordinate.longitude
                }
            }
            if let old = model.assets[existing.id], old.localURL != asset.localURL {
                FileStore.removeVideoAndPreview(old.localURL)
                if let sidecar = old.motionSidecarURL { try? FileManager.default.removeItem(at: sidecar) }
            }
            listing = model.listings.first(where: { $0.id == existing.id }) ?? existing
        } else {
            listing = form.makeListing(coordinate: pendingCoord)
            model.add(listing)
        }
        model.assets[listing.id] = asset
        createdListing = listing
        pendingAsset = asset
        goToReview = true
    }
}

// MARK: - Video source picker (Photos / Files / Record) + import validation

/// The three ways a walkthrough gets into the app. Owns the pickers, the
/// import progress and the validation; hands back a usable `CaptureAsset`.
/// Drone vs handheld is NOT inferred here (decision A8) — Review & Submit asks.
struct VideoSourcePicker: View {
    var enabled: Bool = true
    var onAsset: (CaptureAsset) -> Void

    @State private var showCapture = false
    @State private var showUploadChoice = false
    @State private var showPhotoPicker = false
    @State private var showFilesPicker = false
    /// Non-nil while a picked video is copying in (0…1). Big 4K / iCloud clips
    /// take a while — this drives the visible "Importing video…" progress.
    @State private var importProgress: Double?
    @State private var importFailed = false
    @State private var importFailureMessage = ""

    private var busy: Bool { importProgress != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            bigActionButton(
                title: "Upload a video",
                subtitle: "A clip from Photos or Files — the easiest way",
                icon: "square.and.arrow.up.fill",
                filled: true
            ) {
                showUploadChoice = true
            }

            bigActionButton(
                title: "Record a walkthrough",
                subtitle: "Prefer to film now? We'll coach your pace",
                icon: "record.circle.fill",
                filled: false
            ) {
                showCapture = true
            }

            if let p = importProgress {
                let clamped = min(max(p, 0), 1)
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: clamped) {
                        Text("Importing video… \(Int(clamped * 100))%")
                            .font(.rpCaption.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .tint(Theme.accent)
                    Text("Big videos can take a minute — keep the app open.")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                }
                .padding(.top, 4)
            }
        }
        .fullScreenCover(isPresented: $showCapture) {
            CaptureView { asset in
                deliver(asset)
            }
        }
        .confirmationDialog("Where is your video?", isPresented: $showUploadChoice, titleVisibility: .visible) {
            Button("Photos") { showPhotoPicker = true }
            Button("Files") { showFilesPicker = true }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoVideoPicker(
                onPicked: { url in importFile(url) },
                onProgress: { importProgress = $0 },
                onFailed: {
                    importProgress = nil
                    fail("Please try again. If the video is in iCloud, keep the app open while it downloads.")
                })
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFilesPicker) {
            FilesVideoPicker { url in
                importProgress = 0
                importFile(url)
            }
            .ignoresSafeArea()
        }
        .alert("Couldn't use that video", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importFailureMessage)
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
            .opacity(enabled && !busy ? 1 : 0.5)
        }
        .buttonStyle(ScalePressStyle())
        .disabled(!enabled || busy)   // no double-imports mid-copy
        .accessibilityLabel(Text("\(title). \(subtitle)"))
    }

    /// Probe + validate a file that landed in the app container. The importer
    /// may reject unreadable files itself (decision A9); anything that slips
    /// through with no usable track is refused here with the same alert.
    private func importFile(_ url: URL) {
        Task {
            do {
                // `nil` = let the importer's metadata/filename heuristic decide;
                // Review & Submit shows the result as an explicit, correctable
                // Handheld/Drone control (decision A8, audit F-B-15 / F-D-07).
                let asset = try await MediaImporter.makeAsset(from: url, isDrone: nil)
                await MainActor.run {
                    importProgress = nil
                    if Self.isUsable(asset) {
                        deliver(asset)
                    } else {
                        try? FileManager.default.removeItem(at: asset.localURL)
                        fail("This file has no usable video — it needs a video track longer than a second.")
                    }
                }
            } catch {
                await MainActor.run {
                    importProgress = nil
                    fail(error.localizedDescription)
                }
            }
        }
    }

    static func isUsable(_ asset: CaptureAsset) -> Bool {
        asset.durationS.isFinite && asset.durationS > 0.2
            && asset.width > 0 && asset.height > 0 && asset.bytes > 0
    }

    private func deliver(_ asset: CaptureAsset) {
        guard Self.isUsable(asset) else {
            fail("This recording has no usable video. Please try again.")
            return
        }
        onAsset(asset)
    }

    private func fail(_ message: String) {
        importFailureMessage = message
        importFailed = true
    }
}

// MARK: - Edit an existing listing (decision A3)

/// Same fields as New Listing, prefilled. Saving writes through
/// `AppModel.modify`, flags the listing dirty and PATCHes the server when the
/// listing has been published (decision A6).
struct ListingEditSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let listing: Listing
    @State private var form: ListingFormData
    private let original: ListingFormData

    init(listing: Listing) {
        self.listing = listing
        let data = ListingFormData(listing: listing)
        self._form = State(initialValue: data)
        self.original = data
    }

    private var canSave: Bool { form.isValid && form != original }

    var body: some View {
        NavigationStack {
            ScrollView {
                ListingFieldsForm(form: $form) {
                    EmptyView()
                }
                .padding()
            }
            .background(Theme.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit \(listing.spaceType.spaceNoun)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard canSave, !listing.isSample else { return }
        let id = listing.id
        model.modify(id, sync: false) { form.apply(to: &$0) }
        model.markDirty(id)
        Task { await model.syncListing(id) }
        Haptics.success()
        dismiss()
    }
}

// MARK: - Add a walkthrough video to an existing listing (decision A2/A4)

/// Photos / Files / Record for a listing that has no video yet (or whose
/// render never finished). Stores the asset, resets the listing to draft and
/// continues into Review & Submit. Push it inside a NavigationStack.
struct AddVideoFlowView: View {
    @EnvironmentObject var model: AppModel

    let listing: Listing
    @State private var pendingAsset: CaptureAsset?
    @State private var goToReview = false

    private var currentListing: Listing {
        model.listings.first(where: { $0.id == listing.id }) ?? listing
    }
    private var noun: String { listing.spaceType.spaceNoun }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(listing.address)
                        .font(.rpTitle)
                        .foregroundStyle(Theme.ink)
                    Text("Add the walkthrough video for this \(noun). The tour, the share link and the leads all start from it.")
                        .font(.rpBody)
                        .foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                VStack(alignment: .leading, spacing: 12) {
                    Label("The video", systemImage: "video.fill")
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.ink)
                    VideoSourcePicker(enabled: !listing.isSample) { asset in
                        receive(asset)
                    }
                    if listing.isSample {
                        Label("Samples are read-only — create a \(noun) first.", systemImage: "info.circle")
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("Add video")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $goToReview) {
            if let asset = pendingAsset {
                ReviewSubmitView(listing: currentListing, asset: asset)
            }
        }
    }

    private func receive(_ asset: CaptureAsset) {
        guard !listing.isSample else { return }
        let id = listing.id
        if let old = model.assets[id], old.localURL != asset.localURL {
            FileStore.removeVideoAndPreview(old.localURL)
            if let sidecar = old.motionSidecarURL { try? FileManager.default.removeItem(at: sidecar) }
        }
        model.assets[id] = asset
        model.setStatus(.draft, for: id)
        model.setLastError(nil, for: id)
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
