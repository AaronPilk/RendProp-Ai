import Foundation
import CryptoKit
import Darwin

/// Immutable measured local facts. A name identifies a local history entry;
/// only the measured bytes plus scoped gallery receipt identify a cloud asset.
struct PhotoCloudLocalVersion: Codable, Equatable, Sendable {
    let id: String
    let familyID: String
    let imageFile: String
    let sha256: String
    let bytes: Int64
    let knownAssetID: UUID?
    let historyComplete: Bool
    /// A browser delivery copy has its own bytes. The saved source above never
    /// changes identity or pretends to have the JPEG's digest.
    let browserDelivery: PhotoCloudBrowserDelivery?
    /// Old source assets are retained as separate immutable family members.
    let sourceAssetID: UUID?
    let requiresBrowserDelivery: Bool?
    init(id: String, familyID: String, imageFile: String, sha256: String, bytes: Int64,
         knownAssetID: UUID?, historyComplete: Bool, browserDelivery: PhotoCloudBrowserDelivery? = nil,
         sourceAssetID: UUID? = nil, requiresBrowserDelivery: Bool? = nil) {
        self.id = id; self.familyID = familyID; self.imageFile = imageFile
        self.sha256 = sha256; self.bytes = bytes; self.knownAssetID = knownAssetID
        self.historyComplete = historyComplete; self.browserDelivery = browserDelivery
        self.sourceAssetID = sourceAssetID; self.requiresBrowserDelivery = requiresBrowserDelivery
    }
    var deliverySHA256: String { browserDelivery?.sha256 ?? sha256 }
    var deliveryBytes: Int64 { browserDelivery?.bytes ?? bytes }
    var needsBrowserDelivery: Bool { requiresBrowserDelivery == true }
    var familyAssetIDs: [UUID] { Array(Set([knownAssetID, sourceAssetID].compactMap { $0 })) }
    var deliverySource: PhotoCloudDeliverySource? {
        browserDelivery == nil ? nil : .init(sha256: sha256, bytes: bytes)
    }
}

struct PhotoCloudDeliverySource: Codable, Equatable, Sendable {
    let sha256: String
    let bytes: Int64
}

struct PhotoCloudBrowserDelivery: Codable, Equatable, Sendable {
    let sha256: String
    let bytes: Int64
    let physicalOrgID: UUID
}

/// Server publication is separate from the editing workspace's local choice.
struct PhotoCloudSelectionIdentity: Codable, Equatable, Hashable, Sendable {
    let actorID: UUID
    let libraryOrgID: UUID
    let localListingID: UUID
    let serverListingID: UUID
}

struct PhotoCloudSelectionRaw: Codable, Equatable, Sendable {
    let galleryAssetIDs: [UUID]?
    let mainPhotoKey: String?
    enum CodingKeys: String, CodingKey { case galleryAssetIDs = "gallery_asset_ids", mainPhotoKey = "main_photo_key" }
    init(galleryAssetIDs: [UUID]?, mainPhotoKey: String?) {
        self.galleryAssetIDs = galleryAssetIDs; self.mainPhotoKey = mainPhotoKey
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.galleryAssetIDs), c.contains(.mainPhotoKey) else { throw PhotoCloudSelectionFailure.invalidReply }
        galleryAssetIDs = try c.decodeIfPresent([UUID].self, forKey: .galleryAssetIDs)
        mainPhotoKey = try c.decodeIfPresent(String.self, forKey: .mainPhotoKey)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let galleryAssetIDs { try c.encode(galleryAssetIDs, forKey: .galleryAssetIDs) } else { try c.encodeNil(forKey: .galleryAssetIDs) }
        if let mainPhotoKey { try c.encode(mainPhotoKey, forKey: .mainPhotoKey) } else { try c.encodeNil(forKey: .mainPhotoKey) }
    }
    func validate() throws {
        if let ids = galleryAssetIDs { guard ids.count <= 100, Set(ids).count == ids.count else { throw PhotoCloudSelectionFailure.invalidReply } }
        if let key = mainPhotoKey { guard !key.isEmpty, key.utf8.count <= 500 else { throw PhotoCloudSelectionFailure.invalidReply } }
    }
}

struct PhotoCloudSelectionTarget: Codable, Equatable, Sendable {
    let assetID: UUID
    let sha256: String
    let bytes: Int64
    enum CodingKeys: String, CodingKey { case assetID = "asset_id", sha256, bytes }
    func validate() throws {
        guard bytes > 0, bytes <= 128 * 1024 * 1024,
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw PhotoCloudSelectionFailure.invalidReply }
    }
}

