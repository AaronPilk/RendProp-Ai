import Foundation

/// A usage preference, never a workspace membership or permission.
enum RealEstateRole: String, Codable, CaseIterable, Identifiable {
    case agent
    case photographerVideographer = "photographer_videographer"
    var id: String { rawValue }
    var label: String { self == .agent ? "Agent" : "Photographer or videographer" }
    var isProducer: Bool { self == .photographerVideographer }
}

enum RealEstateRoleStore {
    static let uiRevisionKey = "profile.realEstateRole.uiRevision.v1"
    static func key(owner: String?) -> String { "profile.realEstateRole.v1." + (owner?.lowercased() ?? "onboarding") }
    static var current: RealEstateRole { current(owner: UserDefaults.standard.string(forKey: "auth.supabase.userID")) }
    static func current(owner: String?, defaults: UserDefaults = .standard) -> RealEstateRole {
        RealEstateRole(rawValue: defaults.string(forKey: key(owner: owner)) ?? "") ?? .agent
    }
    static func choose(_ role: RealEstateRole, owner: String?, defaults: UserDefaults = .standard) {
        let k = key(owner: owner)
        defaults.set(role.rawValue, forKey: k)
        defaults.set(true, forKey: k + ".dirty")
        defaults.set(defaults.integer(forKey: uiRevisionKey) + 1, forKey: uiRevisionKey)
    }
    /// A pre-session onboarding choice can be claimed by only the first account.
    static func claimOnboarding(owner: String, defaults: UserDefaults = .standard) {
        let k = key(owner: owner), pending = key(owner: nil)
        guard defaults.object(forKey: k) == nil,
              defaults.string(forKey: pending + ".claimed") == nil,
              let value = defaults.string(forKey: pending), let role = RealEstateRole(rawValue: value) else { return }
        defaults.set(owner.lowercased(), forKey: pending + ".claimed")
        choose(role, owner: owner, defaults: defaults)
    }
    static func acceptCloud(_ role: RealEstateRole, owner: String, defaults: UserDefaults = .standard) {
        let k = key(owner: owner)
        guard !defaults.bool(forKey: k + ".dirty") else { return }
        if defaults.string(forKey: k) != role.rawValue {
            defaults.set(role.rawValue, forKey: k)
            defaults.set(defaults.integer(forKey: uiRevisionKey) + 1, forKey: uiRevisionKey)
        }
    }
    static func markSynced(_ role: RealEstateRole, owner: String, defaults: UserDefaults = .standard) {
        let k = key(owner: owner)
        guard current(owner: owner, defaults: defaults) == role else { return }
        defaults.set(false, forKey: k + ".dirty")
    }
    static func isDirty(owner: String, defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key(owner: owner) + ".dirty") }
}

struct ClientPublicCard: Codable, Hashable, Sendable {
    var name = ""
    var title: String? = nil
    var brokerage: String? = nil
    var phone: String? = nil
    var email: String? = nil
    var website: String? = nil
    var instagram: String? = nil
    var linkedin: String? = nil
    /// Read-only URL resolved by the server from the owned photo asset.
    var avatarURL: String? = nil
    enum CodingKeys: String, CodingKey {
        case name, title, brokerage, phone, email, website, instagram, linkedin
        case avatarURL = "avatar_url"
    }
    init(name: String = "", title: String? = nil, brokerage: String? = nil, phone: String? = nil, email: String? = nil,
         website: String? = nil, instagram: String? = nil, linkedin: String? = nil, avatarURL: String? = nil) {
        self.name = name; self.title = title; self.brokerage = brokerage; self.phone = phone; self.email = email
        self.website = website; self.instagram = instagram; self.linkedin = linkedin; self.avatarURL = avatarURL
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title)
        brokerage = try c.decodeIfPresent(String.self, forKey: .brokerage)
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        website = try c.decodeIfPresent(String.self, forKey: .website)
        instagram = try c.decodeIfPresent(String.self, forKey: .instagram)
        linkedin = try c.decodeIfPresent(String.self, forKey: .linkedin)
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
    }
    var normalized: ClientPublicCard {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return .init(name: name.trimmingCharacters(in: .whitespacesAndNewlines), title: clean(title),
            brokerage: clean(brokerage), phone: clean(phone), email: clean(email), website: clean(website),
            instagram: clean(instagram), linkedin: clean(linkedin), avatarURL: avatarURL)
    }
    var wire: [String: Any] {
        var fields: [String: Any] = ["name": name]
        for (key, value) in [("title",title),("brokerage",brokerage),("phone",phone),("email",email),("website",website),("instagram",instagram),("linkedin",linkedin)] {
            if let value { fields[key] = value }
        }
        return fields
    }
}

