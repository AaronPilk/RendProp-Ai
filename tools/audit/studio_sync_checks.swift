import Foundation

// Compile with the actual Listing, Money and WorkspaceSync sources. FileStore
// is only a test path resolver; no production Auth, customer file or network.
enum FileStore { static func url(fromRelativePath path: String) -> URL { URL(fileURLWithPath: "/isolated/\(path)") } }

@main struct StudioSyncChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        func refuses(_ body: () throws -> Void, _ message: String) {
            do { try body(); preconditionFailure(message) } catch { checks += 1 }
        }
        let sid = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let org = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let localID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        var local = Listing(id: localID, address: "Before office edit", beds: 2, baths: 1, sqft: 1100, price: Money(cents: 100))
        local.serverID = sid; local.serverOrgID = org; local.mainPhotoRelPath = "Photos/local.jpg"
        local.exteriorPhotoRelPath = "Photos/exterior.jpg"; local.aerialRelPath = "Aerials/local.mp4"
        var remote = Listing(id: sid, address: "After office edit", beds: 3, baths: 2, sqft: 1300, price: Money(cents: 200), status: .ready)
        remote.serverID = sid; remote.serverOrgID = org; remote.details = ["floorplan_url": "https://example.invalid/plan.png", "allow_indexing": "true"]
        remote.allowSearchIndexing = true; remote.shareSlug = "office-tour"; remote.shareURL = "https://rendprop.com/f/office-tour"
        let merged = try CloudListingMerge.merge(local: [local], remote: [remote], protected: [])[0]
        check(merged.id == localID && merged.serverID == sid, "Cloud hydration must retain the local UUID and use the same server UUID")
        check(merged.address == remote.address && merged.beds == 3 && merged.price.cents == 200, "Office edits must reach phone facts")
        check(merged.mainPhotoRelPath == local.mainPhotoRelPath && merged.exteriorPhotoRelPath == local.exteriorPhotoRelPath && merged.aerialRelPath == local.aerialRelPath, "Phone files must survive office updates")
        check(merged.serverShareURL?.absoluteString == remote.shareURL && merged.allowSearchIndexing == true, "Published links and indexing must come back from Studio")
        check(merged.details?["floorplan_url"] == remote.details?["floorplan_url"], "Floorplan link must hydrate")
        var dirty = local; dirty.needsServerSync = true; dirty.address = "Phone edit made during refresh"
        let preserved = try CloudListingMerge.merge(local: [dirty], remote: [remote], protected: [])[0]
        check(preserved.address == dirty.address && preserved.needsServerSync == true, "A late local edit must never be overwritten")
        let pending = try CloudListingMerge.merge(local: [local], remote: [remote], protected: [localID])[0]
        check(pending.address == local.address, "Pending render/publish state must stay local")
        let added = try CloudListingMerge.merge(local: [], remote: [remote], protected: [])[0]
        check(added.id == sid && added.cloudImported == true && added.serverOrgID == org, "New desktop listings must appear without a duplicate server row")
        let gone = try CloudListingMerge.merge(local: [merged], remote: [], protected: [])[0]
        check(gone.cloudUnavailable == true && gone.shareURL == nil && gone.mainPhotoRelPath == local.mainPhotoRelPath, "Cloud removal must hide revoked links while preserving files")
        let recovered = try CloudListingMerge.merge(local: [gone], remote: [remote], protected: [])[0]
        check(recovered.cloudUnavailable == false && recovered.lastError == nil, "Restored access must clear the cloud-only warning")
        let unbound = Listing(address: "Unfinished capture", beds: 0, baths: 0, sqft: 0, price: Money(cents: 0))
        let mixed = try CloudListingMerge.merge(local: [unbound], remote: [remote], protected: [])
        check(mixed.contains(unbound), "Never drop a local-only capture")
        refuses({ _ = try CloudListingMerge.merge(local: [local], remote: [remote, remote], protected: []) }, "Duplicate rows cannot be a complete snapshot")
        var malformed = remote; malformed.serverOrgID = nil
        refuses({ _ = try CloudListingMerge.merge(local: [local], remote: [malformed], protected: []) }, "Unscoped row must be refused")
        let encoded = try JSONEncoder().encode(added)
        let decoded = try JSONDecoder().decode(Listing.self, from: encoded)
        check(decoded.serverOrgID == org && decoded.cloudImported == true, "New optional fields must persist")
        let legacy = try JSONDecoder().decode(Listing.self, from: Data("{\"address\":\"Old snapshot\"}".utf8))
        check(legacy.serverOrgID == nil && legacy.cloudImported == nil, "Existing snapshots must still open")

        let now = CloudListingMerge.date("2030-01-01T00:00:00Z")!, expiry = "2030-01-01T00:10:00Z"
        let media = URL(string: "https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.r2.cloudflarestorage.com/bucket/uploads/\(org.uuidString.lowercased())/\(sid.uuidString.lowercased())/photo.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-SignedHeaders=host&X-Amz-Signature=\(String(repeating: "a", count: 64))&X-Amz-Date=20300101T000000Z&X-Amz-Expires=600")!
        try CloudListingMerge.validateMedia(media, expiry: expiry, listingID: sid, orgID: org, now: now); checks += 1
        refuses({ try CloudListingMerge.validateMedia(media, expiry: expiry, listingID: localID, orgID: org, now: now) }, "A signed URL for a different listing must be refused")
        refuses({ try CloudListingMerge.validateMedia(media, expiry: expiry, listingID: sid, orgID: org, now: now.addingTimeInterval(601)) }, "Expired URL must be refreshed")
        refuses({ try CloudListingMerge.validateMedia(URL(string: "https://example.invalid/anything")!, expiry: expiry, listingID: sid, orgID: org, now: now) }, "Storage URLs cannot forward credentials to arbitrary domains")

        let voice = URL(string: media.absoluteString.replacingOccurrences(of: "uploads/\(org.uuidString.lowercased())/\(sid.uuidString.lowercased())/photo.jpg", with: "ai-voice/\(org.uuidString.lowercased())/\(sid.uuidString.lowercased()).mp3"))!
        try CloudListingMerge.validateMedia(voice, expiry: expiry, listingID: sid, orgID: org, now: now, voice: true); checks += 1
        refuses({ try CloudListingMerge.validateMedia(voice, expiry: expiry, listingID: sid, orgID: localID, now: now, voice: true) }, "Cloud narration cannot cross workspaces")
        refuses({ try CloudListingMerge.validateMedia(voice, expiry: expiry, listingID: sid, orgID: org, now: now) }, "Voice storage cannot masquerade as an original photo")

        let prefs = NotificationPrefs(wire: ["lead_received": false, "render_ready": true, "upload_stuck": false,
            "first_tour_nudge": false, "free_week_ending": true, "allowance_low": false, "muted_until": "2099-01-01T00:00:00Z"])
        check(!prefs.enabled && !prefs.leads && prefs.renders && !prefs.uploadStuck && !prefs.firstTourNudge, "Phone must read Studio's exact switches and active mute")
        check(Set(prefs.wire.keys) == Set(["lead_received", "render_ready", "upload_stuck", "first_tour_nudge", "free_week_ending", "allowance_low", "muted_until"]), "Native PATCH must contain the actual six accepted categories")
        check(prefs.wire["upload_stuck"] as? Bool == false && prefs.wire["first_tour_nudge"] as? Bool == false, "Saving on phone must preserve Studio's disabled choices")
        var enabled = prefs; enabled.enabled = true
        check(enabled.wire["muted_until"] is NSNull, "Re-enabling on phone must clear the shared mute")
        var expiredMute = NotificationPrefs(wire: ["muted_until": "2000-01-01T00:00:00Z"])
        check(expiredMute.enabled, "Expired mute must not look disabled")
        expiredMute.enabled = false
        check(expiredMute.wire["muted_until"] as? String == "2099-01-01T00:00:00Z", "Disabling after an expired mute must create a new mute")
        check(NotificationCategory.allCases.count == 6, "All Studio switches must be editable on phone")
        _ = try JSONSerialization.data(withJSONObject: prefs.wire); checks += 1

        let identity = CloudDraftCreation.Identity(userID: org.uuidString, revision: 7)
        var actor = identity
        var draft = unbound
        draft.cloudCreateFingerprint = try CloudDraftCreation.fingerprint(draft)
        var current: Listing? = draft
        var removed: UUID?
        let newID = try await CloudDraftCreation.ensure(snapshot: draft, identity: identity, create: { _ in
            await Task.yield()
            current?.address = "Edited while the first create was pending"
            return remote
        }, current: { current }, activeIdentity: { actor }, save: { current = $0 }, deleteRemoved: { removed = $0 })
        check(newID == sid && current?.id == draft.id, "Async create must attach a server identity without changing local UUID")
        check(current?.address == "Edited while the first create was pending" && current?.needsServerSync == true, "An edit during create must survive and be queued for PATCH")
        check(current?.serverOrgID == org && current?.cloudSyncOwnerID == org, "Create receipt must persist workspace and account ownership")
        check(removed == nil, "Normal creation must not delete anything")
        let protectedCreate = try CloudListingMerge.merge(local: [current!], remote: [], protected: [draft.id])[0]
        check(protectedCreate.cloudUnavailable != true, "A row created during an older snapshot must not be mistaken for a cloud deletion")

        var replay = remote; replay.cloudCreateReplayed = true; replay.address = "Office edit after lost phone receipt"
        current = draft
        _ = try await CloudDraftCreation.ensure(snapshot: draft, identity: identity, create: { _ in replay }, current: { current }, activeIdentity: { actor }, save: { current = $0 }, deleteRemoved: { _ in })
        check(current?.address == replay.address && current?.needsServerSync == false, "An unchanged phone retry must not overwrite a newer office edit")
        current = draft; current?.address = "A new phone edit after the lost receipt"
        _ = try await CloudDraftCreation.ensure(snapshot: current!, identity: identity, create: { _ in replay }, current: { current }, activeIdentity: { actor }, save: { current = $0 }, deleteRemoved: { _ in })
        check(current?.address == "A new phone edit after the lost receipt" && current?.needsServerSync == true, "New phone edits after a lost receipt still need PATCH")

        current = draft
        do {
            _ = try await CloudDraftCreation.ensure(snapshot: draft, identity: identity, create: { _ in
                await Task.yield(); actor = .init(userID: identity.userID, revision: 9); return remote
            }, current: { current }, activeIdentity: { actor }, save: { current = $0 }, deleteRemoved: { _ in preconditionFailure("Cannot delete across an account change") })
            preconditionFailure("Account A→B→A must not apply a stale create reply")
        } catch { checks += 1 }
        check(current?.serverID == nil, "A stale create receipt must not bind the current account")
        actor = identity; current = draft
        do {
            _ = try await CloudDraftCreation.ensure(snapshot: draft, identity: identity, create: { _ in current = nil; await Task.yield(); return remote }, current: { current }, activeIdentity: { actor }, save: { _ in preconditionFailure("Cannot resurrect a deleted local draft") }, deleteRemoved: { removed = $0 })
            preconditionFailure("A deleted draft must cancel create binding")
        } catch { checks += 1 }
        check(removed == sid, "Deleting during create must clean up its received server row")
        var owned = draft; owned.cloudSyncOwnerID = org
        check(CloudDraftCreation.canAutoSync(owned, userID: org) && !CloudDraftCreation.canAutoSync(owned, userID: sid), "Automatic draft creation cannot upload another account's local facts")
        owned.cloudDetachedServerID = sid
        check(!CloudDraftCreation.canAutoSync(owned, userID: org), "A detached prior server identity must be recovered, never recreated")
        let reattached = try CloudListingMerge.merge(local: [owned], remote: [remote], protected: [], ownerID: org)
        check(reattached.count == 1 && reattached[0].id == owned.id && reattached[0].serverID == sid && reattached[0].cloudDetachedServerID == nil, "Returning account must recover its original cloud identity")

        let recipe = NativeReelDraft(schema: 1, kind: "native-reel-setup", portrait: true, titleCard: true, shotCaptions: true,
            captionStyle: "punchCard", transition: "whip", motionPrompt: "Slow push", script: "A bright living room.", tone: "warm",
            wordCaptions: true, voiceMode: "aiVoice", voiceResultId: sid, localNarration: false,
            photos: [.init(localId: "cloud-\(sid.uuidString)", sourcePhotoId: sid), .init(localId: "native-123", sourcePhotoId: nil)], localExtraClipCount: 1, updatedAt: "2030-01-01T00:00:00Z")
        let recipeBytes = try JSONEncoder().encode(recipe)
        let restoredRecipe = try JSONDecoder().decode(NativeReelDraft.self, from: recipeBytes).checked()
        check(restoredRecipe == recipe, "Native setup must roundtrip exact captions, transition, script and ordered photo references")
        check(!String(decoding: recipeBytes, as: UTF8.self).contains("https://") && restoredRecipe.photos[1].sourcePhotoId == nil, "Setup cannot persist signed URLs or invent cloud IDs for local photos")
        _ = try CloudNativeReelDocument(listing_id: sid, revision: 2, payload: recipe).checked(listingID: sid); checks += 1
        refuses({ _ = try CloudNativeReelDocument(listing_id: sid, revision: 2, payload: recipe).checked(listingID: org) }, "A recipe cannot load for another listing")
        var invalid = try JSONSerialization.jsonObject(with: recipeBytes) as! [String: Any]
        invalid["transition"] = "unknown"
        refuses({ _ = try JSONDecoder().decode(NativeReelDraft.self, from: JSONSerialization.data(withJSONObject: invalid)).checked() }, "Unknown transition semantics must not be guessed")
        invalid["transition"] = "cut"; invalid["photos"] = [["localId": "https://private.example/file"]]
        refuses({ _ = try JSONDecoder().decode(NativeReelDraft.self, from: JSONSerialization.data(withJSONObject: invalid)).checked() }, "Raw media URLs cannot be passed as local photo references")

        let voiceReference = SharedVoiceReference(resultID: sid, ownerID: org, listingID: localID)
        check(voiceReference.resultID(ownerID: org, listingID: localID) == sid, "Selected native narration retains its genuine shared result for the same account and listing")
        check(voiceReference.resultID(ownerID: sid, listingID: localID) == nil, "A shared narration reference cannot follow an account switch")
        check(voiceReference.resultID(ownerID: org, listingID: sid) == nil, "A shared narration reference cannot follow a different listing")
        let localVoice = Voiceover(audioURL: URL(fileURLWithPath: "/isolated/voice.mp3"), duration: 4, transcript: "Test", source: .aiVoice)
        check(localVoice.sharedReference == nil, "A missing history receipt does not prevent paid narration from remaining playable")
        let linkedVoice = Voiceover(audioURL: localVoice.audioURL, duration: 4, transcript: "Test", source: .aiVoice, sharedReference: voiceReference)
        check(linkedVoice.sharedReference == voiceReference, "Voiceover carries its association separately from its local UUID")
        print("PASS: \(checks) deterministic native Studio sync checks")
    }
}
