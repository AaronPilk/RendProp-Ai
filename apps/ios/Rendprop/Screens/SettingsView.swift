import SwiftUI

struct SettingsView: View {
    @AppStorage("wifiOnlyUploads") private var wifiOnlyUploads = true
    @AppStorage("uploadMode") private var uploadMode = Config.UploadMode.simulate.rawValue
    @AppStorage("maxQualityCapture") private var maxQualityCapture = false
    @AppStorage("hasOnboarded") private var hasOnboarded = true
    @EnvironmentObject var uploads: UploadManager

    var body: some View {
        Form {
            Section("Uploads") {
                Toggle("Only upload big videos on Wi-Fi", isOn: $wifiOnlyUploads)
                if let s = uploads.state {
                    HStack {
                        Text("Current upload")
                        Spacer()
                        Text("\(s.status.rawValue) · \(s.fractionComplete.formatted(.percent.precision(.fractionLength(0))))")
                            .foregroundStyle(Theme.inkDim)
                    }
                    if s.status == .uploading {
                        Button("Pause upload") { uploads.pause() }
                    } else if s.status == .paused || s.status == .failed {
                        Button("Resume upload") { uploads.resume() }
                    }
                    Button("Cancel upload", role: .destructive) { uploads.cancel() }
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
                Label("One continuous take; end on the best exterior", systemImage: "house")
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

    static var current: AgentCard {
        let d = UserDefaults.standard
        return AgentCard(name: d.string(forKey: "agent.name") ?? "",
                         brokerage: d.string(forKey: "agent.brokerage") ?? "",
                         phone: d.string(forKey: "agent.phone") ?? "",
                         email: d.string(forKey: "agent.email") ?? "")
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

    var body: some View {
        Form {
            Section {
                TextField("Full name", text: $name)
                    .textContentType(.name)
                TextField("Brokerage", text: $brokerage)
                    .textContentType(.organizationName)
                TextField("Phone", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                TextField("Email (optional)", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Your details")
            } footer: {
                Text("This is the card buyers see at the end of every flythrough — how they reach you to book a showing.")
            }

            Section("How it looks on your tour") {
                AgentCardPreview(card: AgentCard(name: name, brokerage: brokerage, phone: phone, email: email))
                    .padding(.vertical, 6)
            }
        }
        .navigationTitle("Agent card")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Mirrors the end-card look inside the player so the agent sees exactly what
/// buyers will see.
struct AgentCardPreview: View {
    let card: AgentCard

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.18))
                Text(card.isSet ? card.initials : "•")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(card.isSet ? card.name : "Your name")
                    .font(.rpHeadline)
                    .foregroundStyle(card.isSet ? Theme.ink : Theme.inkDim)
                Text(card.brokerageLine.isEmpty ? "Brokerage · phone" : card.brokerageLine)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
