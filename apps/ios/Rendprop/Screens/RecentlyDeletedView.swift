import SwiftUI

/// Recently deleted (build 58). A deleted cloud listing stays restorable for
/// 30 days; restoring brings its details, photos and the SAME public tour
/// links back. The walkthrough file and captures were removed from this phone
/// when it was deleted — the tour itself is served from the cloud copy, and
/// the listing reappears as a cloud listing with its files one tap away.
///
/// Read-only for marketing seats (`canRestore` comes from the server), empty
/// and error states are real screens, and every row says when it expires.
struct RecentlyDeletedView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var workspace = WorkspaceStore.shared
    @State private var rows: [TrashedListing] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var restoring: UUID?
    @State private var restoreError: String?
    @State private var restored: RestoredListing?
    @State private var loadedFor: UUID?

    var body: some View {
        List {
            Section {
                Text("Deleted listings stay here for 30 days. Restoring one brings back its details, photos and the exact share links it had. The walkthrough video is served from the cloud copy.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recentlyDeleted.intro")
            }
            if let restored {
                Section {
                    Label(restoredMessage(restored), systemImage: "checkmark.circle.fill")
                        .font(.rpBody).foregroundStyle(Theme.good)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("recentlyDeleted.restored")
                    if restored.cancelledClientDeliveries > 0 {
                        Text("\(restored.cancelledClientDeliveries) client email\(restored.cancelledClientDeliveries == 1 ? "" : "s") that the delete stopped were not re-sent. Open the listing's client details to send them again.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let restoreError {
                Section {
                    Label(restoreError, systemImage: "exclamationmark.triangle.fill")
                        .font(.rpCaption).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("recentlyDeleted.restoreError")
                }
            }
            Section {
                if loading && rows.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking Recently deleted…").font(.rpCaption).foregroundStyle(Theme.inkDim)
                    }
                } else if let loadError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(loadError).font(.rpCaption).foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { Task { await load(force: true) } }
                            .font(.rpBody.weight(.semibold))
                    }
                    .accessibilityIdentifier("recentlyDeleted.loadError")
                } else if rows.isEmpty {
                    Text("Nothing here. Listings you delete will wait here for 30 days.")
                        .font(.rpBody).foregroundStyle(Theme.inkDim)
                        .accessibilityIdentifier("recentlyDeleted.empty")
                } else {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(row.address.isEmpty ? "Untitled listing" : row.address)
                                .font(.rpHeadline).foregroundStyle(Theme.ink)
                            Text(expiryLine(row))
                                .font(.rpCaption).foregroundStyle(row.restorableUntil.timeIntervalSinceNow < 3 * 86_400 ? Theme.warn : Theme.inkDim)
                            if row.hadPublishedTour {
                                Label("Had a live tour — restoring brings the same link back", systemImage: "link")
                                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            }
                            if row.canRestore {
                                Button {
                                    restore(row)
                                } label: {
                                    HStack(spacing: 8) {
                                        if restoring == row.id { ProgressView() }
                                        Label(restoring == row.id ? "Restoring…" : "Restore", systemImage: "arrow.uturn.backward")
                                    }
                                    .font(.rpBody.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Theme.accentSoft)
                                    .foregroundStyle(Theme.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(restoring != nil)
                                .accessibilityIdentifier("recentlyDeleted.restore.\(row.id.uuidString.lowercased())")
                            } else {
                                Text("Only an owner, admin or agent of this library can restore it.")
                                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("recentlyDeleted.row.\(row.id.uuidString.lowercased())")
                    }
                }
            } header: {
                Text(rows.isEmpty ? "" : "\(rows.count) listing\(rows.count == 1 ? "" : "s")")
            }
        }
        .navigationTitle("Recently deleted")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(force: true) }
        .task(id: workspace.selected?.id) { await load(force: false) }
        .onChange(of: auth.userID) { _ in rows = []; restored = nil; restoreError = nil; loadedFor = nil }
    }

    private func expiryLine(_ row: TrashedListing) -> String {
        let days = max(0, Int(ceil(row.restorableUntil.timeIntervalSinceNow / 86_400)))
        let deleted = Self.dayFormatter.string(from: row.deletedAt)
        if days == 0 { return "Deleted \(deleted) · gone for good within the hour" }
        return "Deleted \(deleted) · \(days) day\(days == 1 ? "" : "s") left to restore"
    }
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    private func restoredMessage(_ r: RestoredListing) -> String {
        let name = (r.address ?? "").isEmpty ? "The listing" : r.address!
        return r.republishedRenders > 0
            ? "\(name) is back, and its tour link is live again."
            : "\(name) is back in your library."
    }

    @MainActor private func load(force: Bool) async {
        guard Config.useLiveBackend, auth.isIdentified, let org = workspace.selected?.id else {
            rows = []; loadError = nil; return
        }
        if !force, loadedFor == org, !rows.isEmpty { return }
        let owner = auth.userID, epoch = auth.syncSessionRevision
        loading = true; loadError = nil
        defer { loading = false }
        do {
            let fetched = try await model.api.trashedListings()
            guard workspace.selected?.id == org, auth.userID == owner, auth.syncSessionRevision == epoch else { return }
            rows = fetched.filter { $0.restorableUntil > Date() }
            loadedFor = org
        } catch is CancellationError {
        } catch {
            guard workspace.selected?.id == org, auth.userID == owner, auth.syncSessionRevision == epoch else { return }
            loadError = "Couldn't load Recently deleted — \(AppModel.userMessage(for: error))"
        }
    }

    private func restore(_ row: TrashedListing) {
        guard restoring == nil else { return }
        restoring = row.id; restoreError = nil; restored = nil
        Haptics.selection()
        let org = workspace.selected?.id, owner = auth.userID, epoch = auth.syncSessionRevision
        Task {
            do {
                let result = try await model.restoreListing(serverID: row.id)
                await MainActor.run {
                    guard workspace.selected?.id == org, auth.userID == owner, auth.syncSessionRevision == epoch else { restoring = nil; return }
                    rows.removeAll { $0.id == row.id }
                    restored = result
                    restoring = nil
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    restoring = nil
                    guard workspace.selected?.id == org, auth.userID == owner, auth.syncSessionRevision == epoch else { return }
                    let message = AppModel.userMessage(for: error)
                    restoreError = "Couldn't restore \(row.address.isEmpty ? "this listing" : row.address) — \(message)"
                    // A window that closed while the list was open: drop the row.
                    if let api = error as? APIError, api.status == 410 { rows.removeAll { $0.id == row.id } }
                }
            }
        }
    }
}
