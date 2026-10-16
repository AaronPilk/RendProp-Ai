import Foundation
import CryptoKit

struct PhotoCloudSelectionProjection: Equatable, Sendable {
    let identity: PhotoCloudSelectionIdentity
    let snapshot: PhotoCloudSelectionSnapshot
    let versions: [PhotoCloudLocalVersion]
    let assetByVersion: [String: UUID]
    let selectedVersionIDs: Set<String>
    let coverVersionIDs: Set<String>
    let mutableFamilyIDs: Set<String>
    let pending: Bool

    func label(versionID: String) -> String {
        guard !pending else { return "Checking saved photo choice" }
        guard let version = versions.first(where: { $0.id == versionID }),
              mutableFamilyIDs.contains(version.familyID) else { return "Check listing selection" }
        if selectedVersionIDs.contains(versionID) { return "Selected for listing" }
        if versions.contains(where: { $0.familyID == version.familyID && selectedVersionIDs.contains($0.id) }) {
            return "Another version on listing"
        }
        return "Not selected for listing"
    }

    /// Missing selected metadata, unknown history and cross-family/byte aliases
    /// never become authority to subtract a partial family footprint.
    static func resolve(identity: PhotoCloudSelectionIdentity, snapshot: PhotoCloudSelectionSnapshot,
                        versions: [PhotoCloudLocalVersion], pending: Bool) throws -> Self {
        try snapshot.validate(identity: identity)
        guard Set(versions.map(\.id)).count == versions.count, versions.count <= 2000 else {
            throw PhotoCloudSelectionFailure.unmapped
        }
        var mapping: [String: UUID] = [:], occupied: [UUID: String] = [:]
        var complete = versions.allSatisfy(\.historyComplete)
        for version in versions {
            try PhotoCloudSelectionTarget(assetID: version.knownAssetID ?? UUID(), sha256: version.sha256, bytes: version.bytes).validate()
            let aliases = versions.filter { $0.sha256 == version.sha256 && $0.bytes == version.bytes }
            if aliases.count != 1 { complete = false; continue }
            let matches = snapshot.galleryAssets.filter { $0.sha256 == version.sha256 && $0.bytes == version.bytes }
            guard matches.count <= 1 else { complete = false; continue }
            if let match = matches.first {
                guard version.knownAssetID == match.assetID else { complete = false; continue }
            }
            if let id = version.knownAssetID {
                if occupied[id] != nil { complete = false; continue }
                occupied[id] = version.id; mapping[version.id] = id
            }
        }
        let selected = Set(snapshot.effectiveAssetIDs)
        if !selected.isSubset(of: Set(snapshot.galleryAssets.map(\.assetID))) || !selected.isSubset(of: Set(mapping.values)) {
            complete = false
        }
        let chosen = Set(mapping.filter { selected.contains($0.value) }.map(\.key))
        let covers = Set(mapping.filter { entry in
            snapshot.galleryAssets.contains { $0.assetID == entry.value && $0.storageKey == snapshot.mainPhotoKey }
        }.map(\.key))
        return Self(identity: identity, snapshot: snapshot, versions: versions, assetByVersion: mapping,
            selectedVersionIDs: complete && !pending ? chosen : [], coverVersionIDs: complete && !pending ? covers : [],
            mutableFamilyIDs: complete && !pending ? Set(versions.map(\.familyID)) : [], pending: pending)
    }
}

/// Serializes explicit family choices. Refresh/relaunch recover by GET only.
/// The immutable receipt establishes acceptance; its accompanying CURRENT state
/// wins over that receipt's historical result and over local editing history.
@MainActor final class PhotoCloudSelectionCoordinator {
    private let store: PhotoCloudSelectionJournal
    private var changing = Set<PhotoCloudSelectionIdentity>()
    private var readGeneration: [PhotoCloudSelectionIdentity: UUID] = [:]
    init(store: PhotoCloudSelectionJournal) { self.store = store }

    typealias Catalog = @MainActor () async throws -> [PhotoCloudLocalVersion]
    typealias IdentityCheck = @MainActor () throws -> Void
    typealias Prepare = @MainActor (PhotoCloudLocalVersion, UUID) async throws -> Void

