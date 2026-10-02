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

private enum ClientContactInputField: String, Hashable {
    case name, brokerage, title, phone, publicEmail, website, recipient
}

/// A permanent label stays readable after typing and gives VoiceOver the same
/// meaning as the visual form. Each field is a bounded, concrete view.
private struct ClientContactInput: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let field: ClientContactInputField
    let focus: FocusState<ClientContactInputField?>.Binding
    var next: ClientContactInputField? = nil
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType? = nil
    var capitalization: TextInputAutocapitalization = .words
    var disableCorrection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.ink)
            TextField(prompt, text: $text)
                .font(.rpBody).foregroundStyle(Theme.ink)
                .textContentType(contentType).keyboardType(keyboard)
                .textInputAutocapitalization(capitalization).autocorrectionDisabled(disableCorrection)
                .submitLabel(next == nil ? .done : .next)
                .focused(focus, equals: field)
                .onSubmit { focus.wrappedValue = next }
                .padding(14)
                .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                .accessibilityLabel(Text(title))
                .accessibilityIdentifier("clientContact.\(field == .publicEmail ? "publicEmail" : field.rawValue)")
        }
    }
}

private struct ClientContactSectionTitle: View {
    let title: String
    let subtitle: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.rpHeadline).foregroundStyle(Theme.accent)
            Text(subtitle).font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shared public-card/private-recipient fields. No owner-card fallback.
struct ClientContactFields: View {
    @Binding var contact: ListingClientContact
    @FocusState private var focused: ClientContactInputField?
    private func optional(_ path: WritableKeyPath<ClientPublicCard, String?>) -> Binding<String> {
        Binding(get: { contact.publicCard[keyPath: path] ?? "" }, set: { contact.publicCard[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            publicFields
            privateFields
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focused != nil {
                    Spacer()
                    Button("Done") { focused = nil }.accessibilityIdentifier("clientContact.keyboardDone")
                }
            }
        }
    }
    private var publicFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            ClientContactSectionTitle(title: "Public contact card", subtitle: "Buyers see these details on the listing.", icon: "person.text.rectangle.fill")
            ClientContactInput(title: "Client or business name", prompt: "Name shown to buyers", text: $contact.publicCard.name,
                               field: .name, focus: $focused, next: .brokerage, contentType: .name)
            ClientContactInput(title: "Brokerage or business (optional)", prompt: "Company name", text: optional(\.brokerage),
                               field: .brokerage, focus: $focused, next: .title, contentType: .organizationName)
            ClientContactInput(title: "Title (optional)", prompt: "e.g. Real estate agent", text: optional(\.title),
                               field: .title, focus: $focused, next: .phone)
            ClientContactInput(title: "Public phone (optional)", prompt: "Phone shown to buyers", text: optional(\.phone),
                               field: .phone, focus: $focused, next: .publicEmail, keyboard: .phonePad, contentType: .telephoneNumber)
            ClientContactInput(title: "Public email (optional)", prompt: "Email shown to buyers", text: optional(\.email),
                               field: .publicEmail, focus: $focused, next: .website, keyboard: .emailAddress,
                               contentType: .emailAddress, capitalization: .never, disableCorrection: true)
            ClientContactInput(title: "Website (optional)", prompt: "example.com", text: optional(\.website),
                               field: .website, focus: $focused, next: .recipient, keyboard: .URL,
                               capitalization: .never, disableCorrection: true)
        }.card()
    }
    private var privateFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            ClientContactSectionTitle(title: "Send inquiries to your client", subtitle: "Private delivery email · not part of the public card.", icon: "envelope.badge.shield.half.filled")
            ClientContactInput(title: "Client's lead email", prompt: "Where form submissions should go", text: $contact.recipientEmail,
                               field: .recipient, focus: $focused, keyboard: .emailAddress,
                               contentType: .emailAddress, capitalization: .never, disableCorrection: true)
            Text("You keep a copy of every inquiry in Leads. This address is only public if you also enter it in Public email above.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.border)
            Toggle("Hide Rendprop branding on this listing", isOn: $contact.hideRendpropBranding)
                .font(.rpBody).tint(Theme.accent)
                .accessibilityIdentifier("clientContact.hideBranding")
        }.card()
    }
}

private struct ClientContactAvatar: View {
    let photo: UIImage?
    let avatarURL: String?
    var body: some View {
        Group {
            if let photo { Image(uiImage: photo).resizable().scaledToFill() }
            else if let raw = avatarURL, let url = URL(string: raw) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                placeholder: { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(Theme.accent) }
            } else { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(Theme.accent) }
        }.frame(width: 72, height: 72).clipShape(Circle())
            .background(Theme.accentSoft, in: Circle())
            .overlay(Circle().strokeBorder(Theme.accent.opacity(0.2), lineWidth: 2))
            .accessibilityHidden(true)
    }
}