struct PhotoCloudSelectionRequest: Codable, Equatable, Sendable {
    let familyAssetIDs: [UUID]
    let target: PhotoCloudSelectionTarget?
    let expectedSelection: PhotoCloudSelectionRaw
    let followFamilyCover: Bool
    let reviewed: Bool
    let promoteCover: Bool
    enum CodingKeys: String, CodingKey {
        case familyAssetIDs = "family_asset_ids", target, expectedSelection = "expected_selection"
        case followFamilyCover = "follow_family_cover", reviewed, promoteCover = "promote_cover"
    }
    init(familyAssetIDs: [UUID], target: PhotoCloudSelectionTarget?, expectedSelection: PhotoCloudSelectionRaw,
         followFamilyCover: Bool, reviewed: Bool, promoteCover: Bool = false) {
        self.familyAssetIDs = familyAssetIDs; self.target = target; self.expectedSelection = expectedSelection
        self.followFamilyCover = followFamilyCover; self.reviewed = reviewed; self.promoteCover = promoteCover
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.target) else { throw PhotoCloudSelectionFailure.invalidReply }
        familyAssetIDs = try c.decode([UUID].self, forKey: .familyAssetIDs)
        target = try c.decodeIfPresent(PhotoCloudSelectionTarget.self, forKey: .target)
        expectedSelection = try c.decode(PhotoCloudSelectionRaw.self, forKey: .expectedSelection)
        followFamilyCover = try c.decode(Bool.self, forKey: .followFamilyCover)
        reviewed = try c.decode(Bool.self, forKey: .reviewed)
        promoteCover = c.contains(.promoteCover) ? try c.decode(Bool.self, forKey: .promoteCover) : false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(familyAssetIDs, forKey: .familyAssetIDs)
        if let target { try c.encode(target, forKey: .target) } else { try c.encodeNil(forKey: .target) }
        try c.encode(expectedSelection, forKey: .expectedSelection)
        try c.encode(followFamilyCover, forKey: .followFamilyCover); try c.encode(reviewed, forKey: .reviewed)
        if promoteCover { try c.encode(true, forKey: .promoteCover) }
    }
    func validate() throws {
        try expectedSelection.validate()
        guard (1...100).contains(familyAssetIDs.count), Set(familyAssetIDs).count == familyAssetIDs.count else { throw PhotoCloudSelectionFailure.invalidReply }
        if let target { try target.validate(); guard familyAssetIDs.contains(target.assetID) else { throw PhotoCloudSelectionFailure.invalidReply } }
        else if followFamilyCover || reviewed || promoteCover { throw PhotoCloudSelectionFailure.invalidReply }
        if promoteCover && followFamilyCover { throw PhotoCloudSelectionFailure.invalidReply }
    }
    /// Preserve NULL as NULL, rather than silently changing legacy authority to [].
    func body(operationID: UUID) throws -> [String: Any] {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard var result = try JSONSerialization.jsonObject(with: encoder.encode(self)) as? [String: Any] else { throw PhotoCloudSelectionFailure.invalidReply }
        result["operation_id"] = operationID.uuidString.lowercased()
        return result
    }
}

