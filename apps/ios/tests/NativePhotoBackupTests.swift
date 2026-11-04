import Foundation
import CryptoKit
import SwiftUI

enum Config { static let useLiveBackend = true }
enum CloudSyncError: Error { case identityChanged }
@MainActor final class AuthStore: ObservableObject {
    static let shared = AuthStore()
    var isIdentified = true
    var userID: String? = UUID().uuidString
    var syncSessionRevision: UInt64 = 1
}
enum WorkspaceContext { @MainActor static var selectedOrgID: UUID? = UUID() }
struct CloudMediaAccessContext {
    let actorID: UUID
    let revision: UInt64
    let orgID: UUID
    let selectedLibraryID: UUID?
    @MainActor static func capture(orgID: UUID) throws -> Self {
        guard let actor = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)),
              WorkspaceContext.selectedOrgID == orgID else { throw CloudSyncError.identityChanged }
        return .init(actorID: actor, revision: AuthStore.shared.syncSessionRevision,
                     orgID: orgID, selectedLibraryID: orgID)
    }
    @MainActor func check() throws {
        guard AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == actorID,
              AuthStore.shared.syncSessionRevision == revision,
              WorkspaceContext.selectedOrgID == orgID else { throw CloudSyncError.identityChanged }
    }
}
protocol APIClient: AnyObject {}
struct Listing {
    let id: UUID
    var serverID: UUID?
    var serverOrgID: UUID?
    var isSample = false
    var cloudUnavailable: Bool? = nil
}
@MainActor final class AppModel {
    var listings: [Listing]
    let api: APIClient
    init(_ listing: Listing, api: APIClient) { listings = [listing]; self.api = api }
    func ensureServerListing(_ listing: Listing) async throws -> UUID { listing.serverID! }
}
enum EnhancedPhoto {
    @MainActor static var root: URL = FileManager.default.temporaryDirectory
    @MainActor static func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
}
enum FileStore { static func fileSize(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }
enum DirectUploader {
    enum BrowserPhotoFailure: Error { case unsupportedFormat }
    struct BrowserPhoto: Equatable { let contentType: String; let bytes: Int64; let sha256: String }
    @MainActor static var contents: [String: Data] = [:]
    @MainActor static var uploads: [(role: String, contentType: String, filename: String)] = []
    @MainActor static var offlineUploads = 0
    static func retainedPhoto(_ url: URL) throws -> BrowserPhoto {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= 50 * 1024 * 1024 else { throw BrowserPhotoFailure.unsupportedFormat }
        let mime: String
        if data.starts(with: [0xff, 0xd8, 0xff]) { mime = "image/jpeg" }
        else if data.count >= 12, data.dropFirst(4).prefix(4) == Data("ftyp".utf8) {
            mime = data.dropFirst(8).prefix(4) == Data("heic".utf8) ? "image/heic" : "image/heif"
        } else { throw BrowserPhotoFailure.unsupportedFormat }
        return .init(contentType: mime, bytes: Int64(data.count),
                     sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    @MainActor static func uploadPhoto(fileURL: URL, listingID: UUID, role: String,
                                       contentType: String, keyPrefix: String, api: APIClient,
                                       requestFilename: String? = nil) async throws -> String {
        if offlineUploads > 0 { offlineUploads -= 1; throw URLError(.notConnectedToInternet) }
        let measured = try retainedPhoto(fileURL)
        precondition(measured.contentType == contentType && role == "capture")
        let id = UUID().uuidString.lowercased()
        contents[id] = try Data(contentsOf: fileURL)
        uploads.append((role, contentType, requestFilename ?? fileURL.lastPathComponent))
        return id
    }
}

@MainActor final class FakeBackupAPI: APIClient, NativePhotoBackupAPI {
    let serverID: UUID
    var rows: [String: NativePhotoBackup.Receipt] = [:]
    var offlineReads = 0
    var changeActorOnRead = false
    init(_ serverID: UUID) { self.serverID = serverID }
    func nativePhotoVersion(listingID: UUID, versionID: String,
                            libraryOrgID: UUID) async throws -> NativePhotoBackup.Receipt? {
        if offlineReads > 0 { offlineReads -= 1; throw URLError(.notConnectedToInternet) }
        if changeActorOnRead { AuthStore.shared.userID = UUID().uuidString }
        return rows[versionID]
    }
    func commitNativePhotoVersion(_ manifest: [String: Any], listingID: UUID, versionID: String,
                                  libraryOrgID: UUID) async throws -> NativePhotoBackup.Receipt {
        let json: [String: Any] = ["listing_id": listingID.uuidString.lowercased(),
                                  "version_id": versionID, "family_id": manifest["family_id"]!,
                                  "manifest": manifest, "available": true,
                                  "committed_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_000_000 + Double(rows.count)))]
        let receipt = try NativePhotoBackup.Receipt(json: json)
        rows[versionID] = receipt
        return receipt
    }
    func nativePhotoVersions(listingID: UUID, offset: Int, libraryOrgID: UUID) async throws -> NativePhotoBackup.Page {
        let ordered = rows.values.sorted { $0.versionID < $1.versionID }
        let batch = Array(ordered.dropFirst(offset).prefix(50))
        let next: Any = offset + batch.count < ordered.count ? offset + batch.count : NSNull()
        let json: [String: Any] = ["ok": true, "listing_id": listingID.uuidString.lowercased(),
                                  "versions": batch.map { row($0) }, "next_offset": next]
        return try NativePhotoBackup.Page(json: json, listingID: listingID)
    }
    func nativePhotoDownload(listingID: UUID, asset: NativePhotoBackup.Asset,
                             libraryOrgID: UUID) async throws -> NativePhotoBackup.DownloadTicket {
        var json = asset.json
        json["ok"] = true; json["listing_id"] = listingID.uuidString.lowercased()
        json["url"] = "https://private.example/\(asset.assetID)"
        json["expires_at"] = "2099-01-01T00:00:00Z"
        return try NativePhotoBackup.DownloadTicket(json: json, listingID: listingID, expected: asset)
    }
    private func row(_ receipt: NativePhotoBackup.Receipt) -> [String: Any] {
        ["listing_id": receipt.listingID.uuidString.lowercased(), "version_id": receipt.versionID,
         "family_id": receipt.familyID, "manifest": receipt.manifest, "available": receipt.available,
         "committed_at": ISO8601DateFormatter().string(from: receipt.committedAt)]
    }
}

@main struct NativePhotoBackupTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-backup-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        EnhancedPhoto.root = root
        let localID = UUID(), serverID = UUID(), org = WorkspaceContext.selectedOrgID!
        let source = EnhancedPhoto.directory(for: localID)
        let family = UUID().uuidString.lowercased(), editID = UUID().uuidString.lowercased()
        let customID = UUID().uuidString.lowercased()
        let original = Data([0, 0, 0, 0] + Array("ftypheic".utf8) + [1, 2, 3])
        let enhanced = Data([0xff, 0xd8, 0xff, 1, 2, 3])
        let edited = Data([0xff, 0xd8, 0xff, 4, 5, 6])
        let custom = Data([0xff, 0xd8, 0xff, 7, 8, 9])
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: family, directory: source)
        _ = try PhotoVersionHistory.ensureOriginalSources(directory: source)
        _ = try PhotoVersionHistory.saveEdit(jpeg: edited, id: editID, parentID: family, sourceID: family,
            edit: "declutter", style: nil, disclosure: "Digitally decluttered", provenanceID: UUID().uuidString,
            provenanceRecorded: true, directory: source)
        _ = try PhotoVersionHistory.saveEdit(jpeg: custom, id: customID, parentID: editID, sourceID: editID,
            edit: "custom", style: nil, disclosure: "Custom AI edit", provenanceID: UUID().uuidString,
            provenanceRecorded: true, directory: source)
        let index = try PhotoVersionHistory.load(directory: source)
        check(NativePhotoBackup.ordered(index).map(\.id) == [family + "-original", family, editID, customID],
              "original, capture and edit are ordered before commit")
        let crossDir = root.appendingPathComponent("cross-family")
        let familyA = UUID().uuidString.lowercased(), familyB = UUID().uuidString.lowercased()
        let stageB = UUID().uuidString.lowercased(), stageA = UUID().uuidString.lowercased()
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: familyA, directory: crossDir)
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: familyB, directory: crossDir)
        _ = try PhotoVersionHistory.ensureOriginalSources(directory: crossDir)
        _ = try PhotoVersionHistory.saveEdit(jpeg: edited, id: stageB, parentID: familyB, sourceID: familyB,
            edit: "stage", style: "modern", disclosure: nil, provenanceID: UUID().uuidString,
            provenanceRecorded: true, directory: crossDir)
        try PhotoVersionHistory.selectForPublication(id: stageB, directory: crossDir, reviewed: true)
        _ = try PhotoVersionHistory.saveEdit(jpeg: custom, id: stageA, parentID: familyA, sourceID: familyA,
            edit: "stage", style: "modern", disclosure: nil, provenanceID: UUID().uuidString,
            provenanceRecorded: true, directory: crossDir, stagingReferenceID: stageB)
        let crossIndex = try PhotoVersionHistory.load(directory: crossDir)
        let crossOrder = NativePhotoBackup.ordered(crossIndex).map(\.id)
        check(crossOrder.firstIndex(of: stageB)! < crossOrder.firstIndex(of: stageA)!,
              "referenced stage in another family commits before its dependent edit")
        check(NativePhotoBackup.eligible(crossIndex.versions[stageA]!, in: crossIndex),
              "reviewed cross-family staging reference remains eligible")
        let api = FakeBackupAPI(serverID)
        let model = AppModel(.init(id: localID, serverID: serverID, serverOrgID: org), api: api)
        NativePhotoBackupCoordinator.shared.schedule(listingID: localID, model: model)
        try await waitFor { api.rows.count == 4 }
        check(api.rows.count == 4 && DirectUploader.uploads.count == 4, "all four immutable versions and files saved privately")
        check(DirectUploader.uploads.allSatisfy { $0.role == "capture" }, "no public gallery upload")
        check(DirectUploader.uploads.contains { $0.contentType == "image/heic" && $0.filename.hasSuffix(".heic") },
              "HEIC bytes retain HEIC MIME despite local .jpg name")
        check((api.rows[editID]?.manifest["provenance_id"] as? String) ==
              index.versions[editID]!.provenanceID!.lowercased(),
              "uppercase local provenance UUID is normalized before immutable server replay")
        check(NativePhotoBackupCoordinator.shared.state(for: index.versions[editID]!, listingID: localID) == .backedUp,
              "status requires exact server receipt")

