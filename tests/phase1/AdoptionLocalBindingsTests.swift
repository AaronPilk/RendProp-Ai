import Foundation

/// Inert Auth/network scaffolding; production model methods and persistence
/// bytes are extracted mechanically by adoption-local-bindings.test.mjs.
@main @MainActor
struct AdoptionLocalBindingsTests {
    static var assertions = 0, failures = 0
    static let source = UUID(), destination = UUID(), foreign = UUID(), org = UUID()
    static func check(_ value: Bool, _ label: String) {
        assertions += 1
        if !value { failures += 1; print("FAIL: \(label)") }
    }
    static func pending(source: UUID = source, destination: UUID = destination, operation: UUID = UUID()) -> AnonymousAdoptionRecovery.Pending {
        .init(version: 1, operationID: operation, sourceUserID: source, destinationUserID: destination,
              sourceAccessToken: "synthetic-unused", sourceRefreshToken: "synthetic-unused")
    }
    static func listing() -> Listing {
        var row = Listing(address: "Synthetic local metadata", beds: 1, baths: 1, sqft: 1, price: Money(cents: 1))
        row.serverID = UUID(); row.shareSlug = "synthetic-published"
        row.shareURL = "https://fixture.invalid/f/synthetic-published"
        row.unbrandedShareURL = "https://fixture.invalid/u/synthetic-published"
        row.publishedRenderID = UUID(); return row
    }
    static func fresh() async throws -> AppModel {
        let parent = URL(fileURLWithPath: CommandLine.arguments[1])
        let path = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        FileStore.documents = path
        AuthStore.shared.userID = source.uuidString
        WorkspaceContext.selectedOrgID = nil; WorkspaceContext.ownerSelections = [:]
        Config.useLiveBackend = false
        AuthStore.shared.pendingExists = true; AuthStore.shared.pendingReadFails = false
        let model = AppModel(); await model.load(); return model
    }
    /// Invoke the real extracted AppModel callback in AuthStore's source-first
    /// order. Assigning destination before this callback masks guest custody bugs.
    static func activate(_ model: AppModel, as userID: UUID) {
        let previous = AuthStore.shared.userID
        AuthStore.shared.onAccountChanged?(userID)
        check(AuthStore.shared.userID == previous && model.identityOwnerUserID == userID,
              "Actual outgoing callback finishes while the source subject is still active")
        AuthStore.shared.userID = userID.uuidString
    }
    static func rejects(_ label: String, _ action: () throws -> Void) {
        do { try action(); check(false, label) } catch { check(true, label) }
    }
    static func main() async {
        do { try await run() } catch { check(false, "unexpected fixture error: \(error)") }
        if CommandLine.arguments.contains("--force-failure") { check(false, "deliberate negative control") }
        if failures > 0 { print("FAIL: \(failures)/\(assertions) local binding assertions"); exit(1) }
        print("PASS: \(assertions) local binding assertions; actual extracted AppModel metadata/PersistentStore; no live API or media")
    }
    static func run() async throws {
        let model = try await fresh(), original = listing(), transfer = pending()
        model.listings = [original]
        check(model.prepareLocalAdoption(transfer), "snapshot persists before session replacement")
        let before = PersistentStore.load()
        check(before.adoptionBindings?.matches(transfer) == true && before.listings[0].serverID == original.serverID, "exact source/op/destination with original IDs durable together")
        activate(model, as: destination)
        check(model.listings[0].serverID == nil && model.listings[0].shareURL == nil, "account switch clears active foreign IDs")
        let cleared = PersistentStore.load()
        check(cleared.listings[0].serverID == nil && cleared.adoptionBindings?.entries[0].serverID == original.serverID, "clearing preserves original journal")
        do { _ = try await model.ensureServerListing(model.listings[0]); check(false, "pending link must not create duplicate") }
        catch { check(model.api.calls == 0, "pending link refuses duplicate create with zero transport calls") }
        model.listings[0].address = "Locally edited while transfer pending"
        let restarted = AppModel(); await restarted.load()
        check(restarted.adoptionBindings?.matches(transfer) == true, "real load restores pending journal")
        check(restarted.confirmLocalAdoption(transfer, orgID: org), "exact receipt restores original link")
        let linked = restarted.listings.first { $0.id == original.id }!
        check(linked.serverID == original.serverID && linked.shareURL == original.shareURL, "same server listing and public link restored")
        check(linked.unbrandedShareURL == original.unbrandedShareURL && linked.publishedRenderID == original.publishedRenderID, "unbranded/render IDs preserved")
        check(linked.address == "Locally edited while transfer pending" && linked.needsServerSync == true, "local edits survive and must PATCH")
        let cloud = try await restarted.ensureServerListing(linked)
        check(cloud == original.serverID && restarted.api.calls == 0, "actual ensure reuses restored ID; no duplicate create")
        let committed = PersistentStore.load()
        check(committed.adoptionBindings?.confirmedOrgID == org && committed.listings[0].serverID == original.serverID, "confirmation and IDs commit in one state file")
        restarted.listings[0].shareURL = "https://fixture.invalid/f/newer-publication"
        check(restarted.confirmLocalAdoption(transfer, orgID: org), "same receipt replay succeeds")
        check(!restarted.confirmLocalAdoption(pending(), orgID: org), "confirmed journal still rejects another operation")
        check(restarted.listings[0].shareURL?.hasSuffix("newer-publication") == true, "replay cannot roll back later publication")
        check(!restarted.confirmLocalAdoption(transfer, orgID: foreign), "different org receipt cannot rebind")
        activate(restarted, as: foreign)
        check(!restarted.confirmLocalAdoption(transfer, orgID: org), "late callback for former destination refused")
        check(restarted.listings[0].serverID == nil, "arbitrary account switch never inherits restored IDs")
        AuthStore.shared.userID = destination.uuidString
        let returned = AppModel(); await returned.load()
        check(returned.confirmLocalAdoption(transfer, orgID: org), "retained receipt can rebind after switch-away and relaunch")
        check(returned.listings.first { $0.id == original.id }?.shareURL?.hasSuffix("newer-publication") == true,
              "failed Keychain clear/switch/retry preserves latest confirmed publication")
        activate(returned, as: foreign)
        AuthStore.shared.pendingReadFails = true
        do { _ = try await returned.ensureServerListing(returned.listings[0]); check(false, "locked recovery storage is not absence") }
        catch { check(returned.api.calls == 0, "Keychain read failure preserves pending fence") }
        AuthStore.shared.pendingReadFails = false; AuthStore.shared.pendingExists = false
        _ = try await returned.ensureServerListing(returned.listings[0])
        check(returned.api.calls == 1, "completed cleared transfer does not gate unrelated future account")

        for invalid in [pending(source: foreign), pending(destination: foreign), pending()] {
            let value = try AdoptionLocalBindings.capture(transfer, listings: [original])
            rejects("different binding refused") { _ = try value.restoring([original], pending: invalid, currentUserID: destination, orgID: org) }
        }
        let journal = try AdoptionLocalBindings.capture(transfer, listings: [original])
        rejects("wrong active destination") { _ = try journal.restoring([original], pending: transfer, currentUserID: foreign, orgID: org) }
        rejects("signed-out callback") { _ = try journal.restoring([original], pending: transfer, currentUserID: nil, orgID: org) }
        var conflict = original; conflict.serverID = UUID()
        rejects("never replace a newly assigned foreign ID") { _ = try journal.restoring([conflict], pending: transfer, currentUserID: destination, orgID: org) }
        check(try journal.restoring([], pending: transfer, currentUserID: destination, orgID: org).isEmpty, "deleted local listing never resurrected")
        var sample = original; sample.isSample = true
        check(try AdoptionLocalBindings.capture(transfer, listings: [sample]).entries.isEmpty, "sample references excluded")
        rejects("duplicate local IDs fail closed") { _ = try AdoptionLocalBindings.capture(transfer, listings: [original, original]) }
        var second = original; second.id = UUID()
        rejects("duplicate server IDs fail closed") { _ = try AdoptionLocalBindings.capture(transfer, listings: [original, second]) }
        var huge = original; huge.shareURL = String(repeating: "x", count: 1_048_576)
        rejects("oversized metadata refused, never truncated") { _ = try AdoptionLocalBindings.capture(transfer, listings: [huge]) }
        check(journal.blocks(original.id, currentUserID: destination), "destination waits for receipt")
        check(journal.blocks(original.id, currentUserID: foreign), "foreign account cannot duplicate pending listing")
        check(!journal.blocks(original.id, currentUserID: source), "failed optional sign-in leaves source usable")
        check(!journal.blocks(UUID(), currentUserID: destination), "unrelated new listings remain usable")

        let offline = try await fresh()
        var offlineListing = listing(); offlineListing.serverID = nil
        offline.listings = [offlineListing]
        let offlineTransfer = pending()
        let offlineDraft = ProductionPlanCache.Draft(plan: .starter(listingID: offlineListing.id), revision: 0, dirty: true)
        try ProductionPlanCache.save(offlineDraft, owner: source.uuidString.lowercased(), listingID: offlineListing.id)
        defer { ProductionPlanCache.remove(listingID: offlineListing.id) }
        ProductionVideoLibrary.shared.busy = true
        check(!offline.prepareLocalAdoption(offlineTransfer), "in-flight picker blocks session replacement before its import is indexed")
        ProductionVideoLibrary.shared.busy = false
        check(offline.prepareLocalAdoption(offlineTransfer), "offline-only property enters receipt-bound production transfer")
        WorkspaceContext.selectedOrgID = org
        WorkspaceContext.ownerSelections[source] = org
        activate(offline, as: destination)
        check(offline.listings[0].cloudSyncOwnerID == source, "Actual callback retains source custody before verified adoption")
        do { _ = try await offline.ensureServerListing(offline.listings[0]); check(false, "offline pending transfer must not create a duplicate") }
        catch { check(offline.api.calls == 0, "offline draft waits for verified receipt before cloud create") }
        check(offline.confirmLocalAdoption(offlineTransfer, orgID: org), "verified receipt also recovers offline-only production draft")
        let transferredDraft = try ProductionPlanCache.load(owner: destination.uuidString.lowercased(), listingID: offlineListing.id)
        check(transferredDraft?.plan == offlineDraft.plan && transferredDraft?.adoptedOperationID == offlineTransfer.operationID,
              "actual AppModel confirm calls production transfer before clearing recovery")
        check(offline.adoptionBindings?.productionTransferred == true, "local metadata commits production transfer completion")
        Config.useLiveBackend = true
        check(offline.listings[0].cloudSyncOwnerID == destination && offline.listings[0].cloudDraftOrgID == org,
              "Verified adoption transfers unsynced draft custody and receipt library")
        check(offline.isInSelectedWorkspace(offline.listings[0]), "Adopting account sees the offline draft after confirmation")
        check(CloudDraftCreation.canAutoSync(offline.listings[0], userID: destination), "Adopting account can auto-sync the same offline draft")
        let adoptedReload = AppModel(); await adoptedReload.load()
        check(adoptedReload.listings.contains { $0.id == offlineListing.id && adoptedReload.isInSelectedWorkspace($0) },
              "Adopted offline draft remains in the visible/exportable workspace after disk reload")
        Config.useLiveBackend = false

        let scoped = try await fresh()
        var ownedOffline = offlineListing; ownedOffline.id = UUID(); ownedOffline.cloudSyncOwnerID = source
        var otherOffline = offlineListing; otherOffline.id = UUID(); otherOffline.cloudSyncOwnerID = foreign
        var otherCloud = original; otherCloud.id = UUID(); otherCloud.cloudSyncOwnerID = foreign
        var excludedSample = original; excludedSample.id = UUID(); excludedSample.isSample = true; excludedSample.serverID = nil
        scoped.listings = [ownedOffline, otherOffline, otherCloud, excludedSample]
        let scopedTransfer = pending()
        check(scoped.prepareLocalAdoption(scopedTransfer), "Owned guest journal coexists with preserved other-account drafts")
        check(scoped.adoptionBindings?.productionLocalIDs == [ownedOffline.id] && scoped.adoptionBindings?.entries.isEmpty == true,
              "Capture records only source-custody IDs, excluding foreign server rows and samples")
        var unjournaled = ownedOffline; unjournaled.id = UUID()
        scoped.listings.append(unjournaled)
        // Emulate a prior-version journal that included a foreign ID. It must
        // not authorize metadata/cache transfer for that foreign local row.
        scoped.adoptionBindings?.productionLocalIDs?.append(otherOffline.id)
        scoped.adoptionBindings?.entries.append(.init(localID: otherCloud.id, serverID: otherCloud.serverID!,
            shareSlug: otherCloud.shareSlug, shareURL: otherCloud.shareURL, unbrandedShareURL: otherCloud.unbrandedShareURL,
            publishedRenderID: otherCloud.publishedRenderID))
        WorkspaceContext.selectedOrgID = org; WorkspaceContext.ownerSelections[source] = org
        activate(scoped, as: destination)
        check(scoped.confirmLocalAdoption(scopedTransfer, orgID: org), "Verified receipt scopes an old overbroad journal to current custody")
        let scopedByID = Dictionary(uniqueKeysWithValues: scoped.listings.map { ($0.id, $0) })
        check(scopedByID[ownedOffline.id]?.cloudSyncOwnerID == destination, "Exact source journal draft transfers")
        check(scopedByID[otherOffline.id]?.cloudSyncOwnerID == foreign && scopedByID[otherCloud.id]?.cloudSyncOwnerID == foreign,
              "Foreign offline/server-backed custody never transfers even if an older journal names it")
        check(scopedByID[otherCloud.id]?.serverID == nil, "Older foreign journal cannot restore another account's server identity")
        check(scopedByID[unjournaled.id]?.cloudSyncOwnerID == source, "A draft not in the prepared journal is never silently adopted")
        check(scopedByID[excludedSample.id]?.cloudSyncOwnerID == nil, "Sample listing is never account-owned through adoption")
        Config.useLiveBackend = true
        check(scoped.isInSelectedWorkspace(scopedByID[ownedOffline.id]!) && !scoped.isInSelectedWorkspace(scopedByID[otherOffline.id]!) &&
              !scoped.isInSelectedWorkspace(scopedByID[unjournaled.id]!), "Adopting library includes exact guest draft and excludes unrelated custody")
        Config.useLiveBackend = false

        _ = try await fresh()
        var oldOffline = ownedOffline; oldOffline.id = UUID(); oldOffline.cloudDraftOrgID = org
        var completed = try AdoptionLocalBindings.capture(pending(), listings: [oldOffline])
        completed.confirmedOrgID = org; completed.appliedToCurrentState = true
        completed.productionTransferred = true; completed.ownedIdentityTransferred = true
        check(PersistentStore.save(listings: [oldOffline], assets: [:], tours: [:], renders: [:],
              identityOwnerUserID: destination, adoptionBindings: completed), "Completed build55-style adoption fixture is durable")
        AuthStore.shared.userID = destination.uuidString
        WorkspaceContext.selectedOrgID = org; Config.useLiveBackend = true
        let repaired = AppModel(); await repaired.load()
        check(repaired.listings[0].cloudSyncOwnerID == destination && repaired.isInSelectedWorkspace(repaired.listings[0]),
              "Loading a previously completed receipt repairs the build55 hidden offline draft")
        check(PersistentStore.load().listings[0].cloudSyncOwnerID == destination && CloudDraftCreation.canAutoSync(repaired.listings[0], userID: destination),
              "Completed-receipt custody repair persists and enables automatic sync")
        let laterDestinationOrg = UUID()
        repaired.listings[0].cloudDraftOrgID = laterDestinationOrg
        check(repaired.restoreAdoptedProductionLibrary() && repaired.listings[0].cloudDraftOrgID == laterDestinationOrg,
              "Completed receipt never rolls back an already-adopted draft's later library metadata")
        repaired.listings[0].cloudSyncOwnerID = source
        let repairState = FileStore.documents.appendingPathComponent("rendprop-state.json")
        let repairPrior = FileStore.documents.appendingPathComponent("synthetic-completed-before-failure.json")
        let repairBefore = try Data(contentsOf: repairState)
        try FileManager.default.moveItem(at: repairState, to: repairPrior)
        try FileManager.default.createDirectory(at: repairState, withIntermediateDirectories: false)
        check(!repaired.restoreAdoptedProductionLibrary() && repaired.listings[0].cloudSyncOwnerID == source,
              "Completed-receipt atomic write failure rolls local custody back")
        try FileManager.default.removeItem(at: repairState)
        try FileManager.default.moveItem(at: repairPrior, to: repairState)
        check(try Data(contentsOf: repairState) == repairBefore, "Completed-receipt repair failure preserves prior durable bytes")
        check(repaired.restoreAdoptedProductionLibrary() && repaired.listings[0].cloudSyncOwnerID == destination,
              "Same completed receipt repairs successfully after storage recovers")
        Config.useLiveBackend = false

        let legacyIDs = try await fresh(); legacyIDs.listings = [original, oldOffline]
        let legacyTransfer = pending()
        check(legacyIDs.prepareLocalAdoption(legacyTransfer), "Older journal fallback fixture prepares")
        legacyIDs.adoptionBindings?.productionLocalIDs = nil
        WorkspaceContext.selectedOrgID = org; WorkspaceContext.ownerSelections[source] = org
        activate(legacyIDs, as: destination)
        check(legacyIDs.confirmLocalAdoption(legacyTransfer, orgID: org), "Journal without production IDs restores only its recorded server entries")
        check(legacyIDs.listings.first { $0.id == original.id }?.cloudSyncOwnerID == destination &&
              legacyIDs.listings.first { $0.id == oldOffline.id }?.cloudSyncOwnerID == source,
              "Legacy entries fallback never invents authorization for unrecorded offline IDs")

        // Sign-out cancels a handoff that never received a receipt. Its copy
        // promises those tours stay on this phone and can be published again.
        let cancelled = try await fresh()
        var cancelledDraft = offlineListing; cancelledDraft.id = UUID()
        var cancelledPublished = original; cancelledPublished.id = UUID()
        var retainedOther = offlineListing; retainedOther.id = UUID(); retainedOther.cloudSyncOwnerID = foreign
        cancelled.listings = [cancelledDraft, cancelledPublished, retainedOther]
        let cancelledTransfer = pending()
        check(cancelled.prepareLocalAdoption(cancelledTransfer), "Cancelled handoff fixture prepares")
        // A build-55 journal captured every non-sample row, including a retained foreign draft.
        cancelled.adoptionBindings?.productionLocalIDs?.append(retainedOther.id)
        WorkspaceContext.selectedOrgID = org; WorkspaceContext.ownerSelections[source] = org
        activate(cancelled, as: destination)
        var cancelledByID = Dictionary(uniqueKeysWithValues: cancelled.listings.map { ($0.id, $0) })
        check(cancelledByID[cancelledDraft.id]?.cloudSyncOwnerID == source && cancelledByID[cancelledDraft.id]?.cloudDraftOrgID == org &&
              cancelledByID[cancelledPublished.id]?.cloudDetachedServerID == original.serverID,
              "Pending handoff keeps source custody and the detached server identity")
        cancelled.discardLocalAdoption(operationID: UUID())
        check(cancelled.adoptionBindings?.matches(cancelledTransfer) == true &&
              cancelled.listings.first { $0.id == cancelledDraft.id }?.cloudSyncOwnerID == source,
              "A different operation never releases a pending journal or its custody")
        cancelled.discardLocalAdoption(operationID: cancelledTransfer.operationID)
        cancelledByID = Dictionary(uniqueKeysWithValues: cancelled.listings.map { ($0.id, $0) })
        check(cancelled.adoptionBindings == nil && PersistentStore.load().adoptionBindings == nil, "Explicit discard drops the unconfirmed journal durably")
        check(cancelledByID[cancelledDraft.id]?.cloudSyncOwnerID == nil && cancelledByID[cancelledDraft.id]?.cloudDraftOrgID == nil,
              "Cancelled handoff releases the guest's own offline draft to this phone")
        check(cancelledByID[cancelledPublished.id]?.cloudSyncOwnerID == nil && cancelledByID[cancelledPublished.id]?.serverID == nil &&
              cancelledByID[cancelledPublished.id]?.cloudDetachedServerID == original.serverID,
              "Released published row keeps its detached identity: republish is explicit, never a silent duplicate")
        check(cancelledByID[retainedOther.id]?.cloudSyncOwnerID == foreign, "Another account's retained custody survives a cancelled guest handoff")
        WorkspaceContext.selectedOrgID = UUID()
        Config.useLiveBackend = true
        check(cancelled.isInSelectedWorkspace(cancelledByID[cancelledDraft.id]!) && CloudDraftCreation.canAutoSync(cancelledByID[cancelledDraft.id]!, userID: destination),
              "Next sign-in sees and can publish the released draft")
        check(cancelled.isInSelectedWorkspace(cancelledByID[cancelledPublished.id]!) && !CloudDraftCreation.canAutoSync(cancelledByID[cancelledPublished.id]!, userID: destination),
              "Released published row is visible but never auto-created under the next account")
        check(!cancelled.isInSelectedWorkspace(cancelledByID[retainedOther.id]!), "Cancelled handoff does not expose another account's draft")
        let cancelledReload = AppModel(); await cancelledReload.load()
        check(cancelledReload.listings.contains { $0.id == cancelledDraft.id && $0.cloudSyncOwnerID == nil && cancelledReload.isInSelectedWorkspace($0) },
              "Released custody survives disk reload")
        Config.useLiveBackend = false
        WorkspaceContext.selectedOrgID = nil

        // A guest whose session died for good (revoked refresh token, a
        // definitive 4xx) never journals a handoff: nobody can become that
        // identity again, so its never-synced work belongs to this phone.
        // The next Apple sign-in receives it instead of hiding it forever.
        let orphaned = try await fresh()
        var orphanDraft = offlineListing; orphanDraft.id = UUID()
        var orphanPublished = original; orphanPublished.id = UUID(); orphanPublished.cloudSyncOwnerID = source
        var orphanForeign = offlineListing; orphanForeign.id = UUID(); orphanForeign.cloudSyncOwnerID = foreign
        orphaned.listings = [orphanDraft, orphanPublished, orphanForeign]
        AuthStore.rememberedSessionWasAnonymous = true
        WorkspaceContext.selectedOrgID = org; WorkspaceContext.ownerSelections[source] = org
        activate(orphaned, as: destination)
        AuthStore.rememberedSessionWasAnonymous = false
        let orphanByID = Dictionary(uniqueKeysWithValues: orphaned.listings.map { ($0.id, $0) })
        check(orphanByID[orphanDraft.id]?.cloudSyncOwnerID == nil && orphanByID[orphanDraft.id]?.cloudDraftOrgID == nil,
              "Dead guest's offline draft is released to this phone when no handoff is pending")
        check(orphanByID[orphanPublished.id]?.cloudSyncOwnerID == nil && orphanByID[orphanPublished.id]?.serverID == nil &&
              orphanByID[orphanPublished.id]?.cloudDetachedServerID == original.serverID,
              "Dead guest's published row is released but keeps its detached identity")
        check(orphanByID[orphanForeign.id]?.cloudSyncOwnerID == foreign, "Another account's custody survives a dead-guest release")
        check(PersistentStore.load().listings.first { $0.id == orphanDraft.id }?.cloudSyncOwnerID == nil, "Dead-guest release is durable")
        Config.useLiveBackend = true
        WorkspaceContext.selectedOrgID = UUID()
        check(orphaned.isInSelectedWorkspace(orphanByID[orphanDraft.id]!) && CloudDraftCreation.canAutoSync(orphanByID[orphanDraft.id]!, userID: destination),
              "Next sign-in sees and auto-publishes the dead guest's draft")
        check(orphaned.isInSelectedWorkspace(orphanByID[orphanPublished.id]!) && !CloudDraftCreation.canAutoSync(orphanByID[orphanPublished.id]!, userID: destination),
              "Dead guest's published row is visible but never auto-created under the next account")
        check(!orphaned.isInSelectedWorkspace(orphanByID[orphanForeign.id]!), "Dead-guest release does not expose another account's draft")
        Config.useLiveBackend = false
        WorkspaceContext.selectedOrgID = nil
        // Controls: an identified (or unknown) outgoing session keeps its
        // fence, and so does an anonymous one with a handoff still pending.
        let fenced = try await fresh()
        var fencedDraft = offlineListing; fencedDraft.id = UUID()
        fenced.listings = [fencedDraft]
        AuthStore.rememberedSessionWasAnonymous = false
        WorkspaceContext.selectedOrgID = org; WorkspaceContext.ownerSelections[source] = org
        activate(fenced, as: destination)
        check(fenced.listings[0].cloudSyncOwnerID == source && fenced.listings[0].cloudDraftOrgID == org,
              "An identified or unknown outgoing session keeps custody of its offline draft")
        let journaled = try await fresh()
        var journaledDraft = offlineListing; journaledDraft.id = UUID()
        journaled.listings = [journaledDraft]
        check(journaled.prepareLocalAdoption(pending()), "Anonymous handoff fixture prepares")
        AuthStore.rememberedSessionWasAnonymous = true
        WorkspaceContext.selectedOrgID = org; WorkspaceContext.ownerSelections[source] = org
        activate(journaled, as: destination)
        AuthStore.rememberedSessionWasAnonymous = false
        check(journaled.listings[0].cloudSyncOwnerID == source && journaled.listings[0].cloudDraftOrgID == org,
              "A pending handoff fences the anonymous source's draft until its receipt")
        WorkspaceContext.selectedOrgID = nil

        let busy = try await fresh(); busy.listings = [original]
        for kind in 0..<3 {
            busy.syncInFlight = kind == 0 ? [original.id] : []
            busy.publishInFlight = kind == 1 ? [original.id] : []
            busy.serverCreationInFlight = kind == 2 ? [original.id] : []
            check(!busy.prepareLocalAdoption(transfer), "source in-flight metadata operation refuses snapshot")
        }
        busy.syncInFlight = []; busy.publishInFlight = []; busy.serverCreationInFlight = []
        check(busy.prepareLocalAdoption(transfer), "settled source can prepare")
        check(!busy.prepareLocalAdoption(pending(destination: foreign)), "different operation cannot evict pending journal")
        busy.listings[0].shareSlug = "updated-before-activation"
        check(busy.prepareLocalAdoption(transfer), "same source retry can refresh still-active metadata")
        check(busy.adoptionBindings?.entries[0].shareSlug == "updated-before-activation", "latest source link preserved")
        activate(busy, as: destination)
        let path = FileStore.documents, snapshot = try Data(contentsOf: path.appendingPathComponent("rendprop-state.json"))
        // Keep the valid media parent so the new profile preflight reaches the
        // actual PersistentStore failure. Occupy its exact JSON path with a
        // directory; a missing parent would now fail at an earlier guard.
        let stateFile = path.appendingPathComponent("rendprop-state.json")
        let savedState = path.appendingPathComponent("synthetic-state-before-failure.json")
        try FileManager.default.moveItem(at:stateFile,to:savedState)
        try FileManager.default.createDirectory(at:stateFile,withIntermediateDirectories:false)
        check(!busy.confirmLocalAdoption(transfer, orgID: org), "real atomic file-write failure refuses completion")
        check(busy.adoptionBindings?.confirmedOrgID == nil && busy.listings[0].serverID == nil, "write failure rolls back in-memory marker and IDs")
        try FileManager.default.removeItem(at:stateFile)
        try FileManager.default.moveItem(at:savedState,to:stateFile)
        check(try Data(contentsOf: path.appendingPathComponent("rendprop-state.json")) == snapshot, "write failure leaves previous durable bytes unchanged")
        check(busy.confirmLocalAdoption(transfer, orgID: org), "same receipt can retry after write failure")

        let racing = try await fresh(); var draft = original; draft.serverID = nil; racing.listings = [draft]
        var finishCreate: CheckedContinuation<Void, Never>?
        racing.api.onCreate = { await withCheckedContinuation { finishCreate = $0 } }
        let firstCreate = Task { try await racing.ensureServerListing(draft) }
        for _ in 0..<100 where finishCreate == nil { await Task.yield() }
        check(finishCreate != nil, "actual create reached asynchronous boundary")
        check(!racing.prepareLocalAdoption(transfer), "real in-flight create prevents snapshot-before-reply loss")
        do { _ = try await racing.ensureServerListing(draft); check(false, "double create must be fenced") }
        catch { check(racing.api.calls == 1, "double create makes only one transport call") }
        finishCreate?.resume(); _ = try await firstCreate.value
        check(racing.prepareLocalAdoption(transfer), "finished create participates in source snapshot")
        check(racing.adoptionBindings?.entries.first?.serverID == racing.listings[0].serverID, "actual returned server identity captured")

        let pinned = try await fresh()
        var localA = original; localA.serverID = nil; localA.cloudDraftOrgID = org
        pinned.listings = [localA]
        _ = try await pinned.ensureServerListing(localA)
        check(pinned.listings[0].serverOrgID == org, "Actual create binds returned row to the saved intended workspace")
        check(PersistentStore.load().listings[0].cloudDraftOrgID == org, "Workspace intent survives process-style disk reload")
        var savedWrongWorkspace = false
        do {
            _ = try await CloudDraftCreation.ensure(snapshot: localA, identity: .init(userID: source.uuidString, revision: 0),
                create: { value in var wrong = value; wrong.serverID = UUID(); wrong.serverOrgID = UUID(); return wrong },
                current: { localA }, activeIdentity: { .init(userID: source.uuidString, revision: 0) },
                save: { _ in savedWrongWorkspace = true }, deleteRemoved: { _ in })
            check(false, "Wrong-workspace create must fail")
        } catch { check(!savedWrongWorkspace, "Different-org create response cannot rebind saved local draft") }
        let switchDrafts = try await fresh()
        var unassigned = original; unassigned.serverID = nil; unassigned.serverOrgID = nil; unassigned.cloudDraftOrgID = nil
        switchDrafts.listings = [unassigned]
        WorkspaceContext.selectedOrgID = org
        check(switchDrafts.prepareWorkspaceSwitch(), "Workspace switch persists older draft ownership before changing selection")
        check(PersistentStore.load().listings[0].cloudDraftOrgID == org, "Older draft remains pinned to outgoing workspace across restart")
        ProductionVideoLibrary.shared.busy = true
        check(!switchDrafts.prepareWorkspaceSwitch(), "Workspace switch waits for active media import")
        ProductionVideoLibrary.shared.busy = false
        switchDrafts.clientContactSyncInFlight = [original.id]
        check(!switchDrafts.prepareWorkspaceSwitch(), "Workspace switch waits for a client-contact save or photo upload")
        switchDrafts.clientContactSyncInFlight = []
        check(switchDrafts.prepareWorkspaceSwitch(), "Workspace switch resumes after client-contact work settles")
        WorkspaceContext.selectedOrgID = nil

        let legacyDraftModel = try await fresh()
        var legacyDraft = original
        legacyDraft.serverID = nil; legacyDraft.serverOrgID = nil
        legacyDraft.cloudDraftOrgID = nil; legacyDraft.cloudSyncOwnerID = nil
        legacyDraftModel.listings = [legacyDraft]
        WorkspaceContext.selectedOrgID = org
        AuthStore.shared.userID = source.uuidString
        activate(legacyDraftModel, as: foreign)
        let preservedDraft = legacyDraftModel.listings[0]
        check(preservedDraft.cloudSyncOwnerID == source && preservedDraft.cloudDraftOrgID == org,
              "Unstamped guest draft retains outgoing account and library custody")
        check(preservedDraft.id == legacyDraft.id && preservedDraft.address == legacyDraft.address,
              "Custody fencing preserves the original local draft")
        AuthStore.shared.userID = foreign.uuidString
        Config.useLiveBackend = true
        check(!legacyDraftModel.isInSelectedWorkspace(preservedDraft), "Other account cannot see outgoing guest draft")
        check(!CloudDraftCreation.canAutoSync(preservedDraft, userID: foreign), "Other account cannot auto-create outgoing guest draft")
        let retainedDraft = PersistentStore.load().listings[0]
        check(retainedDraft.cloudSyncOwnerID == source && retainedDraft.cloudDraftOrgID == org,
              "Outgoing guest custody survives actual disk reload")
        AuthStore.shared.userID = source.uuidString
        check(legacyDraftModel.isInSelectedWorkspace(preservedDraft) && CloudDraftCreation.canAutoSync(preservedDraft, userID: source),
              "Returning owner recovers the same preserved draft")
        Config.useLiveBackend = false
        WorkspaceContext.selectedOrgID = nil

        _ = try await fresh()
        var restoredLegacyDraft = legacyDraft; restoredLegacyDraft.id = UUID()
        check(PersistentStore.save(listings: [restoredLegacyDraft], assets: [:], tours: [:], renders: [:], identityOwnerUserID: source),
              "Saved outgoing-owner draft exists before another account launches")
        let destinationOrg = UUID()
        WorkspaceContext.ownerSelections[source] = org
        WorkspaceContext.ownerSelections[foreign] = destinationOrg
        WorkspaceContext.selectedOrgID = destinationOrg
        AuthStore.shared.userID = foreign.uuidString
        let switchedLoad = AppModel(); await switchedLoad.load()
        check(switchedLoad.listings[0].cloudSyncOwnerID == source && switchedLoad.listings[0].cloudDraftOrgID == org,
              "Actual load reads prior owner's library instead of stamping current account's selection")
        check(PersistentStore.load().listings[0].cloudDraftOrgID == org,
              "Previous-owner library custody survives the cross-account reload write")

        let empty = try await fresh()
        empty.listings = []
        check(empty.prepareLocalAdoption(pending()), "empty workspace can journal without inventing listings")
        check(PersistentStore.load().adoptionBindings != nil, "empty valid journal is not misclassified as corrupt library")
        let freshPath = FileStore.documents.appendingPathComponent("rendprop-state.json")
        var bad = try JSONSerialization.jsonObject(with: Data(contentsOf: freshPath)) as! [String: Any]
        bad["listings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([original]))
        bad["adoptionBindings"] = ["version": 999]
        let badBytes = try JSONSerialization.data(withJSONObject: bad)
        try badBytes.write(to: freshPath, options: .atomic)
        let salvage = PersistentStore.load()
        check(salvage.adoptionBindingsUnreadable && salvage.listings.count == 1, "malformed journal reports error while salvaging listing")
        check(!PersistentStore.save(listings: salvage.listings, assets: [:], tours: [:], renders: [:]), "autosave cannot silently drop malformed recovery")
        check(try Data(contentsOf: freshPath) == badBytes, "malformed recovery bytes preserved exactly")
        let blocked = AppModel(); await blocked.load()
        check(blocked.adoptionBindingsUnreadable && AuthStore.shared.errors > 0, "real load reports recovery storage problem")
        do { _ = try await blocked.ensureServerListing(original); check(false, "unreadable recovery must block cloud mutation") }
        catch { check(blocked.api.calls == 0, "unreadable recovery does not call cloud create") }

        let legacy = try await fresh(); legacy.listings = [original]
        let legacyFile = FileStore.documents.appendingPathComponent("rendprop-state.json")
        var old = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyFile)) as! [String: Any]
        old.removeValue(forKey: "adoptionBindings"); old.removeValue(forKey: "identityOwnerUserID")
        try JSONSerialization.data(withJSONObject: old).write(to: legacyFile, options: .atomic)
        let oldLoaded = PersistentStore.load()
        check(oldLoaded.listings.count == 1 && !oldLoaded.adoptionBindingsUnreadable, "legacy absent metadata remains readable without invented transfer")
        let honestEmpty = try await fresh(); honestEmpty.listings = []
        let honestFile = FileStore.documents.appendingPathComponent("rendprop-state.json")
        let honestReload = AppModel(); await honestReload.load()
        check(!honestReload.adoptionBindingsUnreadable && FileManager.default.fileExists(atPath: honestFile.path),
              "honestly empty owned metadata remains a valid durable snapshot on relaunch")
        for failure in ["invalid-json", "directory-instead-of-state", "all-library-entries-malformed"] {
            _ = try await fresh()
            let file = FileStore.documents.appendingPathComponent("rendprop-state.json")
            // Preserve every fixture: move the valid synthetic snapshot aside,
            // then make only this owned fixture unreadable/undecodable.
            try FileManager.default.moveItem(at: file, to: FileStore.documents.appendingPathComponent("prior-valid.json"))
            if failure == "invalid-json" { try Data("not-json".utf8).write(to: file, options: .atomic) }
            else if failure == "all-library-entries-malformed" {
                try JSONSerialization.data(withJSONObject: ["listings": ["unreadable-entry"], "unknown-padding": String(repeating: "x", count: 200)]).write(to: file, options: .atomic)
            }
            else { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }
            let damaged = AppModel(); await damaged.load()
            check(damaged.adoptionBindingsUnreadable, "\(failure) is not an honestly empty library")
            check(!damaged.prepareLocalAdoption(pending()), "\(failure) refuses optional source-session replacement")
            let again = AppModel(); await again.load()
            check(again.adoptionBindingsUnreadable && !again.prepareLocalAdoption(pending()), "\(failure) remains fail-closed after another process-style load")
        }
        let journalWithUnreadableRows = try await fresh(); journalWithUnreadableRows.listings = [original]
        check(journalWithUnreadableRows.prepareLocalAdoption(transfer), "valid journal fixture prepared")
        let journalFile = FileStore.documents.appendingPathComponent("rendprop-state.json")
        var malformedRows = try JSONSerialization.jsonObject(with: Data(contentsOf: journalFile)) as! [String: Any]
        malformedRows["listings"] = ["unreadable-listing"]
        try JSONSerialization.data(withJSONObject: malformedRows).write(to: journalFile, options: .atomic)
        AuthStore.shared.userID = destination.uuidString
        let unknownLibrary = AppModel(); await unknownLibrary.load()
        check(unknownLibrary.adoptionBindingsUnreadable && !unknownLibrary.confirmLocalAdoption(transfer, orgID: org),
              "valid journal cannot turn an unreadable library into successful empty rebind")
    }
}