struct PhotoCloudSelectionSnapshot: Codable, Equatable, Sendable {
    struct Asset: Codable, Equatable, Sendable {
        let assetID: UUID; let sha256: String; let bytes: Int64; let storageKey: String
        enum CodingKeys: String, CodingKey { case assetID = "asset_id", sha256, bytes, storageKey = "storage_key" }
    }
    struct Receipt: Codable, Equatable, Sendable {
        let operationID: UUID; let request: PhotoCloudSelectionRequest; let result: PhotoCloudSelectionRaw
        enum CodingKeys: String, CodingKey { case operationID = "operation_id", request, result }
    }
    struct AbandonedReceipt: Codable, Equatable, Sendable {
        let operationID: UUID; let request: PhotoCloudSelectionRequest
        enum CodingKeys: String, CodingKey { case operationID = "operation_id", request }
    }
    let schema: Int
    let actorID: UUID
    let orgID: UUID
    let libraryOrgID: UUID
    let listingID: UUID
    let galleryAssetIDs: [UUID]?
    let mainPhotoKey: String?
    let effectiveAssetIDs: [UUID]
    let galleryAssets: [Asset]
    let operation: Receipt?
    let operationStatus: String?
    let abandonedOperation: AbandonedReceipt?
    let abandoned: Bool?
    let ok: Bool?
    let replayed: Bool?
    enum CodingKeys: String, CodingKey {
        case schema, actorID = "actor_id", orgID = "org_id", libraryOrgID = "library_org_id", listingID = "listing_id"
        case galleryAssetIDs = "gallery_asset_ids", mainPhotoKey = "main_photo_key", effectiveAssetIDs = "effective_asset_ids"
        case galleryAssets = "gallery_assets", operation, ok, replayed, operationStatus = "operation_status"
        case abandonedOperation = "abandoned_operation", abandoned
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.galleryAssetIDs), c.contains(.mainPhotoKey), c.contains(.operation),
              c.contains(.operationStatus), c.contains(.abandonedOperation) else {
            throw PhotoCloudSelectionFailure.invalidReply
        }
        schema = try c.decode(Int.self, forKey: .schema)
        actorID = try c.decode(UUID.self, forKey: .actorID); orgID = try c.decode(UUID.self, forKey: .orgID)
        libraryOrgID = try c.decode(UUID.self, forKey: .libraryOrgID); listingID = try c.decode(UUID.self, forKey: .listingID)
        galleryAssetIDs = try c.decodeIfPresent([UUID].self, forKey: .galleryAssetIDs)
        mainPhotoKey = try c.decodeIfPresent(String.self, forKey: .mainPhotoKey)
        effectiveAssetIDs = try c.decode([UUID].self, forKey: .effectiveAssetIDs)
        galleryAssets = try c.decode([Asset].self, forKey: .galleryAssets)
        operation = try c.decodeIfPresent(Receipt.self, forKey: .operation)
        operationStatus = try c.decodeIfPresent(String.self, forKey: .operationStatus)
        abandonedOperation = try c.decodeIfPresent(AbandonedReceipt.self, forKey: .abandonedOperation)
        abandoned = try c.decodeIfPresent(Bool.self, forKey: .abandoned)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok); replayed = try c.decodeIfPresent(Bool.self, forKey: .replayed)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(actorID, forKey: .actorID); try c.encode(orgID, forKey: .orgID)
        try c.encode(libraryOrgID, forKey: .libraryOrgID); try c.encode(listingID, forKey: .listingID)
        if let galleryAssetIDs { try c.encode(galleryAssetIDs, forKey: .galleryAssetIDs) } else { try c.encodeNil(forKey: .galleryAssetIDs) }
        if let mainPhotoKey { try c.encode(mainPhotoKey, forKey: .mainPhotoKey) } else { try c.encodeNil(forKey: .mainPhotoKey) }
        try c.encode(effectiveAssetIDs, forKey: .effectiveAssetIDs); try c.encode(galleryAssets, forKey: .galleryAssets)
        if let operation { try c.encode(operation, forKey: .operation) } else { try c.encodeNil(forKey: .operation) }
        if let operationStatus { try c.encode(operationStatus, forKey: .operationStatus) } else { try c.encodeNil(forKey: .operationStatus) }
        if let abandonedOperation { try c.encode(abandonedOperation, forKey: .abandonedOperation) } else { try c.encodeNil(forKey: .abandonedOperation) }
        try c.encodeIfPresent(ok, forKey: .ok); try c.encodeIfPresent(replayed, forKey: .replayed); try c.encodeIfPresent(abandoned, forKey: .abandoned)
    }
    var raw: PhotoCloudSelectionRaw { .init(galleryAssetIDs: galleryAssetIDs, mainPhotoKey: mainPhotoKey) }
    func validate(identity: PhotoCloudSelectionIdentity, physicalOrgID: UUID? = nil, operationID: UUID? = nil) throws {
        guard schema == 1, actorID == identity.actorID, libraryOrgID == identity.libraryOrgID,
              listingID == identity.serverListingID, physicalOrgID == nil || physicalOrgID == orgID else { throw PhotoCloudSelectionFailure.identityChanged }
        try raw.validate()
        guard effectiveAssetIDs.count <= 100, Set(effectiveAssetIDs).count == effectiveAssetIDs.count,
              galleryAssetIDs == nil || effectiveAssetIDs.allSatisfy({ galleryAssetIDs!.contains($0) }),
              galleryAssets.count <= 100, Set(galleryAssets.map(\.assetID)).count == galleryAssets.count else { throw PhotoCloudSelectionFailure.invalidReply }
        let prefix = "renders/\(orgID.uuidString.lowercased())/\(listingID.uuidString.lowercased())/gallery-"
        for a in galleryAssets {
            try PhotoCloudSelectionTarget(assetID: a.assetID, sha256: a.sha256, bytes: a.bytes).validate()
            let suffix = String(a.storageKey.dropFirst(prefix.count))
            guard effectiveAssetIDs.contains(a.assetID), a.storageKey.hasPrefix(prefix), !suffix.isEmpty,
                  a.storageKey.utf8.count <= 500, !suffix.contains("/"), !suffix.contains("\\"),
                  !suffix.contains("%"), !suffix.contains("?"), !suffix.contains("#"),
                  !suffix.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw PhotoCloudSelectionFailure.invalidReply }
        }
        switch operationStatus {
        case "accepted": guard operation != nil, abandonedOperation == nil else { throw PhotoCloudSelectionFailure.invalidReply }
        case "abandoned": guard operation == nil, abandonedOperation != nil else { throw PhotoCloudSelectionFailure.invalidReply }
        case "not_found", nil: guard operation == nil, abandonedOperation == nil else { throw PhotoCloudSelectionFailure.invalidReply }
        default: throw PhotoCloudSelectionFailure.invalidReply
        }
        if operationID != nil, operationStatus == nil { throw PhotoCloudSelectionFailure.invalidReply }
        if let abandonedOperation {
            guard operationID == nil || abandonedOperation.operationID == operationID else { throw PhotoCloudSelectionFailure.invalidReply }
            try abandonedOperation.request.validate()
        }
        if let operation {
            guard operationID == nil || operation.operationID == operationID else { throw PhotoCloudSelectionFailure.invalidReply }
            try operation.request.validate(); try operation.result.validate()
            let request = operation.request
            if request.promoteCover {
                guard operation.result.galleryAssetIDs == request.expectedSelection.galleryAssetIDs,
                      let cover = operation.result.mainPhotoKey, cover.hasPrefix(prefix),
                      !cover.dropFirst(prefix.count).isEmpty,
                      !cover.dropFirst(prefix.count).contains(where: { "/\\%?#".contains($0) || $0.isNewline }),
                      !cover.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw PhotoCloudSelectionFailure.invalidReply }
                return
            }
            guard let ids = operation.result.galleryAssetIDs else { throw PhotoCloudSelectionFailure.invalidReply }
            let chosen = request.target?.assetID
            guard ids.filter({ request.familyAssetIDs.contains($0) }).count == (chosen == nil ? 0 : 1),
                  chosen == nil || ids.contains(chosen!) else { throw PhotoCloudSelectionFailure.invalidReply }
            if let expected = request.expectedSelection.galleryAssetIDs {
                var ordered: [UUID] = []; var inserted = false
                for id in expected {
                    if request.familyAssetIDs.contains(id) {
                        if let chosen, !inserted { ordered.append(chosen); inserted = true }
                    } else { ordered.append(id) }
                }
                if let chosen, !inserted { ordered.append(chosen) }
                guard ordered == ids else { throw PhotoCloudSelectionFailure.invalidReply }
            }
            if !request.followFamilyCover {
                guard chosen == nil ? (operation.result.mainPhotoKey == nil || operation.result.mainPhotoKey == request.expectedSelection.mainPhotoKey)
                    : operation.result.mainPhotoKey == request.expectedSelection.mainPhotoKey else { throw PhotoCloudSelectionFailure.invalidReply }
            }
        }
    }
}

