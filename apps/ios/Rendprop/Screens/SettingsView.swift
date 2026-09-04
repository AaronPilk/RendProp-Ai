import SwiftUI
import UIKit
import PhotosUI
import WebKit

struct SettingsView: View {
    // Key is shared with UploadManager.shouldWarnCellular (which reads it via
    // UserDefaults). The launch code registers the default (`true`) so the
    // toggle and the upload manager agree on a fresh install.
    @AppStorage("wifiOnlyUploads") private var askBeforeCellularUploads = true
    @AppStorage("maxQualityCapture") private var maxQualityCapture = false
    @AppStorage("hasOnboarded") private var hasOnboarded = true
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    // Drives .preferredColorScheme at the app root (RendpropApp reads the same key).
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
    @EnvironmentObject var uploads: UploadManager
    @EnvironmentObject var model: AppModel

    // Real signed-in state for the Account row (never the dev-stub placeholder).
    @ObservedObject private var auth = AuthStore.shared

    // Live-backend plan/usage (contract: GET /me). Loaded only when signed in.
    @State private var usage: UsageSummary?
    @State private var usageError: String?
    @State private var isLoadingUsage = false

    // Sign in / sign out
    @State private var showSignIn = false
    @State private var showSignOutConfirm = false
    @State private var showIntroConfirm = false

    // Account deletion flow (App Store Guideline 5.1.1(v) — in-app deletion).
    @State private var showDeleteConfirm = false
    @State private var showDeleteNeedsSignIn = false
    @State private var isDeletingAccount = false
    @State private var deleteErrorMessage: String?
    @State private var showDeleteError = false
    @State private var showAccountDeleted = false
    @State private var deletionPendingCleanup = false

    // Honest local-only wipe (never described as an account deletion).
    @State private var showClearDataConfirm = false
    @State private var showDataCleared = false