struct ListingClientContact: Codable, Hashable, Sendable {
    var listingID: UUID
    var enabled: Bool
    var publicCard: ClientPublicCard
    var recipientEmail: String
    var hideRendpropBranding = true
    var photoAssetID: UUID? = nil
    var revision: Int = 0
    var updatedAt: String? = nil
    enum CodingKeys: String, CodingKey {
        case listingID = "listing_id", enabled, publicCard = "public_card"
        case recipientEmail = "recipient_email", hideRendpropBranding = "hide_rendprop_branding"
        case photoAssetID = "photo_asset_id", revision, updatedAt = "updated_at"
    }
    var writeBody: [String: Any] {
        ["expected_revision": revision, "enabled": enabled, "public_card": publicCard.wire,
         "recipient_email": recipientEmail, "hide_rendprop_branding": hideRendpropBranding,
         "photo_asset_id": photoAssetID?.uuidString.lowercased() as Any? ?? NSNull()]
    }
    func checked(listingID expected: UUID) throws -> ListingClientContact {
        guard listingID == expected, revision >= 0 else { throw ClientContactError.invalidResponse }
        try ClientContactPolicy.validate(self)
        if let avatar = publicCard.avatarURL, !avatar.isEmpty {
            guard let url = URL(string: avatar), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else { throw ClientContactError.invalidResponse }
        }
        return self
    }
}

enum ClientContactError: LocalizedError {
    case invalidResponse, nameRequired, emailRequired, invalidEmail, invalidLink, changed, busy, clientRequired, pendingPhoto, conflict
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The client contact couldn't be verified. Try refreshing this listing."
        case .nameRequired: return "Enter your client's name or business name."
        case .emailRequired: return "Enter the email address that should receive listing inquiries."
        case .invalidEmail: return "Enter a valid email address."
        case .invalidLink: return "Use a complete website address beginning with https://."
        case .changed: return "Your account or workspace changed. Reopen this listing before saving."
        case .busy: return "Client details are already saving. Please wait, then try again."
        case .clientRequired: return "Choose your client's details or your own account card before publishing this listing."
        case .pendingPhoto: return "The client photo couldn't be uploaded. Save again when connected before publishing."
        case .conflict: return "Your client's details changed in Studio. Reload the latest details before saving this phone's changes."
        }
    }
}

enum ClientContactPolicy {
    static func isEmail(_ value: String) -> Bool {
        value.count <= 200 && value.range(of: "^[^\\s@<>]+@[^\\s@<>]+\\.[^\\s@<>]+$", options: .regularExpression) != nil
    }
    static func validate(_ contact: ListingClientContact) throws {
        guard contact.revision >= 0 else { throw ClientContactError.invalidResponse }
        guard contact.publicCard.name.count <= 200,
              [contact.publicCard.title, contact.publicCard.brokerage, contact.publicCard.phone].allSatisfy({ ($0?.count ?? 0) <= 200 }),
              [contact.publicCard.website, contact.publicCard.instagram, contact.publicCard.linkedin].allSatisfy({ ($0?.count ?? 0) <= 300 }) else { throw ClientContactError.invalidResponse }
        if contact.enabled {
            guard !contact.publicCard.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientContactError.nameRequired }
            guard !contact.recipientEmail.isEmpty else { throw ClientContactError.emailRequired }
        }
        if !contact.recipientEmail.isEmpty, !isEmail(contact.recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)) { throw ClientContactError.invalidEmail }
        if let email = contact.publicCard.email, !email.isEmpty, !isEmail(email) { throw ClientContactError.invalidEmail }
        for website in [contact.publicCard.website, contact.publicCard.instagram, contact.publicCard.linkedin].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            guard let url = URL(string: website), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else { throw ClientContactError.invalidLink }
        }
    }
    /// Never substitute the photographer's name, email, or photo into a client card.
    static func useClientCard(_ contact: ListingClientContact?) -> Bool { contact?.enabled == true }
    static func requiresChoice(isProducer: Bool, contact: ListingClientContact?) -> Bool { isProducer && contact == nil }
    static func canApply(snapshot: ListingClientContact?, latest: ListingClientContact?, snapshotPhoto: String?, latestPhoto: String?) -> Bool {
        snapshot == latest && snapshotPhoto == latestPhoto
    }
    static func sameSavedContent(_ desired: ListingClientContact, _ remote: ListingClientContact) -> Bool {
        var a = desired.publicCard.normalized, b = remote.publicCard.normalized
        a.avatarURL = nil; b.avatarURL = nil
        return desired.enabled == remote.enabled && a == b && desired.recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == remote.recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() &&
            desired.hideRendpropBranding == remote.hideRendpropBranding && desired.photoAssetID == remote.photoAssetID
    }
    struct Acknowledgement { let contact: ListingClientContact; let clearsDirty: Bool }
    static func acknowledge(saved: ListingClientContact, snapshot: ListingClientContact?, latest: ListingClientContact?,
                            snapshotPhoto: String?, latestPhoto: String?) throws -> Acknowledgement {
        guard var latest else { throw ClientContactError.changed }
        if canApply(snapshot: snapshot, latest: latest, snapshotPhoto: snapshotPhoto, latestPhoto: latestPhoto) {
            return .init(contact: saved, clearsDirty: true)
        }
        // Retain a newer local edit and only move its CAS baseline forward.
        latest.revision = max(latest.revision, saved.revision)
        return .init(contact: latest, clearsDirty: false)
    }
}

