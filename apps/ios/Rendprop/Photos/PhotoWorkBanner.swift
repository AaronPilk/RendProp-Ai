import SwiftUI

/// These counts describe saved photos, never a supplier's in-flight percentage.
@MainActor private enum PhotoWorkBannerCopy {
    static func phaseSummary(for job: PhotoWorkQueue.Job) -> String {
        let position = min(max(1, job.current), job.total)
        return "\(job.phase?.title ?? PhotoWorkQueue.Phase.preparing.title) · photo \(position) of \(job.total)"
    }

    static func hasSavedReview(_ job: PhotoWorkQueue.Job) -> Bool {
        job.failures.contains { failure in
            AIFailure.requiresSavedPhotoCheck(failure.error)
        }
    }

    static func completedSummary(for job: PhotoWorkQueue.Job) -> String {
        let failures = job.failures.count
        return "\(job.done) of \(job.total) saved" + (failures > 0 ? " · \(failures) failed" : "")
    }
}

struct PhotoWorkBanner: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var jobs = PhotoWorkQueue.shared
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var workspace = WorkspaceStore.shared
    @ObservedObject private var push = PushManager.shared
    @State private var reviewListing: Listing?

    var body: some View {
        Group {
            ForEach(jobs.visibleJobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: job.running ? "sparkles" : job.failures.isEmpty && !job.interrupted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.accent)
                        Text(job.running ? job.title : PhotoWorkBannerCopy.hasSavedReview(job) ? "Saved edit needs checking" : "\(job.done) of \(job.total) photos ready")
                            .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Review") { reviewListing = model.listings.first { $0.id == job.listingID } }
                            .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel("Review \(job.title) photos")
                            .accessibilityIdentifier("photoWork.review")
                        if job.running {
                            Button { jobs.stopRemaining(jobID: job.id) } label: {
                                Image(systemName: "stop.circle.fill")
                            }.frame(width: 44, height: 44)
                                .foregroundStyle(Theme.warn)
                                .disabled(job.stopRequested)
                                .accessibilityLabel(job.stopRequested ? "\(job.title) remaining edits stopped" : "Stop remaining \(job.title) edits")
                                .accessibilityHint("No more photos will be sent. A photo already sent may still finish and be charged.")
                                .accessibilityIdentifier("photoWork.stopRemaining")
                        }
                        if !job.running {
                            Button { jobs.dismissResult(jobID: job.id) } label: { Image(systemName: "xmark") }
                                .frame(width: 44, height: 44).accessibilityLabel("Dismiss \(job.title) photo status")
                        }
                    }
                    if job.running {
                        Text(job.stopRequested ? "Stopping remaining edits" : PhotoWorkBannerCopy.phaseSummary(for: job))
                            .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("photoWork.phase")
                        ProgressView(value: job.fraction).tint(Theme.accent)
                            .accessibilityLabel("Photo batch progress")
                            .accessibilityValue(PhotoWorkBannerCopy.completedSummary(for: job))
                        Text(job.stopRequested
                             ? "No more photos will be sent. The current request may finish and be charged; its saved result is kept."
                             : PhotoWorkBannerCopy.completedSummary(for: job) + ". You can use other screens in Rendprop while this finishes.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if PhotoWorkBannerCopy.hasSavedReview(job) {
                        Text("Your request is saved. Review, then choose Check saved edit in Photos. This does not start another paid edit.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    } else if job.interrupted {
                        Text("Work stopped. Your saved photos are safe; select the remaining photos to continue.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    } else if !job.failures.isEmpty {
                        Text("\(job.failures.count) didn't change. Review to see the reason and your saved versions.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 10)
                    .background(Theme.card)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("photoWork.banner")
            }
        }
        .task(id: "\(push.pendingPhotoReview?.listingID.uuidString ?? "none")|\(WorkspaceContext.selectedOrgID?.uuidString ?? "none")") {
            await reviewPendingNotification()
        }
        .onChange(of: auth.userID) { _ in jobs.cancel(); reviewListing = nil; push.clearPendingPhotoReview() }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in
            jobs.cancel(); reviewListing = nil
        }
        .sheet(item: $reviewListing) { listing in
            NavigationStack {
                PhotoStudioView(listing: listing, entry: .photos)
                    .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Done") { reviewListing = nil } } }
            }
        }
    }

    private func reviewPendingNotification() async {
        guard let requested = push.pendingPhotoReview else { return }
        // The batch is in memory, but its edited photos and listing survive a
        // relaunch. Wait for the saved library before deciding the target is gone.
        while !model.hasRestoredLibrary && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !Task.isCancelled, push.pendingPhotoReview == requested else { return }
        // A shared team library needs fresh membership before its listing can
        // be opened. An own offline library can use its saved own selection.
        if Config.useLiveBackend && (!workspace.canViewLibrary(requested.workspace)
            || WorkspaceContext.selectedOrgID != requested.workspace) {
            await workspace.refresh()
        }
        while let target = push.pendingPhotoReview, !Task.isCancelled {
            guard PushManager.currentIdentity?.owner == target.owner else {
                push.clearPendingPhotoReview()
                return
            }
            if WorkspaceContext.selectedOrgID != target.workspace {
                if let member = workspace.selectionChoices.first(where: { $0.id == target.workspace && $0.canRead == true }) {
                    push.showSwitchPhotoLibraryNotice(member.displayName)
                } else {
                    push.showUnavailablePhotoNotice()
                    push.clearPendingPhotoReview()
                }
                return
            }
            guard let listing = model.listings.first(where: { $0.id == target.listingID && !$0.isSample
                && $0.cloudUnavailable != true && model.isInSelectedWorkspace($0) }) else {
                push.showUnavailablePhotoNotice()
                push.clearPendingPhotoReview()
                return
            }
            if reviewListing == nil, !NativePresentationAvailability.hasPresentedController {
                reviewListing = listing
                push.clearPendingPhotoReview()
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