struct PhotoCloudSelectionOperation: Codable, Equatable, Sendable {
    let operationID: UUID
    let identity: PhotoCloudSelectionIdentity
    let physicalOrgID: UUID
    let familyID: String
    let versionID: String
    let imageFile: String
    let sha256: String
    let bytes: Int64
    let request: PhotoCloudSelectionRequest
    let deliverySource: PhotoCloudDeliverySource?
    init(operationID: UUID, identity: PhotoCloudSelectionIdentity, physicalOrgID: UUID,
         familyID: String, versionID: String, imageFile: String, sha256: String, bytes: Int64,
         request: PhotoCloudSelectionRequest, deliverySource: PhotoCloudDeliverySource? = nil) {
        self.operationID = operationID; self.identity = identity; self.physicalOrgID = physicalOrgID
        self.familyID = familyID; self.versionID = versionID; self.imageFile = imageFile
        self.sha256 = sha256; self.bytes = bytes; self.request = request; self.deliverySource = deliverySource
    }
    var sourceSHA256: String { deliverySource?.sha256 ?? sha256 }
    var sourceBytes: Int64 { deliverySource?.bytes ?? bytes }
    func validate() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for id in [familyID, versionID, imageFile] {
            guard !id.isEmpty, id.utf8.count <= 240, id != ".", id != "..",
                  id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw PhotoCloudSelectionFailure.invalidReply }
        }
        try PhotoCloudSelectionTarget(assetID: request.target?.assetID ?? operationID, sha256: sha256, bytes: bytes).validate()
        if let source = deliverySource {
            try PhotoCloudSelectionTarget(assetID: operationID, sha256: source.sha256, bytes: source.bytes).validate()
            guard bytes <= 9_500_000 else { throw PhotoCloudSelectionFailure.invalidReply }
        }
        try request.validate()
        if let target = request.target { guard target.sha256 == sha256, target.bytes == bytes else { throw PhotoCloudSelectionFailure.invalidReply } }
    }
}

