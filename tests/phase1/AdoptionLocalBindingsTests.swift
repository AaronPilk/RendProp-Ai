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
        AuthStore.shared.pendingExists = true; AuthStore.shared.pendingReadFails = false
        let model = AppModel(); await model.load(); return model
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
        AuthStore.shared.userID = destination.uuidString
        model.forgetServerIdentities(for: destination)
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
        AuthStore.shared.userID = foreign.uuidString
        restarted.forgetServerIdentities(for: foreign)
        check(!restarted.confirmLocalAdoption(transfer, orgID: org), "late callback for former destination refused")
        check(restarted.listings[0].serverID == nil, "arbitrary account switch never inherits restored IDs")
        AuthStore.shared.userID = destination.uuidString
        let returned = AppModel(); await returned.load()
        check(returned.confirmLocalAdoption(transfer, orgID: org), "retained receipt can rebind after switch-away and relaunch")
        check(returned.listings.first { $0.id == original.id }?.shareURL?.hasSuffix("newer-publication") == true,
              "failed Keychain clear/switch/retry preserves latest confirmed publication")
        AuthStore.shared.userID = foreign.uuidString; returned.forgetServerIdentities(for: foreign)
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
        AuthStore.shared.userID = destination.uuidString; busy.forgetServerIdentities(for: destination)
        let path = FileStore.documents, snapshot = try Data(contentsOf: path.appendingPathComponent("rendprop-state.json"))
        FileStore.documents = path.appendingPathComponent("does-not-exist")
        check(!busy.confirmLocalAdoption(transfer, orgID: org), "real atomic file-write failure refuses completion")
        check(busy.adoptionBindings?.confirmedOrgID == nil && busy.listings[0].serverID == nil, "write failure rolls back in-memory marker and IDs")
        FileStore.documents = path
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
