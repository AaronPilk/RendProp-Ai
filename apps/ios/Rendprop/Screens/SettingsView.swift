import SwiftUI

struct SettingsView: View {
    @AppStorage("wifiOnlyUploads") private var wifiOnlyUploads = true
    @AppStorage("uploadMode") private var uploadMode = Config.UploadMode.simulate.rawValue
    @EnvironmentObject var uploads: UploadManager

    var body: some View {
        Form {
            Section("Uploads") {
                Toggle("Wi-Fi only for large uploads", isOn: $wifiOnlyUploads)
                Picker("Upload mode", selection: $uploadMode) {
                    ForEach(Config.UploadMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
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
                Label("Walk slow and steady — match the haptic rhythm", systemImage: "figure.walk")
                Label("Phone at chest height, keep the bubble level", systemImage: "level")
                Label("One continuous take, sweep doorways slowly", systemImage: "arrow.triangle.turn.up.right.diamond")
                Label("Lights on, blinds open", systemImage: "lightbulb")
                Label("End on the best exterior for a strong finish", systemImage: "house")
            }
            .font(.rpBody)

            Section("Account") {
                LabeledContent("Signed in as", value: "Dev Agent")
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
                LabeledContent("Version", value: "0.1.0 (1)")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
