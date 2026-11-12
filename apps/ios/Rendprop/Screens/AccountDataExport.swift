import Foundation
import SwiftUI
import UIKit

struct AccountExportContext: Equatable {
    let actor: UUID
    let revision: UInt64
    func matches(owner: String?, revision: UInt64, identified: Bool) -> Bool {
        identified && owner.flatMap(UUID.init(uuidString:)) == actor && revision == self.revision
    }
}

enum AccountExportFailure: LocalizedError {
    case invalidReceipt, staleAccount, fileUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidReceipt: return "The account download could not be verified. Please try again."
        case .staleAccount: return "Your account changed. Start a new download for the current account."
        case .fileUnavailable: return "The download could not be saved. Please try again."
        }
    }
}

struct AccountExportReceipt {
    static let maximumBytes = 20 * 1024 * 1024
    struct Omission: Decodable { let collection: String; let reason: String }
    private struct Manifest: Decodable {
        let version: String, actor_id: UUID, generated_at: String, scope: String
        let complete_within_scope: Bool, truncated: Bool
        struct Count: Decodable { let count: Int }
        let collections: [String: Count]
        let omissions: [Omission]
    }
    private struct Envelope: Decodable { let manifest: Manifest }
    let rows: Int
    let omissions: [Omission]
    static func checked(_ data: Data, context: AccountExportContext) throws -> AccountExportReceipt {
        guard !data.isEmpty, data.count <= maximumBytes,
              let decoded = try? JSONDecoder().decode(Envelope.self, from: data),
              decoded.manifest.version == "rendprop-account-export-v1",
              decoded.manifest.actor_id == context.actor,
              decoded.manifest.scope == "current-account-owned-cloud-records",
              decoded.manifest.complete_within_scope, !decoded.manifest.truncated,
              ISO8601DateFormatter().date(from: decoded.manifest.generated_at) != nil || isoFractionalDate(decoded.manifest.generated_at) != nil,
              !decoded.manifest.collections.isEmpty, !decoded.manifest.omissions.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inventory = root["data"] as? [String: Any],
              Set(inventory.keys) == Set(decoded.manifest.collections.keys),
              let profiles = inventory["profiles"] as? [[String: Any]], profiles.count == 1,
              let profileID = profiles[0]["id"] as? String, UUID(uuidString: profileID) == context.actor else { throw AccountExportFailure.invalidReceipt }
        var rows = 0
        for (key, collection) in decoded.manifest.collections {
            guard collection.count >= 0, collection.count <= 10000,
                  let items = inventory[key] as? [[String: Any]], items.count == collection.count else { throw AccountExportFailure.invalidReceipt }
            rows += items.count
            guard rows <= 20000 else { throw AccountExportFailure.invalidReceipt }
        }
        guard decoded.manifest.omissions.allSatisfy({ !$0.collection.isEmpty && !$0.reason.isEmpty }) else { throw AccountExportFailure.invalidReceipt }
        return AccountExportReceipt(rows: rows, omissions: decoded.manifest.omissions)
    }
    private static func isoFractionalDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

/// The app never caches an export for another launch or account. This owned
/// scratch directory has no media download links and is cleared before each
/// action, on cancellation/account change, and at app startup.
enum AccountExportFiles {
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("rendprop-account-export", isDirectory: true) }
    static func purge() { try? FileManager.default.removeItem(at: directory) }
    static func remove(generation: UUID) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(generation.uuidString, isDirectory: true)) }
    static func save(_ bytes: Data, generation: UUID) throws -> URL {
        guard !bytes.isEmpty, bytes.count <= AccountExportReceipt.maximumBytes else { throw AccountExportFailure.fileUnavailable }
        remove(generation: generation)
        let owned = directory.appendingPathComponent(generation.uuidString, isDirectory: true)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false, attributes: attributes)
        let url = owned.appendingPathComponent("rendprop-account-data.json")
        attributes[.posixPermissions] = 0o600
        guard FileManager.default.createFile(atPath: url.path, contents: bytes, attributes: attributes) else { remove(generation: generation); throw AccountExportFailure.fileUnavailable }
        return url
    }
}

struct AccountDataExportView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @State private var task: Task<Void, Never>?
    @State private var context: AccountExportContext?
    @State private var generation: UUID?
    @State private var receipt: AccountExportReceipt?
    @State private var file: URL?
    @State private var sharing = false
    @State private var error: String?
    @State private var loading = false
    private var current: Bool { context?.matches(owner: auth.userID, revision: auth.syncSessionRevision, identified: auth.isIdentified) == true }
    var body: some View {
        List {
            Section {
                Text("Download your account profile, current workspace memberships, assigned listings, contacts, and authored cloud work as a JSON file.")
                Text("Original media files, local unsynced changes, other members’ private data, and operational secrets are excluded. The file includes a manifest listing every excluded collection.")
                    .foregroundStyle(.secondary)
                Button { download() } label: {
                    Label(loading ? "Preparing download…" : "Prepare account download", systemImage: "square.and.arrow.down")
                }
                .disabled(loading || !auth.isIdentified)
                .accessibilityIdentifier("accountExport.download")
            }
            if current, let receipt, file != nil {
                Section {
                    Text("Verified \(receipt.rows) cloud records for this account.")
                    Button { if current { sharing = true } else { clear() } } label: {
                        Label("Save or share JSON file", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("accountExport.share")
                }
                Section("Excluded from this download") {
                    ForEach(Array(receipt.omissions.enumerated()), id: \.offset) { _, item in Text(item.reason) }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Account data")
        .sheet(isPresented: $sharing) {
            if current, let file, let generation {
                AccountExportShare(file: file).onDisappear { finishShare(generation) }
            }
        }
        .onChange(of: auth.userID) { _ in clear() }
        .onChange(of: auth.syncSessionRevision) { _ in clear() }
        .onDisappear { if !sharing { clear() } }
    }
    @MainActor private func clear() {
        task?.cancel(); task = nil; sharing = false; file = nil; receipt = nil; context = nil; loading = false
        if let generation { AccountExportFiles.remove(generation: generation) }
        generation = nil; error = nil
    }
    @MainActor private func finishShare(_ action: UUID) {
        guard generation == action else { return }
        clear()
    }
    @MainActor private func download() {
        clear(); error = nil
        guard auth.isIdentified, let owner = auth.userID.flatMap(UUID.init(uuidString:)) else { error = AccountExportFailure.staleAccount.localizedDescription; return }
        let captured = AccountExportContext(actor: owner, revision: auth.syncSessionRevision)
        let action = UUID()
        context = captured; generation = action; loading = true
        task = Task { @MainActor in
            do {
                let bytes = try await model.api.exportAccountData()
                try Task.checkCancellation()
                guard generation == action, context == captured, captured.matches(owner: auth.userID, revision: auth.syncSessionRevision, identified: auth.isIdentified) else { throw AccountExportFailure.staleAccount }
                let verified = try AccountExportReceipt.checked(bytes, context: captured)
                let saved = try AccountExportFiles.save(bytes, generation: action)
                // No await exists between the final actor fence and presenting
                // the saved result. Cancellation cannot leave a reusable file.
                guard !Task.isCancelled, generation == action, context == captured, captured.matches(owner: auth.userID, revision: auth.syncSessionRevision, identified: auth.isIdentified) else { AccountExportFiles.remove(generation: action); throw AccountExportFailure.staleAccount }
                receipt = verified; file = saved; loading = false; task = nil
            } catch {
                if generation == action, context == captured { clear(); if !(error is CancellationError) { self.error = error.localizedDescription } }
            }
        }
    }
}

private struct AccountExportShare: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