    func refresh(identity: PhotoCloudSelectionIdentity, physicalOrgID: UUID?, api: any ListingPhotoCloudSelectionAPI,
                 catalog: Catalog, requireIdentity: IdentityCheck) async throws -> PhotoCloudSelectionProjection {
        guard !changing.contains(identity) else { throw PhotoCloudSelectionFailure.busy }
        let generation = UUID(); readGeneration[identity] = generation
        func check() throws {
            try Task.checkCancellation(); try requireIdentity()
            guard readGeneration[identity] == generation else { throw PhotoCloudSelectionFailure.identityChanged }
        }
        try check()
        let saved = try store.load(identity)
        if let saved, let physicalOrgID, saved.physicalOrgID != physicalOrgID { throw PhotoCloudSelectionFailure.identityChanged }
        let snapshot = try await api.photoCloudSelection(identity: identity, physicalOrgID: physicalOrgID, operationID: saved?.operationID)
        try check(); try snapshot.validate(identity: identity, physicalOrgID: physicalOrgID, operationID: saved?.operationID)
        if let saved, saved.physicalOrgID != snapshot.orgID { throw PhotoCloudSelectionFailure.identityChanged }
        let versions = try await catalog(); try check()
        var pending = saved != nil
        if let saved, let receipt = snapshot.operation {
            try validateReceipt(receipt, operation: saved)
            guard versions.contains(where: { $0.id == saved.versionID && $0.familyID == saved.familyID &&
                $0.imageFile == saved.imageFile && $0.sha256 == saved.sha256 && $0.bytes == saved.bytes }) else {
                throw PhotoCloudSelectionFailure.changed
            }
            try store.finish(saved, accepted: true); pending = false
        } else if let saved, let abandoned = snapshot.abandonedOperation {
            guard abandoned.operationID == saved.operationID, abandoned.request == saved.request else { throw PhotoCloudSelectionFailure.invalidReply }
            try store.finish(saved); pending = false
        } else if saved == nil, snapshot.operation != nil || snapshot.abandonedOperation != nil { throw PhotoCloudSelectionFailure.invalidReply }
        return try .resolve(identity: identity, snapshot: snapshot, versions: versions, pending: pending)
    }

    func change(identity: PhotoCloudSelectionIdentity, physicalOrgID: UUID?, versionID: String, selecting: Bool,
                followFamilyCover: Bool, reviewed: Bool, promoteCover: Bool = false, requireEmptyCover: Bool = false, api: any ListingPhotoCloudSelectionAPI,
                catalog: Catalog, prepare: Prepare, requireIdentity: IdentityCheck) async throws -> PhotoCloudSelectionProjection {
        guard !changing.contains(identity) else { throw PhotoCloudSelectionFailure.busy }
        guard try store.load(identity) == nil else { throw PhotoCloudSelectionFailure.pending }
        changing.insert(identity); readGeneration[identity] = UUID()
        defer { changing.remove(identity) }
        func check() throws { try Task.checkCancellation(); try requireIdentity() }
        try check()
        var snapshot = try await api.photoCloudSelection(identity: identity, physicalOrgID: physicalOrgID, operationID: nil)
        try check(); try snapshot.validate(identity: identity, physicalOrgID: physicalOrgID)
        var versions = try await catalog(); try check()
        let initialVersions = versions
        guard let version = versions.first(where: { $0.id == versionID }) else { throw PhotoCloudSelectionFailure.unmapped }
        var projection = try PhotoCloudSelectionProjection.resolve(identity: identity, snapshot: snapshot, versions: versions, pending: false)
        guard projection.mutableFamilyIDs.contains(version.familyID) else { throw PhotoCloudSelectionFailure.unmapped }
        if selecting, projection.assetByVersion[versionID] == nil {
            // This is the only preparation capability; refresh has no such closure.
            try await prepare(version, snapshot.orgID); try check()
            versions = try await catalog(); try check()
            guard versions.map({ ($0.id, $0.familyID, $0.imageFile, $0.sha256, $0.bytes, $0.historyComplete) }).elementsEqual(
                initialVersions.map({ ($0.id, $0.familyID, $0.imageFile, $0.sha256, $0.bytes, $0.historyComplete) }), by: { $0 == $1 }) else {
                throw PhotoCloudSelectionFailure.changed
            }
            // Gallery reservation may safely freeze legacy NULL. CAS is captured AFTER preparation.
            snapshot = try await api.photoCloudSelection(identity: identity, physicalOrgID: snapshot.orgID, operationID: nil)
            try check(); try snapshot.validate(identity: identity, physicalOrgID: physicalOrgID)
            projection = try .resolve(identity: identity, snapshot: snapshot, versions: versions, pending: false)
        }
        guard projection.mutableFamilyIDs.contains(version.familyID) else { throw PhotoCloudSelectionFailure.unmapped }
        if requireEmptyCover {
            guard promoteCover else { throw PhotoCloudSelectionFailure.invalidReply }
            guard snapshot.mainPhotoKey == nil else { throw PhotoCloudSelectionFailure.coverNoLongerEmpty }
        }
        let family = versions.filter { $0.familyID == version.familyID }
        let footprint = Array(Set(family.compactMap { projection.assetByVersion[$0.id] })).sorted { $0.uuidString < $1.uuidString }
        guard !footprint.isEmpty else { throw PhotoCloudSelectionFailure.unmapped }
        let target: PhotoCloudSelectionTarget?
        if selecting {
            guard let asset = projection.assetByVersion[versionID] else { throw PhotoCloudSelectionFailure.unmapped }
            target = .init(assetID: asset, sha256: version.sha256, bytes: version.bytes)
        } else { target = nil }
        let familyHasCover = family.contains { projection.coverVersionIDs.contains($0.id) }
        guard !followFamilyCover || (selecting && familyHasCover && !promoteCover) else { throw PhotoCloudSelectionFailure.coverUnavailable }
        if promoteCover {
            guard selecting, projection.selectedVersionIDs.contains(versionID),
                  family.filter({ projection.selectedVersionIDs.contains($0.id) }).count == 1 else { throw PhotoCloudSelectionFailure.changed }
        } else { guard !selecting || !familyHasCover || followFamilyCover else { throw PhotoCloudSelectionFailure.coverUnavailable } }
        let request = PhotoCloudSelectionRequest(familyAssetIDs: footprint, target: target, expectedSelection: snapshot.raw,
            followFamilyCover: followFamilyCover, reviewed: selecting && reviewed, promoteCover: promoteCover)
        let operation = PhotoCloudSelectionOperation(operationID: UUID(), identity: identity, physicalOrgID: snapshot.orgID,
            familyID: version.familyID, versionID: version.id, imageFile: version.imageFile,
            sha256: version.sha256, bytes: version.bytes, request: request)
        try check(); try store.begin(operation)
        let reply: PhotoCloudSelectionSnapshot
        do { reply = try await api.changePhotoCloudSelection(operation) }
        catch {
            // Only this exact code is a definitive pre-mutation CAS refusal.
            if let apiError = error as? APIError, apiError.status == 409 && apiError.code == "gallery_selection_changed" {
                try store.finish(operation)
            }
            throw error
        }
        try check(); try reply.validate(identity: identity, physicalOrgID: snapshot.orgID, operationID: operation.operationID)
        guard reply.ok == true, reply.replayed != nil, let receipt = reply.operation else { throw PhotoCloudSelectionFailure.invalidReply }
        try validateReceipt(receipt, operation: operation)
        let currentVersions = try await catalog(); try check()
        guard currentVersions == versions else { throw PhotoCloudSelectionFailure.changed }
        try store.finish(operation, accepted: true)
        return try .resolve(identity: identity, snapshot: reply, versions: currentVersions, pending: false)
    }