        let offline = root.appendingPathComponent("offline-listing")
        do {
            _ = try await NativePhotoBackupRestorer.restore(serverListingID: serverID, libraryOrgID: org,
                into: offline, api: api, download: { _ in throw URLError(.notConnectedToInternet) })
            preconditionFailure("offline restore claimed success")
        } catch { check(!FileManager.default.fileExists(atPath: offline.path), "offline restore leaves no partial library") }

        let restoredLocalID = UUID()
        let fresh = EnhancedPhoto.directory(for: restoredLocalID)
        let count = try await NativePhotoBackupRestorer.restore(serverListingID: serverID, libraryOrgID: org,
            into: fresh, api: api, download: { url in
                let id = url.lastPathComponent
                let temp = root.appendingPathComponent(UUID().uuidString)
                try DirectUploader.contents[id]!.write(to: temp)
                return (temp, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let recovered = try PhotoVersionHistory.load(directory: fresh)
        check(count == 4 && recovered.versions.count == 4 && recovered.current[family] == customID,
              "fresh-directory restore rebuilds edit lineage and current choice")
        check(recovered.listingSelections == [:], "restore leaves public gallery unselected")
        check(recovered.versions[customID]?.customReviewed == false,
              "restored custom edit defaults to unreviewed, not silently approved")
        check(recovered.versions[customID]?.provenanceRecorded == false,
              "client-supplied provenance flag is not promoted to verified compliance on restore")
        check(try Data(contentsOf: fresh.appendingPathComponent("orig-\(family).jpg")) == original,
              "retained original restored byte-for-byte")
        check(try Data(contentsOf: fresh.appendingPathComponent("enh-\(family).jpg")) == enhanced,
              "enhanced capture restored byte-for-byte")
        check(try Data(contentsOf: fresh.appendingPathComponent("edit-\(editID).jpg")) == edited,
              "edit restored byte-for-byte")
        check(try Data(contentsOf: fresh.appendingPathComponent("edit-\(customID).jpg")) == custom,
              "custom edit restored byte-for-byte")
        let uploadsBeforeRecheck = DirectUploader.uploads.count
        let restoredModel = AppModel(.init(id: restoredLocalID, serverID: serverID, serverOrgID: org), api: api)
        NativePhotoBackupCoordinator.shared.schedule(listingID: restoredLocalID, model: restoredModel)
        try await waitFor {
            NativePhotoBackupCoordinator.shared.state(for: recovered.versions[customID]!, listingID: restoredLocalID) == .backedUp
        }
        check(DirectUploader.uploads.count == uploadsBeforeRecheck,
              "restored private copy rechecks the exact cloud receipt without another upload")

        let tampered = root.appendingPathComponent("tampered-listing")
        do {
            _ = try await NativePhotoBackupRestorer.restore(serverListingID: serverID, libraryOrgID: org,
                into: tampered, api: api, download: { url in
                    let temp = root.appendingPathComponent(UUID().uuidString)
                    try Data([0xff, 0xd8, 0xff, 9]).write(to: temp)
                    return (temp, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
            preconditionFailure("tampered bytes accepted")
        } catch { check(!FileManager.default.fileExists(atPath: tampered.path), "hash failure publishes no partial history") }
        let rejected = root.appendingPathComponent("rejected-signed-response")
        do {
            _ = try await NativePhotoBackupRestorer.restore(serverListingID: serverID, libraryOrgID: org,
                into: rejected, api: api, download: { url in
                    let temp = root.appendingPathComponent(UUID().uuidString)
                    try DirectUploader.contents[url.lastPathComponent]!.write(to: temp)
                    return (temp, HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!)
                })
            preconditionFailure("invalid signed response committed")
        } catch { check(!FileManager.default.fileExists(atPath: rejected.path), "invalid signed response leaves no partial library") }
        let switched = root.appendingPathComponent("switched-listing")
        let ownerBeforeRestore = AuthStore.shared.userID
        do {
            _ = try await NativePhotoBackupRestorer.restore(serverListingID: serverID, libraryOrgID: org,
                into: switched, api: api, download: { url in
                    let temp = root.appendingPathComponent(UUID().uuidString)
                    try DirectUploader.contents[url.lastPathComponent]!.write(to: temp)
                    AuthStore.shared.userID = UUID().uuidString
                    return (temp, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
            preconditionFailure("former actor's restore committed")
        } catch { check(!FileManager.default.fileExists(atPath: switched.path), "actor change refuses restore before publishing history") }
        AuthStore.shared.userID = ownerBeforeRestore
        do {
            _ = try await NativePhotoBackupRestorer.restore(serverListingID: serverID, libraryOrgID: org,
                into: fresh, api: api)
            preconditionFailure("existing directory overwritten")
        } catch { check(try Data(contentsOf: fresh.appendingPathComponent("orig-\(family).jpg")) == original,
                      "existing local photos cannot be overwritten") }

        let secondLocal = UUID(), second = UUID().uuidString.lowercased()
        let secondDir = EnhancedPhoto.directory(for: secondLocal)
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: second, directory: secondDir)
        _ = try PhotoVersionHistory.ensureOriginalSources(directory: secondDir)
        let secondIndex = try PhotoVersionHistory.load(directory: secondDir)
        let secondAPI = FakeBackupAPI(UUID())
        let secondModel = AppModel(.init(id: secondLocal, serverID: secondAPI.serverID, serverOrgID: org), api: secondAPI)
        DirectUploader.offlineUploads = 1
        NativePhotoBackupCoordinator.shared.schedule(listingID: secondLocal, model: secondModel)
        try await waitFor { NativePhotoBackupCoordinator.shared.state(for: secondIndex.versions[second + "-original"]!, listingID: secondLocal) == .retry }
        check(secondAPI.rows.isEmpty, "offline attempt cannot mark original saved")
        NativePhotoBackupCoordinator.shared.retry(listingID: secondLocal, model: secondModel)
        try await waitFor { secondAPI.rows.count == 2 }
        check(secondAPI.rows.count == 2, "retry completes original and enhancement")

        let mixedLocal = UUID(), intactFamily = UUID().uuidString.lowercased()
        let missingFamily = UUID().uuidString.lowercased()
        let mixedDir = EnhancedPhoto.directory(for: mixedLocal)
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: intactFamily, directory: mixedDir)
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: missingFamily, directory: mixedDir)
        try FileManager.default.removeItem(at: mixedDir.appendingPathComponent("orig-\(missingFamily).jpg"))
        do {
            _ = try PhotoVersionHistory.ensureOriginalSources(directory: mixedDir)
            preconditionFailure("Photos load hid a missing retained original")
        } catch {
            check(error is PhotoVersionHistory.Failure, "Photos still reports a missing original")
        }
        let mixedAPI = FakeBackupAPI(UUID())
        let mixedModel = AppModel(.init(id: mixedLocal, serverID: mixedAPI.serverID, serverOrgID: org), api: mixedAPI)
        NativePhotoBackupCoordinator.shared.schedule(listingID: mixedLocal, model: mixedModel)
        try await waitFor { mixedAPI.rows.count == 2 }
        let mixedIndex = try PhotoVersionHistory.load(directory: mixedDir)
        check(mixedAPI.rows[intactFamily + "-original"] != nil && mixedAPI.rows[intactFamily] != nil,
              "backup continues with the intact family")
        check(mixedAPI.rows[missingFamily] == nil &&
              NativePhotoBackupCoordinator.shared.state(for: mixedIndex.versions[missingFamily]!, listingID: mixedLocal) == .needsOriginal,
              "missing family remains visibly unbacked up")

        let thirdLocal = UUID(), third = UUID().uuidString.lowercased()
        let thirdDir = EnhancedPhoto.directory(for: thirdLocal)
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: third, directory: thirdDir)
        _ = try PhotoVersionHistory.ensureOriginalSources(directory: thirdDir)
        let thirdAPI = FakeBackupAPI(UUID()); thirdAPI.changeActorOnRead = true
        let thirdModel = AppModel(.init(id: thirdLocal, serverID: thirdAPI.serverID, serverOrgID: org), api: thirdAPI)
        let previousOwner = AuthStore.shared.userID
        NativePhotoBackupCoordinator.shared.schedule(listingID: thirdLocal, model: thirdModel)
        try await waitFor { AuthStore.shared.userID != nil && AuthStore.shared.userID != previousOwner }
        let thirdIndex = try PhotoVersionHistory.load(directory: thirdDir)
        check(NativePhotoBackupCoordinator.shared.state(for: thirdIndex.versions[third]!, listingID: thirdLocal) != .backedUp,
              "account switch cannot certify a former actor's backup")
        print("\(checks) native backup and restore checks PASS")
    }

    @MainActor private static func waitFor(_ done: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if done() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("timed out waiting for native backup")
    }
}
