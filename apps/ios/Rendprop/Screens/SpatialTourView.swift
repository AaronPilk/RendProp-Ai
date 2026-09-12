import SwiftUI
import ARKit

/// The product path is listing-scoped and separate from the diagnostic export
/// lab. Captures flow to a durable uploader; opening 3D waits for a real server
/// artifact, never a timer or a synthetic "completed" placeholder.
///
/// Before a scan button is offered the screen asks the server whether 3D rooms
/// can be generated at all. A phone that scans, uploads every frame and only
/// then learns at `/start` that the service is switched off has wasted the
/// owner's afternoon, so "not available" is shown plainly up front.
struct SpatialTourView: View {
    let listing: Listing
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var uploads = SpatialUploadCoordinator.shared
    @State private var jobs: [SpatialJob] = []
    @State private var roomLabel = "Living room"
    @State private var captureHandoff: SpatialCaptureHandoff?
    @State private var captureOpenedAt: Date?
    @State private var captureOwner: String?
    @State private var captureHandedOff = false
    @State private var limitNotice: SpatialLimitNotice?
    @State private var capability: SpatialCapability?
    @State private var capabilityError: String?
    @State private var checkingCapability = false
    @State private var viewer: SpatialViewerPresentation?
    @State private var reviewing: SpatialJob?
    @State private var message: String?
    @State private var loading = false
    @State private var preparing = false
    @State private var mutation = false
    // Spatial's own switch. It hard-blocks cellular, unlike the Settings key
    // `wifiOnlyUploads`, which only asks before a cellular upload.
    @AppStorage(SpatialUploadPreferences.wifiOnlyKey) private var wifiOnly = SpatialUploadPreferences.wifiOnlyDefault
    // The last server answer. Lets a phone that was confirmed once still scan
    // while offline; a phone never confirmed (or last told "no") waits.
    @AppStorage("spatialCapabilityConfirmed") private var capabilityConfirmedBefore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    // A non-textual glyph: `view.3d` draws the characters "3D",
                    // which read as "3D 3D walkthrough" next to this title.
                    Label("3D walkthrough", systemImage: "cube.transparent")
                        .font(.rpTitle).foregroundStyle(.white)
                    Text("Scan rooms. Walk through them.")
                        .font(.rpBody).foregroundStyle(.white.opacity(0.92))
                    Text(listing.address).font(.rpCaption).foregroundStyle(.white.opacity(0.82))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20).background(RPGradient.drone)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius + 4))

                if let capability, !capability.enabled {
                    disabledCard(capability)
                } else if capability == nil, capabilityError != nil, !capabilityConfirmedBefore {
                    unknownCapabilityCard
                } else {
                    captureCard
                }

                if let notice = limitNotice { limitCard(notice) }

                if let error = message ?? uploads.recoveryError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Needs attention", systemImage: "exclamationmark.circle")
                            .font(.rpHeadline).foregroundStyle(Theme.ink)
                        Text(error).font(.rpCaption).foregroundStyle(Theme.inkDim)
                        Button("Check again") { Task { await refresh() } }.tint(Theme.accent)
                    }.card().accessibilityIdentifier("spatial.error")
                }

                ForEach(uploads.records(for: listing.id)) { record in uploadCard(record) }

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
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("spatial.product.root")
        .sheet(item: $captureHandoff, onDismiss: {
            // Closed without a verified room: was the last attempt cut off by
            // the recorder's limit? Say so in plain words instead of silence.
            guard !captureHandedOff, let since = captureOpenedAt else { captureOpenedAt = nil; return }
            let owner = captureOwner
            captureOpenedAt = nil
            Task { await inspectCaptures(since: since, owner: owner) }
        }) { handoff in
            SpatialProductCapture(roomLabel: trimmedLabel) { url in
                guard handoff.accepts(presentationID: captureHandoff?.id, currentOwner: auth.userID) else { return }
                captureHandedOff = true
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
            capability = nil
            uploads.reconnect()
            await checkCapability()
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
            limitNotice = nil
            message = nil
        }
    }

    private var trimmedLabel: String { roomLabel.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var liveListing: Listing { model.listings.first(where: { $0.id == listing.id }) ?? listing }
    private var canScan: Bool {
        ARWorldTrackingConfiguration.isSupported && !trimmedLabel.isEmpty && !preparing && !checkingCapability
            && (capability?.enabled == true || (capability == nil && capabilityConfirmedBefore))
    }

    // MARK: Capture

    private var captureCard: some View {
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
            Text("Keep the phone steady, walk slowly, and avoid people, mirrors and personal documents. Scan each room separately. A scan stops by itself after 400 photos or 10 minutes, so keep each room short.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            Button {
                message = nil
                limitNotice = nil
                captureHandedOff = false
                captureOpenedAt = Date()
                captureOwner = auth.userID
                captureHandoff = .init(id: UUID(), ownerID: auth.userID)
            } label: {
                Label("Scan a room", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(!canScan)
            .accessibilityIdentifier("spatial.capture")
            if checkingCapability {
                ProgressView("Checking whether 3D rooms are available…").font(.rpCaption)
            } else if capability == nil, let capabilityError {
                Text("Couldn't confirm 3D availability just now (\(capabilityError)). Scanning still works because this phone was confirmed before; uploads wait for a connection.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .accessibilityIdentifier("spatial.capability.stale")
            }
            if !ARWorldTrackingConfiguration.isSupported {
                Text("Scanning needs an iPhone that supports AR world tracking. You can still open your completed 3D walkthroughs on this device.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .accessibilityIdentifier("spatial.capture.unsupported")
            }
            if preparing {
                ProgressView("Verifying capture and preparing upload…").font(.rpCaption)
            }
        }.card()
    }

    /// The server says no. No scan button, no room name, no toggle — just the
    /// reason in plain words and a way to check again later.
    private func disabledCard(_ capability: SpatialCapability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent").foregroundStyle(Theme.accent)
                Text("3D rooms aren't available yet")
                    .font(.rpHeadline).foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("spatial.disabled.title")
            }
            Text(capability.explanation)
                .font(.rpBody).foregroundStyle(Theme.inkDim)
                .accessibilityIdentifier("spatial.disabled.reason")
            Text("Nothing has been uploaded or generated. Your completed rooms, if any, still open below.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            Button("Check again") { Task { await checkCapability() } }
                .tint(Theme.accent).disabled(checkingCapability)
                .accessibilityIdentifier("spatial.disabled.check")
            if checkingCapability { ProgressView().tint(Theme.accent) }
        }.card().accessibilityIdentifier("spatial.disabled")
    }

    /// We could not ask, and this phone was never told yes. Waiting is more
    /// honest than a scan that may upload a whole room for nothing.
    private var unknownCapabilityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Couldn't check whether 3D rooms are available", systemImage: "wifi.exclamationmark")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
                .accessibilityIdentifier("spatial.capability.unknown")
            Text(capabilityError ?? "The 3D service did not answer.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            Text("Scanning waits until the service confirms it can generate rooms, so a scan is never uploaded for nothing.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            Button("Check again") { Task { await checkCapability() } }
                .tint(Theme.accent).disabled(checkingCapability)
                .accessibilityIdentifier("spatial.capability.check")
            if checkingCapability { ProgressView().tint(Theme.accent) }
        }.card()
    }

    /// The recorder stopped a scan at its own ceiling (400 photos / 10 min).
    /// Today it never marks such a capture exportable, so the honest answer is
    /// "scan again, shorter"; if a later recorder does mark it exportable the
    /// owner may continue with what was saved.
    private func limitCard(_ notice: SpatialLimitNotice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your scan reached the limit", systemImage: "hourglass.bottomhalf.filled")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
            if let usable = notice.usableCapture {
                Text("Scans stop by themselves after 400 photos or 10 minutes, and this one did. Everything up to that point was saved and checked, so you can upload this room as it is, or scan it again with a shorter walk.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                Button("Upload this room as it is") {
                    limitNotice = nil
                    Task { await enqueue(usable, capturedOwner: notice.ownerID) }
                }.tint(Theme.accent).disabled(preparing).accessibilityIdentifier("spatial.limit.upload")
                Button("Scan again instead") { limitNotice = nil }.tint(Theme.accent)
            } else {
                Text("Scans stop by themselves after 400 photos or 10 minutes, and this one did. The photos are saved on this phone, but a scan that hits the limit can't be uploaded, so please scan this room again with a shorter, slower walk.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                Button("OK") { limitNotice = nil }.tint(Theme.accent)
            }
        }.card().accessibilityIdentifier("spatial.limit")
    }

    private func uploadCard(_ record: SpatialUploadRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(record.roomLabel, systemImage: "arrow.up.circle").font(.rpHeadline)
            ProgressView(value: record.uploadProgress)
                .tint(Theme.accent)
                .accessibilityLabel("Verified photo upload progress")
            Text("\(record.confirmedCount) of \(record.frames.count) photos confirmed by the server")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            if record.isServiceUnavailable {
                // Same honest state as the capture card: a Resume button
                // here would only fail at `/start` the same way again.
                Text("3D rooms aren't available yet").font(.rpBody).foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("spatial.upload.unavailable")
                Text(record.failure ?? "Every photo is uploaded and your capture is saved on this phone.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                Button("Check again") { Task { await retryIfAvailable(record) } }
                    .tint(Theme.accent).disabled(checkingCapability)
                    .accessibilityIdentifier("spatial.upload.check")
            } else if let failure = record.failure {
                Text(failure).font(.rpCaption).foregroundStyle(Theme.inkDim)
                if record.isTerminalFailure {
                    Button("Clear this upload") { uploads.forget(record.id) }
                        .tint(Theme.accent).accessibilityIdentifier("spatial.upload.clear")
                    Text("Your saved scan stays on this phone. Scan the room again to try a fresh upload.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                } else if !record.isUserPaused {
                    Button("Resume upload") { uploads.retry(record.id) }
                        .tint(Theme.accent).accessibilityIdentifier("spatial.upload.resume")
                }
            } else {
                Text(record.allowCellular ? "Uploading in the background. Your original capture stays saved." : "Uploads wait for Wi-Fi. Your original capture stays saved.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
        }.card().accessibilityIdentifier("spatial.upload.\(record.id)")
    }

    private func roomCard(_ job: SpatialJob) -> some View {
        // The server still says "uploading" for a room whose every photo is
        // there but whose /start was refused as not configured. Say what is
        // actually happening rather than contradicting the upload card above.
        let stalled = uploads.records.contains { $0.jobID == job.id && $0.isServiceUnavailable }
        return VStack(alignment: .leading, spacing: 10) {
            Text(job.roomLabel).font(.rpHeadline).foregroundStyle(Theme.ink)
            Text(stalled ? "Uploaded — waiting for the 3D service to be switched on" : job.status.title)
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
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
                    Label("Open 3D walkthrough", systemImage: "cube.transparent")
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

    // MARK: Actions

    @MainActor private func checkCapability() async {
        guard !checkingCapability else { return }
        checkingCapability = true
        defer { checkingCapability = false }
        let owner = auth.userID
        do {
            let result = try await model.api.spatialCapability()
            guard auth.userID == owner, !Task.isCancelled else { return }
            capability = result
            capabilityError = nil
            capabilityConfirmedBefore = result.enabled
        } catch {
            guard auth.userID == owner, !Task.isCancelled else { return }
            capabilityError = error.localizedDescription
        }
    }
    /// Re-ask before waking a room that stopped at "not configured"; only a
    /// confirmed yes turns into another `/start`.
    @MainActor private func retryIfAvailable(_ record: SpatialUploadRecord) async {
        await checkCapability()
        if capability?.enabled == true { uploads.retry(record.id) }
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
            uploads.observeServerJobs(result, listingID: serverID)
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
    /// After the capture sheet closes without a verified room, look at what
    /// the recorder saved since it opened. Only a limit-stopped scan gets a
    /// notice; interrupted or failed attempts already told the owner on the
    /// capture screen.
    @MainActor private func inspectCaptures(since: Date, owner: String?) async {
        let found = await Task.detached(priority: .utility) { () -> (usable: URL?, hit: Bool) in
            guard let archive = try? CaptureArchive.local() else { return (nil, false) }
            var newest: CaptureArchiveEntry?
            var offset = 0
            while offset < 10 * CaptureArchive.pageSize {
                guard let page = try? archive.page(offset: offset) else { break }
                for entry in page.entries {
                    guard let created = entry.createdAt, created >= since.addingTimeInterval(-2) else { continue }
                    if newest.flatMap(\.createdAt).map({ created > $0 }) ?? true { newest = entry }
                }
                guard page.hasMore else { break }
                offset += CaptureArchive.pageSize
            }
            guard let newest, newest.status == "limit_reached" else { return (nil, false) }
            // Exportable only if the recorder says so; today it never does for
            // a limit-stopped scan, and this must not second-guess it.
            return (try? archive.validateForExport(id: newest.id), true)
        }.value
        guard found.hit, auth.userID == owner else { return }
        limitNotice = SpatialLimitNotice(usableCapture: found.usable, ownerID: owner)
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

/// A scan the recorder stopped at its ceiling. `usableCapture` is set only
/// when the archive re-verified it for export.
private struct SpatialLimitNotice {
    let usableCapture: URL?
    let ownerID: String?
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