    func abandon(identity: PhotoCloudSelectionIdentity, physicalOrgID: UUID?, api: any ListingPhotoCloudSelectionAPI,
                 catalog: Catalog, requireIdentity: IdentityCheck) async throws -> PhotoCloudSelectionProjection {
        guard !changing.contains(identity) else { throw PhotoCloudSelectionFailure.busy }
        guard let saved = try store.load(identity) else { throw PhotoCloudSelectionFailure.changed }
        if let physicalOrgID, saved.physicalOrgID != physicalOrgID { throw PhotoCloudSelectionFailure.identityChanged }
        changing.insert(identity); readGeneration[identity] = UUID()
        defer { changing.remove(identity) }
        try requireIdentity(); try Task.checkCancellation()
        // A cached logical scope is not evidence that the physical owner has
        // stayed the same. Read its exact current mapping before a close POST.
        let current = try await api.photoCloudSelection(identity: identity, physicalOrgID: saved.physicalOrgID, operationID: saved.operationID)
        try requireIdentity(); try Task.checkCancellation()
        try current.validate(identity: identity, physicalOrgID: saved.physicalOrgID, operationID: saved.operationID)
        if let receipt = current.operation { try validateReceipt(receipt, operation: saved) }
        if let receipt = current.abandonedOperation {
            guard receipt.operationID == saved.operationID, receipt.request == saved.request else { throw PhotoCloudSelectionFailure.invalidReply }
        }
        let reply = try await api.abandonPhotoCloudSelection(saved)
        try requireIdentity(); try Task.checkCancellation()
        try reply.validate(identity: identity, physicalOrgID: saved.physicalOrgID, operationID: saved.operationID)
        guard physicalOrgID == nil || physicalOrgID == saved.physicalOrgID,
              reply.ok == true, reply.replayed != nil, let closed = reply.abandoned else { throw PhotoCloudSelectionFailure.invalidReply }
        if closed {
            guard reply.operationStatus == "abandoned", let receipt = reply.abandonedOperation,
                  receipt.operationID == saved.operationID, receipt.request == saved.request else { throw PhotoCloudSelectionFailure.invalidReply }
        } else {
            guard reply.operationStatus == "accepted", let receipt = reply.operation else { throw PhotoCloudSelectionFailure.invalidReply }
            try validateReceipt(receipt, operation: saved)
        }
        let versions = try await catalog(); try requireIdentity(); try Task.checkCancellation()
        try store.finish(saved, accepted: !closed)
        return try .resolve(identity: identity, snapshot: reply, versions: versions, pending: false)
    }

    private func validateReceipt(_ receipt: PhotoCloudSelectionSnapshot.Receipt, operation: PhotoCloudSelectionOperation) throws {
        guard receipt.operationID == operation.operationID, receipt.request == operation.request else {
            throw PhotoCloudSelectionFailure.invalidReply
        }
    }
}
