import Foundation
import CryptoKit

/// This is called only with AppModel's verified adoption binding, never merely
/// because another account signed in. Each destination commits its marker with
/// its data, so a crash can retry without overwriting newer destination edits.
enum AdoptionProductionLibrary {
    struct Receipt: Codable, Equatable {
        let operationID: UUID
        let sourceUserID: UUID
        let destinationUserID: UUID
        let listingID: UUID
    }
    enum Failure: Error { case conflict, invalidLibrary }

    static func restore(_ binding: AdoptionLocalBindings, survivingIDs: Set<UUID>,
                        documents: URL, defaults: UserDefaults = .standard) throws {
        try binding.validate()
        guard binding.appliedToCurrentState, binding.confirmedOrgID != nil else { throw Failure.conflict }
        let ids = Set(binding.productionLocalIDs ?? binding.entries.map(\.localID)).intersection(survivingIDs)
        let source = binding.sourceUserID.uuidString.lowercased()
        let destination = binding.destinationUserID.uuidString.lowercased()
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let receipt = Receipt(operationID: binding.operationID, sourceUserID: binding.sourceUserID,
                                  destinationUserID: binding.destinationUserID, listingID: id)
            try copyClips(receipt, documents: documents)
            try ProductionPlanCache.adopt(sourceOwner: source, destinationOwner: destination,
                listingID: id, operationID: binding.operationID, defaults: defaults)
        }
    }

    static func directory(owner: String, listingID: UUID, documents: URL) -> URL {
        let digest = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        return documents.appendingPathComponent("ProductionVideos", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
            .appendingPathComponent(listingID.uuidString.lowercased(), isDirectory: true)
    }

    private static func checkDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.invalidLibrary }
    }

    private static func copyClips(_ receipt: Receipt, documents: URL) throws {
        let fm = FileManager.default
        let source = directory(owner: receipt.sourceUserID.uuidString.lowercased(), listingID: receipt.listingID, documents: documents)
        guard fm.fileExists(atPath: source.path) else { return }
        // Refuse redirected parents as well as media symlinks.
        try checkDirectory(source.deletingLastPathComponent().deletingLastPathComponent())
        try checkDirectory(source.deletingLastPathComponent())
        try checkDirectory(source)
        let destination = directory(owner: receipt.destinationUserID.uuidString.lowercased(), listingID: receipt.listingID, documents: documents)
        let receiptName = "adoption-receipt.json"
        if fm.fileExists(atPath: destination.path) {
            try checkDirectory(destination.deletingLastPathComponent())
            try checkDirectory(destination)
            let saved = try regularData(destination.appendingPathComponent(receiptName), maximum: 4096)
            guard try JSONDecoder().decode(Receipt.self, from: saved) == receipt else { throw Failure.conflict }
            return // A completed transfer never rolls back later clip edits.
        }
        let manifest = try regularData(source.appendingPathComponent("library.json"), maximum: 1_000_000)
        guard let entries = try JSONSerialization.jsonObject(with: manifest) as? [[String: Any]], entries.count <= 100 else {
            throw Failure.invalidLibrary
        }
        var filenames = Set<String>()
        for entry in entries {
            guard let id = (entry["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let filename = entry["filename"] as? String,
                  let bytes = entry["bytes"] as? NSNumber, bytes.int64Value > 0,
                  let duration = entry["duration"] as? NSNumber, duration.doubleValue.isFinite, duration.doubleValue > 0,
                  entry["assetID"] == nil, entry["uploaded"] as? Bool != true,
                  entry["uploadStarted"] as? Bool != true else { throw Failure.invalidLibrary }
            let ext = URL(fileURLWithPath: filename).pathExtension
            guard ["mp4", "mov", "m4v"].contains(ext), filename == id.uuidString.lowercased() + "." + ext,
                  filenames.insert(filename).inserted else { throw Failure.invalidLibrary }
            let values = try source.appendingPathComponent(filename).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == bytes.int64Value else { throw Failure.invalidLibrary }
        }
        // Nothing is removed from the source. APFS hard links avoid requiring a
        // second video-sized allocation; clips are immutable after import.
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try checkDirectory(parent)
        let staging = parent.appendingPathComponent(".adoption-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for filename in filenames {
            let from = source.appendingPathComponent(filename), to = staging.appendingPathComponent(filename)
            do { try fm.linkItem(at: from, to: to) }
            catch { try fm.copyItem(at: from, to: to) }
        }
        try manifest.write(to: staging.appendingPathComponent("library.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent(receiptName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var excluded = staging
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        try fm.moveItem(at: staging, to: destination) // Directory plus marker commit together.
    }

    private static func regularData(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count > 0, count < maximum else { throw Failure.invalidLibrary }
        return try Data(contentsOf: url)
    }
}

/// Account-owned profile data is distinct from workspace branding. Only the
/// verified adoption hook may call this; ordinary login/team selection cannot.
/// Guest receipts and pending PATCHes are archived, never rebound or submitted.
enum AdoptionOwnedIdentity {
    struct Card: Codable, Equatable {
        let type: String
        let fields: [String: String]
        let dirty: Bool
        let portraitSHA256: String?
        let destinationWasOccupied: Bool
    }
    struct PaidRequest: Codable, Equatable {
        let listingID: UUID
        let serverListingID: UUID?
        let sourceWorkspace: UUID?
        let sourceData: Data?
        let unreadable: Bool
    }
    struct Journal: Codable, Equatable {
        let operationID: UUID
        let source: UUID
        let destination: UUID
        let org: UUID
        let cards: [Card]
        let sourceReceipt: Data?
        let sourcePending: Data?
        let primaryType: String?
        let paidRequests: [PaidRequest]
        var completed: Bool
        var cardActivated: Bool
    }
    enum Failure: Error { case identity, invalid, storage }
    struct Review: Equatable, Identifiable {
        var id: UUID { operationID }
        let operationID: UUID
        let source: UUID
        let destination: UUID
        let org: UUID
        let type: String
        let fields: [String: String]
        let portraitSHA256: String?
        let journalSHA256: String
    }
    static let fields = ["name", "brokerage", "phone", "email", "website", "instagram", "linkedin", "tiktok"]
    static func prefix(_ owner: UUID) -> String { "personal.card.v1." + owner.uuidString.lowercased() + "." }
    static func key(_ binding: AdoptionLocalBindings) -> String { prefix(binding.destinationUserID) + "adoption." + binding.operationID.uuidString.lowercased() }
    static func portrait(_ owner: UUID, type: String, documents: URL) -> URL {
        let filename = type == "real_estate" ? "agent-headshot.jpg" : "agent-headshot-" + type + ".jpg"
        return documents.appendingPathComponent(prefix(owner) + filename)
    }
    static func fieldKey(_ owner: UUID, type: String, field: String) -> String {
        prefix(owner) + (type == "real_estate" ? "agent." : "agent." + type + ".") + field
    }
    static func requestKey(listingID: UUID, owner: UUID, org: UUID?) -> String {
        "reel.request.\(listingID).\(owner.uuidString.lowercased()).\(org?.uuidString ?? "local")"
    }
    static func requestFile(listingID: UUID, owner: UUID, org: UUID?, documents: URL) -> URL {
        let bytes = Data(requestKey(listingID: listingID, owner: owner, org: org).utf8)
        return documents.appendingPathComponent("reel-requests", isDirectory: true).appendingPathComponent(digest(bytes) + ".json")
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func regularData(_ url: URL, maximum: Int) throws -> Data {
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard value.isRegularFile == true, value.isSymbolicLink != true,
              let count = value.fileSize, count > 0, count <= maximum else { throw Failure.invalid }
        return try Data(contentsOf: url)
    }
    private static func absentFile(_ url: URL) -> Bool {
        // lstat-style attributes preserve broken symlinks as occupied. Only
        // actual ENOENT is absence; denied/protected/invalid paths block work.
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return false }
        catch {
            let failure = error as NSError
            let posix = failure.domain == NSPOSIXErrorDomain ? failure : failure.userInfo[NSUnderlyingErrorKey] as? NSError
            guard posix?.domain == NSPOSIXErrorDomain, posix?.code == 2 else { return false }
            var parent = url.deletingLastPathComponent()
            while parent.path != "/" {
                do {
                    let values = try FileManager.default.attributesOfItem(atPath: parent.path)
                    return values[.type] as? FileAttributeType == .typeDirectory
                } catch {
                    let failure = error as NSError
                    let posix = failure.domain == NSPOSIXErrorDomain ? failure : failure.userInfo[NSUnderlyingErrorKey] as? NSError
                    guard posix?.domain == NSPOSIXErrorDomain, posix?.code == 2 else { return false }
                    parent = parent.deletingLastPathComponent()
                }
            }
            return false
        }
    }
    static func pathIsOccupied(_ url: URL) -> Bool { !absentFile(url) }
    private static func checkedDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.invalid }
    }
    private static func saved(_ binding: AdoptionLocalBindings, defaults: UserDefaults) throws -> Journal? {
        guard defaults.object(forKey: key(binding)) != nil else { return nil }
        guard let data = defaults.data(forKey: key(binding)) else { throw Failure.invalid }
        guard data.count <= 300_000, let journal = try? JSONDecoder().decode(Journal.self, from: data),
              journal.operationID == binding.operationID, journal.source == binding.sourceUserID,
              journal.destination == binding.destinationUserID, journal.org == binding.confirmedOrgID,
              journal.cards.count <= SpaceType.allCases.count, Set(journal.cards.map(\.type)).count == journal.cards.count,
              journal.cards.allSatisfy({ card in SpaceType(rawValue: card.type) != nil
                  && Set(card.fields.keys).isSubset(of: Set(fields)) && card.fields.values.allSatisfy { $0.utf8.count <= 4096 }
                  && (card.portraitSHA256 == nil || card.portraitSHA256!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil) }),
              journal.primaryType == nil || SpaceType(rawValue: journal.primaryType!) != nil,
              journal.paidRequests.count <= 1000,
              Set(journal.paidRequests.map(\.listingID)).isSubset(of: Set(binding.productionLocalIDs ?? binding.entries.map(\.localID))),
              journal.paidRequests.allSatisfy({ request in
                  (request.sourceWorkspace == nil || request.sourceWorkspace == journal.org)
                      && request.serverListingID == binding.entries.first { $0.localID == request.listingID }?.serverID
              }) else { throw Failure.invalid }
        return journal
    }
    private static func save(_ journal: Journal, binding: AdoptionLocalBindings, defaults: UserDefaults) throws {
        let bytes = try JSONEncoder().encode(journal)
        guard bytes.count <= 300_000 else { throw Failure.invalid }
        defaults.set(bytes, forKey: key(binding))
        guard defaults.synchronize(), try saved(binding, defaults: defaults) == journal else { throw Failure.storage }
    }
    /// A current GET /me/card is required before installing local guest text.
    /// An explicit {} is an existing destination card, not an empty SQL slot.
    /// A copied guest acknowledgement may match; newer destination cloud edits
    /// cannot be overwritten merely because the adoption receipt was replayed.
    static func mayActivate(_ journal: Journal, destinationCard: [String: String]?, destinationType: String?, verified: Bool) -> Bool {
        guard verified else { return false }
        if destinationCard == nil { return true }
        guard let bytes = journal.sourceReceipt,
              let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              (json["user_id"] as? String).flatMap(UUID.init(uuidString:)) == journal.source,
              json["ok"] as? Bool == true,
              let sourceCard = json["public_card"] as? [String: String],
              sourceCard == destinationCard, json["space_type"] as? String == destinationType else { return false }
        return true
    }
    /// A verified guest request may have been recorded before selection loaded.
    /// While the destination is also unselected, keep its adopted-org marker
    /// blocking new generation instead of treating an owner-key change as none.
    /// This grants no access to another org and never submits/polls a provider.
    static func unselectedReviewFiles(owner: UUID, listingID: UUID, documents: URL,
                                      defaults: UserDefaults = .standard) throws -> [URL] {
        let journalPrefix = prefix(owner) + "adoption."
        var targets = Set<URL>()
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(journalPrefix) {
            if name.hasPrefix(journalPrefix + "reviewed.") {
                let parts = name.dropFirst((journalPrefix + "reviewed.").count).split(separator: ".")
                guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
                      SpaceType(rawValue: String(parts[1])) != nil,
                      defaults.object(forKey: name) as? Bool == true else { throw Failure.invalid }
                continue
            }
            guard let bytes = defaults.data(forKey: name), bytes.count <= 300_000,
                  let record = try? JSONDecoder().decode(Journal.self, from: bytes),
                  record.destination == owner, record.source != owner,
                  name == journalPrefix + record.operationID.uuidString.lowercased() else { throw Failure.invalid }
            guard record.paidRequests.contains(where: { $0.listingID == listingID && ($0.sourceWorkspace == nil || $0.sourceWorkspace == record.org) }) else { continue }
            let target = requestFile(listingID: listingID, owner: owner, org: record.org, documents: documents)
            if !absentFile(target) || defaults.object(forKey: requestKey(listingID: listingID, owner: owner, org: record.org)) != nil {
                targets.insert(target)
            }
        }
        return targets.sorted { $0.path < $1.path }
    }
    static func forgetUnselectedReviews(owner: UUID, listingID: UUID, documents: URL,
                                        defaults: UserDefaults = .standard) {
        guard let files = try? unselectedReviewFiles(owner: owner, listingID: listingID, documents: documents, defaults: defaults) else { return }
        let targets = Set(files)
        let journalPrefix = prefix(owner) + "adoption."
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(journalPrefix) {
            guard let data = defaults.data(forKey: name), data.count <= 300_000,
                  let journal = try? JSONDecoder().decode(Journal.self, from: data), journal.destination == owner else { continue }
            let file = requestFile(listingID: listingID, owner: owner, org: journal.org, documents: documents)
            guard targets.contains(file) else { continue }
            try? FileManager.default.removeItem(at: file)
            defaults.removeObject(forKey: requestKey(listingID: listingID, owner: owner, org: journal.org))
        }
    }
    static func reviews(owner: UUID, type: String, defaults: UserDefaults = .standard) -> [Review] {
        guard SpaceType(rawValue: type) != nil else { return [] }
        let journalPrefix = prefix(owner) + "adoption."
        return defaults.dictionaryRepresentation().keys.sorted().compactMap { name in
            guard name.hasPrefix(journalPrefix), let bytes = defaults.data(forKey: name), bytes.count <= 300_000,
                  let journal = try? JSONDecoder().decode(Journal.self, from: bytes), journal.completed,
                  journal.destination == owner, journal.source != owner,
                  name == journalPrefix + journal.operationID.uuidString.lowercased(),
                  !defaults.bool(forKey: prefix(owner) + "adoption.reviewed." + journal.operationID.uuidString.lowercased() + "." + type),
                  let card = journal.cards.first(where: { $0.type == type }),
                  Set(card.fields.keys).isSubset(of: Set(fields)), card.fields.values.allSatisfy({ $0.utf8.count <= 4096 }),
                  card.portraitSHA256 == nil || card.portraitSHA256!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
            return Review(operationID: journal.operationID, source: journal.source, destination: owner, org: journal.org,
                type: type, fields: card.fields, portraitSHA256: card.portraitSHA256, journalSHA256: digest(bytes))
        }
    }
    static func isCurrent(_ review: Review, owner: UUID, type: String, defaults: UserDefaults = .standard) -> Bool {
        owner == review.destination && type == review.type && reviews(owner: owner, type: type, defaults: defaults).contains(review)
    }
    static func reviewPortrait(_ review: Review, documents: URL) throws -> Data? {
        guard let expected = review.portraitSHA256 else { return nil }
        try checkedDirectory(documents)
        let data = try regularData(portrait(review.source, type: review.type, documents: documents), maximum: 1_048_576)
        guard digest(data) == expected else { throw Failure.invalid }
        return data
    }
    static func saveReviewedPortrait(_ review: Review, documents: URL) throws {
        guard let bytes = try reviewPortrait(review, documents: documents) else { return }
        let target = portrait(review.destination, type: review.type, documents: documents)
        if !absentFile(target) { _ = try regularData(target, maximum: 1_048_576) }
        try bytes.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard try regularData(target, maximum: 1_048_576) == bytes else { throw Failure.storage }
    }
    static func markReviewed(_ review: Review, owner: UUID, type: String, defaults: UserDefaults = .standard) throws {
        guard isCurrent(review, owner: owner, type: type, defaults: defaults) else { throw Failure.identity }
        let name = prefix(owner) + "adoption.reviewed." + review.operationID.uuidString.lowercased() + "." + type
        defaults.set(true, forKey: name)
        guard defaults.synchronize(), defaults.bool(forKey: name) else { throw Failure.storage }
    }
    static func restore(_ binding: AdoptionLocalBindings, activeOwner: UUID, survivingIDs: Set<UUID>,
                        documents: URL, verifiedDestinationCard: [String: String]? = nil,
                        verifiedDestinationType: String? = nil, destinationCardWasVerified: Bool = false,
                        defaults: UserDefaults = .standard) throws {
        try binding.validate()
        guard binding.appliedToCurrentState, let org = binding.confirmedOrgID,
              activeOwner == binding.destinationUserID else { throw Failure.identity }
        try checkedDirectory(documents)
        var journal: Journal
        if let existing = try saved(binding, defaults: defaults) {
            journal = existing
            if !journal.completed && !destinationCardWasVerified { throw Failure.storage }
        }
        else {
            let source = binding.sourceUserID, target = binding.destinationUserID
            let sourceReceipt = defaults.data(forKey: prefix(source) + "receipt")
            let sourcePending = defaults.data(forKey: prefix(source) + "pending")
            guard (sourceReceipt?.count ?? 0) <= 24_000, (sourcePending?.count ?? 0) <= 24_000 else { throw Failure.invalid }
            var cards: [Card] = []
            for type in SpaceType.allCases.map(\.rawValue) {
                var values: [String: String] = [:]
                for field in fields {
                    if let value = defaults.object(forKey: fieldKey(source, type: type, field: field)) {
                        guard let text = value as? String, text.utf8.count <= 4096 else { throw Failure.invalid }
                        values[field] = text
                    }
                }
                let photo = portrait(source, type: type, documents: documents)
                let photoHash = absentFile(photo) ? nil : try digest(regularData(photo, maximum: 1_048_576))
                if !values.isEmpty || photoHash != nil {
                    cards.append(Card(type: type, fields: values,
                        dirty: defaults.bool(forKey: prefix(source) + "dirty." + type) || sourcePending != nil,
                        portraitSHA256: photoHash,
                        destinationWasOccupied: fields.contains { defaults.object(forKey: fieldKey(target, type: type, field: $0)) != nil }
                            || !absentFile(portrait(target, type: type, documents: documents))))
                }
            }
            let ids = Set(binding.productionLocalIDs ?? binding.entries.map(\.localID)).intersection(survivingIDs)
            var paid: [PaidRequest] = []
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
              // Before workspace selection loads, the actual guest Reel Studio
              // records a local scope. Only this verified source + surviving
              // listing may carry that review blocker into its adopted org.
              for sourceWorkspace: UUID? in [org, nil] {
                let file = requestFile(listingID: id, owner: source, org: sourceWorkspace, documents: documents)
                let legacy = defaults.data(forKey: requestKey(listingID: id, owner: source, org: sourceWorkspace))
                let legacyIsOccupied = defaults.object(forKey: requestKey(listingID: id, owner: source, org: sourceWorkspace)) != nil
                if !absentFile(file) {
                    // An unreadable authoritative file never falls back to an
                    // older preference or permits a new paid generation.
                    let bytes: Data?
                    do { try checkedDirectory(file.deletingLastPathComponent()); bytes = try regularData(file, maximum: 24_000) }
                    catch { bytes = nil }
                    paid.append(PaidRequest(listingID: id, serverListingID: binding.entries.first { $0.localID == id }?.serverID,
                        sourceWorkspace: sourceWorkspace, sourceData: bytes, unreadable: bytes == nil))
                } else if legacyIsOccupied {
                    paid.append(PaidRequest(listingID: id, serverListingID: binding.entries.first { $0.localID == id }?.serverID,
                        sourceWorkspace: sourceWorkspace, sourceData: legacy.flatMap { $0.count <= 24_000 ? $0 : nil },
                        unreadable: legacy == nil || legacy!.count > 24_000))
                }
              }
            }
            journal = Journal(operationID: binding.operationID, source: source, destination: target, org: org,
                cards: cards, sourceReceipt: sourceReceipt, sourcePending: sourcePending,
                primaryType: defaults.string(forKey: prefix(source) + "brand.primaryType"), paidRequests: paid,
                completed: false, cardActivated: false)
            try save(journal, binding: binding, defaults: defaults)
        }
        if journal.completed { return } // Never revive an explicit clear/retired request.
        let dispositionAllows = binding.personalCardDisposition == "source_copied"
            || (binding.personalCardDisposition == "no_source_card" && verifiedDestinationCard == nil)
        let allowCard = dispositionAllows && mayActivate(journal, destinationCard: verifiedDestinationCard,
            destinationType: verifiedDestinationType, verified: destinationCardWasVerified)
        var activatedTypes = Set<String>()
        if allowCard {
            for card in journal.cards {
                let targetPhoto = portrait(journal.destination, type: card.type, documents: documents)
                // Existing destination identity wins as a whole; do not mix a
                // guest's phone/email with a named account's existing name.
                if card.destinationWasOccupied { continue }
                // A retry may follow an interrupted partial installation. Any
                // newer text or portrait makes the recipient's whole card win;
                // the guest archive remains available for deliberate review.
                let textStillMatches = fields.allSatisfy { field in
                    guard let value = defaults.object(forKey: fieldKey(journal.destination, type: card.type, field: field)) else { return true }
                    return value as? String == (card.fields[field] ?? "")
                }
                let portraitStillMatches = absentFile(targetPhoto) || card.portraitSHA256.flatMap { expected in
                    (try? regularData(targetPhoto, maximum: 1_048_576)).map { digest($0) == expected }
                } == true
                guard textStillMatches, portraitStillMatches else { continue }
                if let expected = card.portraitSHA256, absentFile(targetPhoto) {
                    let source = portrait(journal.source, type: card.type, documents: documents)
                    let bytes = try regularData(source, maximum: 1_048_576)
                    guard digest(bytes) == expected else { throw Failure.invalid }
                    try bytes.write(to: targetPhoto, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    guard try regularData(targetPhoto, maximum: 1_048_576) == bytes else { throw Failure.storage }
                }
                // A kill can interrupt preference installation. Replay fills
                // absent keys only; a newer typed value or explicit "" wins.
                for field in fields where defaults.object(forKey: fieldKey(journal.destination, type: card.type, field: field)) == nil {
                    defaults.set(card.fields[field] ?? "", forKey: fieldKey(journal.destination, type: card.type, field: field))
                }
                if card.dirty { defaults.set(true, forKey: prefix(journal.destination) + "dirty." + card.type) }
                activatedTypes.insert(card.type)
            }
            if let primary = journal.primaryType, activatedTypes.contains(primary),
               defaults.object(forKey: prefix(journal.destination) + "brand.primaryType") == nil {
                defaults.set(primary, forKey: prefix(journal.destination) + "brand.primaryType")
            }
            if !activatedTypes.isEmpty {
                defaults.set(true, forKey: prefix(journal.destination) + "migrated")
                defaults.set(defaults.integer(forKey: prefix(journal.destination) + "generation") + 1,
                    forKey: prefix(journal.destination) + "generation")
            }
        }
        for pending in journal.paidRequests where survivingIDs.contains(pending.listingID) {
            let target = requestFile(listingID: pending.listingID, owner: journal.destination, org: journal.org, documents: documents)
            let targetKey = requestKey(listingID: pending.listingID, owner: journal.destination, org: journal.org)
            if !absentFile(target) || defaults.object(forKey: targetKey) != nil { continue }
            var bytes = Data("unreadable adopted paid request; review required".utf8)
            if journal.paidRequests.filter({ $0.listingID == pending.listingID }).count == 1,
               !pending.unreadable, let source = pending.sourceData,
               var json = try? JSONSerialization.jsonObject(with: source) as? [String: Any],
               var context = json["context"] as? [String: Any],
               (context["listingID"] as? String).flatMap(UUID.init(uuidString:)) == pending.listingID,
               (context["owner"] as? String).flatMap(UUID.init(uuidString:)) == journal.source,
               (context["workspace"] as? String).flatMap(UUID.init(uuidString:)) == pending.sourceWorkspace,
               (context["serverListingID"] as? String).flatMap(UUID.init(uuidString:)) == pending.serverListingID {
                context["owner"] = journal.destination.uuidString.lowercased()
                context["workspace"] = journal.org.uuidString
                json["context"] = context
                // This is a safety marker, not invented provider permission.
                // Review/forget is explicit; no automatic paid POST or poll.
                json["submissionUnconfirmed"] = true
                bytes = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try checkedDirectory(target.deletingLastPathComponent())
            try bytes.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            guard try regularData(target, maximum: 24_000) == bytes else { throw Failure.storage }
        }
        guard defaults.synchronize() else { throw Failure.storage }
        journal.cardActivated = !activatedTypes.isEmpty
        journal.completed = true
        try save(journal, binding: binding, defaults: defaults)
    }
}