    /// True when a server account exists to sign into / delete. In the offline
    /// (mock) build there is no account — only data on this phone.
    private var serverAccountsEnabled: Bool { Config.useLiveBackend && Config.enableAuth }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    BusinessTypeView()
                } label: {
                    HStack {
                        Label(SpaceType.current.displayName, systemImage: SpaceType.current.systemImage)
                        Spacer()
                        Text("Change")
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                    }
                }
            } header: {
                Text("Business type")
            } footer: {
                Text("Switch any time — the whole app re-themes instantly: samples, fields, area tags and your tour's call-to-action.")
            }

            Section {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(Appearance.allCases) { a in
                        Label(a.label, systemImage: a.systemImage).tag(a.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceRaw) { _ in Haptics.selection() }
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows your iPhone.")
            }

            if Config.useLiveBackend {
                Section {
                    NavigationLink {
                        LeadsView()
                    } label: {
                        HStack {
                            Label("Leads", systemImage: "person.crop.circle.badge.plus")
                            Spacer()
                            if let count = leadCountLabel {
                                Text(count)
                                    .font(.rpCaption)
                                    .foregroundStyle(Theme.inkDim)
                            }
                        }
                    }
                } footer: {
                    Text("People who fill in the form on your shared tours. Email alerts are coming — check here for now.")
                }
            }

            Section {
                Toggle("Ask before uploading on cellular", isOn: $askBeforeCellularUploads)
                if let s = uploads.state {
                    HStack {
                        Text("Current upload")
                        Spacer()
                        Text("\(uploadStatusLabel(s.status)) · \(s.fractionComplete.formatted(.percent.precision(.fractionLength(0))))")
                            .foregroundStyle(s.status == .done ? Theme.good : Theme.inkDim)
                    }
                    if s.status == .queued && uploads.pendingCellularConfirmation {
                        Button("Start on cellular now") { uploads.confirmCellularAndStart() }
                    } else if s.status == .uploading {
                        Button("Pause upload") { uploads.pause() }
                    } else if s.status == .paused || s.status == .failed {
                        Button("Resume upload") { uploads.resume() }
                    }
                    // No cancel once it's finished — nothing left to cancel.
                    if s.status != .done {
                        Button("Cancel upload", role: .destructive) { uploads.cancel() }
                    }
                }
            } header: {
                Text("Uploads")
            } footer: {
                Text("Videos over 500 MB always ask. Waiting uploads start on their own once you're back on Wi-Fi.")
            }

            Section {
                NavigationLink {
                    AgentCardEditorView()
                } label: {
                    LabeledContent(SpaceType.current.profileCardName,
                                   value: AgentCard.current.isSet ? AgentCard.current.name : "Set up")
                }
            } header: {
                Text("Brand kit")
            } footer: {
                Text(brandKitFooter)
            }

            Section {
                NavigationLink {
                    AIPhotoStudioView()
                } label: {
                    Label("AI Photo Studio", systemImage: "wand.and.stars")
                }
            } header: {
                Text("AI tools")
            } footer: {
                Text("Twilight, sky replacement, lawn repair, decluttering, virtual staging, and custom AI edits on any listing photo.")
            }

            // Notifications section is hidden until push (APNs) is wired — a
            // reviewer must never see "Coming soon" placeholder rows (App Store
            // 2.1). Re-enable this block behind Config.enablePush when APNs ships.
            if Config.enablePush {
                Section("Notifications") {
                    LabeledContent("Render ready", value: "On")
                    LabeledContent("New lead", value: "On")
                }
            }

            // Source of truth for shooting guidance is the capture screen's
            // coaching (PaceRing: a normal walking pace is good; only rushing
            // and fast spins hurt). Keep every other surface saying the same.
            Section("How to shoot a great walkthrough") {
                Label("Walk at your normal pace — steady beats slow", systemImage: "figure.walk")
                Label("No fast spins — turn like you're showing a friend around", systemImage: "arrow.triangle.turn.up.right.diamond")
                Label("Phone upright at chest height, keep the bubble level", systemImage: "level")
                Label("Lights on, blinds open", systemImage: "lightbulb")
                Label("One continuous take (up to 10 minutes); end on your best shot", systemImage: SpaceType.current.systemImage)
            }
            .font(.rpBody)

            Section {
                LabeledContent("Account", value: accountStatusLabel)
                if serverAccountsEnabled {
                    if auth.isSignedIn {
                        Button("Sign out", role: .destructive) { showSignOutConfirm = true }
                    } else {
                        Button {
                            showSignIn = true
                        } label: {
                            Label("Sign in with Apple", systemImage: "apple.logo")
                        }
                    }
                }
                Button {
                    if uploads.state?.status == .uploading {
                        showIntroConfirm = true
                    } else {
                        hasOnboarded = false   // flips the root back to the intro
                    }
                } label: {
                    Label("Watch the intro again", systemImage: "play.rectangle")
                }
            } header: {
                Text("Account")
            } footer: {
                Text(accountFooter)
            }

            if Config.useLiveBackend {
                usageSection
            }

            Section {
                if isDeletingAccount {
                    HStack {
                        Text("Deleting account…").foregroundStyle(Theme.inkDim)
                        Spacer()
                        ProgressView()
                    }
                } else {
                    Button("Delete account", role: .destructive) { deleteTapped() }
                }
                Button("Clear data on this phone", role: .destructive) { showClearDataConfirm = true }
            } header: {
                Text("Your data")
            } footer: {
                Text(serverAccountsEnabled
                     ? "Delete account removes your Rendprop account, published tours and leads from our servers, then clears this phone. Clear data only wipes this phone — your account and published tours stay as they are."
                     : "Clear data removes every listing, video, tour and card stored on this phone.")
            }

            Section("Legal") {
                Link("Terms of Service", destination: URL(string: "https://rendprop.com/terms")!)
                Link("Privacy Policy", destination: URL(string: "https://rendprop.com/privacy")!)
                Text("Only record spaces you have the right to record and publish.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }

            Section {
                Toggle("Max quality capture (4K · 60fps)", isOn: $maxQualityCapture)
                LabeledContent("Version", value: Self.appVersionLabel)
            } header: {
                Text("Advanced")
            } footer: {
                Text("Standard capture is 4K · 30fps. Your finished tour is rendered at 60fps either way; 4K · 60 doubles the file size and warms the phone faster.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadUsage() }
        .refreshable { await loadUsage() }
        .onChange(of: auth.isSignedIn) { signedIn in
            if signedIn {
                Task { await loadUsage() }
            } else {
                usage = nil
                usageError = nil
            }
        }
        .sheet(isPresented: $showSignIn) {
            SignInView {
                Task { await loadUsage() }
            }
        }
        .confirmationDialog("Sign out?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                auth.signOut()
                usage = nil
                usageError = nil
                Haptics.selection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your listings, videos and tours stay on this phone. Publishing and AI tools ask you to sign in again.")
        }
        .alert("Upload in progress", isPresented: $showIntroConfirm) {
            Button("Watch anyway", role: .destructive) { hasOnboarded = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A video is uploading. It keeps going in the background, but you'll lose the progress screen.")
        }
        .alert("Delete account?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(serverAccountsEnabled
                 ? "This permanently deletes your account, published tours, leads and data. Shared links stop working."
                 : "This removes everything stored on this phone.")
        }
        .alert("Sign in to delete your account", isPresented: $showDeleteNeedsSignIn) {
            Button("Sign in") { showSignIn = true }
            Button("Clear this phone only", role: .destructive) { showClearDataConfirm = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your published tours and leads belong to your Rendprop account. Sign in with Apple first so we can delete them — or clear just this phone.")
        }
        .alert("Couldn't delete account", isPresented: $showDeleteError) {
            Button("Retry") { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "Check your connection and try again.")
        }
        .alert("Account deleted", isPresented: $showAccountDeleted) {
            Button("OK") { hasOnboarded = false }   // back to the intro, fresh start
        } message: {
            Text(deletionPendingCleanup
                 ? "Your account is deleted and your tour links are down. Remaining media cleanup finishes automatically in the background."
                 : "Your account and data have been removed.")
        }
        .alert("Clear data on this phone?", isPresented: $showClearDataConfirm) {
            Button("Clear", role: .destructive) { clearLocalDataTapped() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(serverAccountsEnabled
                 ? "Removes every listing, video, tour and card stored on this phone and signs you out. Your account and any published tours are NOT deleted — use Delete account for that."
                 : "Removes every listing, video, tour and card stored on this phone.")
        }
        .alert("Data cleared", isPresented: $showDataCleared) {
            Button("OK") { hasOnboarded = false }
        } message: {
            Text(serverAccountsEnabled
                 ? "Everything stored on this phone was removed. Your account and published tours are unchanged."
                 : "Everything stored on this phone was removed.")
        }
    }

    // MARK: - Small labels

    private func uploadStatusLabel(_ status: UploadManager.Status) -> String {
        switch status {
        case .queued:    return uploads.pendingCellularConfirmation ? "Waiting for Wi-Fi" : "Queued"
        case .uploading: return "Uploading"
        case .paused:    return "Paused"
        case .failed:    return "Failed"
        case .done:      return "Complete"
        }
    }

    private var leadCountLabel: String? {
        guard auth.isSignedIn else { return nil }
        if let e = usage?.entitlements { return "\(e.leads) this month" }
        if let n = usage?.leadCount { return "\(n) this month" }
        return nil
    }

    /// One org = ONE hosted brand kit; the app keeps a card per business type.
    /// Say which one the hosted pages mirror so nobody is surprised.
    private var brandKitFooter: String {
        let primary = AgentCard.primaryBrandType
        if let primary, primary != SpaceType.current {
            return "Hosted tour pages show your \(primary.displayName) card. This \(SpaceType.current.displayName) card is used for in-app previews."
        }
        return "The card \(SpaceType.current.customerNoun) see at the end of every tour — name, contact and links. Photos aren't on hosted pages yet."
    }

    private var accountFooter: String {
        guard serverAccountsEnabled else {
            return "Offline build — capture and on-device rendering work without an account."
        }
        return auth.isSignedIn
            ? "Signed in with Apple. Publishing, leads and AI tools use this account."
            : "Capture and on-device rendering work without an account. Sign in to publish tours, see leads and use AI tools."
    }

    // MARK: - Plan & usage (live backend only)

    @ViewBuilder
    private var usageSection: some View {
        Section {
            if !auth.isSignedIn {
                Text("Sign in to see your plan and this month's usage.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            } else if let usage {
                usageRows(usage)
            } else if let usageError {
                Text(usageError)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                Button("Try again") { Task { await loadUsage() } }
                    .disabled(isLoadingUsage)
            } else {
                HStack {
                    Text("Loading usage…").foregroundStyle(Theme.inkDim)
                    Spacer()
                    ProgressView()
                }
            }
        } header: {
            Text("Plan & usage")
        } footer: {
            Text("Counts reset each month. Pull down to refresh.")
        }
    }

    @ViewBuilder
    private func usageRows(_ usage: UsageSummary) -> some View {
        if let e = usage.entitlements {
            LabeledContent("Plan", value: Self.planLabel(e))
            if let ends = e.trialEndsAt, ends > Date() {
                LabeledContent("Trial ends", value: ends.formatted(date: .abbreviated, time: .omitted))
            }
            usageRow("Tour renders", used: e.used["renders"], cap: e.rendersPerMonth)
            usageRow("Photo edits", used: e.used["photo_edits"], cap: e.photoEditsPerMonth)
            usageRow("Reel clips", used: e.used["reels"], cap: e.reelsPerMonth)
            usageRow("Aerial intros", used: e.used["aerials"], cap: e.aerialsPerMonth)
            usageRow("Drone-glide upscales", used: e.used["drone"], cap: e.topazPerMonth)
            LabeledContent("Leads this month", value: "\(e.leads)")
        } else {
            // Older server shape (no entitlement block): show what we have.
            if let plan = usage.planName, !plan.isEmpty {
                LabeledContent("Plan", value: plan.capitalized)
            }
            if let renders = usage.renderCount {
                LabeledContent("Tour renders", value: "\(renders)")
            }
            if let leads = usage.leadCount {
                LabeledContent("Leads this month", value: "\(leads)")
            }
        }
    }

    /// "7 of 150" — or "Not included" when the plan has no allowance for it.
    /// Never a price: plans and pricing live on rendprop.com (App Store 3.1).
    private func usageRow(_ title: String, used: Int?, cap: Int) -> some View {
        let value: String
        if cap > 0 {
            value = "\(used ?? 0) of \(cap)"
        } else {
            value = "Not included"
        }
        return LabeledContent(title, value: value)
            .foregroundStyle(cap > 0 ? Theme.ink : Theme.inkDim)
    }

    private static func planLabel(_ e: Entitlements) -> String {
        let name = e.plan.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "—" }
        return name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    @MainActor
    private func loadUsage() async {
        guard Config.useLiveBackend, auth.isSignedIn else {
            usage = nil
            return
        }
        isLoadingUsage = true
        defer { isLoadingUsage = false }
        do {
            usage = try await model.api.me()
            usageError = nil
        } catch {
            if error is CancellationError { return }
            usageError = UserFacingError.message(error, fallback: "Couldn't load usage. Pull down to refresh.")
        }
    }

    // MARK: - Account (App Store Guideline 5.1.1(v): in-app account deletion)

    /// What the Account row shows — the real state, never a dev placeholder.
    private var accountStatusLabel: String {
        guard serverAccountsEnabled else { return "Offline build" }
        guard auth.isSignedIn else { return "Not signed in" }
        let name = auth.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Signed in with Apple" : name
    }

    /// App version straight from the bundle so this row can never go stale.
    private static var appVersionLabel: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    private struct AccountDeleteError: LocalizedError {
        let status: Int
        var errorDescription: String? { "The server responded with status \(status)." }
    }

    /// Decoded shape of DELETE /me — the app must not treat a bare 2xx as
    /// success (audit P0-4): `ok` is authoritative, and `cleanup_complete`
    /// reports whether media/CRM cleanup finished inline or is queued.
    private struct ServerDeleteResponse: Decodable {
        let ok: Bool
        let cleanupComplete: Bool?
        enum CodingKeys: String, CodingKey {
            case ok
            case cleanupComplete = "cleanup_complete"
        }
    }

    /// Server-side erasure per the backend contract: `DELETE {base}/me` with the
    /// bearer JWT + apikey. Returns whether external cleanup fully completed
    /// inline (false = queued, retried server-side until done).
    private func requestServerAccountDeletion() async throws -> Bool {
        guard let url = Config.apiBaseURL?.appendingPathComponent("me") else {
            throw URLError(.badURL)
        }
        // Freshness-guaranteed accessor — refreshes the JWT first if it's stale.
        guard let token = await AuthStore.validAccessToken() else {
            throw URLError(.userAuthenticationRequired)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw AccountDeleteError(status: status) }
        guard let decoded = try? JSONDecoder().decode(ServerDeleteResponse.self, from: data),
              decoded.ok else {
            throw AccountDeleteError(status: status)
        }
        return decoded.cleanupComplete ?? true
    }

    /// "Delete account" tapped. A signed-out user on the live backend is NOT
    /// offered a fake deletion: their account (and every published tour) lives
    /// on the server, so they must sign in first — or choose the honest
    /// "Clear this phone only".
    private func deleteTapped() {
        if serverAccountsEnabled && !auth.isSignedIn {
            showDeleteNeedsSignIn = true
        } else {
            showDeleteConfirm = true
        }
    }

    @MainActor
    private func deleteAccount() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        if serverAccountsEnabled {
            // The session may have expired between the tap and the confirm.
            guard auth.isSignedIn else {
                showDeleteNeedsSignIn = true
                return
            }
            // 1. Server-side erasure first (account, published tours, uploads).
            //    If it fails, STOP — local data stays intact and the alert offers
            //    Retry, so nothing is half-deleted.
            do {
                deletionPendingCleanup = !(try await requestServerAccountDeletion())
            } catch {
                deleteErrorMessage = "Your account was NOT deleted. \(UserFacingError.message(error))"
                showDeleteError = true
                return
            }
        } else {
            // Offline build: there is no server account. This is a local wipe and
            // the confirmation copy said exactly that.
            deletionPendingCleanup = false
        }

        // 2. Local erasure: session, listings + videos + tours, profile cards.
        if uploads.state != nil { uploads.cancel() }
        auth.signOut()
        wipeLocalData()
        Haptics.success()
        showAccountDeleted = true   // OK → hasOnboarded = false
    }

    /// Honest local-only wipe. Signs out (the tokens are data on this phone
    /// too) but never touches the server account or hosted tours.
    @MainActor
    private func clearLocalDataTapped() {
        if uploads.state != nil { uploads.cancel() }
        auth.signOut()
        wipeLocalData()
        Haptics.success()
        showDataCleared = true
    }

    /// Remove everything the app stored on this device. Demo samples are
    /// reseeded afterwards so the app still works as a fresh install.
    ///
    /// Documents is wiped WHOLESALE (then Recordings/Imports are recreated) so
    /// no later-added folder (reels, FloorPlans, Aerials, Photos, enhanced-*.mp4,
    /// preview-*.html, the state snapshot) can be missed again (audit F-C-11).
    @MainActor
    private func wipeLocalData() {
        // Stop any render/publish first — a job finishing after the wipe would
        // write a tour for a listing that no longer exists.
        for id in Array(model.renderCoordinator.jobs.keys) { model.renderCoordinator.cancel(listingID: id) }

        // In-memory state — every didSet re-persists, so the snapshot on disk
        // ends up empty too (PersistentStore never saves samples).
        model.listings.removeAll()
        model.assets.removeAll()
        model.tours.removeAll()
        model.renders.removeAll()
        model.pendingPublish.removeAll()          // nothing left to publish on relaunch
        model.uploadedRenderAssets.removeAll()    // server asset ids belong to the wiped account

        let fm = FileManager.default

        // 1. Documents — everything, hidden files included.
        if let items = try? fm.contentsOfDirectory(at: FileStore.documents,
                                                   includingPropertiesForKeys: nil,
                                                   options: []) {
            for url in items { try? fm.removeItem(at: url) }
        }
        // Recreate the working folders the capture/import paths expect.
        _ = FileStore.recordingsDir
        _ = FileStore.importsDir

        // 2. Caches (personalized player-demo HTML + demo video copy) and tmp.
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: caches.appendingPathComponent("player-demo"))
        }
        if let tmpItems = try? fm.contentsOfDirectory(at: fm.temporaryDirectory,
                                                      includingPropertiesForKeys: nil,
                                                      options: []) {
            for url in tmpItems { try? fm.removeItem(at: url) }
        }

        // 3. WebKit site data from hosted pages loaded in PlayerWebView
        //    (lead-form cookies, localStorage beacons).
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                modifiedSince: .distantPast) {}

        // 4. Profile cards for EVERY business type (keys are namespaced per
        //    industry; real estate uses the legacy bare keys) + brand bookkeeping.
        let d = UserDefaults.standard
        for type in SpaceType.allCases {
            for field in AgentCard.fieldNames {
                d.removeObject(forKey: AgentCard.key(field, for: type))
            }
        }
        d.removeObject(forKey: AgentCard.primaryTypeKey)
        d.removeObject(forKey: AgentCard.lastPushedKey)
        d.removeObject(forKey: "auth.userName")
        d.removeObject(forKey: "auth.orgName")
        // In-flight / cached aerial job records (per listing) go with the data.
        for key in d.dictionaryRepresentation().keys
        where key.hasPrefix("aerial.pending.") || key.hasPrefix("aerial.meta.") {
            d.removeObject(forKey: key)
        }

        // 5. Fresh samples for the current business type.
        model.reseedSamples()
    }
}

// MARK: - User-facing error copy
// One place that turns transport/server errors into a sentence a user can act
// on. `APIError.server` carries the server's own message (decision A12); the
// helpers below cover the status-specific cases.
enum UserFacingError {
    static let pricingURL = URL(string: "https://rendprop.com/pricing")

    static func message(_ error: Error, fallback: String = "Something went wrong. Please try again.") -> String {
        if let api = error as? APIError {
            if api.isUnauthorized { return "Please sign in again to continue." }
            if api.isRateLimited { return "Too many requests — try again in a few minutes." }
            if case .server(_, _, let message) = api, !message.isEmpty { return message }
            return api.errorDescription ?? fallback
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .timedOut, .dnsLookupFailed, .cannotFindHost, .internationalRoamingOff:
                return "You're offline — check your connection and try again."
            default:
                break
            }
        }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    /// 402 from the server — the plan doesn't include this (or the monthly
    /// allowance is used up). The UI shows an "Upgrade plan" link; prices stay
    /// on the website (App Store 3.1).
    static func isQuota(_ error: Error) -> Bool {
        (error as? APIError)?.isQuota ?? false
    }

    static func isUnauthorized(_ error: Error) -> Bool {
        (error as? APIError)?.isUnauthorized ?? false
    }
}

// MARK: - Leads
// The people who filled in the form on a hosted tour (GET /leads, RLS-scoped to
// the signed-in org). All leads from Settings/Profile; one listing's leads from
// the detail screen. Lives in this in-target file (new-file rule).

struct LeadsView: View {
    /// nil = every lead for the account; a listing = only that listing's leads.
    var listing: Listing? = nil

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared

    @State private var leads: [Lead] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var showSignIn = false

    private var needsSignIn: Bool { Config.enableAuth && !auth.isSignedIn }

    /// A listing that was never published has no server id — nothing to fetch.
    private var listingNotPublished: Bool {
        guard let listing else { return false }
        return listing.serverID == nil
    }

    private struct DaySection: Identifiable {
        let id: Date
        let title: String
        let leads: [Lead]
    }

    private var sections: [DaySection] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: leads) { cal.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            DaySection(id: day,
                       title: Self.dayTitle(day),
                       leads: (groups[day] ?? []).sorted { $0.createdAt > $1.createdAt })
        }
    }

    var body: some View {
        List {
            content
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Leads")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: auth.isSignedIn) { _ in Task { await load() } }
        .sheet(isPresented: $showSignIn) {
            SignInView {
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let listing {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(listing.address.replacingOccurrences(of: " (Sample)", with: ""))
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.ink)
                    if listing.serverShareURL != nil {
                        Text("Leads from this \(listing.spaceType.spaceNoun)'s shared tour.")
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                    }
                }
                .padding(.vertical, 2)
            }
        }

        if listing?.isSample == true {
            infoRow(icon: "sparkles",
                    title: "Sample \(SpaceType.current.spaceNoun)s don't collect leads",
                    detail: "Create a \(SpaceType.current.spaceNoun) and publish its tour — the form on your shared link sends leads here.")
        } else if needsSignIn {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Sign in to see your leads", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.ink)
                    Text("Leads belong to your Rendprop account. Sign in with Apple to load them.")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                    Button {
                        showSignIn = true
                    } label: {
                        Label("Sign in with Apple", systemImage: "apple.logo")
                            .font(.rpBody.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
        } else if listingNotPublished {
            infoRow(icon: "link.badge.plus",
                    title: "Publish this \(SpaceType.current.spaceNoun) to start collecting leads",
                    detail: "The form at the end of your shared tour sends leads here. This \(SpaceType.current.spaceNoun) hasn't been published yet.")
        } else if let errorMessage, leads.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Couldn't load leads", systemImage: "exclamationmark.triangle")
                        .font(.rpHeadline)
                        .foregroundStyle(Theme.warn)
                    Text(errorMessage)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                    Button("Try again") { Task { await load() } }
                        .disabled(isLoading)
                }
                .padding(.vertical, 4)
            }
        } else if isLoading && !hasLoaded {
            Section {
                HStack {
                    Text("Loading leads…").foregroundStyle(Theme.inkDim)
                    Spacer()
                    ProgressView()
                }
            }
        } else if leads.isEmpty {
            infoRow(icon: "tray",
                    title: "No leads yet",
                    detail: "Leads from your tours appear here — email alerts are coming. Share your tour link to get the first one.")
        } else {
            if let errorMessage {
                // Stale list + a refresh that failed: keep the data, say so.
                Section {
                    Text(errorMessage).font(.rpCaption).foregroundStyle(Theme.warn)
                }
            }
            ForEach(sections) { day in
                Section(day.title) {
                    ForEach(day.leads) { lead in
                        LeadRow(lead: lead, showListing: listing == nil)
                    }
                }
            }
        }
    }

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.rpHeadline)
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
            .padding(.vertical, 4)
        }
    }

    private static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    @MainActor
    private func load() async {
        if needsSignIn { hasLoaded = true; return }
        if let listing, listing.isSample || listing.serverID == nil { hasLoaded = true; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await model.api.leads(listingServerID: listing?.serverID)
            leads = fetched.sorted { $0.createdAt > $1.createdAt }
            errorMessage = nil
            hasLoaded = true
        } catch {
            if error is CancellationError { return }
            errorMessage = UserFacingError.message(error, fallback: "Couldn't load leads. Pull down to try again.")
            hasLoaded = true
        }
    }
}

