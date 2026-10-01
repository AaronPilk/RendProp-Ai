import Foundation

enum FileStore { static func url(fromRelativePath path: String) -> URL { URL(fileURLWithPath: "/isolated/" + path) } }

@main enum ClientContactTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func expect(_ value: Bool, _ label: String) throws { checks += 1; guard value else { throw Failure.assertion(label) } }
    static func rejects(_ label: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { checks += 1; return }
        throw Failure.assertion(label)
    }
    @MainActor static func main() async throws {
        let listingID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let org = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let photoID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let ownerA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", ownerB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let suite = "synthetic.client.contact." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try expect(RealEstateRoleStore.current(owner: ownerA, defaults: defaults) == .agent, "Existing unknown account presents Agent")
        RealEstateRoleStore.choose(.photographerVideographer, owner: nil, defaults: defaults)
        RealEstateRoleStore.claimOnboarding(owner: ownerA, defaults: defaults)
        try expect(RealEstateRoleStore.current(owner: ownerA, defaults: defaults).isProducer, "First session receives explicit onboarding choice")
        try expect(RealEstateRoleStore.isDirty(owner: ownerA, defaults: defaults), "Onboarding choice waits for confirmed profile save")
        RealEstateRoleStore.claimOnboarding(owner: ownerB, defaults: defaults)
        try expect(RealEstateRoleStore.current(owner: ownerB, defaults: defaults) == .agent, "Another account cannot inherit onboarding choice")
        RealEstateRoleStore.acceptCloud(.agent, owner: ownerA, defaults: defaults)
        try expect(RealEstateRoleStore.current(owner: ownerA, defaults: defaults).isProducer, "Cloud read cannot erase offline preference")
        RealEstateRoleStore.markSynced(.agent, owner: ownerA, defaults: defaults)
        try expect(RealEstateRoleStore.isDirty(owner: ownerA, defaults: defaults), "Stale profile write cannot acknowledge different current role")
        RealEstateRoleStore.markSynced(.photographerVideographer, owner: ownerA, defaults: defaults)
        try expect(!RealEstateRoleStore.isDirty(owner: ownerA, defaults: defaults), "Only matching server write clears dirty preference")
        RealEstateRoleStore.acceptCloud(.agent, owner: ownerA, defaults: defaults)
        try expect(RealEstateRoleStore.current(owner: ownerA, defaults: defaults) == .agent, "Clean role receives office changes")
        let legacy = try JSONDecoder().decode(Listing.self, from: Data("{\"address\":\"Old local draft\"}".utf8))
        try expect(legacy.clientContact == nil && legacy.clientPhotoRelPath == nil && legacy.clientContactDirty == nil, "Old listing snapshot opens with original card semantics")
        let disabledJSON = "{\"listing_id\":\"\(listingID)\",\"enabled\":false,\"public_card\":{},\"recipient_email\":\"\",\"hide_rendprop_branding\":false,\"photo_asset_id\":null,\"revision\":1,\"updated_at\":null}"
        let disabled = try JSONDecoder().decode(ListingClientContact.self, from: Data(disabledJSON.utf8))
        try expect(try disabled.checked(listingID: listingID).publicCard.name == "", "Disabled contact with empty public card decodes")
        try expect(!ClientContactPolicy.useClientCard(disabled), "Disabled per-listing card uses explicit owner fallback")
        try expect(!ClientContactPolicy.requiresChoice(isProducer: true, contact: disabled), "Photographer can publish explicit own-company card without changing workflow")
        try expect(ClientContactPolicy.requiresChoice(isProducer: true, contact: nil), "New photographer publication asks who buyers should contact")
        try expect(!ClientContactPolicy.requiresChoice(isProducer: false, contact: nil), "Existing agent publication retains own-card default")
        var draft = ListingClientContact(listingID: listingID, enabled: true,
            publicCard: ClientPublicCard(name: "Client One", phone: "+1 555 012 3456"), recipientEmail: "Client@Example.invalid")
        try ClientContactPolicy.validate(draft)
        try expect(ClientContactPolicy.useClientCard(draft), "Enabled card is all-or-nothing, including missing optional fields")
        var listing = legacy; listing.id = listingID; listing.serverID = listingID; listing.serverOrgID = org
        listing.clientContact = draft; listing.clientContactDirty = true; listing.clientPhotoRelPath = "ClientContacts/one.jpg"; listing.clientPhotoDirty = true
        let roundtrip = try JSONDecoder().decode(Listing.self, from: JSONEncoder().encode(listing))
        try expect(roundtrip.clientContact == draft && roundtrip.clientPhotoRelPath == listing.clientPhotoRelPath && roundtrip.clientPhotoDirty == true, "Contact and unfinished photo upload survive relaunch")
        var remote = listing; remote.address = "Office facts"; remote.clientContact = nil; remote.clientContactDirty = nil
        let merged = try CloudListingMerge.merge(local: [listing], remote: [remote], protected: [])[0]
        try expect(merged.clientContact == draft && merged.clientContactDirty == true, "Property fact hydration cannot erase separate contact draft")
        try expect(merged.clientPhotoRelPath == listing.clientPhotoRelPath, "Cloud fact hydration retains client photo separate from property hero")
        let body = draft.writeBody
        let publicBody = body["public_card"] as! [String: Any]
        try expect(publicBody["recipient_email"] == nil && publicBody["avatar_url"] == nil, "Private lead email and arbitrary avatar URL never written as public card")
        let ownerCard = AgentCard.current
        let clientCard = AgentCard.forListing(listing, fallback: ownerCard)
        try expect(clientCard.name == "Client One" && clientCard.email.isEmpty && clientCard.website.isEmpty, "Optional public fields cannot inherit photographer private contact")
        try expect(!clientCard.usesOwnHeadshot && clientCard.resolvedHeadshotURL?.path == "/isolated/ClientContacts/one.jpg", "Client preview uses only the listing's client photo")
        var noPhoto = listing; noPhoto.clientPhotoRelPath = nil
        try expect(AgentCard.forListing(noPhoto, fallback: ownerCard).resolvedHeadshotURL == nil, "Missing client photo must never show photographer headshot")
        var otherListing = listing; otherListing.id = org; otherListing.clientPhotoRelPath = "ClientContacts/two.jpg"
        try expect(AgentCard.forListing(otherListing, fallback: ownerCard).resolvedHeadshotURL != clientCard.resolvedHeadshotURL, "Two listings isolate their client photos")
        otherListing.clientContact = disabled
        let fallback = AgentCard.forListing(otherListing, fallback: ownerCard)
        try expect(fallback.email == ownerCard.email && fallback.resolvedHeadshotURL == AgentCard.headshotURL, "Disabled contact deliberately selects complete owner card")
        draft.publicCard.avatarURL = "https://example.invalid/server-only.jpg"
        try expect(draft.publicCard.wire["avatar_url"] == nil, "Server-resolved avatar URL cannot be echoed as caller input")
        var malformed = draft; malformed.publicCard.name = ""
        try await rejects("Enabled name required") { try ClientContactPolicy.validate(malformed) }
        malformed = draft; malformed.recipientEmail = ""
        try await rejects("Enabled recipient required") { try ClientContactPolicy.validate(malformed) }
        malformed = draft; malformed.recipientEmail = "bad\n@other.invalid"
        try await rejects("Recipient rejects line breaks") { try ClientContactPolicy.validate(malformed) }
        malformed = draft; malformed.publicCard.website = "javascript:alert(1)"
        try await rejects("Public link cannot execute code") { try ClientContactPolicy.validate(malformed) }
        malformed = draft; malformed.publicCard.website = "https://person:password@example.invalid"
        try await rejects("Public URL cannot carry credentials") { try ClientContactPolicy.validate(malformed) }
        malformed = draft; malformed.publicCard.avatarURL = "file:///private/photo.jpg"
        try await rejects("Server avatar cannot access local files") { _ = try malformed.checked(listingID: listingID) }
        try await rejects("Contact must belong to requested listing") { _ = try draft.checked(listingID: org) }
        var reads = 0, writes = 0, uploads = 0
        var identityCurrent = true, draftCurrent = true
        let snapshot = ClientContactCommit.Snapshot(contact: draft, photoPath: nil, photoDirty: false)
        var saved = draft; saved.revision = 1; saved.recipientEmail = "client@example.invalid"
        let first = try await ClientContactCommit.resolve(snapshot: snapshot, listingID: listingID,
            isIdentityCurrent: { identityCurrent }, isDraftCurrent: { draftCurrent },
            fetch: { reads += 1; return nil }, uploadPhoto: { _ in uploads += 1; return photoID },
            save: { submitted in writes += 1; try expect(submitted.recipientEmail == "client@example.invalid", "Save canonicalizes private recipient"); return saved })
        try expect(first.revision == 1 && reads == 1 && writes == 1 && uploads == 0, "One new client save performs one guarded write")
        let recovered = try await ClientContactCommit.resolve(snapshot: snapshot, listingID: listingID,
            isIdentityCurrent: { true }, isDraftCurrent: { true }, fetch: { saved },
            uploadPhoto: { _ in uploads += 1; return photoID }, save: { _ in writes += 1; return saved })
        try expect(recovered == saved && writes == 1, "Lost PUT reply adopts identical canonical receipt without overwriting or resending")
        var persistedPhoto = snapshot
        persistedPhoto.photoPath = "ClientContacts/retry.jpg"; persistedPhoto.photoDirty = true
        var savedPhoto: ListingClientContact?
        var photoUploads = 0, photoWrites = 0, receiptBinds = 0
        try await rejects("Simulate headshot PUT success with missing response") {
            _ = try await ClientContactCommit.resolve(snapshot: persistedPhoto, listingID: listingID,
                isIdentityCurrent: { true }, isDraftCurrent: { true }, fetch: { nil },
                uploadPhoto: { _ in photoUploads += 1; return photoID },
                onPhotoUploaded: { asset in
                    receiptBinds += 1; persistedPhoto.contact.photoAssetID = asset; persistedPhoto.photoDirty = false
                }, save: { submitted in
                    photoWrites += 1; var receipt = submitted; receipt.revision = 1; savedPhoto = receipt
                    throw Failure.assertion("synthetic lost response")
                })
        }
        let persistedListing = try JSONDecoder().decode(Listing.self, from: JSONEncoder().encode({ () -> Listing in
            var value = listing; value.clientContact = persistedPhoto.contact; value.clientPhotoDirty = persistedPhoto.photoDirty
            value.clientPhotoRelPath = persistedPhoto.photoPath; return value
        }()))
        try expect(persistedListing.clientContact?.photoAssetID == photoID && persistedListing.clientPhotoDirty == false,
                   "Photo upload receipt survives relaunch before contact PUT can be confirmed")
        let retriedPhoto = try await ClientContactCommit.resolve(snapshot: .init(contact: persistedListing.clientContact!,
            photoPath: persistedListing.clientPhotoRelPath, photoDirty: persistedListing.clientPhotoDirty == true), listingID: listingID,
            isIdentityCurrent: { true }, isDraftCurrent: { true }, fetch: { savedPhoto },
            uploadPhoto: { _ in photoUploads += 1; return UUID() },
            onPhotoUploaded: { _ in receiptBinds += 1 }, save: { _ in photoWrites += 1; return savedPhoto! })
        try expect(retriedPhoto == savedPhoto && photoUploads == 1 && photoWrites == 1 && receiptBinds == 1,
                   "Headshot retry adopts the exact saved receipt without another upload or overwrite")
        var other = saved; other.publicCard.name = "Another client's newer office edit"
        try await rejects("Conflict cannot overwrite newer client") {
            _ = try await ClientContactCommit.resolve(snapshot: snapshot, listingID: listingID,
                isIdentityCurrent: { true }, isDraftCurrent: { true }, fetch: { other },
                uploadPhoto: { _ in uploads += 1; return photoID }, save: { _ in writes += 1; return saved })
        }
        try expect(writes == 1, "Conflicting revision caused no write")
        identityCurrent = false
        try await rejects("Account switch rejects before GET") {
            _ = try await ClientContactCommit.resolve(snapshot: snapshot, listingID: listingID,
                isIdentityCurrent: { identityCurrent }, isDraftCurrent: { true }, fetch: { reads += 1; return nil },
                uploadPhoto: { _ in uploads += 1; return photoID }, save: { _ in writes += 1; return saved })
        }
        try expect(reads == 1 && writes == 1, "Foreign account operation made no network calls")
        identityCurrent = true
        try await rejects("Workspace changes while reading reject before write") {
            _ = try await ClientContactCommit.resolve(snapshot: snapshot, listingID: listingID,
                isIdentityCurrent: { identityCurrent }, isDraftCurrent: { true }, fetch: { identityCurrent = false; return nil },
                uploadPhoto: { _ in uploads += 1; return photoID }, save: { _ in writes += 1; return saved })
        }
        try expect(writes == 1, "Changed read context cannot mutate server")
        identityCurrent = true
        try await rejects("Draft edited during GET rejects stale save") {
            _ = try await ClientContactCommit.resolve(snapshot: snapshot, listingID: listingID,
                isIdentityCurrent: { true }, isDraftCurrent: { draftCurrent }, fetch: { draftCurrent = false; return nil },
                uploadPhoto: { _ in uploads += 1; return photoID }, save: { _ in writes += 1; return saved })
        }
        draftCurrent = true
        var withPhoto = snapshot; withPhoto.photoPath = "ClientContacts/one.jpg"; withPhoto.photoDirty = true
        try await rejects("Workspace change during upload rejects contact mutation") {
            _ = try await ClientContactCommit.resolve(snapshot: withPhoto, listingID: listingID,
                isIdentityCurrent: { identityCurrent }, isDraftCurrent: { true }, fetch: { nil },
                uploadPhoto: { _ in uploads += 1; identityCurrent = false; return photoID },
                onPhotoUploaded: { _ in receiptBinds += 1 }, save: { _ in writes += 1; return saved })
        }
        try expect(writes == 1 && uploads == 1, "Uploaded photo cannot be bound into a different workspace")
        try expect(receiptBinds == 1, "Foreign-workspace upload reply cannot persist a receipt on a different listing")
        try await rejects("New photo selected during upload rejects stale receipt") {
            _ = try await ClientContactCommit.resolve(snapshot: withPhoto, listingID: listingID,
                isIdentityCurrent: { true }, isDraftCurrent: { draftCurrent }, fetch: { nil },
                uploadPhoto: { _ in draftCurrent = false; return photoID },
                onPhotoUploaded: { _ in receiptBinds += 1 }, save: { _ in writes += 1; return saved })
        }
        try expect(receiptBinds == 1 && writes == 1, "A newer photo cannot inherit the previous selection's upload receipt")
        draftCurrent = true
        identityCurrent = true
        try await rejects("Account changed during PUT rejects response binding") {
            _ = try await ClientContactCommit.resolve(snapshot: snapshot, listingID: listingID,
                isIdentityCurrent: { identityCurrent }, isDraftCurrent: { true }, fetch: { nil },
                uploadPhoto: { _ in photoID }, save: { _ in identityCurrent = false; return saved })
        }
        var latest = draft; latest.recipientEmail = "new-client@example.invalid"
        let late = try ClientContactPolicy.acknowledge(saved: saved, snapshot: draft, latest: latest,
            snapshotPhoto: "old.jpg", latestPhoto: "new.jpg")
        try expect(!late.clearsDirty && late.contact.recipientEmail == latest.recipientEmail && late.contact.revision == saved.revision, "A late edit preserves recipient/photo dirty state while advancing CAS baseline")
        let exact = try ClientContactPolicy.acknowledge(saved: saved, snapshot: draft, latest: draft, snapshotPhoto: "same.jpg", latestPhoto: "same.jpg")
        try expect(exact.clearsDirty && exact.contact == saved, "Only unchanged local draft receives clean acknowledgement")
        let legacyDelivery = try JSONDecoder().decode(ClientLeadDelivery.self, from: Data("{\"state\":\"email_sent\",\"recipient_email\":\"old@example.invalid\",\"can_resend\":true}".utf8))
        try expect(legacyDelivery.currentRecipientEmail == nil && legacyDelivery.label == "Email sent to client", "Older delivery metadata remains readable")
        let newDelivery = try JSONDecoder().decode(ClientLeadDelivery.self, from: Data("{\"state\":\"failed\",\"recipient_email\":\"old@example.invalid\",\"current_recipient_email\":\"new@example.invalid\",\"can_resend\":true}".utf8))
        try expect(newDelivery.recipientEmail != newDelivery.currentRecipientEmail && newDelivery.label == "Email needs attention", "Delivery history remains distinct from current resend destination")
        let oldInquiry = try JSONDecoder().decode(ClientLeadDelivery.self, from: Data("{\"state\":\"skipped\",\"recipient_email\":null,\"client_name\":null,\"last_attempt_at\":null,\"current_recipient_email\":\"client@example.invalid\",\"can_resend\":true}".utf8))
        try expect(oldInquiry.label == "Ready to send to client" && oldInquiry.recipientEmail == nil, "Older inquiry offers first send without inventing delivery history")
        var cancelled = oldInquiry; cancelled.lastAttemptAt = "2026-10-01T18:00:00Z"
        try expect(cancelled.label == "Client email skipped", "Cancelled attempt does not claim a provider never delivered it")
        try expect(CloudListingMerge.isContactPhotoKey("renders/\(org)/\(listingID)/contact-\(photoID).jpg"), "Contact photo prefix classified separately")
        try expect(!CloudListingMerge.isContactPhotoKey("renders/\(org)/\(listingID)/gallery-\(photoID).jpg"), "Real property gallery remains available")
        let stateJSON = "{\"org_id\":\"\(org)\",\"listing_id\":\"\(listingID)\",\"renders\":[],\"photos\":[{\"id\":\"\(photoID)\",\"listing_id\":\"\(listingID)\",\"original_key\":\"renders/\(org)/\(listingID)/contact-\(photoID).jpg\",\"enhanced_key\":null,\"is_staged\":false}],\"chapters\":[],\"next_offset\":null}"
        let state = try JSONDecoder().decode(CloudListingState.self, from: Data(stateJSON.utf8))
        try await rejects("Contact photo cannot become property export/AI input") { _ = try state.checked(listingID: listingID, orgID: org, offset: 0) }
        print("Client contact checks passed: \(checks) (synthetic data; no email, network, provider or camera calls)")
    }
}