protocol ListingPhotoCloudSelectionAPI: Sendable {
    @MainActor func photoCloudSelection(identity: PhotoCloudSelectionIdentity, physicalOrgID: UUID?, operationID: UUID?) async throws -> PhotoCloudSelectionSnapshot
    @MainActor func changePhotoCloudSelection(_ operation: PhotoCloudSelectionOperation) async throws -> PhotoCloudSelectionSnapshot
    @MainActor func abandonPhotoCloudSelection(_ operation: PhotoCloudSelectionOperation) async throws -> PhotoCloudSelectionSnapshot
}

enum PhotoCloudSelectionFailure: Error, LocalizedError {
    case identityChanged, invalidReply, unmapped, pending, changed, coverUnavailable, coverNoLongerEmpty, busy
    var errorDescription: String? {
        switch self {
        case .identityChanged: return "This home's account or workspace changed. Refresh its listing selection."
        case .invalidReply: return "The listing selection could not be verified. Keep the saved request and refresh."
        case .unmapped: return "Some cloud photo versions aren't mapped on this phone. Refresh the cloud photos before changing this selection."
        case .pending: return "An earlier photo choice still needs its result checked. Refresh to check that saved request."
        case .changed: return "The listing photos changed elsewhere. Review the current selection before choosing again."
        case .coverUnavailable: return "This version is kept on your phone. Changing the cloud cover needs a separate confirmed action."
        case .coverNoLongerEmpty: return "The listing cover changed elsewhere. Its current cover will be kept."
        case .busy: return "Another photo choice is being checked for this home."
        }
    }
}

struct PhotoCloudInitialPublicationIntent: Codable, Equatable, Sendable {
    let identity: PhotoCloudSelectionIdentity
    let versions: [PhotoCloudLocalVersion]
    var completedVersionIDs: [String] = []
    let coverVersionID: String?
    let initialCoverWasEmpty: Bool
    var coverFinished: Bool
    var coverWasPreserved: Bool = false
    /// Only the first verified source on a still-unselected home may create
    /// this intent. Its marker survives an accepted selection with a lost
    /// reply, so a later Photos visit may finish the cover without guessing.
    var automaticFirstCover: Bool? = nil
    init(identity: PhotoCloudSelectionIdentity, versions: [PhotoCloudLocalVersion], coverVersionID: String? = nil,
         initialCoverWasEmpty: Bool = false, automaticFirstCover: Bool = false) {
        self.identity = identity; self.versions = versions; self.coverVersionID = coverVersionID
        self.initialCoverWasEmpty = initialCoverWasEmpty; self.coverFinished = coverVersionID == nil
        self.automaticFirstCover = automaticFirstCover ? true : nil
    }
    func validate() throws {
        guard versions.count <= 100, Set(versions.map(\.id)).count == versions.count,
              Set(versions.map(\.familyID)).count == versions.count,
              completedVersionIDs == Array(versions.prefix(completedVersionIDs.count).map(\.id)) else {
            throw PhotoCloudSelectionFailure.invalidReply
        }
        if let coverVersionID { guard versions.contains(where: { $0.id == coverVersionID }) else { throw PhotoCloudSelectionFailure.invalidReply } }
        if automaticFirstCover == true {
            guard versions.count == 1, coverVersionID == versions[0].id, initialCoverWasEmpty else {
                throw PhotoCloudSelectionFailure.invalidReply
            }
        }
        guard !coverWasPreserved || coverFinished, coverVersionID != nil || coverFinished else { throw PhotoCloudSelectionFailure.invalidReply }
        for v in versions {
            try PhotoCloudSelectionTarget(assetID: v.knownAssetID ?? identity.serverListingID, sha256: v.sha256, bytes: v.bytes).validate()
            guard v.historyComplete, [v.id,v.familyID,v.imageFile].allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 240 && $0 != "." && $0 != ".." &&
                $0.range(of: "^[A-Za-z0-9._-]+$",options:.regularExpression) != nil
            }) else { throw PhotoCloudSelectionFailure.unmapped }
        }
    }
}