/// One lead: who, when, what they wrote, and one-tap call / email.
struct LeadRow: View {
    let lead: Lead
    var showListing = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(lead.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Someone" : lead.name)
                    .font(.rpHeadline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(lead.createdAt, style: .time)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
            if showListing, let address = lead.listingAddress?.trimmingCharacters(in: .whitespaces), !address.isEmpty {
                Label(address, systemImage: SpaceType.current.systemImage)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .lineLimit(1)
            }
            if let message = lead.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                Text(message)
                    .font(.rpBody)
                    .foregroundStyle(Theme.ink)
            }
            if let extra = lead.extra, !extra.isEmpty {
                ForEach(extra.keys.sorted(), id: \.self) { key in
                    if let value = extra[key], !value.trimmingCharacters(in: .whitespaces).isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Self.prettyKey(key))
                                .font(.rpCaption.weight(.semibold))
                                .foregroundStyle(Theme.inkDim)
                            Text(value)
                                .font(.rpCaption)
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                if let phone = lead.phone?.trimmingCharacters(in: .whitespaces), !phone.isEmpty,
                   let url = Self.telURL(phone) {
                    Link(destination: url) {
                        Label(phone, systemImage: "phone.fill")
                    }
                }
                if let email = lead.email?.trimmingCharacters(in: .whitespaces), !email.isEmpty,
                   let url = Self.mailURL(email) {
                    Link(destination: url) {
                        Label(email, systemImage: "envelope.fill")
                            .lineLimit(1)
                    }
                }
            }
            .font(.rpCaption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.top, 2)
            if let source = lead.source?.trimmingCharacters(in: .whitespaces), !source.isEmpty, source != "tour" {
                Text("via \(source)")
                    .font(.caption2)
                    .foregroundStyle(Theme.inkDim)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// "eventDate" → "Event date"; "party_size" → "Party size".
    private static func prettyKey(_ key: String) -> String {
        var out = ""
        for ch in key.replacingOccurrences(of: "_", with: " ") {
            if ch.isUppercase, !out.isEmpty, out.last != " " { out.append(" ") }
            out.append(ch)
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return key }
        return first.uppercased() + trimmed.dropFirst().lowercased()
    }

    /// tel: wants digits (and a leading +) — "(555) 012-3456" → tel:5550123456.
    static func telURL(_ phone: String) -> URL? {
        var digits = phone.filter { $0.isNumber }
        if phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") { digits = "+" + digits }
        guard digits.count >= 3 else { return nil }
        return URL(string: "tel:\(digits)")
    }

    static func mailURL(_ email: String) -> URL? {
        let allowed = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
        return URL(string: "mailto:\(allowed)")
    }
}

// MARK: - AI Photo Studio
// Twilight / sky-replace / lawn-repair on a listing photo via the `ai-photo`
// edge function (Gemini). Inlined here (in a compiled file) so it can't be
// dropped from the build target — same rule as AgentCard below.

struct AIPhotoStudioView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared

    private enum Edit: String, CaseIterable, Identifiable {
        case twilight, sky, lawn, declutter, stage, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .twilight:  return "Twilight"
            case .sky:       return "Blue sky"
            case .lawn:      return "Green lawn"
            case .declutter: return "Declutter"
            case .stage:     return "Staging"
            case .custom:    return "Custom"
            }
        }
    }

    /// Furnishing look for `edit = .stage` — mirrors the ai-photo contract.
    private enum StageStyle: String, CaseIterable, Identifiable {
        case modern, rustic, minimalist, scandinavian
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @State private var pickerItem: PhotosPickerItem?
    @State private var original: UIImage?
    @State private var edited: UIImage?
    @State private var edit: Edit = .twilight
    @State private var stageStyle: StageStyle = .modern
    @State private var customPrompt = ""
    @State private var isWorking = false
    @State private var errorMsg: String?
    @State private var errorIsQuota = false
    @State private var showSignIn = false

    private var customPromptTrimmed: String {
        customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var needsSignIn: Bool { Config.useLiveBackend && Config.enableAuth && !auth.isSignedIn }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let edited {
                    resultCard(edited)
                } else if let original {
                    Image(uiImage: original)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    editChips
                    if edit == .stage {
                        Picker("Style", selection: $stageStyle) {
                            ForEach(StageStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text("Empty or dated rooms get furnished in the style you pick.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if edit == .custom {
                        TextField("Describe the change — e.g. 'make it look freshly painted white with warm evening light'",
                                  text: $customPrompt, axis: .vertical)
                            .lineLimit(3...6)
                            .textFieldStyle(.roundedBorder)
                        Text("\(customPrompt.count)/600")
                            .font(.rpCaption)
                            .foregroundStyle(customPrompt.count >= 600 ? Theme.warn : Theme.inkDim)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Button(action: enhanceTapped) {
                        HStack {
                            if isWorking { ProgressView().tint(.white) }
                            Text(isWorking ? "Enhancing…" : (needsSignIn ? "Sign in to enhance" : "Enhance photo"))
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent).foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(isWorking || (edit == .custom && customPromptTrimmed.isEmpty))
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Text("Choose a different photo").font(.rpBody).foregroundStyle(Theme.accent)
                    }
                } else {
                    emptyState
                }

                if let errorMsg {
                    VStack(spacing: 8) {
                        Text(errorMsg).font(.rpCaption).foregroundStyle(Theme.warn)
                            .multilineTextAlignment(.center)
                        if errorIsQuota, let url = UserFacingError.pricingURL {
                            Link("Upgrade plan", destination: url)
                                .font(.rpCaption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .padding()
            // The AI result is the payoff — crossfade to the before/after card
            // instead of snapping when the enhanced image lands.
            .animation(.easeInOut(duration: 0.3), value: edited != nil)
        }
        .background(Theme.bg)
        .navigationTitle("AI Photo Studio")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { _ in loadPicked() }
        .onChange(of: customPrompt) { newValue in
            if newValue.count > 600 { customPrompt = String(newValue.prefix(600)) }
        }
        .sheet(isPresented: $showSignIn) {
            SignInView {
                enhance()
            }
        }
    }

    /// One tappable chip per edit — six options don't fit a segmented control.
    private var editChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Edit.allCases) { e in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { edit = e }
                        Haptics.selection()
                    } label: {
                        Text(e.label)
                            .font(.rpCaption.weight(.semibold))
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .background(edit == e ? Theme.accent : Theme.accentSoft, in: Capsule())
                            .foregroundStyle(edit == e ? Color.white : Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48, weight: .light)).foregroundStyle(Theme.accent)
            Text("Turn a listing photo into a twilight, blue-sky, or green-lawn shot — or declutter it, stage it virtually, and describe any edit in your own words.")
                .font(.rpBody).foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center).padding(.horizontal)
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose a photo", systemImage: "photo.on.rectangle")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.accent).foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.top, 40)
    }

    private func resultCard(_ img: UIImage) -> some View {
        VStack(spacing: 12) {
            Text("Before → After").font(.rpKicker).foregroundStyle(Theme.inkDim)
            if let original {
                HStack(spacing: 8) {
                    Image(uiImage: original).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Image(uiImage: img).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Image(uiImage: img).resizable().scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button {
                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                Haptics.success()
            } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.accent).foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            ShareLink(item: Image(uiImage: img),
                      preview: SharePreview("Enhanced photo", image: Image(uiImage: img))) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button("Try another look") { edited = nil }
                .font(.rpBody).foregroundStyle(Theme.accent).padding(.top, 2)
        }
    }

    private func loadPicked() {
        guard let item = pickerItem else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let ui = UIImage(data: data) {
                await MainActor.run { original = ui; edited = nil; errorMsg = nil; errorIsQuota = false }
            }
        }
    }

    /// AI edits are metered per account — a signed-out user gets the sign-in
    /// sheet first (the edit runs right after), not a 401 error string.
    private func enhanceTapped() {
        if needsSignIn {
            showSignIn = true
            return
        }
        enhance()
    }

    private func enhance() {
        guard let original else { return }
        isWorking = true; errorMsg = nil; errorIsQuota = false
        let selectedEdit = edit
        let selectedStyle = stageStyle
        let prompt = String(customPromptTrimmed.prefix(600))
        Task {
            do {
                let scaled = Self.downscaled(original, maxDimension: 2048)
                guard let jpeg = scaled.jpegData(compressionQuality: 0.9) else {
                    throw NSError(domain: "AIPhoto", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Couldn't read that photo."])
                }
                let outB64 = try await model.api.aiPhotoEdit(
                    imageBase64: jpeg.base64EncodedString(), mime: "image/jpeg", edit: selectedEdit.rawValue,
                    style: selectedEdit == .stage ? selectedStyle.rawValue : nil,
                    prompt: selectedEdit == .custom ? prompt : nil)
                guard let outData = Data(base64Encoded: outB64), let outImg = UIImage(data: outData) else {
                    throw NSError(domain: "AIPhoto", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The AI didn't return an image. Try again."])
                }
                await MainActor.run { edited = outImg; isWorking = false; Haptics.success() }
            } catch {
                await MainActor.run {
                    errorMsg = UserFacingError.message(error)
                    errorIsQuota = UserFacingError.isQuota(error)
                    isWorking = false
                    if UserFacingError.isUnauthorized(error) { showSignIn = true }
                }
            }
        }
    }

    /// Downscale so the base64 upload stays small (and cheaper) without visible loss.
    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        let longest = max(w, h)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

// MARK: - Agent Card
// The card buyers see at the end of every flythrough. Lives here (in an
// already-compiled file) rather than a new .swift so it can't get dropped from
// the build target. Stored in UserDefaults; read into the player at share time.
//
// ONE ORG, ONE HOSTED CARD: the server keeps a single `orgs.brand_kit`, while the
// app keeps a card per business type (a restaurant's card is separate from a
// real-estate agent's). To keep hosted pages coherent, only the card of the
// org's PRIMARY business type is pushed to the brand kit. The primary type is
// whatever `SpaceType.current` was the first time a card was saved (stored under
// `brand.primaryType`); the card editor offers "Use this card on hosted tours"
// to move it. Cards for other types are used for in-app previews only.

struct AgentCard {
    var name: String
    var brokerage: String
    var phone: String
    var email: String
    var website: String
    var instagram: String = ""
    var linkedin: String = ""
    var tiktok: String = ""

    static let fieldNames = ["name", "brokerage", "phone", "email", "website", "instagram", "linkedin", "tiktok"]

    /// UserDefaults key of the business type whose card mirrors to the hosted brand kit.
    static let primaryTypeKey = "brand.primaryType"
    /// Snapshot of the last payload pushed to PATCH /me/brand (skip identical pushes).
    static let lastPushedKey = "brand.lastPushed"

    /// Storage key NAMESPACED by business type, so each industry keeps its own
    /// card — a restaurant's card is separate from a real-estate agent's.
    /// Real estate uses the original un-namespaced keys so any card set up
    /// before this change is preserved.
    static func key(_ field: String, for type: SpaceType) -> String {
        type == .realEstate ? "agent.\(field)" : "agent.\(type.rawValue).\(field)"
    }

    static func key(_ field: String) -> String { key(field, for: SpaceType.current) }

    static func card(for type: SpaceType) -> AgentCard {
        let d = UserDefaults.standard
        return AgentCard(name: d.string(forKey: key("name", for: type)) ?? "",
                         brokerage: d.string(forKey: key("brokerage", for: type)) ?? "",
                         phone: d.string(forKey: key("phone", for: type)) ?? "",
                         email: d.string(forKey: key("email", for: type)) ?? "",
                         website: d.string(forKey: key("website", for: type)) ?? "",
                         instagram: d.string(forKey: key("instagram", for: type)) ?? "",
                         linkedin: d.string(forKey: key("linkedin", for: type)) ?? "",
                         tiktok: d.string(forKey: key("tiktok", for: type)) ?? "")
    }

    static var current: AgentCard { card(for: SpaceType.current) }

    // MARK: Hosted brand kit (one per org)

    /// The business type whose card the hosted pages show. nil until a card has
    /// been pushed once.
    static var primaryBrandType: SpaceType? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: primaryTypeKey) else { return nil }
            return SpaceType(rawValue: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: primaryTypeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: primaryTypeKey)
            }
        }
    }

    /// The fields PATCH /me/brand accepts (empty string clears server-side).
    var brandFields: [String: String] {
        ["name": name, "brokerage": brokerage, "phone": phone,
         "email": email, "website": website, "instagram": instagram,
         "linkedin": linkedin, "tiktok": tiktok]
    }

    /// Push the card for `type` to the org's hosted brand kit — but ONLY when it
    /// is set (never erase the hosted card with an empty editor, audit F-C-05)
    /// and ONLY when `type` is the org's primary type (adopting `type` as primary
    /// when none is recorded yet). `force` re-pushes even if nothing changed.
    /// Best-effort, fire-and-forget: offline or signed-out keeps the local card
    /// and the next edit retries.
    @MainActor
    static func syncToBrandKit(for type: SpaceType, api: APIClient, force: Bool = false) {
        guard Config.useLiveBackend, AuthStore.currentAccessToken != nil else { return }
        let card = Self.card(for: type)
        guard card.isSet else { return }
        if let primary = primaryBrandType {
            guard primary == type else { return }
        } else {
            primaryBrandType = type   // first card ever saved → this is the org's primary type
        }
        let fields = card.brandFields
        let signature = fieldNames.map { fields[$0] ?? "" }.joined(separator: "\u{1F}")
        if !force, UserDefaults.standard.string(forKey: lastPushedKey) == signature { return }
        Task.detached {
            do {
                try await api.updateBrand(fields)
                UserDefaults.standard.set(signature, forKey: lastPushedKey)
            } catch {
                // Keep the local card; the next edit or launch retries.
            }
        }
    }

    // MARK: Social links (accept a full URL, a domain, or a @handle)
    var instagramURL: URL? { Self.socialURL(instagram, base: "https://instagram.com/") }
    var tiktokURL: URL? { Self.socialURL(tiktok, base: "https://tiktok.com/@") }
    var linkedinURL: URL? { Self.socialURL(linkedin, base: "https://linkedin.com/in/") }

    private static func socialURL(_ raw: String, base: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: t) }
        // "instagram.com/me", "www.tiktok.com/@me", "linkedin.com/in/me" are
        // URLs missing their scheme — never prefix them with the network's host
        // (that produced https://instagram.com/instagram.com/me, audit F-C-19).
        if looksLikeHost(t) { return URL(string: "https://" + t) }
        let handle = t.hasPrefix("@") ? String(t.dropFirst()) : t
        guard !handle.isEmpty else { return nil }
        return URL(string: base + handle)
    }

    /// A bare domain / path ("instagram.com/me", "www.x.com/me", "mysite.com")
    /// vs. a handle ("sarah.mitchell", "@sarah"). Handles may contain dots, so
    /// only a path separator, a www. prefix or a well-known TLD marks a host.
    private static func looksLikeHost(_ t: String) -> Bool {
        if t.hasPrefix("@") { return false }
        let lower = t.lowercased()
        if lower.hasPrefix("www.") { return true }
        if lower.contains("/") { return true }
        let tlds = [".com", ".net", ".org", ".io", ".co", ".app", ".me", ".tv", ".us", ".uk",
                    ".ca", ".au", ".de", ".fr", ".es", ".it", ".nl", ".biz", ".info",
                    ".realtor", ".homes", ".realestate", ".bar", ".restaurant", ".fit"]
        return tlds.contains { lower.hasSuffix($0) }
    }

    // MARK: Headshot (saved to disk, ~512px) — per business type
    static func headshotURL(for type: SpaceType) -> URL {
        let file = type == .realEstate
            ? "agent-headshot.jpg"
            : "agent-headshot-\(type.rawValue).jpg"
        return FileStore.documents.appendingPathComponent(file)
    }
    static var headshotURL: URL { headshotURL(for: SpaceType.current) }

    var hasHeadshot: Bool { FileManager.default.fileExists(atPath: Self.headshotURL.path) }
    var headshotBase64: String? {
        guard let data = try? Data(contentsOf: Self.headshotURL) else { return nil }
        return data.base64EncodedString()
    }

    static func saveHeadshot(_ image: UIImage) {
        let maxDim: CGFloat = 512
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return }
        let scale = min(1, maxDim / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let scaled = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        if let data = scaled.jpegData(compressionQuality: 0.85) {
            try? data.write(to: headshotURL, options: .atomic)
        }
    }
    static func removeHeadshot() { try? FileManager.default.removeItem(at: headshotURL) }

    // MARK: Website
    var websiteURL: URL? {
        let t = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        let hasScheme = lower.hasPrefix("http://") || lower.hasPrefix("https://")
        return URL(string: hasScheme ? t : "https://\(t)")
    }
    var websiteDisplay: String {
        (websiteURL?.host ?? website).replacingOccurrences(of: "www.", with: "")
    }

    var isSet: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// "AP" from "Aaron Pilkington". Falls back to a bullet if empty.
    var initials: String {
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        let first = parts.first.map { String($0.prefix(1)) } ?? ""
        let last = parts.count > 1 ? String(parts[parts.count - 1].prefix(1)) : ""
        let combined = (first + last).uppercased()
        return combined.isEmpty ? "•" : combined
    }

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? "there" }

    /// "Demo Realty Group · (555) 012-3456" — drops whichever part is empty.
    var brokerageLine: String {
        [brokerage, phone].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct AgentCardEditorView: View {
    // Keys namespaced by the current business type (AgentCard.key) so editing
    // the restaurant card never touches the real-estate card. The editor is
    // pushed fresh each time, so these resolve to the active industry.
    @EnvironmentObject private var model: AppModel
    @AppStorage(AgentCard.key("name")) private var name = ""
    @AppStorage(AgentCard.key("brokerage")) private var brokerage = ""
    @AppStorage(AgentCard.key("phone")) private var phone = ""
    @AppStorage(AgentCard.key("email")) private var email = ""
    @AppStorage(AgentCard.key("website")) private var website = ""
    @AppStorage(AgentCard.key("instagram")) private var instagram = ""
    @AppStorage(AgentCard.key("linkedin")) private var linkedin = ""
    @AppStorage(AgentCard.key("tiktok")) private var tiktok = ""
    @AppStorage(AgentCard.primaryTypeKey) private var primaryTypeRaw = ""

    @State private var pickerItem: PhotosPickerItem?
    @State private var headshot: UIImage?

    /// The type this editor was opened for (fixed at push time, like the keys).
    private let editingType = SpaceType.current

    private var primaryType: SpaceType? { SpaceType(rawValue: primaryTypeRaw) }
    private var isPrimary: Bool { primaryType == nil || primaryType == editingType }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Theme.accent.opacity(0.18))
                        if let headshot {
                            Image(uiImage: headshot).resizable().scaledToFill().clipShape(Circle())
                        } else {
                            Image(systemName: "person.fill").font(.title2).foregroundStyle(Theme.accent)
                        }
                    }
                    .frame(width: 60, height: 60)

                    VStack(alignment: .leading, spacing: 6) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label(headshot == nil ? "Add photo" : "Change photo", systemImage: "camera")
                        }
                        if headshot != nil {
                            Button(role: .destructive) {
                                AgentCard.removeHeadshot(); headshot = nil; pickerItem = nil
                            } label: {
                                Label("Remove", systemImage: "trash").font(.rpCaption)
                            }
                        }
                    }
                    Spacer()
                }
            } header: {
                Text(editingType.profilePhotoLabel)
            } footer: {
                // Honest: there is no upload path for the photo yet — hosted
                // tour pages render initials (audit F-C-06).
                Text("Shows in the app and in your in-app previews. Hosted tour pages show your initials for now — photo upload is coming.")
            }

            Section {
                TextField(editingType.profileNameLabel, text: $name)
                    .textContentType(.name)
                TextField(editingType.profileOrgLabel, text: $brokerage)
                    .textContentType(.organizationName)
                TextField("Phone", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                TextField("Email (optional)", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                TextField("Website (optional)", text: $website)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Your details")
            } footer: {
                Text("This is the card \(editingType.customerNoun) see at the end of every tour — how they reach you to \(editingType.ctaTitle.lowercased()). Phone and email become tap-to-call and tap-to-email.")
            }

            Section {
                socialField("Instagram", "camera.aperture", $instagram)
                socialField("LinkedIn", "briefcase", $linkedin)
                socialField("TikTok", "music.note", $tiktok)
            } header: {
                Text("Social")
            } footer: {
                Text("Paste a full link, a domain like instagram.com/you, or just your @handle. These show on your profile and on your hosted tours.")
            }

            if let primaryType, primaryType != editingType {
                Section {
                    Button {
                        AgentCard.primaryBrandType = editingType
                        AgentCard.syncToBrandKit(for: editingType, api: model.api, force: true)
                        Haptics.selection()
                    } label: {
                        Label("Use this card on hosted tours", systemImage: "globe")
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("Your hosted tour pages currently show your \(primaryType.displayName) card. Rendprop hosts one card per account; this \(editingType.displayName) card is used for in-app previews until you switch.")
                }
            }

            Section {
                AgentCardPreview(
                    card: AgentCard(name: name, brokerage: brokerage, phone: phone, email: email, website: website),
                    headshot: headshot)
                    .padding(.vertical, 6)
            } header: {
                Text("Preview (in-app)")
            } footer: {
                Text(isPrimary
                     ? "Hosted pages show the same card with your initials instead of the photo."
                     : "Hosted pages show your \(primaryType?.displayName ?? "primary") card.")
            }
        }
        .navigationTitle(editingType.profileCardName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { headshot = UIImage(contentsOfFile: AgentCard.headshotURL(for: editingType).path) }
        .onDisappear {
            // Sync the card to the org's brand kit so it renders on every
            // HOSTED share link — the public tour page reads these fields
            // (2026-08-26 audit P0-1). Only when the card is SET and only for
            // the org's primary business type (audit F-C-05: an empty editor
            // dismissed on a second business type used to erase the hosted card).
            AgentCard.syncToBrandKit(for: editingType, api: model.api)
        }
        .onChange(of: pickerItem) { newItem in
            guard let newItem else { return }
            let type = editingType
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    AgentCard.saveHeadshot(img)
                    await MainActor.run { headshot = UIImage(contentsOfFile: AgentCard.headshotURL(for: type).path) }
                }
            }
        }
    }

    private func socialField(_ label: String, _ icon: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            TextField(label, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }
    }
}

