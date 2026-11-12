import Foundation
import SwiftUI
import Darwin

/// A private, immutable copy of each locally retained photo version. This is
/// independent of the public gallery and of the user's listing selections.
enum NativePhotoBackup {
    struct Asset: Equatable {
        let assetID: String
        let sha256: String
        let bytes: Int64
        let contentType: String

        var json: [String: Any] { [
            "asset_id": assetID.lowercased(), "sha256": sha256,
            "bytes": bytes, "content_type": contentType
        ] }
        init(assetID: String, measured: DirectUploader.BrowserPhoto) throws {
            guard let id = UUID(uuidString: assetID) else { throw Failure.invalidReceipt }
            self.assetID = id.uuidString.lowercased()
            sha256 = measured.sha256; bytes = measured.bytes; contentType = measured.contentType
        }
        init(json: Any?) throws {
            guard let value = json as? [String: Any],
                  let raw = value["asset_id"] as? String, let id = UUID(uuidString: raw),
                  let sha = value["sha256"] as? String, sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let count = value["bytes"] as? NSNumber, count.int64Value > 0,
                  count.int64Value <= 50 * 1024 * 1024,
                  count.doubleValue == Double(count.int64Value),
                  let mime = value["content_type"] as? String else { throw Failure.invalidReceipt }
            assetID = id.uuidString.lowercased(); sha256 = sha; bytes = count.int64Value; contentType = mime
        }
        func matches(_ measured: DirectUploader.BrowserPhoto) -> Bool {
            sha256 == measured.sha256 && bytes == measured.bytes && contentType == measured.contentType
        }
    }

    struct Receipt {
        let listingID: UUID
        let versionID: String
        let familyID: String
        let manifest: [String: Any]
        let available: Bool
        let committedAt: Date
        init(json: Any) throws {
            guard let value = json as? [String: Any],
                  let raw = value["listing_id"] as? String, let listing = UUID(uuidString: raw),
                  let version = value["version_id"] as? String,
                  let family = value["family_id"] as? String,
                  let body = value["manifest"] as? [String: Any],
                  let available = value["available"] as? Bool,
                  let timestamp = value["committed_at"] as? String else { throw Failure.invalidReceipt }
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let whole = ISO8601DateFormatter(); whole.formatOptions = [.withInternetDateTime]
            guard let committed = fractional.date(from: timestamp) ?? whole.date(from: timestamp) else {
                throw Failure.invalidReceipt
            }
            listingID = listing; versionID = version; familyID = family
            manifest = body; self.available = available; committedAt = committed
        }
        func exactlyMatches(_ body: [String: Any], listingID: UUID, version: PhotoVersionHistory.Version) throws -> Bool {
            guard self.listingID == listingID, versionID == version.id, familyID == version.familyID else { return false }
            return try NativePhotoBackup.canonical(manifest) == NativePhotoBackup.canonical(body)
        }
    }

    struct Page {
        let versions: [Receipt]
        let nextOffset: Int?
        init(json: Any, listingID: UUID) throws {
            guard let value = json as? [String: Any], value["ok"] as? Bool == true,
                  (value["listing_id"] as? String).flatMap(UUID.init(uuidString:)) == listingID,
                  let rows = value["versions"] as? [Any], rows.count <= 50 else { throw Failure.invalidReceipt }
            versions = try rows.map { try Receipt(json: $0) }
            guard versions.allSatisfy({ $0.listingID == listingID }) else { throw Failure.invalidReceipt }
            if value["next_offset"] is NSNull { nextOffset = nil }
            else if let number = value["next_offset"] as? NSNumber, number.intValue >= 0 { nextOffset = number.intValue }
            else { throw Failure.invalidReceipt }
        }
    }

    struct DownloadTicket {
        let asset: Asset
        let listingID: UUID
        let url: URL
        init(json: Any, listingID: UUID, expected: Asset) throws {
            guard let value = json as? [String: Any], value["ok"] as? Bool == true,
                  (value["listing_id"] as? String).flatMap(UUID.init(uuidString:)) == listingID,
                  let rawURL = value["url"] as? String, let url = URL(string: rawURL), url.scheme == "https",
                  url.host != nil else { throw Failure.invalidReceipt }
            let asset = try Asset(json: value)
            guard asset == expected else { throw Failure.invalidReceipt }
            self.asset = asset; self.listingID = listingID; self.url = url
        }
    }

