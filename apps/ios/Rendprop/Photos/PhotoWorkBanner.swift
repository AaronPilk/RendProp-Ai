import SwiftUI

struct PhotoWorkBanner: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var jobs = PhotoWorkQueue.shared
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var workspace = WorkspaceStore.shared
    @State private var reviewListing: Listing?

    var body: some View {
        Group {
            if let job = jobs.visibleJob {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: job.running ? "sparkles" : job.failures.isEmpty && !job.interrupted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.accent)
                        Text(job.running ? "\(job.title) · \(job.percent)%" : "\(job.done) of \(job.total) photos ready")
                            .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Review") { reviewListing = model.listings.first { $0.id == job.listingID } }
                            .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
                            .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("photoWork.review")
                        if !job.running {
                            Button { jobs.dismissResult() } label: { Image(systemName: "xmark") }
                                .frame(width: 44, height: 44).accessibilityLabel("Dismiss photo status")
                        }
                    }
                    if job.running {
                        ProgressView(value: job.fraction).tint(Theme.accent)
                            .accessibilityLabel("Photo batch progress")
                            .accessibilityValue("\(job.percent) percent; \(job.done) changed, \(job.failures.count) failed")
                        Text("Photo \(job.current) of \(job.total). You can use other screens in Rendprop while this finishes.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
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
        .onChange(of: auth.userID) { _ in jobs.cancel(); reviewListing = nil }
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
}
