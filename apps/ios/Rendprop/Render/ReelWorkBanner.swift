import SwiftUI

/// Describes measured shot progress, never progress inside a provider request.
enum ReelWorkBannerCopy {
    static func title(running: Bool, paused: Bool, ready: Bool, stitching: Bool,
                      completed: Int, total: Int) -> String {
        if paused { return "Video paused" }
        if ready { return "Your video is ready" }
        guard running else { return "Video needs attention" }
        let count = "\(min(max(0, completed), max(0, total))) of \(max(0, total)) photos ready"
        return stitching ? "Finishing video · \(count)" : "Making video · \(count)"
    }

    static func explanation(paused: Bool, running: Bool, ready: Bool = false) -> String {
        if paused {
            return "iOS paused local processing. Your saved requests and clips are kept. Reopen the video to resume."
        }
        if running {
            return "You can use other screens. Locking or leaving the app may pause local processing; saved requests remain recoverable."
        }
        if ready { return "Open the video to watch it." }
        return "Your saved work is kept. Open this video to see what happened and continue."
    }
}

/// A notification or banner may open only an existing, current-scope job's
/// available listing. Historical HUD suppression does not erase review access.
@MainActor enum ReelWorkReviewAdmission {
    static func bannerJob(visibleJobs: [ReelWorkJob], listings: [Listing]) -> ReelWorkJob? {
        let available = visibleJobs.filter { listing(jobID: $0.id, visibleJobs: visibleJobs, listings: listings) != nil }
        return available.first(where: { $0.running || $0.isServerRendering || $0.paused }) ?? available.last
    }

    static func job(jobID: UUID, visibleJobs: [ReelWorkJob], listings: [Listing]) -> ReelWorkJob? {
        guard listing(jobID: jobID, visibleJobs: visibleJobs, listings: listings) != nil else { return nil }
        return visibleJobs.first(where: { $0.id == jobID || $0.serverJob?.reply?.jobID == jobID })
    }

    /// A sheet that already admitted an exact job keeps that job while moving
    /// back to setup. This does not admit a new banner/notification target.
    static func presentedJob(jobID: UUID, jobs: [ReelWorkJob], listings: [Listing]) -> ReelWorkJob? {
        job(jobID: jobID, visibleJobs: jobs.filter(\.isContextCurrent), listings: listings)
    }

    static func listing(jobID: UUID, visibleJobs: [ReelWorkJob], listings: [Listing]) -> Listing? {
        guard let job = visibleJobs.first(where: { $0.id == jobID || $0.serverJob?.reply?.jobID == jobID }),
              let listing = listings.first(where: { $0.id == job.listingID }),
              !listing.isSample, listing.cloudUnavailable != true else { return nil }
        return listing
    }
}