    enum Failure: LocalizedError {
        case invalidReceipt, changedFile, missingOriginal, missingAncestor, conflict, unavailable, changedIdentity
        var errorDescription: String? {
            switch self {
            case .invalidReceipt: return "The cloud backup receipt could not be verified."
            case .changedFile: return "This photo changed while backup was running."
            case .missingOriginal: return "The retained original is missing on this iPhone."
            case .missingAncestor: return "An earlier version must be backed up first."
            case .conflict: return "The cloud has a different copy for this version. Your local photo is unchanged."
            case .unavailable: return "The cloud copy is unavailable. Your local photo is unchanged."
            case .changedIdentity: return "The account or workspace changed during backup."
            }
        }
    }

    static func canonical(_ value: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else { throw Failure.invalidReceipt }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func manifest(version: PhotoVersionHistory.Version, listingID: UUID,
                         image: Asset, original: Asset) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func nullable(_ value: String?) -> Any { value ?? NSNull() as Any }
        let canonicalProvenance = version.provenanceID.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
        return [
            "schema": 1, "listing_id": listingID.uuidString.lowercased(),
            "version_id": version.id, "family_id": version.familyID,
            "image_file": version.imageFile, "original_file": nullable(version.originalFile),
            "image": image.json, "original": original.json,
            "parent_id": nullable(version.parentID), "source_id": nullable(version.sourceID),
            "staging_base_id": nullable(version.stagingBaseID),
            "staging_reference_id": nullable(version.stagingReferenceID),
            "edit": version.edit, "style": nullable(version.style), "effects": version.effects,
            "disclosure": nullable(version.disclosure), "provenance_id": nullable(canonicalProvenance),
            "provenance_recorded": version.provenanceRecorded,
            "created_at": formatter.string(from: version.createdAt)
        ]
    }

    /// Ancestry is committed first. A reviewed staging reference can belong to
    /// another family, so it is an explicit dependency too.
    static func ordered(_ index: PhotoVersionHistory.Index) -> [PhotoVersionHistory.Version] {
        var result: [PhotoVersionHistory.Version] = [], done = Set<String>(), visiting = Set<String>()
        func visit(_ version: PhotoVersionHistory.Version) {
            guard !done.contains(version.id), !visiting.contains(version.id) else { return }
            visiting.insert(version.id)
            var dependencies = [version.parentID, version.sourceID, version.stagingBaseID, version.stagingReferenceID].compactMap { $0 }
            if version.edit != "capture-original" { dependencies.insert(version.familyID + "-original", at: 0) }
            for id in dependencies where id != version.id {
                if let ancestor = index.versions[id] { visit(ancestor) }
            }
            visiting.remove(version.id); done.insert(version.id); result.append(version)
        }
        for version in index.versions.values.sorted(by: {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }) { visit(version) }
        return result
    }

    static func eligible(_ version: PhotoVersionHistory.Version, in index: PhotoVersionHistory.Index) -> Bool {
        guard version.originalVerified, version.sourceHistoryKnown, version.originalFile != nil,
              index.versions[version.familyID + "-original"] != nil,
              index.versions[version.familyID]?.edit == "capture" else { return false }
        guard ["capture-original", "capture", "declutter", "stage", "twilight", "sky", "lawn", "custom"].contains(version.edit),
              version.provenanceID == nil || version.provenanceID.flatMap(UUID.init(uuidString:)) != nil,
              !version.provenanceRecorded || version.provenanceID != nil,
              (version.style?.count ?? 0) <= 100, (version.disclosure?.count ?? 0) <= 2000,
              version.effects.count <= 12, Set(version.effects).count == version.effects.count,
              version.effects.allSatisfy({ $0.range(of: "^[a-z-]{1,32}$", options: .regularExpression) != nil })
        else { return false }
        for id in [version.parentID, version.sourceID, version.stagingBaseID].compactMap({ $0 }) {
            guard index.versions[id]?.familyID == version.familyID else { return false }
        }
        if let reference = version.stagingReferenceID {
            guard let staged = index.versions[reference], staged.effects.contains("stage"),
                  staged.stagingReviewed == true || version.serverListingID != nil else { return false }
        }
        return true
    }
}