/// Mirrors the end-card look inside the player so the agent sees exactly what
/// buyers will see.
struct AgentCardPreview: View {
    let card: AgentCard
    var headshot: UIImage? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.18))
                if let headshot {
                    Image(uiImage: headshot).resizable().scaledToFill().clipShape(Circle())
                } else {
                    Text(card.isSet ? card.initials : "•")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(card.isSet ? card.name : "Your name")
                    .font(.rpHeadline)
                    .foregroundStyle(card.isSet ? Theme.ink : Theme.inkDim)
                Text(card.brokerageLine.isEmpty ? "\(SpaceType.current.businessLabel) · phone" : card.brokerageLine)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                if card.websiteURL != nil {
                    Text(card.websiteDisplay)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Profile tab (the friendly "about me / contact card" view)
struct ProfileView: View {
    @EnvironmentObject var model: AppModel
    // Observed so the card reloads the moment the business type changes.
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @State private var card = AgentCard.current
    @State private var headshot: UIImage?
    @State private var portfolioURL: URL?
    @State private var showPortfolioShare = false
    @State private var isBuildingPortfolio = false
    @State private var portfolioNote: String?

    /// Exactly the listings the exporter will include — the button count and
    /// the export can never disagree again (audit F-C-13).
    private var shareable: [Listing] { PortfolioExporter.eligible(model.listings) }
    /// Real listings of this type that are NOT shareable (unpublished or sold).
    private var realCount: Int {
        model.listings.filter { !$0.isSample && $0.belongsToCurrentType }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    VStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Theme.accent.opacity(0.18))
                            if let headshot {
                                Image(uiImage: headshot).resizable().scaledToFill().clipShape(Circle())
                            } else {
                                Text(card.isSet ? card.initials : "•")
                                    .font(.system(size: 34, design: .rounded).weight(.bold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .frame(width: 96, height: 96)

                        Text(card.isSet ? card.name : "Set up your card").font(.rpTitle)
                        if !card.brokerageLine.isEmpty {
                            Text(card.brokerageLine).font(.rpBody).foregroundStyle(Theme.inkDim)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    socialRow

                    NavigationLink { AgentCardEditorView() } label: {
                        Label(card.isSet ? "Edit card" : "Set up card", systemImage: "pencil")
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.accent).foregroundStyle(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if Config.useLiveBackend {
                        NavigationLink { LeadsView() } label: {
                            Label("Your leads", systemImage: "person.crop.circle.badge.plus")
                                .font(.rpBody.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    if !shareable.isEmpty {
                        Button {
                            buildPortfolio()
                        } label: {
                            HStack(spacing: 8) {
                                if isBuildingPortfolio { ProgressView().tint(Theme.accent) }
                                Label("Share my portfolio (\(shareable.count))", systemImage: "square.and.arrow.up")
                            }
                            .font(.rpBody.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(isBuildingPortfolio)
                        Text("One page with your \(shareable.count == 1 ? "published \(SpaceType.current.spaceNoun)" : "\(shareable.count) published \(SpaceType.current.spaceNoun)s") — each opens its tour. Shared as a file you can send to \(SpaceType.current.customerNoun).")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .multilineTextAlignment(.center)
                    } else if realCount > 0 {
                        Text("Publish a tour to share your portfolio — only published, active \(SpaceType.current.spaceNoun)s are included.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }

                    if let portfolioNote {
                        Text(portfolioNote)
                            .font(.rpCaption).foregroundStyle(Theme.warn)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .background(Theme.bg)
            .onAppear {
                card = AgentCard.current
                headshot = UIImage(contentsOfFile: AgentCard.headshotURL.path)
                // Heal older installs: push the card into the org brand kit so
                // HOSTED tour pages show it (website link included) without
                // requiring an edit first. Only the primary type's card, only
                // when set, and skipped when nothing changed since the last push.
                AgentCard.syncToBrandKit(for: SpaceType.current, api: model.api)
            }
            .onChange(of: spaceTypeRaw) { _ in
                card = AgentCard.current   // load THIS industry's card
                headshot = UIImage(contentsOfFile: AgentCard.headshotURL.path)
            }
            .sheet(isPresented: $showPortfolioShare) {
                if let u = portfolioURL { ShareSheet(items: [u]) }
            }
        }
    }

    /// The export inlines every main photo — build it off the main thread so
    /// the tab doesn't freeze on a big portfolio.
    private func buildPortfolio() {
        guard !isBuildingPortfolio else { return }
        isBuildingPortfolio = true
        portfolioNote = nil
        let listings = model.listings
        let agent = AgentCard.current
        Task {
            let url = await Task.detached(priority: .userInitiated) {
                PortfolioExporter.build(listings: listings, agent: agent)
            }.value
            await MainActor.run {
                isBuildingPortfolio = false
                if let url {
                    portfolioURL = url
                    showPortfolioShare = true
                } else {
                    portfolioNote = "Couldn't build the portfolio page. Try again."
                }
            }
        }
    }

    private var socialRow: some View {
        // (name, icon, url) — the name doubles as the VoiceOver label, since
        // these links are icon-only.
        let links: [(name: String, icon: String, url: URL?)] = [
            ("Website", "globe", card.websiteURL),
            ("Instagram", "camera.aperture", card.instagramURL),
            ("LinkedIn", "briefcase", card.linkedinURL),
            ("TikTok", "music.note", card.tiktokURL),
        ]
        return HStack(spacing: 14) {
            ForEach(links.indices, id: \.self) { i in
                if let url = links[i].url {
                    Link(destination: url) {
                        Image(systemName: links[i].icon)
                            .font(.title3).foregroundStyle(Theme.accent)
                            .frame(width: 48, height: 48)
                            .background(Theme.accentSoft, in: Circle())
                    }
                    .accessibilityLabel(Text(links[i].name))
                }
            }
        }
    }
}

// MARK: - Portfolio share (one page with all listings)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Builds a self-contained HTML portfolio of the agent's active listings —
/// main photos embedded, each linking to its tour. Shareable as a file today;
/// becomes a hosted URL once the backend ships.
enum PortfolioExporter {
    /// The ONE filter both the Profile button and the export use: this
    /// industry's real, unsold, PUBLISHED listings (a tour with no real server
    /// slug is skipped — never a fabricated /f/<uuid> link, audit 2026-08-26).
    static func eligible(_ listings: [Listing]) -> [Listing] {
        listings.filter {
            !$0.isSample && !$0.isSold && $0.belongsToCurrentType && $0.serverShareURL != nil
        }
    }

    static func build(listings: [Listing], agent: AgentCard) -> URL? {
        let active = eligible(listings)
        guard !active.isEmpty else { return nil }

        let cards = active.map { l -> String in
            var img = "<div class=\"ph ph-empty\">RENDPROP</div>"
            if let url = l.mainPhotoURL, let b64 = photoBase64(url) {
                img = "<div class=\"ph\" style=\"background-image:url('data:image/jpeg;base64,\(b64)')\"></div>"
            }
            // esc() the server URL too — it lands in an href and a buggy/hostile
            // server response shouldn't be able to inject markup into the export.
            let tour = esc(l.serverShareURL?.absoluteString ?? "")
            let price = l.price.cents > 0 ? " · " + esc(l.price.formatted) : ""
            return """
            <a class="card" href="\(tour)" target="_blank" rel="noopener">\(img)<div class="meta"><div class="addr">\(esc(l.address))</div><div class="sub">\(esc(l.subtitleLine))\(price)</div></div></a>
            """
        }.joined(separator: "\n")

        var avatar = ""
        if let b64 = agent.headshotBase64 {
            avatar = "<div class=\"avatar\" style=\"background-image:url('data:image/jpeg;base64,\(b64)')\"></div>"
        } else if agent.isSet {
            avatar = "<div class=\"avatar\">\(esc(agent.initials))</div>"
        }
        let contact = [agent.brokerageLine, agent.email].filter { !$0.isEmpty }.map { esc($0) }.joined(separator: " · ")
        let header = agent.isSet
            ? "<header>\(avatar)<div><div class=\"nm\">\(esc(agent.name))</div><div class=\"ct\">\(contact)</div></div></header>"
            : ""

        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(agent.isSet ? agent.name : "My Listings")) · Rendprop</title>
        <style>
          :root{--accent:#7c4dff}
          *{box-sizing:border-box;margin:0;padding:0}
          body{font-family:-apple-system,system-ui,sans-serif;background:#f6f6f8;color:#12121a;padding:20px;max-width:760px;margin:0 auto}
          header{display:flex;align-items:center;gap:14px;margin-bottom:22px}
          .avatar{width:56px;height:56px;border-radius:50%;background:#ece6ff;background-size:cover;background-position:center;display:flex;align-items:center;justify-content:center;font-weight:700;color:var(--accent)}
          header .nm{font-size:20px;font-weight:700}
          header .ct{font-size:13px;color:#6b6b78;margin-top:2px}
          .grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}
          @media(max-width:520px){.grid{grid-template-columns:1fr}}
          .card{display:block;background:#fff;border-radius:16px;overflow:hidden;text-decoration:none;color:inherit;box-shadow:0 6px 18px rgba(0,0,0,.06)}
          .ph{height:160px;background:#ece6ff;background-size:cover;background-position:center;display:flex;align-items:center;justify-content:center}
          .ph-empty{color:var(--accent);font-weight:700;letter-spacing:.15em;font-size:13px}
          .meta{padding:12px 14px}
          .addr{font-weight:650;font-size:15px}
          .sub{color:#6b6b78;font-size:13px;margin-top:3px}
          footer{text-align:center;color:#9a9aa6;font-size:12px;margin-top:24px}
        </style></head><body>
        \(header)
        <div class="grid">\(cards)</div>
        <footer>Made with Rendprop</footer>
        </body></html>
        """

        let out = FileStore.documents.appendingPathComponent("rendprop-portfolio.html")
        do {
            try html.write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }

    /// Main photos can be 12 MP; a portfolio card is 160 px tall. Downscale to
    /// ~800 px and re-encode so the shared file stays a few hundred KB per card.
    private static func photoBase64(_ url: URL) -> String? {
        guard let image = UIImage(contentsOfFile: url.path) else {
            return (try? Data(contentsOf: url))?.base64EncodedString()
        }
        let longest = max(image.size.width, image.size.height)
        let target: CGFloat = 800
        let scaled: UIImage
        if longest > target, longest > 0 {
            let scale = target / longest
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            scaled = UIGraphicsImageRenderer(size: size).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        } else {
            scaled = image
        }
        return scaled.jpegData(compressionQuality: 0.72)?.base64EncodedString()
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Business type picker
// Reached from Settings → Business type (and the Home tab menu switches the
// same key). Pick what you show off, and the whole app re-themes — samples,
// tab identity, fields, area tags, and the tour's call-to-action. Lives in
// this in-target file (new-file rule).
struct BusinessTypeView: View {
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @EnvironmentObject var model: AppModel

    private var current: SpaceType { SpaceType(rawValue: spaceTypeRaw) ?? .realEstate }
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("What do you show off?")
                    .font(.rpTitle)
                    .foregroundStyle(Theme.ink)
                Text("Pick your business — Rendprop becomes an app built just for it. Your listings for every type are kept; the list shows the selected type.")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(SpaceType.allCases) { type in
                        Button {
                            spaceTypeRaw = type.rawValue
                            model.reseedSamples()
                            Haptics.selection()
                        } label: {
                            typeCard(type)
                        }
                        .buttonStyle(ScalePressStyle())
                    }
                }

                previewCard
            }
            .padding()
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .navigationTitle("Business type")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func typeCard(_ type: SpaceType) -> some View {
        let selected = type == current
        return VStack(alignment: .leading, spacing: 8) {
            Image(systemName: type.systemImage)
                .font(.system(size: 26))
                .foregroundStyle(selected ? Color.white : Theme.accent)
            Text(type.displayName)
                .font(.rpHeadline)
                .foregroundStyle(selected ? Color.white : Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(type.pitch)
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.85) : Theme.inkDim)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(selected ? Theme.accent : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.border)
        )
        .shadow(color: selected ? Theme.accent.opacity(0.28) : Color.black.opacity(0.05),
                radius: selected ? 10 : 6, x: 0, y: 4)
        // Selecting a business re-themes the whole app — let the picked card's
        // fill/glow settle in rather than snapping as the grid reseeds.
        .animation(.easeInOut(duration: 0.22), value: selected)
        .accessibilityLabel(Text("\(type.displayName). \(type.pitch)\(selected ? ". Selected" : "")"))
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("How \(current.displayName) mode works", systemImage: current.systemImage)
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)

            VStack(alignment: .leading, spacing: 6) {
                Text("TOUR STOPS \(current.customerNoun.uppercased()) CAN JUMP TO")
                    .font(.rpKicker).foregroundStyle(Theme.inkDim)
                chipsRow(Array(current.quickTags.prefix(6)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("DETAILS YOU CAN SHOW")
                    .font(.rpKicker).foregroundStyle(Theme.inkDim)
                chipsRow(current.showsPropertyDetails
                         ? ["Beds", "Baths", "Sq ft", "Price"]
                         : Array(current.detailFields.prefix(5).map { $0.label }))
            }

            HStack(spacing: 8) {
                Text("YOUR TOUR'S BUTTON")
                    .font(.rpKicker).foregroundStyle(Theme.inkDim)
                Spacer()
                Text(current.ctaTitle)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(Color.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
    }

    private func chipsRow(_ items: [String]) -> some View {
        // Simple wrapping via a vertical stack of horizontal lines would need
        // layout math; a horizontal scroll keeps it one-line and simple.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.accentSoft, in: Capsule())
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
            }
        }
    }
}
