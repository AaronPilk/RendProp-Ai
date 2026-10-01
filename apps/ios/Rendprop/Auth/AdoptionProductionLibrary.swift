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
