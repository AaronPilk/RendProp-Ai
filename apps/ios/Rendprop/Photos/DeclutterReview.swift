import SwiftUI
import UIKit
import ImageIO

/// Explicit analysis, then explicit image-edit admission. Closing cancels unsent analysis.
@MainActor final class PhotoDeclutterReviewModel: ObservableObject, Identifiable {
    struct Item: Identifiable {
        let id: String
        let photo: EnhancedPhoto
        var assessment = AIPhotoDeclutterAssessment.uncertain
        var originalSHA256: String?
        var preparedSHA256: String?
        var validAssessment = false
        var selected = false
        var manualOverride = false
        var error: String?
        var costBoundCents = 0.0
    }
    let id = UUID()
    @Published private(set) var items: [Item] = []
    @Published private(set) var analyzing = false
    @Published private(set) var finished = false
    @Published private(set) var completed = 0
    @Published private(set) var failure: String?
    private let model: AppModel
    private let listing: Listing
    private let space: SpaceType
    private let actor = AuthStore.shared.userID
    private let authRevision = AuthStore.shared.syncSessionRevision
    private let library = WorkspaceContext.selectedOrgID
    private let consentRevision = AIConsent.shared.revocationRevision
    private var task: Task<Void, Never>?
    private var activityStartedAt: Date?
    private let directory: URL
    var selectedCount: Int { items.filter(\.selected).count }
    var skippedCount: Int { items.count - selectedCount }
    var costBoundCents: Double { items.reduce(0) { $0 + $1.costBoundCents } }
    var isCurrent: Bool {
        !Task.isCancelled && AuthStore.shared.userID == actor && AuthStore.shared.syncSessionRevision == authRevision
            && WorkspaceContext.selectedOrgID == library && AIConsent.shared.isGranted
            && AIConsent.shared.revocationRevision == consentRevision
            && model.listings.contains { $0.id == listing.id && $0.cloudUnavailable != true }
    }
    init(model: AppModel, listing: Listing, photos: [EnhancedPhoto], space: SpaceType) {
        self.model = model; self.listing = listing; self.space = space
        directory = EnhancedPhoto.directory(for: listing.id)
        var seen = Set<String>()
        for photo in photos.prefix(100) {
            do {
                guard photo.enhancedURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { throw PhotoVersionHistory.Failure.changedVersion }
                let prior = photo.originalURL == photo.enhancedURL ? nil : photo.originalURL.lastPathComponent
                let tracked = try PhotoVersionHistory.trackExisting(id: photo.id, imageFile: photo.enhancedURL.lastPathComponent, priorFile: prior, directory: directory)
                let source = try PhotoVersionHistory.originalForEditing(id: tracked.id, directory: directory)
                guard seen.insert(source.id).inserted else { continue }
                let url = directory.appendingPathComponent(source.imageFile)
                items.append(Item(id: source.id, photo: EnhancedPhoto(id: source.id, originalURL: url, enhancedURL: url)))
            } catch {
                guard seen.insert(photo.id).inserted else { continue }
                items.append(Item(id: photo.id, photo: photo, error: "The retained original could not be verified. No edit can start."))
            }
        }
    }
    private func requireCurrent() throws {
        try Task.checkCancellation()
        guard isCurrent else { throw CloudSyncError.identityChanged }
    }
    private static func originalHash(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 80_000_000 else { throw PhotoVersionHistory.Failure.missingImage }
            return DeclutterGenerationApproval.sha256(try Data(contentsOf: url, options: .mappedIfSafe))
        }.value
    }
    func analyze() {
        guard !analyzing, !finished, isCurrent, let actor, let library,
              let api = model.api as? PhotoDeclutterAssessmentAPI else { failure = "Photo analysis is unavailable. No image edit was started."; return }
        analyzing = true; activityStartedAt = Date(); reportActivity(.working, stage: "Assessing photos")
        NativeActivityStore.shared.registerStop(id: "assessment:\(id)", scope: .init(actor: UUID(uuidString: actor), library: library)) { [weak self] in self?.cancel() }
        task = Task { @MainActor in
            defer {
                analyzing = false; finished = true; task = nil
                reportActivity(Task.isCancelled ? .stopped : .ready, stage: Task.isCancelled ? "Photo assessment stopped" : "Assessment ready to review")
            }
            for index in items.indices {
                do {
                    try requireCurrent()
                    guard items[index].error == nil else { completed += 1; continue }
                    let source = try PhotoVersionHistory.originalForEditing(id: items[index].id, directory: directory)
                    guard source.id == items[index].id else { throw PhotoVersionHistory.Failure.changedVersion }
                    let url = directory.appendingPathComponent(source.imageFile), original = try await Self.originalHash(url)
                    guard let b64 = await AIImagePrep.jpegBase64(at: url, maxDimension: 2048, quality: 0.9, maxBytes: 1_000_000), let bytes = Data(base64Encoded: b64) else { throw PhotoVersionHistory.Failure.missingImage }
                    try requireCurrent()
                    let prepared = DeclutterGenerationApproval.sha256(bytes)
                    let reply = try await api.assessDeclutter(.init(imageBase64: b64, sourceSHA256: prepared, requestID: UUID(), actor: actor, library: library,
                        listingServerID: listing.serverID, consentRevision: consentRevision, spaceType: space.rawValue))
                    try requireCurrent()
                    guard try await Self.originalHash(url) == original,
                          try PhotoVersionHistory.originalForEditing(id: source.id, directory: directory).id == source.id else { throw PhotoVersionHistory.Failure.changedVersion }
                    items[index].originalSHA256 = original; items[index].preparedSHA256 = prepared
                    items[index].assessment = reply.assessment; items[index].validAssessment = true
                    items[index].costBoundCents = reply.costBoundCents
                    items[index].selected = reply.assessment.decision == .needed
                } catch {
                    items[index].assessment = .uncertain; items[index].selected = false
                    items[index].error = "This photo could not be assessed safely. No image edit is selected."
                    if !isCurrent || Task.isCancelled { failure = "Review stopped because its account, consent or listing context changed."; break }
                }
                completed += 1
                reportActivity(.working, stage: "Assessing photos")
            }
        }
    }
    func toggle(_ id: String) {
        guard !analyzing, isCurrent, let index = items.firstIndex(where: { $0.id == id }), items[index].validAssessment else { return }
        items[index].selected.toggle()
        items[index].manualOverride = items[index].selected && items[index].assessment.decision != .needed
    }
    func confirm() async throws -> (photos: [EnhancedPhoto], approvals: [String: DeclutterGenerationApproval]) {
        try requireCurrent()
        guard finished, !analyzing, let actor, let library else { throw PhotoVersionHistory.Failure.reviewRequired }
        var approvals: [String: DeclutterGenerationApproval] = [:], photos: [EnhancedPhoto] = []
        for item in items where item.selected {
            guard item.validAssessment, let original = item.originalSHA256, let prepared = item.preparedSHA256,
                  try await Self.originalHash(item.photo.enhancedURL) == original else { throw PhotoVersionHistory.Failure.changedVersion }
            try requireCurrent()
            let approval = DeclutterGenerationApproval(actor: actor, library: library, listing: listing.id, sourceVersionID: item.id,
                originalSHA256: original, preparedSHA256: prepared, consentRevision: consentRevision,
                assessment: item.assessment, manualOverride: item.manualOverride)
            guard approval.permits(actor: actor, library: library, listing: listing.id, sourceVersionID: item.id,
                originalSHA256: original, preparedSHA256: prepared, consentGranted: AIConsent.shared.isGranted,
                consentRevision: AIConsent.shared.revocationRevision) else { throw PhotoVersionHistory.Failure.reviewRequired }
            approvals[item.id] = approval; photos.append(item.photo)
        }
        return (photos, approvals)
    }
    private func reportActivity(_ state: NativeActivityEntry.State, stage: String) {
        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == authRevision,
              WorkspaceContext.selectedOrgID == library, AIConsent.shared.revocationRevision == consentRevision else { return }
        NativeActivityStore.shared.observe(id: "assessment:\(id)", listingID: listing.id, kind: .analysis, state: state,
            stage: stage, completed: completed, total: items.count, startedAt: activityStartedAt,
            scope: .init(actor: actor.flatMap(UUID.init(uuidString:)), library: library))
    }
    func cancel() { task?.cancel(); if analyzing && !finished { reportActivity(.stopped, stage: "Photo assessment stopped") } }
}