private struct ClientContactPublicPreview: View {
    let card: ClientPublicCard
    let photo: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ClientContactSectionTitle(title: "Your client's card", subtitle: "Preview of the details buyers will see.", icon: "eye.fill")
            HStack(alignment: .top, spacing: 14) {
                ClientContactAvatar(photo: photo, avatarURL: card.avatarURL)
                VStack(alignment: .leading, spacing: 5) {
                    Text(card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Client or business name" : card.name)
                        .font(.rpHeadline).foregroundStyle(Theme.ink)
                    if let brokerage = card.brokerage, !brokerage.isEmpty { Text(brokerage).font(.rpCaption).foregroundStyle(Theme.inkDim) }
                    if let title = card.title, !title.isEmpty { Text(title).font(.rpCaption).foregroundStyle(Theme.inkDim) }
                    if let phone = card.phone, !phone.isEmpty { Label(phone, systemImage: "phone.fill").font(.rpCaption).foregroundStyle(Theme.accent) }
                    if let email = card.email, !email.isEmpty { Label(email, systemImage: "envelope.fill").font(.rpCaption).foregroundStyle(Theme.accent) }
                    if let website = card.website, !website.isEmpty { Label(website, systemImage: "globe").font(.rpCaption).foregroundStyle(Theme.accent) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.card().accessibilityIdentifier("clientContact.publicPreview")
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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                routingCard
                if contact.enabled {
                    ClientContactPublicPreview(card: contact.publicCard, photo: photo)
                    photoCard
                    ClientContactFields(contact: $contact)
                }
                if let error {
                    Text(error)
                        .font(.rpCaption).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .card().accessibilityIdentifier("clientContact.error")
                }
                if live.clientContactDirty == true, live.serverID != nil {
                    Button("Reload the latest details from Studio", role: .destructive) { reloadConfirm = true }
                        .font(.rpCaption.weight(.semibold)).padding(.vertical, 8)
                }
            }.padding(Theme.spacing)
        }
            .background(Theme.bg).tint(Theme.accent)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
            .navigationTitle("Listing contact").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
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
    private var routingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ClientContactSectionTitle(title: "Who should buyers contact?", subtitle: "Choose the card for this listing.", icon: "person.crop.rectangle.fill")
            Toggle("Use a client's contact details", isOn: $contact.enabled)
                .font(.rpBody).tint(Theme.accent).accessibilityIdentifier("clientContact.enabled")
            Text(contact.enabled ? "Your client appears on this listing. Your own profile and other listings keep their details."
                 : "This listing uses your own account card. You can switch to a client's card any time.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
        }.card()
    }
    private var photoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ClientContactSectionTitle(title: "Client photo or business logo", subtitle: "Add the person or business buyers should recognize.", icon: "photo.fill")
            HStack(spacing: 14) {
                ClientContactAvatar(photo: photo, avatarURL: contact.publicCard.avatarURL)
                VStack(alignment: .leading, spacing: 10) {
                    PhotosPicker(selection: $picker, matching: .images) { Label("Choose photo", systemImage: "photo.on.rectangle") }
                        .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("clientContact.photo")
                    if photo != nil || contact.photoAssetID != nil {
                        Button("Remove photo", role: .destructive) { photo = nil; photoChanged = true; contact.photoAssetID = nil; contact.publicCard.avatarURL = nil; picker = nil }
                            .font(.rpCaption).accessibilityIdentifier("clientContact.removePhoto")
                    }
                }
                Spacer(minLength: 0)
            }
        }.card()
    }
    private var saveBar: some View {
        VStack(spacing: 8) {
            PrimaryButton(title: saving ? "Saving…" : contact.enabled ? "Save client details" : "Use my account card",
                          systemImage: saving ? nil : "checkmark", isDisabled: saving || loading) {
                // Commit through the existing validated/session-fenced path;
                // the fixed action stays above the keyboard while editing.
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                Task { await save() }
            }.accessibilityIdentifier("clientContact.save")
            if saving { ProgressView().tint(Theme.accent) }
            Text("Form inquiries stay in your Leads. When your client's card is on, inquiries are also emailed to the lead address.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, Theme.spacing).padding(.top, 12).padding(.bottom, 8)
            .background(Theme.bg)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
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
