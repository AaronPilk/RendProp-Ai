import SwiftUI
import PhotosUI
import UIKit
import ImageIO

struct RealEstateRoleChoice: View {
    @Binding var selected: RealEstateRole
    var body: some View {
        VStack(spacing: 12) {
            ForEach(RealEstateRole.allCases) { role in
                Button { selected = role; Haptics.selection() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: role.isProducer ? "camera.fill" : "person.crop.circle")
                            .font(.title2).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(role.label).font(.rpHeadline)
                            Text(role.isProducer ? "Create listing media for clients. Their contact details appear on each listing."
                                 : "Create and share your own listings.")
                                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        }
                        Spacer()
                        Image(systemName: selected == role ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Theme.accent)
                    }.foregroundStyle(Theme.ink).padding(16)
                        .background(selected == role ? Theme.accentSoft : Theme.card, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("realEstateRole.\(role.rawValue)")
                    .accessibilityAddTraits(selected == role ? [.isSelected] : [])
            }
        }
    }
}

struct RealEstateRoleSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = RealEstateRoleStore.current
    private let owner = AuthStore.shared.userID
    private let revision = AuthStore.shared.syncSessionRevision
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How do you work?").font(.rpLargeTitle)
            RealEstateRoleChoice(selected: $selected)
            Text("This changes your starting workflow. Your listings, plan and workspace permissions stay the same.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            PrimaryButton(title: "Save", systemImage: "checkmark") {
                guard AuthStore.shared.userID == owner, AuthStore.shared.syncSessionRevision == revision else { return }
                RealEstateRoleStore.choose(selected, owner: owner)
                Task { await model.syncRealEstateRole() }
                dismiss()
            }.accessibilityIdentifier("realEstateRole.save")
            Spacer()
        }.padding().background(Theme.bg).navigationTitle("Real estate workflow")
    }
}