/// One pending request per account/library/home, across all families and relaunches.
/// Unknown outcomes are only read back; this store never authorizes a PATCH replay.
final class PhotoCloudSelectionJournal: @unchecked Sendable {
    private struct Entry: Codable { let schema: Int; let operation: PhotoCloudSelectionOperation }
    private static let lock = NSLock()
    private let directory: URL
    init(directory: URL) { self.directory = directory.appendingPathComponent(".photo-cloud-selections", isDirectory: true) }
    private func url(_ identity: PhotoCloudSelectionIdentity) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let key = SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
    private func requireDirectory(create: Bool) throws {
        guard directory.isFileURL else { throw PhotoCloudSelectionFailure.invalidReply }
        if !FileManager.default.fileExists(atPath: directory.path) {
            guard create else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw PhotoCloudSelectionFailure.invalidReply }
    }
    private func synchronizeDirectory() throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw PhotoCloudSelectionFailure.invalidReply }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw PhotoCloudSelectionFailure.invalidReply }
    }
    private func read(_ identity: PhotoCloudSelectionIdentity) throws -> PhotoCloudSelectionOperation? {
        try requireDirectory(create: false)
        let path = try url(identity)
        let exists = FileManager.default.fileExists(atPath: path.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil
        guard exists else { return nil }
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= 64 * 1024,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw PhotoCloudSelectionFailure.invalidReply }
        let data = try Data(contentsOf: path)
        guard data.count == size, let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.schema == 1,
              entry.operation.identity == identity else { throw PhotoCloudSelectionFailure.invalidReply }
        try entry.operation.validate(); return entry.operation
    }
    func load(_ identity: PhotoCloudSelectionIdentity) throws -> PhotoCloudSelectionOperation? {
        Self.lock.lock(); defer { Self.lock.unlock() }; return try read(identity)
    }
    func begin(_ operation: PhotoCloudSelectionOperation) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }; try operation.validate()
        guard try read(operation.identity) == nil else { throw PhotoCloudSelectionFailure.pending }
        try requireDirectory(create: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Entry(schema: 1, operation: operation))
        guard data.count <= 64 * 1024 else { throw PhotoCloudSelectionFailure.invalidReply }
        let temp = directory.appendingPathComponent(".pending-\(UUID().uuidString).tmp")
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: attributes) else { throw PhotoCloudSelectionFailure.invalidReply }
        defer { try? FileManager.default.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp); defer { try? handle.close() }; try handle.synchronize()
        try FileManager.default.moveItem(at: temp, to: url(operation.identity))
        try synchronizeDirectory()
    }
    func finish(_ operation: PhotoCloudSelectionOperation, accepted: Bool = false) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let current = try read(operation.identity) else { return }
        guard current == operation else { throw PhotoCloudSelectionFailure.pending }
        if accepted, operation.request.target != nil, var intent = try readInitial(operation.identity),
           let captured = intent.versions.first(where: { $0.id == operation.versionID }),
           captured.familyID == operation.familyID, captured.imageFile == operation.imageFile,
           captured.sha256 == operation.sourceSHA256, captured.bytes == operation.sourceBytes {
            // Persist queue progress BEFORE retiring the accepted operation.
            // A crash can replay bookkeeping, never the network mutation.
            if operation.request.promoteCover, intent.coverVersionID == operation.versionID,
               intent.completedVersionIDs.count == intent.versions.count {
                intent.coverFinished = true; try writeInitial(intent)
            } else if !operation.request.promoteCover,
                      intent.versions.dropFirst(intent.completedVersionIDs.count).first?.id == operation.versionID {
                intent.completedVersionIDs.append(operation.versionID); try writeInitial(intent)
            }
        }
        try FileManager.default.removeItem(at: url(operation.identity))
        try synchronizeDirectory()
    }
    private func initialURL(_ identity: PhotoCloudSelectionIdentity) throws -> URL {
        try url(identity).deletingPathExtension().appendingPathExtension("initial.json")
    }
    private func readInitial(_ identity: PhotoCloudSelectionIdentity) throws -> PhotoCloudInitialPublicationIntent? {
        try requireDirectory(create: false)
        let file = try initialURL(identity)
        guard FileManager.default.fileExists(atPath: file.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath:file.path)) != nil else { return nil }
        let values = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        let attrs = try FileManager.default.attributesOfItem(atPath:file.path)
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size > 0, size <= 128*1024, (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw PhotoCloudSelectionFailure.invalidReply }
        let data = try Data(contentsOf:file)
        guard data.count == size else { throw PhotoCloudSelectionFailure.invalidReply }
        let intent = try JSONDecoder().decode(PhotoCloudInitialPublicationIntent.self,from:data)
        guard intent.identity == identity else { throw PhotoCloudSelectionFailure.invalidReply }
        try intent.validate(); return intent
    }
    private func writeInitial(_ intent: PhotoCloudInitialPublicationIntent) throws {
        try intent.validate(); try requireDirectory(create:true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(intent)
        guard data.count <= 128*1024 else { throw PhotoCloudSelectionFailure.invalidReply }
        let file = try initialURL(intent.identity)
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:file.path)
        #endif
        let handle = try FileHandle(forWritingTo:file); defer { try? handle.close() }; try handle.synchronize()
        try synchronizeDirectory()
    }
    func initialIntent(_ identity: PhotoCloudSelectionIdentity) throws -> PhotoCloudInitialPublicationIntent? {
        Self.lock.lock(); defer { Self.lock.unlock() }; return try readInitial(identity)
    }
    func beginInitial(_ intent: PhotoCloudInitialPublicationIntent) throws -> PhotoCloudInitialPublicationIntent {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let existing = try readInitial(intent.identity) { return existing }
        try writeInitial(intent); return intent
    }
    func confirmInitialCurrent(_ identity: PhotoCloudSelectionIdentity, version: PhotoCloudLocalVersion) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard var intent = try readInitial(identity), let next = intent.versions.dropFirst(intent.completedVersionIDs.count).first,
              next.id == version.id, next.familyID == version.familyID, next.imageFile == version.imageFile,
              next.sha256 == version.sha256, next.bytes == version.bytes else { throw PhotoCloudSelectionFailure.changed }
        intent.completedVersionIDs.append(next.id); try writeInitial(intent)
    }
    func confirmInitialCover(_ identity: PhotoCloudSelectionIdentity, version: PhotoCloudLocalVersion, preserved: Bool) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        // Effect alone can satisfy only a cover step that has NOT dispatched.
        guard try read(identity) == nil, var intent = try readInitial(identity),
              intent.completedVersionIDs.count == intent.versions.count,
              intent.coverVersionID == version.id,
              let captured = intent.versions.first(where: { $0.id == version.id }),
              captured.familyID == version.familyID, captured.imageFile == version.imageFile,
              captured.sha256 == version.sha256, captured.bytes == version.bytes else { throw PhotoCloudSelectionFailure.pending }
        intent.coverFinished = true; intent.coverWasPreserved = preserved; try writeInitial(intent)
    }
    func finishInitial(_ identity: PhotoCloudSelectionIdentity) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let intent = try readInitial(identity), intent.completedVersionIDs.count == intent.versions.count,
              intent.coverFinished else { throw PhotoCloudSelectionFailure.pending }
        try FileManager.default.removeItem(at: initialURL(identity))
        try synchronizeDirectory()
    }

    /// A newer manual gallery choice cancels only an undispatched automatic
    /// default. A pending network operation still needs its receipt checked.
    func discardAutomaticInitial(_ identity: PhotoCloudSelectionIdentity) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try read(identity) == nil else { throw PhotoCloudSelectionFailure.pending }
        guard try readInitial(identity)?.automaticFirstCover == true else { return }
        try FileManager.default.removeItem(at: initialURL(identity))
        try synchronizeDirectory()
    }

}
