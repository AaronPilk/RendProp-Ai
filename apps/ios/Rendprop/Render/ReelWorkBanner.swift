import SwiftUI

/// Describes measured shot progress, never progress inside a provider request.
enum ReelWorkBannerCopy {
    static func title(running: Bool, paused: Bool, ready: Bool, stitching: Bool,
                      completed: Int, total: Int) -> String {
        if paused { return "Reel paused" }
        if ready { return "Your reel is ready" }
        guard running else { return "Reel needs review" }
        let count = "\(min(max(0, completed), max(0, total))) of \(max(0, total)) photos ready"
        return stitching ? "Finishing reel · \(count)" : "Making reel · \(count)"
    }

    static func explanation(paused: Bool, running: Bool) -> String {
        if paused {
            return "iOS paused local processing. Your saved requests and clips are kept. Reopen the reel to resume."
        }
        if running {
            return "You can use other screens. Locking or leaving the app may pause local processing; saved requests remain recoverable."
        }
        return "Open the reel to watch it or review the saved progress."
    }
}

/// A notification or banner may open only an existing, currently visible job's
/// available listing. Visibility is the queue's account/workspace/consent fence.
@MainActor enum ReelWorkReviewAdmission {
    static func listing(jobID: UUID, visibleJobs: [ReelWorkJob], listings: [Listing]) -> Listing? {
        guard let job = visibleJobs.first(where: { $0.id == jobID }),
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

    var body: some View {
        Group {
            if let job = jobs.currentJob {
                ReelWorkStatusRow(job: job, review: { open(job.id) }, dismiss: {
                    jobs.dismissResult(listingID: job.listingID)
                })
            }
        }
        .task(id: push.pendingReelJobID) { await reviewPendingNotification() }
        .onChange(of: auth.syncSessionRevision) { _ in invalidateReview() }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in invalidateReview() }
        .onChange(of: consent.isGranted) { _ in invalidateReview() }
        .sheet(item: Binding(get: { currentReviewListing }, set: { value in
            reviewListing = value
            if value == nil { reviewJobID = nil }
        })) { listing in
            // The view reconnects to the queue-owned job. Opening sends no new
            // generation and does not replace its selected JPEGs or shot order.
            ReelStudioView(listing: listing,
                           photos: EnhancedPhoto.loadAll(listingID: listing.id),
                           extraClipURLs: listing.aerialURL.map { [$0] } ?? [])
                .environmentObject(model)
        }
    }

    private var currentReviewListing: Listing? {
        guard let id = reviewJobID, reviewListing != nil else { return nil }
        return ReelWorkReviewAdmission.listing(jobID: id, visibleJobs: jobs.visibleJobs, listings: model.listings)
    }

    private func open(_ id: UUID) {
        guard !NativePresentationAvailability.hasPresentedController,
              let listing = ReelWorkReviewAdmission.listing(jobID: id, visibleJobs: jobs.visibleJobs,
                                                           listings: model.listings) else { return }
        reviewJobID = id
        reviewListing = listing
    }

    private func invalidateReview() {
        jobs.reconcileIdentity()
        reviewListing = nil
        reviewJobID = nil
        push.clearPendingReelJob()
    }

    private func reviewPendingNotification() async {
        while let id = push.pendingReelJobID, !Task.isCancelled {
            guard ReelWorkReviewAdmission.listing(jobID: id, visibleJobs: jobs.visibleJobs,
                                                 listings: model.listings) != nil else {
                push.clearPendingReelJob()
                return
            }
            if reviewListing == nil, !NativePresentationAvailability.hasPresentedController {
                open(id)
                if reviewJobID == id { push.clearPendingReelJob() }
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
    let review: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: job.phase == .done ? "checkmark.circle.fill" : job.running ? "film.stack" : "pause.circle")
                    .foregroundStyle(Theme.accent)
                Text(ReelWorkBannerCopy.title(running: job.running, paused: job.paused,
                    ready: job.phase == .done, stitching: job.phase == .stitching,
                    completed: job.completedClips, total: job.totalClips))
                    .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(job.running ? "View" : "Review", action: review)
                    .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("reelWork.review")
                if !job.running, !job.paused {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .frame(width: 44, height: 44).accessibilityLabel("Dismiss reel status")
                        .accessibilityIdentifier("reelWork.dismiss")
                }
            }
            if job.running {
                ProgressView(value: job.fraction).tint(Theme.accent)
                    .accessibilityLabel("Reel photo progress")
                    .accessibilityValue("\(job.completedClips) of \(job.totalClips) photos ready; \(job.percent) percent")
                Text(job.statusText).font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ReelWorkBannerCopy.explanation(paused: job.paused, running: job.running))
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            if job.running || job.paused {
                if push.authorization == .notDetermined {
                    Button("Notify me when ready") { Task { await push.requestAuthorization() } }
                        .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
                        .frame(minHeight: 44).accessibilityIdentifier("reelWork.allowNotifications")
                } else if push.authorization == .denied {
                    Button("Enable completion alerts in Settings") { PushManager.openSystemSettings() }
                        .font(.rpCaption).foregroundStyle(Theme.accent)
                        .frame(minHeight: 44).accessibilityIdentifier("reelWork.notificationSettings")
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reelWork.banner")
    }
}
