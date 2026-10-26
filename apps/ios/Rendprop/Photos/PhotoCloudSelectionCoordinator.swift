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
    /// A selected original asset may still need a browser-readable delivery.
    /// This is separate from the user's saved-version selection.
    var browserReadyVersionIDs: Set<String> {
        guard !pending, !mutableFamilyIDs.isEmpty else { return [] }
        let selected = Set(snapshot.effectiveAssetIDs)
        return Set(versions.filter { version in
            guard mutableFamilyIDs.contains(version.familyID) else { return false }
            let family = Set(versions.filter { $0.familyID == version.familyID }.flatMap(\.familyAssetIDs))
            guard let asset = assetByVersion[version.id], selected.intersection(family) == [asset] else { return false }
            return !version.needsBrowserDelivery || version.browserDelivery != nil
        }.map(\.id))
    }

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
        var conflictingFamilies: Set<String> = []
        for version in versions {
            try PhotoCloudSelectionTarget(assetID: version.knownAssetID ?? UUID(), sha256: version.sha256, bytes: version.bytes).validate()
            if let delivery = version.browserDelivery {
                try PhotoCloudSelectionTarget(assetID: version.knownAssetID ?? UUID(), sha256: delivery.sha256, bytes: delivery.bytes).validate()
                guard delivery.bytes <= 9_500_000, delivery.physicalOrgID == snapshot.orgID else { throw PhotoCloudSelectionFailure.unmapped }
            }
            let aliases = versions.filter { $0.sha256 == version.sha256 && $0.bytes == version.bytes }
            let deliveryAliases = versions.filter { $0.deliverySHA256 == version.deliverySHA256 && $0.deliveryBytes == version.deliveryBytes }
            if aliases.count != 1 || deliveryAliases.count != 1 {
                conflictingFamilies.insert(version.familyID)
                continue
            }
            let matches = snapshot.galleryAssets.filter { $0.sha256 == version.deliverySHA256 && $0.bytes == version.deliveryBytes }
            guard matches.count <= 1 else { complete = false; continue }
            if let match = matches.first {
                guard version.knownAssetID == match.assetID else { complete = false; continue }
            }
            if let id = version.knownAssetID {
                if occupied[id] != nil { complete = false; continue }
                occupied[id] = version.id; mapping[version.id] = id
            }
            if let id = version.sourceAssetID {
                guard version.browserDelivery != nil, id != version.knownAssetID,
                      occupied[id] == nil else { complete = false; continue }
                if let present = snapshot.galleryAssets.first(where: { $0.assetID == id }),
                   present.sha256 != version.sha256 || present.bytes != version.bytes {
                    complete = false; continue
                }
                let matches = snapshot.galleryAssets.filter { $0.sha256 == version.sha256 && $0.bytes == version.bytes }
                guard matches.count <= 1, matches.first?.assetID == nil || matches.first?.assetID == id else {
                    complete = false; continue
                }
                occupied[id] = version.id
            }
        }
        // A duplicate unselected import cannot erase another family's confirmed
        // badge. Its own family remains non-mutable, including every known
        // asset claim that overlaps another version/family.
        let claims = Dictionary(grouping: versions.flatMap { version in
            version.familyAssetIDs.map { ($0, version.familyID) }
        }, by: { $0.0 })
        for claim in claims.values where claim.count > 1 {
            conflictingFamilies.formUnion(claim.map { $0.1 })
        }
        let conflictingAssets = Set(versions.filter { conflictingFamilies.contains($0.familyID) }.flatMap(\.familyAssetIDs))
        let selected = Set(snapshot.effectiveAssetIDs)
        if !selected.isDisjoint(with: conflictingAssets) { complete = false }
        if !selected.isSubset(of: Set(snapshot.galleryAssets.map(\.assetID))) || !selected.isSubset(of: Set(occupied.keys)) {
            complete = false
        }
        let mutable = complete && !pending ? Set(versions.map(\.familyID)).subtracting(conflictingFamilies) : []
        let eligibleVersions = Set(versions.filter { mutable.contains($0.familyID) }.map(\.id))
        let chosen = Set(occupied.filter { selected.contains($0.key) && eligibleVersions.contains($0.value) }.map(\.value))
        let covers = Set(occupied.filter { entry in
            eligibleVersions.contains(entry.value) && snapshot.galleryAssets.contains { $0.assetID == entry.key && $0.storageKey == snapshot.mainPhotoKey }
        }.map(\.value))
        return Self(identity: identity, snapshot: snapshot, versions: versions, assetByVersion: mapping,
            selectedVersionIDs: complete && !pending ? chosen : [], coverVersionIDs: complete && !pending ? covers : [],
            mutableFamilyIDs: mutable, pending: pending)
    }
}

