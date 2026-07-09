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
                LabeledContent("Agent card", value: "Coming soon")
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