struct ReelWorkBanner: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var jobs = ReelWorkQueue.shared
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var workspace = WorkspaceStore.shared
    @ObservedObject private var consent = AIConsent.shared
    @ObservedObject private var push = PushManager.shared
    @State private var reviewListing: Listing?
    @State private var reviewJobID: UUID?
    @State private var pendingReviewJobID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let job = ReelWorkReviewAdmission.bannerJob(visibleJobs: jobs.visibleJobs, listings: model.listings) {
                ReelWorkStatusRow(job: job, review: { open(job.id) }, dismiss: {
                    jobs.dismissResult(jobID: job.id)
                })
                if pendingReviewJobID != nil {
                    Text("Close the current sheet to review this video.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Theme.card)
                        .accessibilityIdentifier("reelWork.reviewPending")
                }
            }
        }
        .task(id: push.pendingReelJobID) { await reviewPendingNotification() }
        .task(id: pendingReviewJobID) { await reviewPendingBanner() }
        .onChange(of: auth.syncSessionRevision) { _ in invalidateReview() }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in invalidateReview() }
        .onChange(of: consent.isGranted) { _ in invalidateReview() }
        .sheet(item: Binding(get: { currentReviewListing }, set: { value in
            reviewListing = value
            if value == nil { reviewJobID = nil }
        })) { listing in
            // The view reconnects to the queue-owned job. Opening sends no new
            // generation and does not replace its selected JPEGs or shot order.
            if let id = reviewJobID,
               let job = ReelWorkReviewAdmission.presentedJob(jobID: id, jobs: jobs.jobs, listings: model.listings) {
                ReelStudioView(listing: listing,
                               photos: EnhancedPhoto.loadAll(listingID: listing.id),
                               extraClipURLs: listing.aerialURL.map { [$0] } ?? [],
                               reviewingJob: job)
                    .environmentObject(model)
            }
        }
    }

    private var currentReviewListing: Listing? {
        guard let id = reviewJobID, reviewListing != nil,
              let job = ReelWorkReviewAdmission.presentedJob(jobID: id, jobs: jobs.jobs, listings: model.listings) else { return nil }
        return model.listings.first { $0.id == job.listingID }
    }

    private func open(_ id: UUID) {
        guard let job = ReelWorkReviewAdmission.job(jobID: id, visibleJobs: jobs.reviewableJobs, listings: model.listings),
              let listing = ReelWorkReviewAdmission.listing(jobID: job.id, visibleJobs: jobs.reviewableJobs,
                                                           listings: model.listings) else { return }
        // Feature sheets may still be dismissing when the global button is
        // tapped. Keep this exact intent instead of silently discarding it.
        if NativePresentationAvailability.hasPresentedController {
            pendingReviewJobID = id
            return
        }
        // The local queue ID survives retiring the terminal server projection.
        // A notification may have opened this same work through a server alias.
        reviewJobID = job.id
        reviewListing = listing
        pendingReviewJobID = nil
    }

    private func reviewPendingBanner() async {
        while let id = pendingReviewJobID, !Task.isCancelled {
            guard ReelWorkReviewAdmission.listing(jobID: id, visibleJobs: jobs.reviewableJobs,
                                                 listings: model.listings) != nil else {
                pendingReviewJobID = nil
                return
            }
            if reviewListing == nil, !NativePresentationAvailability.hasPresentedController {
                open(id)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func invalidateReview() {
        jobs.reconcileIdentity()
        reviewListing = nil
        reviewJobID = nil
        pendingReviewJobID = nil
        push.clearPendingReelJob()
    }

    private func reviewPendingNotification() async {
        jobs.restoreServerJobs(model: model)
        while let id = push.pendingReelJobID, !Task.isCancelled {
            guard ReelWorkReviewAdmission.listing(jobID: id, visibleJobs: jobs.reviewableJobs,
                                                 listings: model.listings) != nil else {
                push.clearPendingReelJob()
                return
            }
            if reviewListing == nil, !NativePresentationAvailability.hasPresentedController {
                open(id)
                if let job = ReelWorkReviewAdmission.job(jobID: id, visibleJobs: jobs.reviewableJobs, listings: model.listings),
                   reviewJobID == job.id { push.clearPendingReelJob() }
                return
            }
            // A capture/share/purchase modal keeps its place. A notification
            // does not interrupt it or discard an edit to show reel progress.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}

private struct ReelWorkStatusRow: View {
    @ObservedObject var job: ReelWorkJob
    @ObservedObject private var push = PushManager.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let review: () -> Void
    let dismiss: () -> Void

    private var active: Bool { job.running || job.isServerRendering }
    private var headline: String {
        if job.usesPhotoMotion, active { return job.statusText }
        return ReelWorkBannerCopy.title(running: active, paused: job.paused,
            ready: job.phase == .done, stitching: job.phase == .stitching,
            completed: job.completedClips, total: job.totalClips)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                HStack(alignment: .center, spacing: 10) {
                    Group {
                        if active, job.usesPhotoMotion, !reduceMotion {
                            ProgressView().tint(Theme.accent)
                        } else {
                            Image(systemName: job.phase == .done ? "checkmark.circle.fill" : active ? (job.usesPhotoMotion ? "hourglass" : "film.stack") : "pause.circle")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .dynamicTypeSize(.large)
                    .frame(width: 20, height: 20).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline).font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(job.title).font(.rpCaption.weight(.medium)).foregroundStyle(Theme.inkDim)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Button(active ? "View" : "Review", action: review)
                        .font(.rpCaption.weight(.semibold))
                        .buttonStyle(RendpropPillButtonStyle(compact: true, horizontalPadding: 14))
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("reelWork.review")
                    if !active, !job.paused {
                        Button(action: dismiss) { Image(systemName: "xmark") }
                            .buttonStyle(RendpropPillButtonStyle(compact: true, horizontalPadding: 12))
                            .frame(minWidth: 44, minHeight: 44).accessibilityLabel("Dismiss video status")
                            .accessibilityIdentifier("reelWork.dismiss")
                    }
                }
            }
            if active, !job.usesPhotoMotion {
                ProgressView(value: job.fraction).tint(Theme.accent)
                    .accessibilityLabel("Video photo progress")
                    .accessibilityValue("\(job.completedClips) of \(job.totalClips) photos ready; \(job.percent) percent")
                if job.statusText != headline {
                    Text(job.statusText).font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if job.paused || (active && !job.isServerRendering) {
                Text(job.paused ? "Saved work is kept. Open to resume." : "Keep Rendprop open while processing.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if active || job.paused {
                if push.authorization == .notDetermined {
                    Button("Notify me when ready") { Task { await push.requestAuthorization() } }
                        .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
                        .buttonStyle(RendpropPillButtonStyle(compact: true, horizontalPadding: 14))
                        .frame(minHeight: 44).accessibilityIdentifier("reelWork.allowNotifications")
                } else if push.authorization == .denied {
                    Button("Enable completion alerts in Settings") { PushManager.openSystemSettings() }
                        .font(.rpCaption).foregroundStyle(Theme.accent)
                        .buttonStyle(RendpropPillButtonStyle(compact: true, horizontalPadding: 14))
                        .frame(minHeight: 44).accessibilityIdentifier("reelWork.notificationSettings")
                }
            }
        }
        .padding(12)
        .modifier(RendpropGlassSurface())
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reelWork.banner")
    }
}

// MARK: - Activity tab
struct NativeActivityView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ObservedObject private var activity = NativeActivityStore.shared
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var workspace = WorkspaceStore.shared
    @ObservedObject private var consent = AIConsent.shared
    @State private var reviewing: NativeActivityEntry?
    @State private var presentation = NativeActivityPresentationState()
    @State private var search = ""
    @State private var isVisible = false
    private var scope: NativePresentationScope { .init(actorID: auth.userID, orgID: WorkspaceContext.selectedOrgID) }
    private var scopedEntries: [NativeActivityEntry] { NativeActivityCatalog.scoped(activity.entries, scope: NativeActivityStore.currentScope) }
    private var matchingEntries: [NativeActivityEntry] { NativeActivityCatalog.scoped(scopedEntries, scope: NativeActivityStore.currentScope, search: search) }
    private var category: NativeActivityCategory { presentation.selectedCategory(entries: scopedEntries) }
    private var groups: [NativeActivityListingGroup] { NativeActivityCatalog.groups(matchingEntries, category: category) }
    private var detailBinding: Binding<NativeActivityEntry?> { Binding(get: { presentation.detail }, set: { presentation.detail = $0 }) }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicType.isAccessibilitySize ? 1 : 2), spacing: 8) {
                        ForEach(NativeActivityCategory.allCases) { choice in
                            Button { presentation.category = choice } label: {
                                HStack(spacing: 8) {
                                    Text(choice.title).font(.rpCaption.weight(.semibold))
                                    Spacer(minLength: 0)
                                    Text("\(NativeActivityCatalog.count(choice, entries: matchingEntries))")
                                        .font(.rpCaption.monospacedDigit())
                                }.frame(maxWidth: .infinity)
                            }
                            .buttonStyle(RendpropPillButtonStyle(selected: category == choice, compact: true, horizontalPadding: 12))
                            .accessibilityAddTraits(category == choice ? .isSelected : [])
                            .accessibilityIdentifier("activity.filter.\(choice.rawValue)")
                        }
                    }
                    if groups.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: search.isEmpty ? "tray" : "magnifyingglass").font(.title2).foregroundStyle(Theme.accent)
                            Text(search.isEmpty ? "No \(category == .attention ? "requests need attention" : category == .history ? "generation history yet" : category.title.lowercased() + " generations")" : "No matching properties")
                                .font(.rpBody.weight(.semibold))
                            if scopedEntries.isEmpty { Text("Your photo edits, videos and openings will appear here.").font(.rpCaption).foregroundStyle(Theme.inkDim) }
                        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 28)
                    } else {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(group.title).font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                                VStack(spacing: 0) {
                                    ForEach(group.entries) { entry in
                                        Button { presentation.showDetail(entry, scope: NativeActivityStore.currentScope) } label: {
                                            NativeActivityCompactRow(entry: entry)
                                        }.buttonStyle(.plain)
                                        if entry.id != group.entries.last?.id { Divider().padding(.leading, 54) }
                                    }
                                }.modifier(RendpropContentSurface())
                            }
                        }
                    }
                    if activity.storageUnavailable {
                        Label("Activity history could not be saved on this iPhone. Your original work records stay with each listing.", systemImage: "exclamationmark.triangle")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    }
                }.padding(16)
            }
            .background(Theme.bg).navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search properties")
            .refreshable { await activity.refreshAerialStatuses(); activity.synchronize() }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false; activity.suspendAerialRefresh() }
            .task(id: "\(presentation.pendingReview?.id ?? "none")|\(reviewing?.id ?? "none")|\(isVisible)|\(auth.syncSessionRevision)|\(WorkspaceContext.selectedOrgID?.uuidString ?? "local")|\(scenePhase == .active)|\(consent.revocationRevision)") {
                activity.attach(model: model)
                guard presentation.permitsForegroundRefresh(reviewingID: reviewing?.id), isVisible, scenePhase == .active else { return }
                while !Task.isCancelled && presentation.permitsForegroundRefresh(reviewingID: reviewing?.id) && isVisible && scenePhase == .active {
                    await activity.refreshAerialStatuses()
                    do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                }
            }
            .onChange(of: scope) { _ in presentation.reset(); reviewing = nil; search = ""; activity.synchronize() }
            .sheet(item: detailBinding, onDismiss: {
                reviewing = presentation.takeReview(entries: activity.entries, scope: NativeActivityStore.currentScope)
            }) { _ in
                NavigationStack {
                    ScrollView {
                        if let entry = presentation.resolvedDetail(entries: activity.entries, scope: NativeActivityStore.currentScope) {
                            NativeActivityCard(entry: entry, review: {
                                if presentation.requestReview(entry, scope: NativeActivityStore.currentScope) { activity.suspendAerialRefresh() }
                            }, stop: stopAction(entry), reviewTitle: entry.kind == .aerial && exactAerial(entry) ? "Review" : "Open listing & review")
                            Text("Completion estimates are not available yet.").font(.rpCaption).foregroundStyle(Theme.inkDim).padding(.top, 12)
                        } else {
                            Text("This saved request is no longer available in this account or property.")
                                .font(.rpBody).foregroundStyle(Theme.inkDim).padding()
                        }
                    }.padding(16).background(Theme.bg).navigationTitle("Generation details").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { presentation.detail = nil }.frame(minHeight: 44) } }
                }
            }
            .sheet(item: $reviewing) { entry in
                if let listing = model.listings.first(where: { $0.id == entry.listingID && model.isInSelectedWorkspace($0) }),
                   entry.scope == NativeActivityStore.currentScope, !listing.isSample, listing.cloudUnavailable != true {
                    review(entry, listing: listing).environmentObject(model)
                }
            }
        }
    }
    private func stopAction(_ entry: NativeActivityEntry) -> (() -> Void)? {
        guard entry.scope == NativeActivityStore.currentScope, entry.state.isActive else { return nil }
        if entry.kind == .aerial {
            guard exactAerialJournal(entry)?.canStopUnfinishedRequest == true,
                  !activity.stoppingIDs.contains(entry.id) else { return nil }
            return { Task { await activity.stopAerial(entry) } }
        }
        if let stop = activity.localStop(for: entry) { return stop }
        if entry.kind == .photos, let job = PhotoWorkQueue.shared.visibleJob,
           entry.id == "photo:\(job.id)", job.running, !job.stopRequested { return {
               guard entry.scope == NativeActivityStore.currentScope, PhotoWorkQueue.shared.visibleJob?.id == job.id else { return }
               PhotoWorkQueue.shared.stopRemaining()
           } }
        if entry.kind == .video, let job = ReelWorkQueue.shared.reviewableJobs.first(where: { NativeActivityStore.reelID($0) == entry.id }) {
            return { Task { guard entry.scope == NativeActivityStore.currentScope, job.isContextCurrent, NativeActivityStore.reelID(job) == entry.id else { return }; if job.serverJob != nil { await PropertyVideoJobRunner.shared.cancel(job) } else { job.cancel() }; activity.synchronize() } }
        }
        if entry.kind == .tour, model.renderCoordinator.activityID(entry.listingID) == entry.id,
           model.renderCoordinator.isRunning(entry.listingID) { return {
               guard entry.scope == NativeActivityStore.currentScope, model.renderCoordinator.activityID(entry.listingID) == entry.id else { return }
               model.renderCoordinator.cancel(listingID: entry.listingID); activity.synchronize()
           } }
        return nil // Historical or unavailable work has review access only.
    }
    private func exactAerial(_ entry: NativeActivityEntry) -> Bool { exactAerialJournal(entry) != nil }
    private func exactAerialJournal(_ entry: NativeActivityEntry) -> AerialOpeningJournal? {
        guard entry.scope == NativeActivityStore.currentScope, let actor = entry.scope.actor, let library = entry.scope.library,
              let listing = model.listings.first(where: { $0.id == entry.listingID }), let server = listing.serverID else { return nil }
        let context = PropertyVideoJobContext(localListingID: listing.id, listingID: server, actorID: actor, orgID: library)
        guard let saved = try? AerialOpeningStore.load(context), saved.physicalOrgID == listing.serverOrgID,
              entry.matchesAerialOperation(saved.manifest.operationID, scope: NativeActivityStore.currentScope) else { return nil }
        return saved
    }
    @ViewBuilder private func review(_ entry: NativeActivityEntry, listing: Listing) -> some View {
        if entry.kind == .aerial && exactAerial(entry) {
            AerialOpeningScreen(listing: listing, isPresentedModally: true, expectedOperationID: UUID(uuidString: String(entry.id.dropFirst("aerial:".count))))
        } else if entry.kind == .video,
                  let job = ReelWorkQueue.shared.reviewableJobs.first(where: { NativeActivityStore.reelID($0) == entry.id }) {
            ReelStudioView(listing: listing, photos: EnhancedPhoto.loadAll(listingID: listing.id),
                extraClipURLs: listing.aerialURL.map { [$0] } ?? [], reviewingJob: job)
        } else if entry.kind == .photos || entry.kind == .analysis {
            NavigationStack {
                PhotoStudioView(listing: listing, entry: .photos)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { reviewing = nil } } }
            }
        } else {
            NavigationStack {
                FlythroughDetailView(listing: listing)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { reviewing = nil } } }
            }
        }
    }
}
struct NativeActivityCompactRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let entry: NativeActivityEntry
    private var kind: String {
        switch entry.kind { case .photos: return "Photo edits"; case .video: return "Video"; case .aerial: return "Aerial opening"; case .analysis: return "Photo assessment"; case .voice: return "Voiceover"; case .tour: return "Tour" }
    }
    private var symbol: String {
        switch entry.kind { case .photos: return "photo.on.rectangle"; case .video: return "film"; case .aerial: return "airplane"; case .analysis: return "text.magnifyingglass"; case .voice: return "waveform"; case .tour: return "building.2" }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind).font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.ink)
                    NativeGenerationProgressView(progress: entry.generationProgress, compact: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.inkDim).accessibilityHidden(true)
            }.padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 64).contentShape(Rectangle())
                .accessibilityElement(children: .combine).accessibilityHint("View generation details")
                .accessibilityIdentifier("activity.row.\(entry.id)")
        }
    }
}
struct NativeActivityCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let entry: NativeActivityEntry
    let review: () -> Void
    let stop: (() -> Void)?
    var reviewTitle = "Open listing & review"
    private var kind: String {
        switch entry.kind { case .photos: return "Photo edits"; case .video: return "Video"; case .aerial: return "Aerial opening"; case .analysis: return "Photo assessment"; case .voice: return "Voiceover"; case .tour: return "Tour" }
    }
    private var symbol: String {
        switch entry.state { case .ready: return "checkmark.circle.fill"; case .failed, .attention: return "exclamationmark.circle"; case .stopped: return "stop.circle"; case .waiting: return "clock"; case .working: return "waveform.path" }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(Theme.accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(kind).font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text(entry.listingTitle).font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
                NativeGenerationProgressView(progress: entry.generationProgress)
                VStack(alignment: .leading, spacing: 5) {
                    if let start = entry.startedAt { Text(entry.state.isActive && !entry.isAerialAwaitingReview ? "Elapsed \(Self.elapsed(from: start, now: timeline.date))" : "Started \(Self.elapsed(from: start, now: timeline.date)) ago") }
                    else { Text("Start time unavailable for this saved request") }

                }.font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    Button(reviewTitle, action: review)
                        .buttonStyle(RendpropPillButtonStyle(compact: true)).frame(minHeight: 44)
                    if let stop {
                        Button("Stop", action: stop).buttonStyle(RendpropPillButtonStyle(compact: true)).frame(minHeight: 44)
                            .accessibilityHint("Stops remaining work. A request already sent may still finish.")
                    }
                }.font(.rpCaption.weight(.semibold))
            }.padding(18).modifier(RendpropGlassSurface())
                .accessibilityElement(children: .contain).accessibilityIdentifier("activity.\(entry.kind.rawValue).\(entry.id)")
        }
    }
    static func elapsed(from start: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(start)
        let seconds = elapsed.isFinite ? Int(min(315_576_000, max(0, elapsed))) : 0
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

/// Shared completed-work display. Time only describes real observation age;
/// it never advances the percentage or invents provider execution progress.
struct NativeGenerationProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: NativeGenerationProgress
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                HStack(alignment: .top, spacing: 8) {
                    if progress.canIndicateLive(at: timeline.date), !reduceMotion {
                        ProgressView().controlSize(.small).tint(Theme.accent).accessibilityHidden(true)
                    } else if progress.active {
                        Image(systemName: progress.checkFailed ? "wifi.exclamationmark" : "clock")
                            .foregroundStyle(Theme.inkDim).accessibilityHidden(true)
                    }
                    Text(progress.phase).font(compact ? .rpCaption : .rpBody).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let percent = progress.percent, let completed = progress.completed, let total = progress.total {
                    ProgressView(value: Double(completed), total: Double(total)).tint(Theme.accent)
                        .accessibilityLabel(progress.unit).accessibilityValue("\(completed) of \(total), \(percent) percent")
                    Text("\(percent)% · \(completed) of \(total) \(progress.unit)")
                        .font(.rpCaption.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                } else { Text("Progress not reported").font(.rpCaption).foregroundStyle(Theme.inkDim) }
                if progress.checkFailed {
                    Text("Could not check status. Last confirmed progress is shown.")
                        .font(.rpCaption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                } else if progress.checkIsStale(at: timeline.date) {
                    Text(progress.lastCheckedAt == nil ? "Waiting for a status check" : "Status check is out of date")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
                if progress.checksExpected {
                    Text(progress.lastCheckedAt.map { "Last checked \(NativeActivityCard.elapsed(from: $0, now: timeline.date)) ago" } ?? "No successful status check yet")
                        .font(.caption2).foregroundStyle(Theme.inkDim)
                }
                if let lastProgressAt = progress.lastProgressAt {
                    Text("Last progress \(NativeActivityCard.elapsed(from: lastProgressAt, now: timeline.date)) ago")
                        .font(.caption2).foregroundStyle(Theme.inkDim)
                } else if progress.active || progress.checksExpected {
                    Text("Progress update time unavailable")
                        .font(.caption2).foregroundStyle(Theme.inkDim)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        }
    }
}