protocol NativePhotoBackupAPI: AnyObject {
    @MainActor func nativePhotoVersion(listingID: UUID, versionID: String, libraryOrgID: UUID) async throws -> NativePhotoBackup.Receipt?
    @MainActor func commitNativePhotoVersion(_ manifest: [String: Any], listingID: UUID, versionID: String,
                                  libraryOrgID: UUID) async throws -> NativePhotoBackup.Receipt
    @MainActor func nativePhotoVersions(listingID: UUID, offset: Int, libraryOrgID: UUID) async throws -> NativePhotoBackup.Page
    @MainActor func nativePhotoDownload(listingID: UUID, asset: NativePhotoBackup.Asset,
                                        libraryOrgID: UUID) async throws -> NativePhotoBackup.DownloadTicket
}

@MainActor final class NativePhotoBackupCoordinator: ObservableObject {
    static let shared = NativePhotoBackupCoordinator()
    enum State: Equatable {
        case local, backingUp, backedUp, needsOriginal, retry, unavailable, conflict, tooLarge, unsupported
        var title: String {
            switch self {
            case .local: return "On this iPhone"
            case .backingUp: return "Saving to account…"
            case .backedUp: return "Saved to account"
            case .needsOriginal: return "Needs original on this iPhone"
            case .retry, .unavailable, .conflict, .tooLarge, .unsupported: return "Needs attention"
            }
        }
        var symbol: String {
            switch self {
            case .backedUp: return "checkmark.icloud.fill"
            case .backingUp: return "arrow.up.icloud"
            case .needsOriginal, .unavailable, .conflict, .tooLarge, .unsupported: return "exclamationmark.icloud"
            default: return "icloud"
            }
        }
        var detail: String {
            switch self {
            case .local: return "Saved here; account copy has not finished."
            case .backingUp: return "Sending the unchanged saved file to your account."
            case .backedUp: return "The account reports a private copy. Restore checks the downloaded file before use."
            case .needsOriginal: return "An unaltered original is not verified on this iPhone."
            case .retry: return "Could not finish saving to your account. Keep this iPhone copy and retry when online."
            case .unavailable: return "The account copy is unavailable. The saved file remains on this iPhone."
            case .conflict: return "The account has a different copy of this version. The local file is unchanged."
            case .tooLarge: return "This photo exceeds the 50 MB account limit. It remains on this iPhone."
            case .unsupported: return "This saved version or format is not supported by account backup yet. It remains on this iPhone."
            }
        }
    }
    @Published private var states: [String: State] = [:]
    private var running: [UUID: Task<Void, Never>] = [:]
    private init() {}

    private func key(_ listingID: UUID, _ versionID: String) -> String? {
        guard let owner = AuthStore.shared.userID, let org = WorkspaceContext.selectedOrgID else { return nil }
        return owner.lowercased() + ":" + org.uuidString.lowercased() + ":" + listingID.uuidString.lowercased() + ":" + versionID
    }
    func state(for version: PhotoVersionHistory.Version, listingID: UUID) -> State {
        guard version.originalVerified, let originalFile = version.originalFile,
              FileStore.fileSize(EnhancedPhoto.directory(for: listingID).appendingPathComponent(originalFile)) > 0 else {
            return .needsOriginal
        }
        guard version.sourceHistoryKnown,
              ["capture-original", "capture", "declutter", "stage", "twilight", "sky", "lawn", "custom"].contains(version.edit) else { return .unsupported }
        guard let key = key(listingID, version.id) else { return .local }
        return states[key] ?? .local
    }
    private func set(_ state: State, versionID: String, listingID: UUID) {
        guard let key = key(listingID, versionID) else { return }
        states[key] = state
    }

    func schedule(listingID: UUID, model: AppModel) {
        guard Config.useLiveBackend, AuthStore.shared.isIdentified, running[listingID] == nil,
              let listing = model.listings.first(where: { $0.id == listingID }), !listing.isSample,
              listing.cloudUnavailable != true, model.api is NativePhotoBackupAPI else { return }
        running[listingID] = Task { [weak self, weak model] in
            guard let self else { return }
            defer { self.running.removeValue(forKey: listingID) }
            guard let model else { return }
            await self.run(listingID: listingID, model: model)
        }
    }
    func retry(listingID: UUID, model: AppModel) { schedule(listingID: listingID, model: model) }