/// Presentation and bounded batch policy for the existing exact-version mutator.
/// A tick always means a confirmed selection, never an in-flight intention.
enum PhotoGridListingSelection {
    struct Target: Equatable, Sendable {
        let id: String
        let familyID: String
        let imageFile: String
        let requiresReview: Bool
    }
    enum State: Equatable, Sendable {
        case unknown, pending, available, selected, selectedNeedsBrowserCopy, reviewRequired, saving
        var isSelected: Bool { self == .selected || self == .selectedNeedsBrowserCopy }
        var title: String {
            switch self {
            case .selected: return "On listing"
            case .selectedNeedsBrowserCopy: return "On listing · prepare copy"
            case .available: return "Use on listing"
            case .reviewRequired: return "Review to use"
            case .unknown: return "Check selection"
            case .pending: return "Check saved choice"
            case .saving: return "Saving…"
            }
        }
        var value: String {
            switch self {
            case .selected: return "Selected for listing"
            case .selectedNeedsBrowserCopy: return "Selected for listing. A browser-compatible copy needs preparation."
            case .available: return "Not selected for listing"
            case .reviewRequired: return "Review required before listing selection"
            case .unknown: return "Listing selection is not confirmed"
            case .pending: return "A saved listing choice needs confirmation"
            case .saving: return "Listing choice is being confirmed"
            }
        }
    }
    static func state(_ target: Target, cloud: Bool, projection: PhotoCloudSelectionProjection?, localSelected: Bool?, saving: Bool = false) -> State {
        if saving { return .saving }
        let selected: Bool
        if cloud {
            guard let projection else { return .unknown }
            if projection.pending { return .pending }
            guard projection.mutableFamilyIDs.contains(target.familyID) else { return .unknown }
            selected = projection.selectedVersionIDs.contains(target.id)
        } else {
            guard let known = localSelected else { return .unknown }
            selected = known
        }
        if selected, cloud, let projection,
           projection.versions.first(where: { $0.id == target.id })?.needsBrowserDelivery == true,
           !projection.browserReadyVersionIDs.contains(target.id) { return .selectedNeedsBrowserCopy }
        return selected ? .selected : target.requiresReview ? .reviewRequired : .available
    }
    /// Existing category ordering is newest-first within each source family.
    /// Keep one exact shown version; never replace an unreviewed one with a
    /// different, older version without the owner's choice.
    static func categoryTargets(_ ordered: [Target]) -> [Target] {
        var families: Set<String> = []
        return ordered.filter { families.insert($0.familyID).inserted }
    }
    struct Report: Equatable { var selected = 0; var unchanged = 0; var needsReview = 0 }
    @MainActor static func selectAll(_ targets: [Target], requireCurrent: () throws -> Void,
        state: (Target) throws -> State, select: (Target) async throws -> Void) async -> (Report, Error?) {
        var report = Report()
        do {
            for target in categoryTargets(targets) {
                try requireCurrent()
                switch try state(target) {
                case .selected: report.unchanged += 1
                case .reviewRequired: report.needsReview += 1
                case .available, .selectedNeedsBrowserCopy:
                    try await select(target)
                    try requireCurrent()
                    guard try state(target) == .selected else { throw PhotoCloudSelectionFailure.changed }
                    report.selected += 1
                case .unknown: throw PhotoCloudSelectionFailure.unmapped
                case .pending, .saving: throw PhotoCloudSelectionFailure.pending
                }
            }
            return (report, nil)
        } catch { return (report, error) }
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
    typealias ValidateTarget = @MainActor (PhotoCloudLocalVersion, UUID, String?) async throws -> Void

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
                $0.imageFile == saved.imageFile && $0.sha256 == saved.sourceSHA256 && $0.bytes == saved.sourceBytes &&
                $0.deliverySHA256 == saved.sha256 && $0.deliveryBytes == saved.bytes && $0.deliverySource == saved.deliverySource }) else {
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
                followFamilyCover: Bool, reviewed: Bool, promoteCover: Bool = false, requireEmptyCover: Bool = false, requireSelectedVersion: Bool = false, requireCurrentSelection: Bool = false, api: any ListingPhotoCloudSelectionAPI,
                catalog: Catalog, prepare: Prepare, validateTarget: ValidateTarget, requireIdentity: IdentityCheck) async throws -> PhotoCloudSelectionProjection {
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
        guard var version = versions.first(where: { $0.id == versionID }) else { throw PhotoCloudSelectionFailure.unmapped }
        var projection = try PhotoCloudSelectionProjection.resolve(identity: identity, snapshot: snapshot, versions: versions, pending: false)
        func checkCurrentSelection(_ current: PhotoCloudSelectionProjection) throws {
            guard !requireCurrentSelection || (selecting && current.selectedVersionIDs.contains(versionID) &&
                current.versions.filter({ $0.familyID == version.familyID && current.selectedVersionIDs.contains($0.id) }).count == 1) else {
                throw PhotoCloudSelectionFailure.changed
            }
        }
        try checkCurrentSelection(projection)
        guard projection.mutableFamilyIDs.contains(version.familyID) else { throw PhotoCloudSelectionFailure.unmapped }
        if selecting, projection.assetByVersion[versionID] == nil || (version.needsBrowserDelivery && version.browserDelivery == nil) {
            // This is the only preparation capability; refresh has no such closure.
            try await prepare(version, snapshot.orgID); try check()
            versions = try await catalog(); try check()
            guard versions.map({ ($0.id, $0.familyID, $0.imageFile, $0.sha256, $0.bytes, $0.historyComplete) }).elementsEqual(
                initialVersions.map({ ($0.id, $0.familyID, $0.imageFile, $0.sha256, $0.bytes, $0.historyComplete) }), by: { $0 == $1 }) else {
                throw PhotoCloudSelectionFailure.changed
            }
            guard let preparedVersion = versions.first(where: { $0.id == versionID }) else { throw PhotoCloudSelectionFailure.changed }
            version = preparedVersion
            // Gallery reservation may safely freeze legacy NULL. CAS is captured AFTER preparation.
            snapshot = try await api.photoCloudSelection(identity: identity, physicalOrgID: snapshot.orgID, operationID: nil)
            try check(); try snapshot.validate(identity: identity, physicalOrgID: physicalOrgID)
            projection = try .resolve(identity: identity, snapshot: snapshot, versions: versions, pending: false)
        }
        try checkCurrentSelection(projection)
        guard projection.mutableFamilyIDs.contains(version.familyID) else { throw PhotoCloudSelectionFailure.unmapped }
        if requireEmptyCover {
            guard promoteCover else { throw PhotoCloudSelectionFailure.invalidReply }
            guard snapshot.mainPhotoKey == nil else { throw PhotoCloudSelectionFailure.coverNoLongerEmpty }
        }
        if requireSelectedVersion {
            guard !selecting, projection.selectedVersionIDs.contains(versionID) else { throw PhotoCloudSelectionFailure.changed }
        }
        let family = versions.filter { $0.familyID == version.familyID }
        let footprint = Array(Set(family.flatMap(\.familyAssetIDs))).sorted { $0.uuidString < $1.uuidString }
        guard !footprint.isEmpty else { throw PhotoCloudSelectionFailure.unmapped }
        let target: PhotoCloudSelectionTarget?
        if selecting {
            guard let asset = projection.assetByVersion[versionID] else { throw PhotoCloudSelectionFailure.unmapped }
            let receipt = snapshot.galleryAssets.first(where: { $0.assetID == asset })
            if let receipt, receipt.sha256 != version.deliverySHA256 || receipt.bytes != version.deliveryBytes { throw PhotoCloudSelectionFailure.unmapped }
            try await validateTarget(version, asset, receipt?.storageKey); try check()
            target = .init(assetID: asset, sha256: version.deliverySHA256, bytes: version.deliveryBytes)
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
            sha256: version.deliverySHA256, bytes: version.deliveryBytes, request: request, deliverySource: version.deliverySource)
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