/// Shared public-card/private-recipient fields. No owner-card fallback.
struct ClientContactFields: View {
    @Binding var contact: ListingClientContact
    private func optional(_ path: WritableKeyPath<ClientPublicCard, String?>) -> Binding<String> {
        Binding(get: { contact.publicCard[keyPath: path] ?? "" }, set: { contact.publicCard[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Client name or business name", text: $contact.publicCard.name).textContentType(.name)
                .accessibilityIdentifier("clientContact.name")
            TextField("Brokerage or business (optional)", text: optional(\.brokerage)).textContentType(.organizationName)
            TextField("Title (optional)", text: optional(\.title))
            TextField("Public phone (optional)", text: optional(\.phone)).keyboardType(.phonePad).textContentType(.telephoneNumber)
            TextField("Public email (optional)", text: optional(\.email)).keyboardType(.emailAddress).textContentType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Website (optional)", text: optional(\.website)).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Divider()
            Text("Where should listing inquiries go?").font(.rpHeadline)
            TextField("Client's lead email", text: $contact.recipientEmail).keyboardType(.emailAddress).textContentType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("clientContact.recipient")
            Text("This email receives form submissions. It is private unless you also enter it as the public email above. You keep a copy of every inquiry in Leads.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            Toggle("Hide Rendprop branding on this listing", isOn: $contact.hideRendpropBranding)
        }.textFieldStyle(.roundedBorder)
    }
}

struct ListingClientContactSummary: View {
    let listing: Listing
    @AppStorage(RealEstateRoleStore.uiRevisionKey) private var roleRevision = 0
    var body: some View {
        NavigationLink { ListingClientContactEditor(listing: listing) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Who should buyers contact?", systemImage: "person.text.rectangle.fill").font(.rpHeadline)
                    Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.bold))
                }
                if let contact = listing.clientContact, contact.enabled {
                    Text(contact.publicCard.name).font(.rpBody.weight(.semibold))
                    Text("Inquiries go to \(contact.recipientEmail)").font(.rpCaption).foregroundStyle(Theme.inkDim)
                    if listing.clientContactDirty == true { Text("Saved on this phone · needs cloud save before publishing").font(.rpCaption).foregroundStyle(Theme.warn) }
                    if contact.hideRendpropBranding { Text("Rendprop branding hidden").font(.rpCaption).foregroundStyle(Theme.inkDim) }
                } else {
                    Text(listing.clientContact != nil ? "Your account card is selected for this listing. Tap to change it."
                         : RealEstateRoleStore.current.isProducer ? "Add your client's name, photo and contact details before publishing."
                         : "Your account card is used. Tap to show a client's details for this listing.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
            }.foregroundStyle(Theme.ink).padding(16)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
        }.buttonStyle(.plain).accessibilityIdentifier("listing.clientContact")
    }
}

enum ClientContactPhotoStore {
    static func thumbnail(_ data: Data) -> UIImage? {
        guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    /// A new file for every selection prevents an in-flight save reading later bytes.
    @MainActor static func save(_ image: UIImage, owner: String?, org: UUID?, listing: UUID) throws -> String {
        guard image.size.width > 0, image.size.height > 0 else { throw ClientContactError.pendingPhoto }
        let factor = min(1, 512 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = resized.jpegData(compressionQuality: 0.85), data.count <= 2_000_000 else { throw ClientContactError.pendingPhoto }
        let scope = owner.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() ?? "local"
        let dir = FileStore.documents.appendingPathComponent("ClientContacts/\(scope)/\(org?.uuidString.lowercased() ?? "local")/\(listing.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(UUID().uuidString.lowercased() + ".jpg")
        try data.write(to: file, options: .atomic)
        return FileStore.relativePath(for: file)
    }
}

struct ListingClientContactEditor: View {
    let listing: Listing
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var contact: ListingClientContact
    @State private var photo: UIImage?
    @State private var picker: PhotosPickerItem?
    @State private var photoChanged = false
    @State private var saving = false
    @State private var loading = false
    @State private var error: String?
    @State private var context: Context?
    @State private var reloadConfirm = false
    private struct Context: Equatable { let owner: String?; let revision: UInt64; let org: UUID? }
    private var current: Context { .init(owner: AuthStore.shared.userID, revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID) }
    private var live: Listing { model.listings.first(where: { $0.id == listing.id }) ?? listing }
    init(listing: Listing) {
        self.listing = listing
        _contact = State(initialValue: listing.clientContact ?? ListingClientContact(listingID: listing.serverID ?? listing.id,
            enabled: RealEstateRoleStore.current.isProducer, publicCard: ClientPublicCard(), recipientEmail: ""))
    }
    var body: some View {
        Form {
            Section {
                Toggle("Use a client's contact details", isOn: $contact.enabled).accessibilityIdentifier("clientContact.enabled")
            } footer: { Text("Applies only to this listing. Your own profile and other listings keep their existing details.") }
            if contact.enabled {
                Section("Client photo or business logo") {
                    HStack(spacing: 14) {
                        Group {
                            if let photo { Image(uiImage: photo).resizable().scaledToFill() }
                            else if let raw = contact.publicCard.avatarURL, let url = URL(string: raw) {
                                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.fill").font(.title2) }
                            } else { Image(systemName: "person.fill").font(.title2) }
                        }.frame(width: 64, height: 64).clipShape(Circle())
                        PhotosPicker(selection: $picker, matching: .images) { Label("Choose photo", systemImage: "photo") }
                            .accessibilityIdentifier("clientContact.photo")
                        if photo != nil || contact.photoAssetID != nil {
                            Button("Remove", role: .destructive) { photo = nil; photoChanged = true; contact.photoAssetID = nil; contact.publicCard.avatarURL = nil; picker = nil }
                        }
                    }
                }
                Section("Details shown on the listing") { ClientContactFields(contact: $contact) }
            }
            if let error {
                Section { Text(error).foregroundStyle(Theme.warn).accessibilityIdentifier("clientContact.error") }
            }
            Section {
                Button { Task { await save() } } label: {
                    HStack { Text(saving ? "Saving…" : "Save client details"); if saving { Spacer(); ProgressView() } }
                }.disabled(saving || loading).accessibilityIdentifier("clientContact.save")
                if live.clientContactDirty == true, live.serverID != nil {
                    Button("Reload the latest details from Studio", role: .destructive) { reloadConfirm = true }
                }
            } footer: { Text("Saving updates the published listing's contact card. Form inquiries stay in your account and are emailed to the client.") }
        }.navigationTitle("Listing contact").navigationBarTitleDisplayMode(.inline)
            .disabled(saving || loading || (context != nil && context != current))
            .task { if context == nil { context = current; await load() } }
            .confirmationDialog("Replace this phone's draft with the latest client details?", isPresented: $reloadConfirm, titleVisibility: .visible) {
                Button("Reload latest details", role: .destructive) { Task { await load(discardDraft: true) } }
            }
            .onChange(of: picker) { item in
                guard let item else { return }; let expected = current
                Task { @MainActor in
                    if let data = try? await item.loadTransferable(type: Data.self), data.count <= 20_000_000,
                       let image = ClientContactPhotoStore.thumbnail(data), picker == item, context == expected, current == expected {
                        photo = image; photoChanged = true
                    }
                }
            }
    }
    @MainActor private func load(discardDraft: Bool = false) async {
        loading = true; defer { loading = false }
        do {
            try await model.refreshClientContact(for: listing.id, discardDraft: discardDraft)
            guard context == current else { throw ClientContactError.changed }
            if let stored = live.clientContact { contact = stored }
            else if discardDraft { contact = .init(listingID: live.serverID ?? live.id, enabled: RealEstateRoleStore.current.isProducer, publicCard: .init(), recipientEmail: "") }
            photo = live.clientPhotoRelPath.flatMap { UIImage(contentsOfFile: FileStore.url(fromRelativePath: $0).path) }
            photoChanged = false; error = nil
        } catch { self.error = UserFacingError.message(error, fallback: "Client details couldn't be loaded. Your saved draft is still here.") }
    }
    @MainActor private func save() async {
        guard !saving, context == current else { return }
        saving = true; defer { saving = false }
        var persistedDraft = false
        do {
            contact.publicCard.name = contact.publicCard.name.trimmingCharacters(in: .whitespacesAndNewlines)
            contact.recipientEmail = contact.recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let email = contact.publicCard.email { contact.publicCard.email = email.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let website = contact.publicCard.website, !website.isEmpty, !website.contains("://") { contact.publicCard.website = "https://" + website }
            try ClientContactPolicy.validate(contact)
            var path = live.clientPhotoRelPath
            if photoChanged {
                path = try photo.map { try ClientContactPhotoStore.save($0, owner: current.owner, org: current.org, listing: listing.id) }
                contact.photoAssetID = nil; contact.publicCard.avatarURL = nil
            }
            try model.setClientContactDraft(contact, photoPath: path, photoDirty: photoChanged && photo != nil || live.clientPhotoDirty == true, for: listing.id)
            persistedDraft = true; photoChanged = false
            try await model.syncClientContactBeforePublish(listing.id)
            guard context == current else { throw ClientContactError.changed }
            Haptics.success(); dismiss()
        } catch {
            // The upload may be confirmed even when PUT is not. Keep its saved
            // receipt for Retry; a newly selected photo or Remove clears it.
            if persistedDraft, context == current, let stored = live.clientContact { contact = stored }
            self.error = UserFacingError.message(error, fallback: "Couldn't save the client details. Your draft is saved on this phone. Try again when connected.")
        }
    }
}
