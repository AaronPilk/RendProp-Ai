import SwiftUI
import UIKit
import PhotosUI

struct SettingsView: View {
    @AppStorage("wifiOnlyUploads") private var wifiOnlyUploads = true
    @AppStorage("uploadMode") private var uploadMode = Config.UploadMode.simulate.rawValue
    @AppStorage("maxQualityCapture") private var maxQualityCapture = false
    @AppStorage("hasOnboarded") private var hasOnboarded = true
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @EnvironmentObject var uploads: UploadManager

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(SpaceType.current.displayName, systemImage: SpaceType.current.systemImage)
                    Spacer()
                    Text("Business tab")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                }
            } header: {
                Text("Business type")
            } footer: {
                Text("Switch your business type any time from the Business tab — the whole app re-themes instantly.")
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
                    LabeledContent("Agent card",
                                   value: AgentCard.current.isSet ? AgentCard.current.name : "Set up")
                }
                // TODO Phase 2: org brand kit (logo, colors, CTA) — master spec 4.5
            }

            Section("Notifications") {
                LabeledContent("Render ready", value: "Push · Phase 2")
                LabeledContent("New lead", value: "Push + SMS · Phase 2")
                // TODO Phase 2: APNs — Config.enablePush (master spec Part 18)
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
                LabeledContent("Signed in as", value: "Dev Agent")
                Button {
                    hasOnboarded = false   // flips the root back to the intro
                } label: {
                    Label("Watch the intro again", systemImage: "play.rectangle")
                }
                Button("Delete account", role: .destructive) {
                    // TODO Phase 2: real account deletion + GDPR erasure across
                    // Stream/R2/DB (master spec Part 15) — App Store requirement.
                }
            }

            Section("Legal") {
                Link("Terms of Service", destination: URL(string: "https://rendprop.app/terms")!)
                Link("Privacy Policy", destination: URL(string: "https://rendprop.app/privacy")!)
                Text("Only record spaces you have the right to record and publish.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }

            Section {
                Toggle("Max quality capture (4K · 60fps)", isOn: $maxQualityCapture)
                Picker("Upload mode", selection: $uploadMode) {
                    ForEach(Config.UploadMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                LabeledContent("Version", value: "0.1.0 (1)")
            } header: {
                Text("Advanced")
            } footer: {
                Text("Standard capture is 4K · 30fps — your finished tour is smoothed to 60fps either way, and video files are half the size.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
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

    static var current: AgentCard {
        let d = UserDefaults.standard
        return AgentCard(name: d.string(forKey: "agent.name") ?? "",
                         brokerage: d.string(forKey: "agent.brokerage") ?? "",
                         phone: d.string(forKey: "agent.phone") ?? "",
                         email: d.string(forKey: "agent.email") ?? "",
                         website: d.string(forKey: "agent.website") ?? "",
                         instagram: d.string(forKey: "agent.instagram") ?? "",
                         linkedin: d.string(forKey: "agent.linkedin") ?? "",
                         tiktok: d.string(forKey: "agent.tiktok") ?? "")
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

    // MARK: Headshot (saved to disk, ~512px)
    static var headshotURL: URL { FileStore.documents.appendingPathComponent("agent-headshot.jpg") }
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

    /// "Skyway Realty Group · (555) 012-3456" — drops whichever part is empty.
    var brokerageLine: String {
        [brokerage, phone].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct AgentCardEditorView: View {
    @AppStorage("agent.name") private var name = ""
    @AppStorage("agent.brokerage") private var brokerage = ""
    @AppStorage("agent.phone") private var phone = ""
    @AppStorage("agent.email") private var email = ""
    @AppStorage("agent.website") private var website = ""
    @AppStorage("agent.instagram") private var instagram = ""
    @AppStorage("agent.linkedin") private var linkedin = ""
    @AppStorage("agent.tiktok") private var tiktok = ""

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
                Text("Headshot")
            }

            Section {
                TextField("Full name", text: $name)
                    .textContentType(.name)
                TextField(SpaceType.current.businessLabel, text: $brokerage)
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
        .navigationTitle("Agent card")
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
    @State private var card = AgentCard.current
    @State private var headshot: UIImage?
    @State private var portfolioURL: URL?
    @State private var showPortfolioShare = false

    private var shareableCount: Int { model.listings.filter { !$0.isSample }.count }

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
            .sheet(isPresented: $showPortfolioShare) {
                if let u = portfolioURL { ShareSheet(items: [u]) }
            }
        }
    }

    private var socialRow: some View {
        let links: [(String, URL?)] = [
            ("globe", card.websiteURL),
            ("camera.aperture", card.instagramURL),
            ("briefcase", card.linkedinURL),
            ("music.note", card.tiktokURL),
        ]
        return HStack(spacing: 14) {
            ForEach(links.indices, id: \.self) { i in
                if let url = links[i].1 {
                    Link(destination: url) {
                        Image(systemName: links[i].0)
                            .font(.title3).foregroundStyle(Theme.accent)
                            .frame(width: 48, height: 48)
                            .background(Theme.accentSoft, in: Circle())
                    }
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
        let active = listings.filter { !$0.isSample && !$0.isSold }
        guard !active.isEmpty else { return nil }

        let cards = active.map { l -> String in
            var img = "<div class=\"ph ph-empty\">RENDPROP</div>"
            if let url = l.mainPhotoURL, let data = try? Data(contentsOf: url) {
                img = "<div class=\"ph\" style=\"background-image:url('data:image/jpeg;base64,\(data.base64EncodedString())')\"></div>"
            }
            let tour = "https://rendprop.app/f/\(l.id.uuidString.prefix(8).lowercased())"
            let price = l.price.cents > 0 ? " · " + esc(l.price.formatted) : ""
            return """
            <a class="card" href="\(tour)" target="_blank" rel="noopener">\(img)<div class="meta"><div class="addr">\(esc(l.address))</div><div class="sub">\(esc(l.metaLine))\(price)</div></div></a>
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
                        .buttonStyle(.plain)
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