    /// True while this house's backup is running.
    func isRunning(listingID: UUID) -> Bool { running[listingID] != nil }

    /// Starts the backup `schedule` starts and returns once it has finished,
    /// so a caller working through several houses does them one at a time.
    /// Returns at once when backup cannot start for this house.
    func scheduleAndWait(listingID: UUID, model: AppModel) async {
        schedule(listingID: listingID, model: model)
        await running[listingID]?.value
    }

    private func run(listingID: UUID, model: AppModel) async {
        guard let api = model.api as? NativePhotoBackupAPI,
              let listing = model.listings.first(where: { $0.id == listingID }) else { return }
        let directory = EnhancedPhoto.directory(for: listingID)
        guard let index = try? PhotoVersionHistory.ensureAvailableOriginalSourcesForBackup(directory: directory) else { return }
        let context: CloudMediaAccessContext
        do {
            guard let library = WorkspaceContext.selectedOrgID else { return }
            context = try CloudMediaAccessContext.capture(orgID: library)
        } catch { return }
        let serverID: UUID
        do {
            serverID = try await model.ensureServerListing(listing)
            try context.check()
        } catch { return }
        let physicalOrgID = model.listings.first(where: { $0.id == listingID })?.serverOrgID
        func check() throws {
            try Task.checkCancellation(); try context.check()
            guard let current = model.listings.first(where: { $0.id == listingID }),
                  !current.isSample, current.cloudUnavailable != true,
                  current.serverID == serverID, current.serverOrgID == physicalOrgID else {
                throw NativePhotoBackup.Failure.changedIdentity
            }
        }
        var assets: [String: NativePhotoBackup.Asset] = [:]
        var accepted = Set<String>()
        for version in NativePhotoBackup.ordered(index) {
            guard NativePhotoBackup.eligible(version, in: index) else {
                let missing = version.originalFile.map {
                    FileStore.fileSize(directory.appendingPathComponent($0)) == 0
                } ?? true
                set(version.originalVerified && !missing ? .unsupported : .needsOriginal,
                    versionID: version.id, listingID: listingID); continue
            }
            do {
                try check()
                let ancestors = [version.parentID, version.sourceID, version.stagingBaseID, version.stagingReferenceID]
                    .compactMap { $0 }
                guard ancestors.allSatisfy(accepted.contains) else { throw NativePhotoBackup.Failure.missingAncestor }
                set(.backingUp, versionID: version.id, listingID: listingID)
                let originalName = version.originalFile!
                let imageURL = directory.appendingPathComponent(version.imageFile)
                let originalURL = directory.appendingPathComponent(originalName)
                let image = try await Task.detached(priority: .utility) { try DirectUploader.retainedPhoto(imageURL) }.value
                let original: DirectUploader.BrowserPhoto
                if imageURL == originalURL { original = image }
                else { original = try await Task.detached(priority: .utility) { try DirectUploader.retainedPhoto(originalURL) }.value }
                try check()
                let sourceID = version.familyID + "-original"
                let existing = try await api.nativePhotoVersion(listingID: serverID, versionID: version.id,
                    libraryOrgID: context.selectedLibraryID ?? context.orgID)
                try check()
                let originalAsset: NativePhotoBackup.Asset
                if version.id == sourceID {
                    if let existing { originalAsset = try NativePhotoBackup.Asset(json: existing.manifest["original"]) }
                    else { originalAsset = try await upload(originalURL, measured: original, serverID: serverID, api: model.api) }
                } else if let known = assets[sourceID] { originalAsset = known }
                else { throw NativePhotoBackup.Failure.missingAncestor }
                guard originalAsset.matches(original) else { throw NativePhotoBackup.Failure.conflict }
                let imageAsset: NativePhotoBackup.Asset
                if version.id == sourceID { imageAsset = originalAsset }
                else if let existing { imageAsset = try NativePhotoBackup.Asset(json: existing.manifest["image"]) }
                else { imageAsset = try await upload(imageURL, measured: image, serverID: serverID, api: model.api) }
                guard imageAsset.matches(image) else { throw NativePhotoBackup.Failure.conflict }
                var body = NativePhotoBackup.manifest(version: version, listingID: serverID,
                    image: imageAsset, original: originalAsset)
                if version.serverListingID == serverID.uuidString.lowercased(),
                   let savedFlag = existing?.manifest["provenance_recorded"] as? Bool {
                    // Restore intentionally drops this unverified compliance
                    // flag locally. Preserve its original manifest value only
                    // to compare the immutable cloud receipt for saved bytes.
                    body["provenance_recorded"] = savedFlag
                }
                let receipt: NativePhotoBackup.Receipt
                if let existing { receipt = existing }
                else {
                    do {
                        receipt = try await api.commitNativePhotoVersion(body, listingID: serverID,
                            versionID: version.id, libraryOrgID: context.selectedLibraryID ?? context.orgID)
                    } catch {
                        // The POST reply may have been lost after commit. An
                        // exact GET is safe; never create a second manifest.
                        guard let recovered = try? await api.nativePhotoVersion(listingID: serverID,
                            versionID: version.id, libraryOrgID: context.selectedLibraryID ?? context.orgID) else { throw error }
                        receipt = recovered
                    }
                }
                try check()
                guard try receipt.exactlyMatches(body, listingID: serverID, version: version) else {
                    throw NativePhotoBackup.Failure.conflict
                }
                guard receipt.available else { throw NativePhotoBackup.Failure.unavailable }
                assets[version.id] = imageAsset
                accepted.insert(version.id)
                set(.backedUp, versionID: version.id, listingID: listingID)
            } catch is CancellationError { return }
            catch NativePhotoBackup.Failure.unavailable { set(.unavailable, versionID: version.id, listingID: listingID) }
            catch NativePhotoBackup.Failure.conflict { set(.conflict, versionID: version.id, listingID: listingID) }
            catch NativePhotoBackup.Failure.changedIdentity { return }
            catch CloudSyncError.identityChanged { return }
            catch DirectUploader.BrowserPhotoFailure.unsupportedFormat {
                let imageBytes = FileStore.fileSize(directory.appendingPathComponent(version.imageFile))
                let originalBytes = version.originalFile.map { FileStore.fileSize(directory.appendingPathComponent($0)) } ?? 0
                set(max(imageBytes, originalBytes) > 50 * 1024 * 1024 ? .tooLarge : .unsupported,
                    versionID: version.id, listingID: listingID)
            }
            catch { set(.retry, versionID: version.id, listingID: listingID) }
        }
    }

