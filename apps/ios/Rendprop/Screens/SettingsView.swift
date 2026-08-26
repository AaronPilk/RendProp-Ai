import SwiftUI
import UIKit
import PhotosUI

struct SettingsView: View {
    @AppStorage("wifiOnlyUploads") private var wifiOnlyUploads = true
    @AppStorage("maxQualityCapture") private var maxQualityCapture = false
    @AppStorage("hasOnboarded") private var hasOnboarded = true
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    // Drives .preferredColorScheme at the app root (RendpropApp reads the same key).
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
    @EnvironmentObject var uploads: UploadManager
    @EnvironmentObject var model: AppModel

    // Real signed-in state for the Account row (never the dev-stub placeholder).
    @ObservedObject private var auth = AuthStore.shared

    // Live-backend usage/cost (contract: GET /me). Loaded only when useLiveBackend.
    @State private var usage: UsageSummary?
    @State private var usageFailed = false

    // Account deletion flow (App Store Guideline 5.1.1(v) — in-app deletion).
    @State private var showDeleteConfirm = false
    @State private var isDeletingAccount = false
    @State private var deleteErrorMessage: String?
    @State private var showDeleteError = false
    @State private var showAccountDeleted = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(SpaceType.current.displayName, systemImage: SpaceType.current.systemImage)
                    Spacer()
                    Text("Home tab")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                }
            } header: {
                Text("Business type")
            } footer: {
                Text("Switch your business type any time from the Home tab — the whole app re-themes instantly.")
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
                Text("System follows your iPhone. The whole app re-themes instantly.")
            }

            Section("Uploads") {
                Toggle("Only upload big videos on Wi-Fi", isOn: $wifiOnlyUploads)
                if let s = uploads.state {
                    HStack {
                        Text("Current upload")
                        Spacer()
                        Text("\(s.status == .done ? "Complete" : s.status.rawValue.capitalized) · \(s.fractionComplete.formatted(.percent.precision(.fractionLength(0))))")
                            .foregroundStyle(s.status == .done ? Theme.good : Theme.inkDim)
                    }
                    if s.status == .uploading {
                        Button("Pause upload") { uploads.pause() }
                    } else if s.status == .paused || s.status == .failed {
                        Button("Resume upload") { uploads.resume() }
                    }
                    // No cancel once it's finished — nothing left to cancel.
                    if s.status != .done {
                        Button("Cancel upload", role: .destructive) { uploads.cancel() }
                    }
                }
            }

            Section("Brand kit") {
                LabeledContent("Accent", value: "Rendprop Gold")
                NavigationLink {
                    AgentCardEditorView()
                } label: {
                    LabeledContent(SpaceType.current.profileCardName,
                                   value: AgentCard.current.isSet ? AgentCard.current.name : "Set up")
                }
                // TODO Phase 2: org brand kit (logo, colors, CTA) — master spec 4.5
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

            Section("How to shoot a great walkthrough") {
                Label("Walk at your normal pace — steady beats slow", systemImage: "figure.walk")
                Label("No fast spins — turn like you're showing a friend around", systemImage: "arrow.triangle.turn.up.right.diamond")
                Label("Phone at chest height, keep the bubble level", systemImage: "level")
                Label("Lights on, blinds open", systemImage: "lightbulb")
                Label("One continuous take; end on your best shot", systemImage: SpaceType.current.systemImage)
            }
            .font(.rpBody)

            Section("Account") {
                LabeledContent("Account", value: accountStatusLabel)
                Button {
                    hasOnboarded = false   // flips the root back to the intro
                } label: {
                    Label("Watch the intro again", systemImage: "play.rectangle")
                }
                if isDeletingAccount {
                    HStack {
                        Text("Deleting account…").foregroundStyle(Theme.inkDim)
                        Spacer()
                        ProgressView()
                    }
                } else {
                    Button("Delete account", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }

            if Config.useLiveBackend {
                usageSection
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
                Text("Standard capture is 4K · 30fps — your finished tour is smoothed to 60fps either way, and video files are half the size.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadUsage() }
        .alert("Delete account?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account, published tours, and data.")
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
            Text("Your account and data have been removed.")
        }
    }

    // MARK: - Usage (live backend only)

    @ViewBuilder
    private var usageSection: some View {
        Section {
            if let usage {
                LabeledContent("AI spend this month", value: usage.aiSpend.formatted)
                LabeledContent("Renders", value: "\(usage.renderCount ?? 0)")
                LabeledContent("Leads", value: "\(usage.leadCount ?? 0)")
                if let plan = usage.planName, !plan.isEmpty {
                    LabeledContent("Plan", value: plan)
                }
            } else if usageFailed {
                Text("Couldn't load usage. Pull to refresh or check your connection.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            } else {
                HStack {
                    Text("Loading usage…").foregroundStyle(Theme.inkDim)
                    Spacer()
                    ProgressView()
                }
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("This month's AI spend, renders, and leads for your account.")
        }
    }

    @MainActor
    private func loadUsage() async {
        guard Config.useLiveBackend else { return }
        do {
            usage = try await model.api.me()
            usageFailed = false
        } catch {
            usageFailed = true
        }
    }

    // MARK: - Account (App Store Guideline 5.1.1(v): in-app account deletion)

    /// What the Account row shows — the real state, never a dev placeholder.
    private var accountStatusLabel: String {
        guard Config.enableAuth, auth.isSignedIn else { return "Guest" }
        let name = auth.userName.trimmingCharacters(in: .whitespaces)
        return (name.isEmpty || name == "Dev Agent") ? "Signed in with Apple" : name
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

    /// Server-side erasure per the backend contract: `DELETE {base}/me` with the
    /// bearer JWT + apikey → 200 {"ok":true}. Built inline (URLSession) on
    /// purpose so the APIClient protocol stays untouched.
    private func requestServerAccountDeletion() async throws {
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
        let (_, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw AccountDeleteError(status: status) }
    }

    @MainActor
    private func deleteAccount() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        // 1. Server-side erasure first (account, published tours, uploads).
        //    If it fails, STOP — local data stays intact and the alert offers
        //    Retry, so nothing is half-deleted.
        if Config.useLiveBackend, Config.enableAuth, auth.isSignedIn {
            do {
                try await requestServerAccountDeletion()
            } catch {
                deleteErrorMessage = "Your account was NOT deleted. \(error.localizedDescription)"
                showDeleteError = true
                return
            }
        }

        // 2. Local erasure: session, listings + videos + tours, profile cards.
        //    (Guest / signed-out: this local wipe is the whole deletion.)
        if uploads.state != nil { uploads.cancel() }
        AuthStore.shared.signOut()
        wipeLocalData()
        Haptics.success()
        showAccountDeleted = true   // OK → hasOnboarded = false
    }

    /// Remove everything the app stored on this device. Demo samples are
    /// reseeded afterwards so the app still works as a fresh install.
    @MainActor
    private func wipeLocalData() {
        // In-memory state — every didSet re-persists, so the snapshot on disk
        // ends up empty too (PersistentStore never saves samples).
        model.listings.removeAll()
        model.assets.removeAll()
        model.tours.removeAll()
        model.renders.removeAll()
        model.reseedSamples()

        // Recorded/imported videos + the exported portfolio page.
        let fm = FileManager.default
        try? fm.removeItem(at: FileStore.recordingsDir)
        try? fm.removeItem(at: FileStore.importsDir)
        try? fm.removeItem(at: FileStore.documents.appendingPathComponent("rendprop-portfolio.html"))

        // Listing photos + AI edits, enhanced/aerial render masters, and the
        // personalized player-demo cache — "account deleted" must leave none of
        // the user's media on the device (audit 2026-08-26).
        try? fm.removeItem(at: FileStore.documents.appendingPathComponent("Photos"))
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: caches.appendingPathComponent("player-demo"))
        }
        if let docs = try? fm.contentsOfDirectory(at: FileStore.documents,
                                                  includingPropertiesForKeys: nil) {
            for url in docs {
                let n = url.lastPathComponent
                if (n.hasPrefix("enhanced-") || n.hasPrefix("aerial-") || n.hasPrefix("preview-")) {
                    try? fm.removeItem(at: url)
                }
            }
        }

        // Profile cards + headshots for EVERY business type (keys are
        // namespaced per industry; real estate uses the legacy bare keys).
        let d = UserDefaults.standard
        let fields = ["name", "brokerage", "phone", "email", "website", "instagram", "linkedin", "tiktok"]
        for type in SpaceType.allCases {
            for field in fields {
                let key = type == .realEstate ? "agent.\(field)" : "agent.\(type.rawValue).\(field)"
                d.removeObject(forKey: key)
            }
            let headshot = type == .realEstate ? "agent-headshot.jpg" : "agent-headshot-\(type.rawValue).jpg"
            try? fm.removeItem(at: FileStore.documents.appendingPathComponent(headshot))
        }
        d.removeObject(forKey: "auth.userName")
        d.removeObject(forKey: "auth.orgName")
    }
}

// MARK: - AI Photo Studio
// Twilight / sky-replace / lawn-repair on a listing photo via the `ai-photo`
// edge function (Gemini). Inlined here (in a compiled file) so it can't be
// dropped from the build target — same rule as AgentCard below.

struct AIPhotoStudioView: View {
    @EnvironmentObject var model: AppModel

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

    private var customPromptTrimmed: String {
        customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
                    Button(action: enhance) {
                        HStack {
                            if isWorking { ProgressView().tint(.white) }
                            Text(isWorking ? "Enhancing…" : "Enhance photo")
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
                    Text(errorMsg).font(.rpCaption).foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.center)
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
                await MainActor.run { original = ui; edited = nil; errorMsg = nil }
            }
        }
    }

    private func enhance() {
        guard let original else { return }
        isWorking = true; errorMsg = nil
        Task {
            do {
                let scaled = Self.downscaled(original, maxDimension: 2048)
                guard let jpeg = scaled.jpegData(compressionQuality: 0.9) else {
                    throw NSError(domain: "AIPhoto", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Couldn't read that photo."])
                }
                let outB64 = try await model.api.aiPhotoEdit(
                    imageBase64: jpeg.base64EncodedString(), mime: "image/jpeg", edit: edit.rawValue,
                    style: edit == .stage ? stageStyle.rawValue : nil,
                    prompt: edit == .custom ? String(customPromptTrimmed.prefix(600)) : nil)
                guard let outData = Data(base64Encoded: outB64), let outImg = UIImage(data: outData) else {
                    throw NSError(domain: "AIPhoto", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The AI didn't return an image. Try again."])
                }
                await MainActor.run { edited = outImg; isWorking = false; Haptics.success() }
            } catch {
                await MainActor.run { errorMsg = error.localizedDescription; isWorking = false }
            }
        }
    }

    /// Downscale so the base64 upload stays small (and cheaper) without visible loss.
    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        let longest = max(w, h)
        guard longest > maxDimension else { return image }
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

struct AgentCard {
    var name: String
    var brokerage: String
    var phone: String
    var email: String
    var website: String
    var instagram: String = ""
    var linkedin: String = ""
    var tiktok: String = ""

    /// Storage key NAMESPACED by business type, so each industry keeps its own
    /// card — a restaurant's card is separate from a real-estate agent's.
    /// Real estate uses the original un-namespaced keys so any card set up
    /// before this change is preserved.
    static func key(_ field: String) -> String {
        SpaceType.current == .realEstate
            ? "agent.\(field)"
            : "agent.\(SpaceType.current.rawValue).\(field)"
    }

    static var current: AgentCard {
        let d = UserDefaults.standard
        return AgentCard(name: d.string(forKey: key("name")) ?? "",
                         brokerage: d.string(forKey: key("brokerage")) ?? "",
                         phone: d.string(forKey: key("phone")) ?? "",
                         email: d.string(forKey: key("email")) ?? "",
                         website: d.string(forKey: key("website")) ?? "",
                         instagram: d.string(forKey: key("instagram")) ?? "",
                         linkedin: d.string(forKey: key("linkedin")) ?? "",
                         tiktok: d.string(forKey: key("tiktok")) ?? "")
    }

    // MARK: Social links (accept a full URL or a @handle)
    var instagramURL: URL? { Self.socialURL(instagram, base: "https://instagram.com/") }
    var tiktokURL: URL? { Self.socialURL(tiktok, base: "https://tiktok.com/@") }
    var linkedinURL: URL? { Self.socialURL(linkedin, base: "https://linkedin.com/in/") }

    private static func socialURL(_ raw: String, base: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.lowercased().hasPrefix("http") { return URL(string: t) }
        let handle = t.hasPrefix("@") ? String(t.dropFirst()) : t
        return URL(string: base + handle)
    }

    // MARK: Headshot (saved to disk, ~512px) — per business type
    static var headshotURL: URL {
        let file = SpaceType.current == .realEstate
            ? "agent-headshot.jpg"
            : "agent-headshot-\(SpaceType.current.rawValue).jpg"
        return FileStore.documents.appendingPathComponent(file)
    }
    var hasHeadshot: Bool { FileManager.default.fileExists(atPath: Self.headshotURL.path) }
    var headshotBase64: String? {
        guard let data = try? Data(contentsOf: Self.headshotURL) else { return nil }
        return data.base64EncodedString()
    }

    static func saveHeadshot(_ image: UIImage) {
        let maxDim: CGFloat = 512
        let scale = min(1, maxDim / max(image.size.width, image.size.height))
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
        let t = website.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return URL(string: t.lowercased().hasPrefix("http") ? t : "https://\(t)")
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
    @AppStorage(AgentCard.key("name")) private var name = ""
    @AppStorage(AgentCard.key("brokerage")) private var brokerage = ""
    @AppStorage(AgentCard.key("phone")) private var phone = ""
    @AppStorage(AgentCard.key("email")) private var email = ""
    @AppStorage(AgentCard.key("website")) private var website = ""
    @AppStorage(AgentCard.key("instagram")) private var instagram = ""
    @AppStorage(AgentCard.key("linkedin")) private var linkedin = ""
    @AppStorage(AgentCard.key("tiktok")) private var tiktok = ""

    @State private var pickerItem: PhotosPickerItem?
    @State private var headshot: UIImage?

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
                Text(SpaceType.current.profilePhotoLabel)
            }

            Section {
                TextField(SpaceType.current.profileNameLabel, text: $name)
                    .textContentType(.name)
                TextField(SpaceType.current.profileOrgLabel, text: $brokerage)
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
                Text("This is the card \(SpaceType.current.customerNoun) see at the end of every tour — how they reach you to \(SpaceType.current.ctaTitle.lowercased()).")
            }

            Section {
                socialField("Instagram", "camera.aperture", $instagram)
                socialField("LinkedIn", "briefcase", $linkedin)
                socialField("TikTok", "music.note", $tiktok)
            } header: {
                Text("Social")
            } footer: {
                Text("Paste a full link or just your @handle. These show on your profile and on every shared tour.")
            }

            Section("How it looks on your tour") {
                AgentCardPreview(
                    card: AgentCard(name: name, brokerage: brokerage, phone: phone, email: email, website: website),
                    headshot: headshot)
                    .padding(.vertical, 6)
            }
        }
        .navigationTitle(SpaceType.current.profileCardName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { headshot = UIImage(contentsOfFile: AgentCard.headshotURL.path) }
        .onChange(of: pickerItem) { newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    AgentCard.saveHeadshot(img)
                    await MainActor.run { headshot = UIImage(contentsOfFile: AgentCard.headshotURL.path) }
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

    private var shareableCount: Int {
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

                    if shareableCount > 0 {
                        Button {
                            portfolioURL = PortfolioExporter.build(listings: model.listings, agent: AgentCard.current)
                            showPortfolioShare = portfolioURL != nil
                        } label: {
                            Label("Share my portfolio (\(shareableCount))", systemImage: "square.and.arrow.up")
                                .font(.rpBody.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        Text("One link with all your \(SpaceType.current.spaceNoun)s — send it to \(SpaceType.current.customerNoun) to browse everything you have.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
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
    static func build(listings: [Listing], agent: AgentCard) -> URL? {
        // Only the current industry's tours — a real-estate portfolio never
        // bundles in food places.
        // Only PUBLISHED tours — a portfolio must never contain fabricated,
        // never-existed /f/<uuid-prefix> links that 404 for every recipient
        // (audit 2026-08-26). A tour with no real server slug is skipped.
        let active = listings.filter {
            !$0.isSample && !$0.isSold && $0.belongsToCurrentType && $0.serverShareURL != nil
        }
        guard !active.isEmpty else { return nil }

        let cards = active.map { l -> String in
            var img = "<div class=\"ph ph-empty\">RENDPROP</div>"
            if let url = l.mainPhotoURL, let data = try? Data(contentsOf: url) {
                img = "<div class=\"ph\" style=\"background-image:url('data:image/jpeg;base64,\(data.base64EncodedString())')\"></div>"
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

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Business tab
// The business type is a first-class tab: pick what you show off, and the
// whole app re-themes — samples, tab identity, fields, area tags, and the
// tour's call-to-action. Lives in this in-target file (new-file rule).
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
                Text("Pick your business — Rendprop becomes an app built just for it.")
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
        .navigationTitle("Business")
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
