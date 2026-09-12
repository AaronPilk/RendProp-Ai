import SwiftUI
import ARKit

/// The product path is listing-scoped and separate from the diagnostic export
/// lab. Captures flow to a durable uploader; opening 3D waits for a real server
/// artifact, never a timer or a synthetic "completed" placeholder.
struct SpatialTourView: View {
    let listing: Listing
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var uploads = SpatialUploadCoordinator.shared
    @State private var jobs: [SpatialJob] = []
    @State private var roomLabel = "Living room"
    @State private var captureHandoff: SpatialCaptureHandoff?
    @State private var viewer: SpatialViewerPresentation?
    @State private var reviewing: SpatialJob?
    @State private var message: String?
    @State private var loading = false
    @State private var preparing = false
    @State private var mutation = false
    @State private var restartRecordID: UUID?
    @AppStorage("wifiOnlyUploads") private var wifiOnly = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    Label("3D walkthrough", systemImage: "view.3d")
                        .font(.rpTitle).foregroundStyle(.white)
                    Text("Scan rooms. Walk through them.")
                        .font(.rpBody).foregroundStyle(.white.opacity(0.92))
                    Text(listing.address).font(.rpCaption).foregroundStyle(.white.opacity(0.82))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20).background(RPGradient.drone)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius + 4))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Capture a room").font(.rpHeadline).foregroundStyle(Theme.ink)
                    Text("Room photos and measured camera positions upload automatically for private cloud generation. You can leave this screen while photos upload. Nothing is shared until you review and publish it.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    TextField("Room name", text: $roomLabel)
                        .textFieldStyle(.roundedBorder).textInputAutocapitalization(.words)
                        .accessibilityIdentifier("spatial.roomName")
                    Toggle("Upload on Wi-Fi only", isOn: $wifiOnly)
                        .font(.rpBody).tint(Theme.accent)
                        .accessibilityIdentifier("spatial.wifiOnly")
                    Text("Keep the phone steady, walk slowly, and avoid people, mirrors and personal documents. Scan each room separately.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    Button {
                        message = nil
                        captureHandoff = .init(id: UUID(), ownerID: auth.userID)
                    } label: {
                        Label("Scan a room", systemImage: "camera.viewfinder")
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!ARWorldTrackingConfiguration.isSupported || trimmedLabel.isEmpty || preparing)
                    .accessibilityIdentifier("spatial.capture")
                    if !ARWorldTrackingConfiguration.isSupported {
                        Text("Scanning needs an iPhone that supports AR world tracking. You can still open your completed 3D walkthroughs on this device.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .accessibilityIdentifier("spatial.capture.unsupported")
                    }
                    if preparing {
                        ProgressView("Verifying capture and preparing upload…").font(.rpCaption)
                    }
                }.card()

                if let error = message ?? uploads.recoveryError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Needs attention", systemImage: "exclamationmark.circle")
                            .font(.rpHeadline).foregroundStyle(Theme.ink)
                        Text(error).font(.rpCaption).foregroundStyle(Theme.inkDim)
                        Button("Check again") { Task { await refresh() } }.tint(Theme.accent)
                    }.card().accessibilityIdentifier("spatial.error")
                }

                ForEach(uploads.records(for: listing.id)) { record in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(record.roomLabel, systemImage: "arrow.up.circle").font(.rpHeadline)
                        ProgressView(value: record.uploadProgress)
                            .tint(Theme.accent)
                            .accessibilityLabel("Verified photo upload progress")
                        Text("\(record.confirmedCount) of \(record.frames.count) photos confirmed by the server")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        if let failure = record.failure {
                            Text(failure).font(.rpCaption).foregroundStyle(Theme.inkDim)
                            if !record.isUserPaused {
                                Button("Resume upload") { uploads.retry(record.id) }
                                    .tint(Theme.accent).accessibilityIdentifier("spatial.upload.resume")
                                if let frame = record.frames.first(where: { $0.restartRequired == true || $0.restartIntent != nil }),
                                   (frame.restartGeneration ?? 0) < 3 {
                                    Button("Restart interrupted photo…") { restartRecordID = record.id }
                                        .disabled(uploads.restartingFrame).tint(Theme.accent)
                                }
                            }
                        } else {
                            Text(record.allowCellular ? "Uploading in the background. Your original capture stays saved." : "Uploads wait for Wi-Fi. Your original capture stays saved.")
                                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        }
                    }.card().accessibilityIdentifier("spatial.upload.\(record.id)")
                }

                HStack {
                    Text("Your rooms").font(.rpHeadline)
                    Spacer()
                    Button("Refresh") { Task { await refresh() } }.disabled(loading)
                        .tint(Theme.accent).accessibilityIdentifier("spatial.refresh")
                }
                if loading && jobs.isEmpty { ProgressView("Checking your rooms…") }
                if !loading && jobs.isEmpty {
                    Text("Your completed rooms will appear here. A scan is the starting point; cloud generation creates the 3D space you can walk through.")
                        .font(.rpBody).foregroundStyle(Theme.inkDim).card()
                        .accessibilityIdentifier("spatial.empty")
                }
                ForEach(jobs) { job in roomCard(job) }
            }.padding()
        }
        .background(Theme.bg)
        .navigationTitle("3D walkthrough")
        .confirmationDialog("Restart one interrupted photo?", isPresented: Binding(get: { restartRecordID != nil }, set: { if !$0 { restartRecordID = nil } })) {
            Button("Restart photo upload") {
                if let id = restartRecordID { Task { await uploads.restartFailedFrame(id) } }
                restartRecordID = nil
            }
            Button("Keep capture", role: .cancel) { restartRecordID = nil }
        } message: {
            Text("Your room capture stays on this phone. We'll first check whether this photo already finished. One replacement uses a new upload allowance; the room and its other photos are kept. At most three restarts per photo.")
        }
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("spatial.product.root")
        .sheet(item: $captureHandoff) { handoff in
            SpatialProductCapture(roomLabel: trimmedLabel) { url in
                guard handoff.accepts(presentationID: captureHandoff?.id, currentOwner: auth.userID) else { return }
                captureHandoff = nil
                Task { await enqueue(url, capturedOwner: handoff.ownerID) }
            }
        }
        .sheet(item: $viewer) { value in
            NavigationStack {
                PlayerWebView(remoteURL: value.url)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(value.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { viewer = nil } } }
            }
        }
        .sheet(item: $reviewing) { job in
            SpatialPrivacyReview(job: job, api: model.api) { updated in
                replace(updated)
                reviewing = nil
            }
        }
        .task(id: auth.userID) {
            jobs = [] // No previous workspace's room survives an account switch.
            uploads.reconnect()
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                guard scenePhase == .active else { continue }
                await refresh(silent: true)
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { uploads.reconnect() }
        }
        .onChange(of: auth.userID) { _ in
            // A private capability is still a credential until it expires.
            // Tear down its web view immediately when the workspace changes.
            viewer = nil
            reviewing = nil
            captureHandoff = nil
            message = nil
        }
    }

    private var trimmedLabel: String { roomLabel.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var liveListing: Listing { model.listings.first(where: { $0.id == listing.id }) ?? listing }

    private func roomCard(_ job: SpatialJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.roomLabel).font(.rpHeadline).foregroundStyle(Theme.ink)
            Text(job.status.title).font(.rpCaption).foregroundStyle(Theme.inkDim)
            if job.status.isGenerating {
                ProgressView().tint(Theme.accent)
                Text("Cloud generation continues when you leave the app. We will show the room here when the server confirms it is ready.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            if job.status == .failed {
                Text(job.failureCode == "user_cancelled" ? "Stopped. Your capture is preserved; you can resume this room without scanning again." : "Generation stopped before a complete room was available. Your capture is preserved.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                if let failure = job.failureCode { Text("Reference: \(failure)").font(.rpCaption).foregroundStyle(Theme.inkDim) }
                if job.canRetry {
                    Button("Retry cloud generation") { Task { await recover(job, action: .retry) } }
                        .tint(Theme.accent).disabled(mutation).accessibilityIdentifier("spatial.retry.\(job.id)")
                    Text("Reuses your uploaded room. This starts the next cloud generation attempt, within your plan's limit.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                } else if job.retryAfter != nil && !job.canResume {
                    Text("The previous cloud run is still finishing. Retry will become available when the server confirms it can safely start again.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
                if job.canResume {
                    Button("Resume this room") { Task { await recover(job, action: .resume) } }
                        .tint(Theme.accent).disabled(mutation).accessibilityIdentifier("spatial.resume.\(job.id)")
                }
            }
            if job.canCancel {
                Button("Stop this room") { Task { await recover(job, action: .cancel) } }
                    .tint(Theme.accent).disabled(mutation).accessibilityIdentifier("spatial.cancel.\(job.id)")
                Text("Stops pending work without deleting your saved capture.").font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            if job.status == .review || job.status == .ready {
                Button { Task { await open(job) } } label: {
                    Label("Open 3D walkthrough", systemImage: "view.3d")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(mutation)
                    .accessibilityIdentifier("spatial.open.\(job.id)")
                Button("Review privacy and sharing") { reviewing = job }
                    .tint(Theme.accent).accessibilityIdentifier("spatial.review.\(job.id)")
                if job.status == .ready, job.privacyState == .approved, let url = job.shareURL {
                    ShareLink(item: url) { Label("Share 3D walkthrough", systemImage: "square.and.arrow.up") }
                        .tint(Theme.accent).accessibilityIdentifier("spatial.share.\(job.id)")
                } else if job.privacyState == .excluded {
                    Text("This room is excluded from sharing.").font(.rpCaption).foregroundStyle(Theme.inkDim)
                } else {
                    Text("Private — not shared.").font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
            }
        }.card()
    }

    @MainActor private func refresh(silent: Bool = false) async {
        guard !loading else { return }
        guard let serverID = liveListing.serverID else { jobs = []; return }
        let owner = auth.userID
        loading = true
        defer { loading = false }
        do {
            let result = try await model.api.spatialJobs(listingID: serverID)
            guard !Task.isCancelled, auth.userID == owner else { return }
            guard result.allSatisfy({ $0.listingID == serverID }) else { throw SpatialClientError.invalidResponse }
            jobs = result
            if !silent { message = nil }
        } catch {
            guard auth.userID == owner, !Task.isCancelled else { return }
            if !silent { message = error.localizedDescription }
        }
    }
    @MainActor private func enqueue(_ url: URL, capturedOwner: String?) async {
        preparing = true
        defer { preparing = false }
        do {
            guard let owner = capturedOwner, auth.userID == owner else { throw SpatialClientError.accountChanged }
            let serverID = try await model.ensureServerListing(liveListing)
            guard auth.userID == owner else { throw SpatialClientError.accountChanged }
            try await uploads.enqueue(capture: url, listingLocalID: listing.id, listingID: serverID,
                                      roomLabel: trimmedLabel, allowCellular: !wifiOnly)
            await refresh()
        } catch { message = error.localizedDescription }
    }
    @MainActor private func open(_ job: SpatialJob) async {
        mutation = true
        defer { mutation = false }
        let owner = auth.userID
        do {
            let fresh = try await model.api.spatialJob(id: job.id)
            guard auth.userID == owner, fresh.listingID == job.listingID else { throw SpatialClientError.accountChanged }
            guard let url = fresh.viewerURL, let revision = fresh.artifactRevision else { throw SpatialClientError.invalidResponse }
            replace(fresh)
            viewer = .init(url: url, title: fresh.roomLabel, sceneID: fresh.id, revision: revision)
        } catch { message = error.localizedDescription }
    }
    private enum RecoveryAction { case retry, cancel, resume }
    @MainActor private func recover(_ job: SpatialJob, action: RecoveryAction) async {
        guard !mutation else { return }
        mutation = true
        defer { mutation = false }
        let owner = auth.userID
        do {
            let result: SpatialJob
            switch action {
            case .retry:
                guard job.canRetry else { throw SpatialClientError.invalidResponse }
                result = try await model.api.retrySpatialJob(id: job.id, operationID: job.retryOperationID)
            case .cancel:
                guard job.canCancel else { throw SpatialClientError.invalidResponse }
                try uploads.pause(jobID: job.id)
                result = try await model.api.cancelSpatialJob(id: job.id)
            case .resume:
                guard job.canResume else { throw SpatialClientError.invalidResponse }
                result = try await model.api.resumeSpatialJob(id: job.id)
            }
            guard auth.userID == owner, result.id == job.id, result.listingID == job.listingID else {
                throw SpatialClientError.accountChanged
            }
            if case .cancel = action {
                guard result.status == .failed, result.failureCode == "user_cancelled" else { throw SpatialClientError.invalidResponse }
            }
            if case .resume = action {
                guard result.status == .uploading else { throw SpatialClientError.invalidResponse }
                try uploads.resume(jobID: job.id)
            }
            replace(result)
            message = nil
        } catch { message = error.localizedDescription }
    }
    private func replace(_ job: SpatialJob) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job }
    }
}

private struct SpatialViewerPresentation: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let sceneID: UUID
    let revision: UUID
    var expectation: SpatialViewerExpectation { .init(sceneID: sceneID, revision: revision, url: url) }
}

private struct SpatialProductCapture: View {
    let roomLabel: String
    let completed: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presentation = SpatialProductCapturePresentation()
    var body: some View {
        NavigationStack {
            SpatialProductCaptureController(controller: presentation.controller, completed: completed)
                .navigationTitle(roomLabel).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { presentation.controller.endPresentation(); dismiss() }
                    }
                }
        }.interactiveDismissDisabled()
    }
}
@MainActor private final class SpatialProductCapturePresentation: ObservableObject {
    let controller = SpatialCaptureViewController()
}
private struct SpatialProductCaptureController: UIViewControllerRepresentable {
    let controller: SpatialCaptureViewController
    let completed: (URL) -> Void
    func makeUIViewController(context: Context) -> SpatialCaptureViewController {
        controller.onVerifiedCapture = completed
        return controller
    }
    func updateUIViewController(_ uiViewController: SpatialCaptureViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: SpatialCaptureViewController, coordinator: ()) { controller.endPresentation() }
}

private struct SpatialPrivacyReview: View {
    let job: SpatialJob
    let api: APIClient
    let updated: (SpatialJob) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthStore.shared
    @State private var viewer: SpatialViewerPresentation?
    @State private var openedRevision: UUID?
    @State private var confirmed = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Review the actual room") {
                    Text("Walk through every angle. Check family photographs, mail, prescriptions, screens, mirrors and open cupboards before sharing.")
                    Button("Open private 3D preview") { Task { await openPreview() } }
                        .disabled(busy).accessibilityIdentifier("spatial.privacy.preview")
                    Toggle("I reviewed this room and it is safe to share", isOn: $confirmed)
                        .disabled(openedRevision != job.artifactRevision || busy)
                        .accessibilityIdentifier("spatial.privacy.confirm")
                    Text("If anything is private, keep the room private or exclude the whole room. A visual overlay is not a privacy redaction of the 3D file.")
                        .font(.footnote)
                }
                Section("Sharing") {
                    Button("Publish this reviewed room") { Task { await submit(exclude: false) } }
                        .disabled(!confirmed || openedRevision != job.artifactRevision || busy)
                        .accessibilityIdentifier("spatial.privacy.publish")
                    Button("Exclude room from sharing") { Task { await submit(exclude: true) } }
                        .disabled(busy).accessibilityIdentifier("spatial.privacy.exclude")
                    Button("Keep private") { dismiss() }.disabled(busy)
                }
                if busy { ProgressView("Saving privacy choices…") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .tint(Theme.accent)
            .navigationTitle("Privacy review").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .sheet(item: $viewer) { value in
                NavigationStack {
                    PlayerWebView(remoteURL: value.url, spatialExpectation: value.expectation, onSpatialReady: {
                        // URL fetch/load success does not count: the hosted
                        // renderer must confirm this exact active model drew.
                        guard viewer?.id == value.id, value.sceneID == job.id,
                              value.revision == job.artifactRevision else { return }
                        openedRevision = value.revision
                    }).ignoresSafeArea(edges: .bottom)
                        .navigationTitle(value.title).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { viewer = nil } } }
                }
            }
        }.interactiveDismissDisabled(busy)
    }
    @MainActor private func openPreview() async {
        busy = true
        defer { busy = false }
        let owner = auth.userID
        do {
            let fresh = try await api.spatialJob(id: job.id)
            guard auth.userID == owner, fresh.listingID == job.listingID else { throw SpatialClientError.accountChanged }
            guard fresh.artifactRevision == job.artifactRevision, let url = fresh.viewerURL else { throw SpatialClientError.invalidResponse }
            guard let revision = fresh.artifactRevision else { throw SpatialClientError.invalidResponse }
            confirmed = false
            openedRevision = nil
            viewer = .init(url: url, title: "Private · \(job.roomLabel)", sceneID: fresh.id, revision: revision)
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func submit(exclude: Bool) async {
        guard let revision = job.artifactRevision else { return }
        guard exclude || (confirmed && openedRevision == revision) else { return }
        busy = true
        defer { busy = false }
        let owner = auth.userID
        do {
            let request = SpatialReviewRequest(artifactRevision: revision, approved: !exclude,
                                               excludeRoom: exclude, redactions: [])
            var result = try await api.reviewSpatialJob(id: job.id, review: request)
            guard auth.userID == owner else { throw SpatialClientError.accountChanged }
            if !exclude {
                guard result.privacyState == .approved else { throw SpatialClientError.invalidResponse }
                result = try await api.publishSpatialJob(id: job.id, artifactRevision: revision)
                guard auth.userID == owner, result.shareURL != nil, result.status == .ready else { throw SpatialClientError.invalidResponse }
            } else if result.privacyState != .excluded || result.shareURL != nil { throw SpatialClientError.invalidResponse }
            updated(result)
        } catch { self.error = error.localizedDescription }
    }
}