    private func upload(_ url: URL, measured: DirectUploader.BrowserPhoto,
                        serverID: UUID, api: APIClient) async throws -> NativePhotoBackup.Asset {
        let name: String
        switch measured.contentType {
        case "image/heic": name = "native-photo.heic"
        case "image/heif": name = "native-photo.heif"
        case "image/png": name = "native-photo.png"
        case "image/webp": name = "native-photo.webp"
        default: name = "native-photo.jpg"
        }
        let id = try await DirectUploader.uploadPhoto(fileURL: url, listingID: serverID,
            role: "capture", contentType: measured.contentType, keyPrefix: "native-photo-backup",
            api: api, requestFilename: name)
        let after = try await Task.detached(priority: .utility) { try DirectUploader.retainedPhoto(url) }.value
        guard after == measured else { throw NativePhotoBackup.Failure.changedFile }
        return try NativePhotoBackup.Asset(assetID: id, measured: measured)
    }
}

/// Downloads into a sibling staging directory and publishes the history only
/// after every file passes the committed SHA-256, size and MIME checks.
@MainActor enum NativePhotoBackupRestorer {
    static func restore(serverListingID: UUID, libraryOrgID: UUID, into destination: URL,
                        api: NativePhotoBackupAPI,
                        requireListing: @escaping @MainActor () throws -> Void = {},
                        download: @escaping (URL) async throws -> (URL, URLResponse) = {
                            try await URLSession.shared.download(from: $0)
                        }) async throws -> Int {
        let context = try CloudMediaAccessContext.capture(orgID: libraryOrgID)
        try context.check(); try requireListing()
        // PhotoStudioView's directory accessor creates an empty directory even
        // before a photo is restored. Remove only an empty directory: rmdir is
        // atomic and refuses to remove any local file that appeared meanwhile.
        try removeEmptyDestination(destination)
        var receipts: [NativePhotoBackup.Receipt] = [], seen = Set<String>(), offset = 0
        repeat {
            try context.check(); try requireListing()
            let page = try await api.nativePhotoVersions(listingID: serverListingID, offset: offset, libraryOrgID: libraryOrgID)
            try context.check(); try requireListing()
            guard !page.versions.isEmpty || page.nextOffset == nil else { throw NativePhotoBackup.Failure.invalidReceipt }
            for row in page.versions {
                guard row.available, seen.insert(row.versionID).inserted else { throw NativePhotoBackup.Failure.unavailable }
                receipts.append(row)
            }
            guard receipts.count <= 10_000 else { throw NativePhotoBackup.Failure.invalidReceipt }
            if let next = page.nextOffset {
                guard next > offset else { throw NativePhotoBackup.Failure.invalidReceipt }
                offset = next
            } else { break }
        } while true
        guard !receipts.isEmpty else { return 0 }

        var index = PhotoVersionHistory.Index()
        index.listingSelections = [:] // Restore never publishes a gallery choice.
        var assetsByFile: [String: NativePhotoBackup.Asset] = [:]
        for row in receipts {
            let version = try version(from: row.manifest, serverListingID: serverListingID)
            guard version.id == row.versionID, version.familyID == row.familyID,
                  index.versions[version.id] == nil else { throw NativePhotoBackup.Failure.invalidReceipt }
            let image = try NativePhotoBackup.Asset(json: row.manifest["image"])
            let original = try NativePhotoBackup.Asset(json: row.manifest["original"])
            guard let originalFile = version.originalFile,
                  assetsByFile[version.imageFile].map({ $0 == image }) ?? true,
                  assetsByFile[originalFile].map({ $0 == original }) ?? true else {
                throw NativePhotoBackup.Failure.conflict
            }
            assetsByFile[version.imageFile] = image
            assetsByFile[originalFile] = original
            index.versions[version.id] = version
        }
        for version in index.versions.values {
            let originalID = version.familyID + "-original"
            guard let source = index.versions[originalID], source.edit == "capture-original",
                  let root = index.versions[version.familyID], root.edit == "capture",
                  source.originalFile == version.originalFile, root.originalFile == version.originalFile else {
                throw NativePhotoBackup.Failure.missingAncestor
            }
            for id in [version.parentID, version.sourceID, version.stagingBaseID].compactMap({ $0 }) {
                guard index.versions[id]?.familyID == version.familyID else { throw NativePhotoBackup.Failure.missingAncestor }
            }
            if let referenceID = version.stagingReferenceID {
                guard let reference = index.versions[referenceID], reference.effects.contains("stage") else {
                    throw NativePhotoBackup.Failure.missingAncestor
                }
            }
            guard let sourceRow = receipts.first(where: { $0.versionID == originalID }) else {
                throw NativePhotoBackup.Failure.missingAncestor
            }
            let sourceAsset = try NativePhotoBackup.Asset(json: sourceRow.manifest["original"])
            guard assetsByFile[version.originalFile!] == sourceAsset else { throw NativePhotoBackup.Failure.conflict }
        }
        let families = Set(index.versions.values.map(\.familyID))
        index.familyOrder = families.sorted {
            let a = index.versions[$0]?.createdAt ?? .distantPast, b = index.versions[$1]?.createdAt ?? .distantPast
            return a == b ? $0 < $1 : a < b
        }
        for family in families {
            let candidates = receipts.filter { $0.familyID == family && $0.versionID != family + "-original" }
            index.current[family] = candidates.max(by: {
                $0.committedAt == $1.committedAt ? $0.versionID < $1.versionID : $0.committedAt < $1.committedAt
            })?.versionID
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".native-photo-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        for (name, asset) in assetsByFile.sorted(by: { $0.key < $1.key }) {
            try context.check(); try requireListing()
            let ticket = try await api.nativePhotoDownload(listingID: serverListingID, asset: asset, libraryOrgID: libraryOrgID)
            try context.check(); try requireListing()
            let (temporary, response) = try await download(ticket.url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try context.check(); try requireListing()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  response.url?.scheme == "https" else { throw NativePhotoBackup.Failure.invalidReceipt }
            let measured = try await Task.detached(priority: .utility) { try DirectUploader.retainedPhoto(temporary) }.value
            guard asset.matches(measured) else { throw NativePhotoBackup.Failure.conflict }
            try FileManager.default.moveItem(at: temporary, to: stage.appendingPathComponent(name))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(index).write(to: stage.appendingPathComponent(".photo-history.json"), options: .atomic)
        _ = try PhotoVersionHistory.load(directory: stage)
        try context.check(); try requireListing()
        // SwiftUI may reevaluate the screen's eager directory getter during
        // the download. It can recreate only an empty destination; never
        // overwrite or remove a directory containing local work.
        try removeEmptyDestination(destination)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw NativePhotoBackup.Failure.conflict }
        try FileManager.default.moveItem(at: stage, to: destination)
        return index.versions.count
    }

    private static func removeEmptyDestination(_ destination: URL) throws {
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        guard destination.path.withCString({ Darwin.rmdir($0) }) == 0 else {
            throw NativePhotoBackup.Failure.conflict
        }
    }

    private static func version(from body: [String: Any], serverListingID: UUID) throws -> PhotoVersionHistory.Version {
        func required(_ key: String) throws -> String {
            guard let value = body[key] as? String, safe(value) else { throw NativePhotoBackup.Failure.invalidReceipt }
            return value
        }
        func optional(_ key: String, identifier: Bool = false) throws -> String? {
            if body[key] is NSNull { return nil }
            guard let value = body[key] as? String, (!identifier || safe(value)) else {
                throw NativePhotoBackup.Failure.invalidReceipt
            }
            return value
        }
        let id = try required("version_id"), family = try required("family_id")
        let imageFile = try required("image_file"), originalFile = try required("original_file")
        let edit = try required("edit")
        guard (body["schema"] as? NSNumber)?.intValue == 1,
              (body["listing_id"] as? String).flatMap(UUID.init(uuidString:)) == serverListingID,
              originalFile == "orig-\(family).jpg",
              let effects = body["effects"] as? [String],
              body["provenance_recorded"] is Bool,
              let rawDate = body["created_at"] as? String,
              ["capture-original", "capture", "declutter", "stage", "twilight", "sky", "lawn", "custom"].contains(edit)
        else { throw NativePhotoBackup.Failure.invalidReceipt }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter(); whole.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: rawDate) ?? whole.date(from: rawDate) else {
            throw NativePhotoBackup.Failure.invalidReceipt
        }
        let parent = try optional("parent_id", identifier: true), source = try optional("source_id", identifier: true)
        let base = try optional("staging_base_id", identifier: true), reference = try optional("staging_reference_id", identifier: true)
        let style = try optional("style"), disclosure = try optional("disclosure")
        let provenance = try optional("provenance_id")
        guard provenance == nil || provenance.flatMap(UUID.init(uuidString:)) != nil else { throw NativePhotoBackup.Failure.invalidReceipt }
        if edit == "capture-original" {
            guard id == family + "-original", imageFile == originalFile, parent == nil, source == nil,
                  base == nil, reference == nil, effects.isEmpty else { throw NativePhotoBackup.Failure.invalidReceipt }
        } else if edit == "capture" {
            guard id == family, imageFile == "enh-\(family).jpg", parent == nil, source == nil,
                  base == nil, reference == nil, effects.isEmpty else { throw NativePhotoBackup.Failure.invalidReceipt }
        } else {
            guard imageFile.hasPrefix("edit-\(id)."), ["jpg", "png", "webp"].contains((imageFile as NSString).pathExtension),
                  parent != nil, source != nil else { throw NativePhotoBackup.Failure.invalidReceipt }
        }
        var version = PhotoVersionHistory.Version(id: id, familyID: family, imageFile: imageFile,
            originalFile: originalFile, originalVerified: true, parentID: parent, sourceID: source,
            stagingBaseID: base, edit: edit, style: style, effects: effects, sourceHistoryKnown: true,
            disclosure: disclosure, provenanceID: provenance, originalAssetID: nil,
            serverListingID: serverListingID.uuidString.lowercased(), provenanceRecorded: false,
            createdAt: date)
        version.stagingReferenceID = reference
        if effects.contains("stage") { version.stagingReviewed = false }
        if effects.contains("custom") { version.customReviewed = false }
        return version
    }

    private static func safe(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }
}