struct PhotoDeclutterReviewSheet: View {
    @ObservedObject var review: PhotoDeclutterReviewModel
    let onConfirm: ([EnhancedPhoto], [String: DeclutterGenerationApproval]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var resultsFocused: Bool
    @State private var confirming = false
    @State private var error: String?

    private var checkTitle: String { review.items.count == 1 ? "Check this photo" : "Check \(review.items.count) photos" }
    private var checkingTitle: String {
        review.items.count == 1 ? "Checking this photo…" : "Checking photo \(min(review.completed + 1, review.items.count)) of \(review.items.count)…"
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !review.finished {
                            selectedPhotos
                            VStack(alignment: .leading, spacing: 10) {
                                Text(review.analyzing ? "Looking for clutter" : "Check before you edit")
                                    .font(.rpTitle).foregroundStyle(Theme.ink)
                                Text("We’ll check for visible movable clutter. This has a small AI processing cost. No image edit starts until you choose Generate.")
                                    .font(.rpBody).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if review.finished {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Your photo check").font(.rpTitle).foregroundStyle(Theme.ink)
                                    .accessibilityAddTraits(.isHeader).accessibilityFocused($resultsFocused)
                                Text("\(review.selectedCount) image edits selected · \(review.skippedCount) skipped")
                                    .font(.rpBody).foregroundStyle(Theme.inkDim)
                            }.id("declutter.results")
                            group("Needs declutter", decision: .needed, symbol: "wand.and.stars")
                            group("Already clear", decision: .unnecessary, symbol: "checkmark.circle")
                            group("Needs review", decision: .uncertain, symbol: "questionmark.circle")
                            Text("Recorded analysis cost bound: $\(String(format: "%.3f", review.costBoundCents / 100)). This is a processing bound, not a supplier invoice. Only the photos you confirm will start paid image edits.")
                                .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                        }
                        if let message = error ?? review.failure {
                            Label(message, systemImage: "exclamationmark.circle")
                                .font(.rpBody).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(20)
                }
                .background(Theme.bg)
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomAction }
                .navigationTitle("Declutter review").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { review.cancel(); dismiss() }
                    }
                }
                .onChange(of: review.finished) { finished in
                    guard finished else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        proxy.scrollTo("declutter.results", anchor: .top)
                    }
                    resultsFocused = true
                }
            }
        }.onDisappear { review.cancel() }
    }

    private var selectedPhotos: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(review.items.count == 1 ? "Selected photo" : "\(review.items.count) selected photos")
                .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            if review.items.count == 1, let item = review.items.first {
                DeclutterReviewThumb(url: item.photo.enhancedURL, prominent: true)
                    .accessibilityLabel("Selected photo")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(review.items.enumerated()), id: \.element.id) { index, item in
                            VStack(alignment: .leading, spacing: 8) {
                                DeclutterReviewThumb(url: item.photo.enhancedURL, prominent: true)
                                Text("Photo \(index + 1)").font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.inkDim)
                            }.frame(width: dynamicTypeSize.isAccessibilitySize ? 260 : 220)
                                .accessibilityElement(children: .combine).accessibilityLabel("Selected photo \(index + 1) of \(review.items.count)")
                        }
                    }
                }
            }
        }.accessibilityIdentifier("declutter.review.selectedPhotos")
    }

    @ViewBuilder private var bottomAction: some View {
        VStack(spacing: 10) {
            if review.finished {
                Button {
                    confirming = true
                    Task { @MainActor in
                        defer { confirming = false }
                        do { let confirmed = try await review.confirm(); onConfirm(confirmed.photos, confirmed.approvals); dismiss() }
                        catch { self.error = "The reviewed photos or account changed. Reopen this review before editing." }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if confirming { ProgressView().tint(.white) }
                        Text(review.selectedCount == 0 ? "Done · no image edits" : "Generate \(review.selectedCount) Declutter \(review.selectedCount == 1 ? "edit" : "edits")")
                            .font(.rpBody.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, minHeight: 28)
                }
                .modifier(RendpropActionAppearance()).disabled(confirming || !review.isCurrent)
                .accessibilityIdentifier("declutter.review.confirm")
            } else if review.analyzing {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(review.completed), total: Double(max(review.items.count, 1)))
                        .tint(Theme.accent).accessibilityLabel(checkingTitle)
                    Text(checkingTitle).font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("No image edits have started.").font(.rpCaption).foregroundStyle(Theme.inkDim)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
            } else {
                Button { review.analyze() } label: {
                    Label(checkTitle, systemImage: "sparkle.magnifyingglass")
                        .font(.rpBody.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }.modifier(RendpropActionAppearance())
                    .accessibilityIdentifier("declutter.review.analyze")
            }
        }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
            .background(Theme.bg)
    }

    @ViewBuilder private func group(_ title: String, decision: AIPhotoDeclutterAssessment.Decision, symbol: String) -> some View {
        let items = review.items.filter { $0.assessment.decision == decision }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Label("\(title) · \(items.count)", systemImage: symbol)
                    .font(.rpBody.weight(.semibold)).foregroundStyle(decision == .uncertain ? Theme.warn : Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        if dynamicTypeSize.isAccessibilitySize {
                            DeclutterReviewThumb(url: item.photo.enhancedURL, prominent: true)
                            resultDetails(item, decision: decision)
                        } else {
                            HStack(alignment: .top, spacing: 14) {
                                DeclutterReviewThumb(url: item.photo.enhancedURL)
                                resultDetails(item, decision: decision)
                            }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(RendpropContentSurface())
                }
            }
        }
    }

    private func resultDetails(_ item: PhotoDeclutterReviewModel.Item, decision: AIPhotoDeclutterAssessment.Decision) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.error ?? item.assessment.reason).font(.rpBody).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if item.validAssessment {
                Button(item.selected ? (item.manualOverride ? "Included manually · remove" : "Selected · remove") : (decision == .needed ? "Include" : "Include anyway")) { review.toggle(item.id) }
                    .font(.rpCaption.weight(.semibold))
                    .buttonStyle(RendpropPillButtonStyle(selected: item.selected, compact: true, horizontalPadding: 12))
                    .accessibilityAddTraits(item.selected ? .isSelected : [])
                    .accessibilityIdentifier("declutter.review.include.\(item.id)")
            } else {
                Text("No generation available from a missing assessment.").font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            if item.selected {
                Label("Selected for an image edit", systemImage: "checkmark.circle.fill")
                    .font(.rpCaption).foregroundStyle(Theme.accent)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Full originals stay on disk; the review retains only small display thumbnails.
private struct DeclutterReviewThumb: View {
    let url: URL
    var prominent = false
    @State private var image: UIImage?
    @State private var unavailable = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: prominent ? .fit : .fill) }
            else if unavailable {
                Label("Photo preview unavailable", systemImage: "photo")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim).padding(8)
            } else { ProgressView("Loading photo…").font(.rpCaption) }
        }
        .frame(maxWidth: prominent ? .infinity : 88)
        .frame(height: prominent ? 240 : 88)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipped().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unavailable ? "Photo preview unavailable" : "Selected saved photo")
        .task(id: url) {
            let dimension = prominent ? 1000 : 200
            let loaded = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                        [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                         kCGImageSourceThumbnailMaxPixelSize: dimension] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: image)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded; unavailable = loaded == nil
        }
    }
}