/// The same guarded transaction drives the phone's save/publish and pure race tests.
enum ClientContactCommit {
    struct Snapshot: Equatable {
        var contact: ListingClientContact
        var photoPath: String?
        var photoDirty: Bool
    }
    static func resolve(snapshot: Snapshot, listingID: UUID,
                        isIdentityCurrent: () -> Bool, isDraftCurrent: () -> Bool,
                        fetch: () async throws -> ListingClientContact?,
                        uploadPhoto: (String) async throws -> UUID,
                        onPhotoUploaded: ((UUID) throws -> Void)? = nil,
                        save: (ListingClientContact) async throws -> ListingClientContact) async throws -> ListingClientContact {
        func check(requireDraft: Bool = true) throws {
            try Task.checkCancellation()
            guard isIdentityCurrent(), !requireDraft || isDraftCurrent() else { throw ClientContactError.changed }
        }
        try check()
        var draft = snapshot.contact; draft.listingID = listingID
        draft.publicCard = draft.publicCard.normalized
        draft.recipientEmail = draft.recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try ClientContactPolicy.validate(draft)
        let remote = try await fetch(); try check()
        if snapshot.photoDirty, let photo = snapshot.photoPath {
            let asset = try await uploadPhoto(photo); try check()
            draft.photoAssetID = asset
            // Keep the upload receipt before PUT so a lost response can retry the
            // exact same photo. The caller binds it only to this unchanged draft.
            try onPhotoUploaded?(asset)
        }
        if draft.revision != (remote?.revision ?? 0) {
            // Lost PUT reply: the desired card is already saved. Read the receipt
            // without overwriting subsequent Studio edits or uploading another file.
            guard let remote, ClientContactPolicy.sameSavedContent(draft, remote) else { throw ClientContactError.conflict }
            return remote
        }
        let saved = try await save(draft)
        // A change of account/workspace must not bind a reply to another account.
        // The caller independently preserves late local edits after this write.
        try check(requireDraft: false)
        return try saved.checked(listingID: listingID)
    }
}

struct ClientLeadDelivery: Codable, Hashable, Sendable {
    var state: String
    var recipientEmail: String?
    var clientName: String?
    var lastAttemptAt: String?
    var sentAt: String?
    var canResend: Bool
    var reason: String?
    var currentRecipientEmail: String? = nil
    var currentClientName: String? = nil
    enum CodingKeys: String, CodingKey {
        case state, recipientEmail = "recipient_email", clientName = "client_name"
        case lastAttemptAt = "last_attempt_at", sentAt = "sent_at", canResend = "can_resend", reason
        case currentRecipientEmail = "current_recipient_email", currentClientName = "current_client_name"
    }
    var label: String {
        switch state {
        case "email_sent": return "Email sent to client"
        case "queued": return "Email queued"
        case "sending": return "Sending email"
        case "failed": return "Email needs attention"
        case "skipped": return lastAttemptAt == nil ? "Ready to send to client" : "Client email skipped"
        default: return "Client email not sent"
        }
    }
}
