import SwiftUI
import AVKit
import UIKit
import ImageIO

enum CloudPhotoCardColumns {
    static func preview(for size: DynamicTypeSize) -> [GridItem] {
        size.isAccessibilitySize ? [GridItem(.flexible(minimum: 0), alignment: .top)] : [GridItem(.adaptive(minimum: 140), alignment: .top)]
    }
    static func media(for size: DynamicTypeSize) -> [GridItem] {
        size.isAccessibilitySize ? [GridItem(.flexible(minimum: 0), alignment: .top)] : [GridItem(.adaptive(minimum: 155), alignment: .top)]
    }
}

/// Card-size previews of cloud photos. A card is about 160 points wide, so
/// the full-size file is decoded straight to a small bitmap off the main
/// actor and remembered for this run of the app. Before this, every card
/// decoded the complete photo at full resolution and fetched it again each
/// time the screen reopened, because a freshly signed link never matches a
/// cached one. Memory only: neither the private link nor the image bytes are
/// written to disk, and the link is sent without cookies or redirects.
enum CloudPhotoThumbnails {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    /// The photo's server id plus its stored object, never the signed link:
    /// the signature changes on every read, the object does not.
    private static func key(id: UUID, url: URL) -> NSString {
        "\(id.uuidString)|\(CloudListingMerge.validatedMediaKey(url) ?? "")" as NSString
    }

    static func cached(id: UUID, url: URL) -> UIImage? {
        cache.object(forKey: key(id: id, url: url))
    }

    static func load(id: UUID, url: URL, maxPixel: Int = 600) async -> UIImage? {
        let k = key(id: id, url: url)
        if let hit = cache.object(forKey: k) { return hit }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request, delegate: CloudFileDownload.NoRedirect()),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty, data.count <= 25 * 1024 * 1024, !Task.isCancelled else { return nil }
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let decoded {
            let cost = Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4)
            cache.setObject(decoded, forKey: k, cost: cost)
        }
        return decoded
    }
}

/// The proposed cell width sizes the rectangle. Image pixels only draw inside
/// that rectangle; their intrinsic width cannot expand the grid column.
private struct CloudPhotoCardThumbnail: View {
    let id: UUID
    let url: URL
    let height: CGFloat
    var thumbnail: Image?
    @State private var loaded: UIImage?

    var body: some View {
        Rectangle().fill(Theme.fillSubtle)
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                GeometryReader { bounds in
                    Group {
                        if let thumbnail { thumbnail.resizable().scaledToFill() }
                        else if let loaded { Image(uiImage: loaded).resizable().scaledToFill() }
                        else { Image(systemName: "photo").foregroundStyle(Theme.inkDim) }
                    }
                    .frame(width: bounds.size.width, height: bounds.size.height)
                    .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
            .task(id: url) {
                guard thumbnail == nil else { return }
                if let hit = CloudPhotoThumbnails.cached(id: id, url: url) { loaded = hit; return }
                let image = await CloudPhotoThumbnails.load(id: id, url: url)
                if !Task.isCancelled, let image { loaded = image }
            }
    }
}

struct CloudPhotoPreviewCard: View {
    let photo: CloudMediaPage.Photo
    var thumbnail: Image? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CloudPhotoCardThumbnail(id: photo.id, url: photo.url, height: 140, thumbnail: thumbnail)
            Text(photo.caption?.isEmpty == false ? photo.caption! : "Listing photo")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text(photo.original_url == nil && photo.is_altered != false
                 ? "Cloud copy · original unavailable" : "Cloud photo · review available files")
                .font(.caption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if photo.is_staged { Text("Virtually staged").font(.caption).foregroundStyle(Theme.warn) }
        }
        .padding(10)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cloud.previewCard.\(photo.id.uuidString)")
    }
}

struct CloudMediaPhotoCard: View {
    let photo: CloudMediaPage.Photo
    let busy: Bool
    let savedCopy: Bool
    let imported: Bool
    var thumbnail: Image? = nil
    let saveCopy: () -> Void
    let importPhoto: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CloudPhotoCardThumbnail(id: photo.id, url: photo.url, height: 145, thumbnail: thumbnail)
            Text(photo.caption?.isEmpty == false ? photo.caption! : "Listing photo")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if photo.is_staged { Text("Virtually staged").font(.caption).foregroundStyle(.orange) }
            if photo.original_url == nil && photo.is_altered != false {
                Text("Only this cloud copy is available. Saving it to iPhone Photos does not restore its original or edit history.")
                    .font(.caption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Button(action: saveCopy) {
                    Label(savedCopy ? "Saved to iPhone Photos" : "Save available copy to Photos",
                          systemImage: savedCopy ? "checkmark" : "square.and.arrow.down")
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
                }
                .modifier(RendpropActionAppearance(primary: true, compact: true))
                .disabled(busy || savedCopy)
                .accessibilityIdentifier("cloud.saveCopy.\(photo.id.uuidString)")
            } else {
                Button(action: importPhoto) {
                    Label(imported ? "Saved in Photo Studio" : "Save to Photo Studio",
                          systemImage: imported ? "checkmark" : "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
                }
                .modifier(RendpropActionAppearance(primary: true, compact: true))
                .disabled(busy || imported)
                .accessibilityIdentifier("cloud.importPhoto.\(photo.id.uuidString)")
            }
        }
        .padding(12)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cloud.mediaCard.\(photo.id.uuidString)")
    }
}

/// Metadata only. Previewing never restores originals, writes history, or
/// changes the listing's selected gallery. Keep private links in this scope.
@MainActor final class CloudPhotoPreviewLoader: ObservableObject {
    struct Context: Hashable {
        let actorID: UUID
        let revision: UInt64
        let libraryID: UUID
        let localListingID: UUID
        let listingID: UUID
        let orgID: UUID
    }
    @Published private(set) var context: Context?
    @Published private(set) var photos: [CloudMediaPage.Photo] = []
    @Published private(set) var hasMore = false
    @Published private(set) var unavailable = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var generation = UUID()
    private var loaded = false

    func reset() {
        generation = UUID(); context = nil; photos = []; hasMore = false
        unavailable = 0; loading = false; error = nil; loaded = false
    }

    func load(_ requested: Context, force: Bool = false,
              fetch: (Int) async throws -> CloudMediaPage,
              isCurrent: () -> Bool) async {
        guard context != requested || !loading else { return }
        guard force || context != requested || !loaded else { return }
        reset()
        let operation = generation
        context = requested; loading = true
        defer { if generation == operation { loading = false } }
        func check() throws {
            try Task.checkCancellation()
            guard generation == operation, isCurrent() else { throw CloudSyncError.identityChanged }
        }
        do {
            var found: [CloudMediaPage.Photo] = [], seen = Set<UUID>(), offset = 0, missing = 0
            // At most four metadata pages; only six display previews are shown.
            // If more pages exist, the count is explicitly a lower bound.
            for pageNumber in 0..<4 {
                try check()
                let page = try await fetch(offset)
                try check()
                _ = try page.checked(listingID: requested.listingID, orgID: requested.orgID,
                                     offset: offset, actorID: requested.actorID)
                guard page.photos.allSatisfy({ seen.insert($0.id).inserted }) else { throw CloudSyncError.incomplete }
                found += page.photos; missing += page.unavailable_count
                try check()
                photos = found; hasMore = page.next_offset != nil; unavailable = missing; loaded = true
                if found.count < 6, let next = page.next_offset, pageNumber < 3 { offset = next; continue }
                return
            }
        } catch is CancellationError { if generation == operation { reset() }; return }
        catch {
            guard generation == operation else { return }
            guard isCurrent() else { reset(); return }
            loaded = false
            self.error = "Cloud photo loading couldn't finish. Your files and listing choices are unchanged. Try again when connected."
        }
    }
}

/// The empty local gallery still shows the account's available display copies.
/// Import and save remain explicit in the existing scoped Cloud files screen.
struct CloudPhotoLibraryPreview: View {
    let listing: Listing
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var loader = CloudPhotoPreviewLoader()

    private var scope: CloudPhotoPreviewLoader.Context? {
        guard auth.isIdentified, let actor = auth.userID.flatMap(UUID.init(uuidString:)),
              let library = WorkspaceContext.selectedOrgID,
              let current = model.listings.first(where: { $0.id == listing.id }),
              !current.isSample, current.cloudUnavailable != true, model.isInSelectedWorkspace(current),
              let sid = current.serverID, let org = current.serverOrgID else { return nil }
        return .init(actorID: actor, revision: auth.syncSessionRevision, libraryID: library,
                     localListingID: current.id, listingID: sid, orgID: org)
    }
    private var visiblePhotos: [CloudMediaPage.Photo] { loader.context == scope && scope != nil ? loader.photos : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(visiblePhotos.isEmpty ? "Cloud photos" : "Cloud photos · \(visiblePhotos.count)\(loader.hasMore ? "+" : "")",
                  systemImage: "icloud")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
                .accessibilityIdentifier("photos.cloudCount")
            if loader.context == scope, loader.loading {
                ProgressView("Loading cloud photos…")
            }
            if !visiblePhotos.isEmpty {
                LazyVGrid(columns: CloudPhotoCardColumns.preview(for: dynamicTypeSize), spacing: 12) {
                    ForEach(Array(visiblePhotos.prefix(6).enumerated()), id: \.element.id) { item in
                        let photo = item.element
                        NavigationLink { CloudMediaView(listing: listing) } label: {
                            CloudPhotoPreviewCard(photo: photo)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(photoAccessibilityLabel(photo, ordinal: item.offset + 1))
                        .accessibilityHint("Opens available cloud files and saving options.")
                        .accessibilityIdentifier("photos.cloudPreview.\(photo.id.uuidString)")
                    }
                }
                Text("Open a cloud photo to view available files and saving options. A cloud copy does not restore its original or edit history.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            } else if loader.context == scope, !loader.loading, loader.error == nil, scope != nil {
                Text(loader.hasMore ? "More cloud files are available in Cloud files." : "No available cloud photos were found for this listing.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            if loader.context == scope, loader.unavailable > 0 {
                Text("Some account files are still processing or unavailable.").font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            if loader.context == scope, let error = loader.error {
                Text(error).font(.rpCaption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                Button("Retry cloud photos") { Task { await load(force: true) } }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .accessibilityIdentifier("photos.retryCloudPreview")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("photos.cloudPreview")
        .task(id: scope) { await load() }
    }

    private func photoAccessibilityLabel(_ photo: CloudMediaPage.Photo, ordinal: Int) -> String {
        var parts = ["Cloud photo \(ordinal)"]
        if photo.is_altered == true { parts.append("Altered image") }
        if photo.is_staged { parts.append("Virtually staged") }
        if photo.original_url == nil && photo.is_altered != false { parts.append("Original and edit history unavailable") }
        return parts.joined(separator: ". ")
    }

    @MainActor private func load(force: Bool = false) async {
        guard let requested = scope, let api = model.api as? WorkspaceSyncAPI,
              let access = try? CloudMediaAccessContext.capture(orgID: requested.orgID) else { loader.reset(); return }
        await loader.load(requested, force: force, fetch: { offset in
            try await api.cloudMedia(listingID: requested.listingID, orgID: requested.orgID, offset: offset)
        }, isCurrent: {
            scope == requested && (try? access.check()) != nil
        })
    }
}

/// On-demand access keeps an office's large originals off cellular until the
/// agent chooses a file. Successful imports use the existing Photo/Review tools.
struct CloudMediaView: View {
    let listing: Listing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @State private var photos: [CloudMediaPage.Photo] = []
    @State private var videos: [CloudMediaPage.Video] = []
    @State private var chapters: [CloudListingState.Chapter] = []
    @State private var creative: CloudCreative?
    @State private var creativeError: String?
    @State private var nextOffset: Int?
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var importing: UUID?
    @State private var importTask: Task<Void, Never>?
    @State private var replaceVideo: CloudMediaPage.Video?
    @State private var imported = Set<UUID>()
    @State private var savedCopies = Set<UUID>()

    private var current: Listing { model.listings.first(where: { $0.id == listing.id }) ?? listing }
    @State private var mediaContext: String?
    @State private var importGeneration = UUID()
    private func context(org: UUID, listingID: UUID) -> String {
        "\(auth.userID ?? "")|\(auth.syncSessionRevision)|\(org.uuidString)|\(listingID.uuidString)"
    }
    @MainActor private func hasCurrentMediaContext(_ captured: CloudMediaAccessContext, localID: UUID, listingID: UUID) -> Bool {
        (try? captured.check()) != nil && mediaContext == context(org: captured.orgID, listingID: listingID) &&
            model.listings.contains(where: { $0.id == localID && $0.serverID == listingID && $0.serverOrgID == captured.orgID && $0.cloudUnavailable != true })
    }
    private var floorPlanURL: URL? {
        guard auth.isIdentified, current.cloudUnavailable != true,
              let org = current.serverOrgID, let sid = current.serverID,
              mediaContext == context(org: org, listingID: sid) else { return nil }
        return CloudFloorPlanLink.resolve(details: current.details, photos: photos,
                                         listingID: sid, orgID: org, now: Date(), actorID: auth.userID.flatMap(UUID.init(uuidString:)))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Files from your phone and Studio").font(.title2.bold())
                Text("Photos with their originals can open in Photo Studio. When only a cloud copy is available, you can save that copy to iPhone Photos.")
                    .font(.subheadline).foregroundStyle(Theme.inkDim)
                if loading { ProgressView("Loading cloud files…") }
                if let error { Label(error, systemImage: "exclamationmark.icloud").font(.subheadline).foregroundStyle(.orange) }
                if let notice { Text(notice).font(.subheadline).foregroundStyle(Theme.accent) }
                if let floorPlanURL {
                    Link(destination: floorPlanURL) { Label("View shared floor plan", systemImage: "square.split.2x2") }
                        .buttonStyle(.bordered)
                }
                if !photos.isEmpty {
                    Text("Photos").font(.headline)
                    LazyVGrid(columns: CloudPhotoCardColumns.media(for: dynamicTypeSize), spacing: 16) {
                        ForEach(photos) { photo in
                            CloudMediaPhotoCard(photo: photo, busy: importing != nil,
                                savedCopy: savedCopies.contains(photo.id), imported: imported.contains(photo.id),
                                saveCopy: { saveAvailableCopy(photo) }, importPhoto: { importPhoto(photo) })
                        }
                    }
                }
                if !videos.isEmpty {
                    Text("Videos").font(.headline)
                    ForEach(videos) { video in
                        VStack(alignment: .leading, spacing: 12) {
                            CloudVideoPreview(url: video.url).frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 12))
                            Text("Video from \(CloudListingMerge.date(video.created_at)?.formatted(date: .abbreviated, time: .omitted) ?? "your workspace")").font(.subheadline)
                            if let duration = video.duration_s, duration.isFinite, duration >= 0 { Text("\(Int(duration.rounded())) seconds").font(.caption).foregroundStyle(Theme.inkDim) }
                            Button {
                                if model.assets[current.id] != nil { replaceVideo = video } else { importVideo(video) }
                            } label: { Label(imported.contains(video.id) ? "Ready in your listing" : "Use this video on iPhone", systemImage: "arrow.down.circle") }
                                .buttonStyle(.bordered).disabled(importing != nil || imported.contains(video.id))
                        }
                    }
                }
                creativeSection
                if let importing { HStack { ProgressView(); Text("Saving file to this iPhone…") }.id(importing) }
                if nextOffset != nil { Button("Load more cloud files") { Task { await load(more: true) } }.disabled(loading || importing != nil) }
                if !loading && error == nil && photos.isEmpty && videos.isEmpty { Text("No completed uploads yet. Finish uploading from your iPhone or Studio, then refresh.").foregroundStyle(Theme.inkDim) }
                if !imported.isEmpty {
                    NavigationLink { PhotoStudioView(listing: current, entry: .photos) } label: { Label("Open this listing's Photo Studio", systemImage: "photo.stack") }
                }
            }.padding()
        }
        .background(Theme.bg).navigationTitle("Cloud files").navigationBarTitleDisplayMode(.inline)
        .task(id: auth.userID) { await load() }
        .refreshable { await load() }
        .toolbar { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading || importing != nil).accessibilityLabel("Refresh cloud files") }
        .onDisappear { importTask?.cancel() }
        .onChange(of: auth.userID) { _ in clearAccountFiles() }
        .onChange(of: auth.syncSessionRevision) { _ in clearAccountFiles() }
        .onChange(of: WorkspaceContext.selectedOrgID) { _ in clearAccountFiles() }
        .onChange(of: auth.isIdentified) { identified in if !identified { clearAccountFiles() } }
        .confirmationDialog("Replace the walkthrough on this iPhone?", isPresented: Binding(get: { replaceVideo != nil }, set: { if !$0 { replaceVideo = nil } }), presenting: replaceVideo) { video in
            Button("Use cloud video") { replaceVideo = nil; importVideo(video) }
            Button("Keep current video", role: .cancel) { replaceVideo = nil }
        } message: { _ in Text("This changes the video selected for editing. Your published tour stays available.") }
    }

    @ViewBuilder private var creativeSection: some View {
        if let creativeError { Text(creativeError).font(.subheadline).foregroundStyle(.orange) }
        if let creative {
            if !creative.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Studio script").font(.headline)
                    Text(creative.script).font(.subheadline).textSelection(.enabled)
                    Button("Use script in Reel Studio") {
                        guard let org = current.serverOrgID, let sid = current.serverID,
                              let captured = try? CloudMediaAccessContext.capture(orgID: org),
                              hasCurrentMediaContext(captured, localID: current.id, listingID: sid) else { return }
                        do {
                            try CloudVoiceStore.saveScript(creative.script, listingID: current.id)
                            notice = "Script saved. Open Reel Studio on this listing to continue."
                        } catch { self.error = "The script couldn't be saved. Please try again." }
                    }.buttonStyle(.bordered).disabled(importing != nil)
                }.padding().background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14))
            }
            let voices = creative.results.filter { $0.kind == "voice" }
            if !voices.isEmpty {
                Text("Studio narration").font(.headline)
                ForEach(voices) { voice in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(voice.label).font(.subheadline.weight(.medium))
                        if let disclosure = voice.disclosure { Text(disclosure).font(.caption).foregroundStyle(Theme.inkDim) }
                        if voice.state == "completed", let url = voice.url {
                            CloudAudioPreview(url: url)
                            Button { importVoice(voice) } label: {
                                Label(imported.contains(voice.id) ? "Ready in Reel Studio" : "Use narration on iPhone", systemImage: "waveform")
                            }.buttonStyle(.bordered).disabled(importing != nil || imported.contains(voice.id))
                        } else {
                            Text(voice.state == "failed" || voice.state == "needs_review" ? "Open Studio to review this generation." : "Narration is still processing. Refresh when it finishes.")
                                .font(.caption).foregroundStyle(Theme.inkDim)
                        }
                    }.padding().background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    @MainActor private func clearAccountFiles() {
        importTask?.cancel(); importGeneration = UUID(); importing = nil; importTask = nil
        photos = []; videos = []; chapters = []; imported = []; savedCopies = []
        creative = nil; creativeError = nil; notice = nil; replaceVideo = nil; mediaContext = nil
    }

    @MainActor private func load(more: Bool = false) async {
        guard !loading, importing == nil else { return }
        loading = true; error = nil
        defer { loading = false }
        if !more { photos = []; videos = []; chapters = []; nextOffset = nil; creative = nil; creativeError = nil; mediaContext = nil }
        guard auth.isIdentified else { error = "Connect the same Apple account you use in Studio to see shared files."; return }
        let initialActor = auth.userID, initialRevision = auth.syncSessionRevision, initialOrg = WorkspaceContext.selectedOrgID
        if current.serverOrgID == nil { await model.refreshCloudWorkspace() }
        guard auth.userID == initialActor, auth.syncSessionRevision == initialRevision, WorkspaceContext.selectedOrgID == initialOrg else { return }
        guard let sid = current.serverID, let org = current.serverOrgID, current.cloudUnavailable != true,
              let cloud = model.api as? WorkspaceSyncAPI else { error = "This listing hasn't reached your cloud workspace yet. Publish or upload it first."; return }
        let actor = auth.userID, revision = auth.syncSessionRevision
        guard let captured = try? CloudMediaAccessContext.capture(orgID: org) else { return }
        do {
            let offset = more ? (nextOffset ?? 0) : 0
            let page = try await cloud.cloudMedia(listingID: sid, orgID: org, offset: offset)
            guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified, current.serverID == sid, current.serverOrgID == org,
                  (try? captured.check()) != nil else { throw CloudSyncError.identityChanged }
            guard Set(photos.map(\.id)).isDisjoint(with: page.photos.map(\.id)), Set(videos.map(\.id)).isDisjoint(with: page.videos.map(\.id)) else { throw CloudSyncError.incomplete }
            photos += page.photos; videos += page.videos; nextOffset = page.next_offset
            mediaContext = context(org: org, listingID: sid)
            if page.unavailable_count > 0 { notice = "Some files are still processing or no longer available. Refresh after the upload finishes." }
            if !more {
                let state = try await cloud.cloudListingState(listingID: sid, orgID: org, offset: 0)
                guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified,
                      hasCurrentMediaContext(captured, localID: current.id, listingID: sid) else { throw CloudSyncError.identityChanged }
                chapters = state.chapters
                do {
                    let saved = try await cloud.cloudCreative(listingID: sid, orgID: org)
                    guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified,
                      hasCurrentMediaContext(captured, localID: current.id, listingID: sid) else { throw CloudSyncError.identityChanged }
                    creative = saved
                } catch {
                    if auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified,
                       hasCurrentMediaContext(captured, localID: current.id, listingID: sid) {
                        creativeError = "Studio scripts and narration couldn't be loaded. Refresh to try again."
                    }
                }
            }
        } catch is CancellationError { return }
        catch { if auth.userID == actor && auth.syncSessionRevision == revision { self.error = error is CloudSyncError ? error.localizedDescription : "Cloud files couldn't be loaded. Refresh to try again." } }
    }

    @MainActor private func saveAvailableCopy(_ photo: CloudMediaPage.Photo) {
        guard importing == nil, photo.original_url == nil, photo.is_altered != false,
              let org = current.serverOrgID, let sid = current.serverID,
              current.cloudUnavailable != true else { return }
        let localID = current.id, actor = auth.userID, revision = auth.syncSessionRevision
        guard let captured = try? CloudMediaAccessContext.capture(orgID: org),
              hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { return }
        let generation = UUID(); importGeneration = generation
        importing = photo.id; error = nil; notice = nil
        importTask = Task {
            defer { if importGeneration == generation { importing = nil; importTask = nil } }
            var temporary: URL?
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            do {
                try CloudListingMerge.validateMedia(photo.url, expiry: photo.expires_at,
                    listingID: sid, orgID: org, now: Date(), actorID: captured.actorID)
                guard hasCurrentMediaContext(captured, localID: localID, listingID: sid) else {
                    throw CloudSyncError.identityChanged
                }
                let copy = try await CloudFileDownload.fetch(photo.url, kind: .photo)
                temporary = copy.url
                try Task.checkCancellation()
                guard auth.userID == actor, auth.syncSessionRevision == revision,
                      hasCurrentMediaContext(captured, localID: localID, listingID: sid) else {
                    throw CloudSyncError.identityChanged
                }
                try await PhotosLibrarySaver.saveCloudCopyFile(at: copy.url) {
                    self.hasCurrentMediaContext(captured, localID: localID, listingID: sid)
                }
                guard hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { return }
                savedCopies.insert(photo.id)
                notice = "Copy saved to iPhone Photos. It is not an original; the original and edit history are still unavailable."
            } catch is CancellationError { return }
            catch {
                if hasCurrentMediaContext(captured, localID: localID, listingID: sid) {
                    self.error = error is CloudSyncError ? error.localizedDescription
                        : "The available copy couldn't be saved to iPhone Photos. Check Photos access or free space, then try again."
                }
            }
        }
    }

    @MainActor private func importPhoto(_ photo: CloudMediaPage.Photo) {
        guard importing == nil, let org = current.serverOrgID, let sid = current.serverID,
              let originalURL = photo.original_url ?? (photo.is_altered == false ? photo.url : nil) else { return }
        let localID = current.id, actor = auth.userID, revision = auth.syncSessionRevision
        guard let captured = try? CloudMediaAccessContext.capture(orgID: org),
              hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { return }
        let generation = UUID(); importGeneration = generation
        importing = photo.id; error = nil; notice = nil
        importTask = Task {
            defer { if importGeneration == generation { importing = nil; importTask = nil } }
            var temporary: [URL] = []
            defer { for url in temporary { try? FileManager.default.removeItem(at: url) } }
            do {
                guard hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { throw CloudSyncError.identityChanged }
                try CloudListingMerge.validateMedia(originalURL, expiry: photo.expires_at, listingID: sid, orgID: org, now: Date(), actorID: captured.actorID)
                try CloudListingMerge.validateMedia(photo.url, expiry: photo.expires_at, listingID: sid, orgID: org, now: Date(), actorID: captured.actorID)
                let original = try await CloudFileDownload.fetch(originalURL, kind: .photo); temporary.append(original.url)
                guard hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { throw CloudSyncError.identityChanged }
                let enhanced = photo.url == originalURL ? original : try await CloudFileDownload.fetch(photo.url, kind: .photo)
                if enhanced.url != original.url { temporary.append(enhanced.url) }
                try Task.checkCancellation()
                guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified,
                      hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { throw CloudSyncError.identityChanged }
                let directory = EnhancedPhoto.directory(for: localID)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = "cloud-\(photo.id.uuidString)"
                let originalDest = directory.appendingPathComponent("orig-\(name).\(original.ext)")
                // An interrupted metadata commit must not expose staged bytes
                // through the legacy enh-* scanner as an ordinary photo.
                let enhancedDest = directory.appendingPathComponent("cloud-photo-\(name).\(enhanced.ext)")
                if !FileManager.default.fileExists(atPath: originalDest.path) { try FileManager.default.copyItem(at: original.url, to: originalDest) }
                if !FileManager.default.fileExists(atPath: enhancedDest.path) { try FileManager.default.copyItem(at: enhanced.url, to: enhancedDest) }
                try PhotoVersionHistory.registerImport(id: name, imageFile: enhancedDest.lastPathComponent,
                    originalFile: originalDest.lastPathComponent, staged: photo.is_staged,
                    altered: photo.is_altered != false, directory: directory)
                guard let ownerID = actor.flatMap(UUID.init(uuidString:)) else { throw CloudSyncError.identityChanged }
                // Bind the response's genuine ID to the imported bytes, never to
                // a filename that happens to contain a UUID.
                try await CloudPhotoReferences.shared.save(sourceID: photo.id, fileURL: enhanced.url,
                    ownerID: ownerID, orgID: org, listingID: sid)
                guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified,
                      hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { throw CloudSyncError.identityChanged }
                if current.mainPhotoURL == nil,
                   let cover = try PhotoVersionHistory.availableCoverVersion(directory: directory) {
                    model.modify(localID, sync: false) {
                        $0.mainPhotoRelPath = FileStore.relativePath(for: directory.appendingPathComponent(cover.imageFile))
                    }
                }
                imported.insert(photo.id); notice = "Photo and its original are available in this listing's Photo Studio."
            } catch is CancellationError { return }
            catch { if hasCurrentMediaContext(captured, localID: localID, listingID: sid) { self.error = error is CloudSyncError ? error.localizedDescription : "The photo couldn't be saved. Refresh its private link and try again." } }
        }
    }

    @MainActor private func importVideo(_ video: CloudMediaPage.Video) {
        guard importing == nil, let org = current.serverOrgID, let sid = current.serverID else { return }
        let localID = current.id, actor = auth.userID, revision = auth.syncSessionRevision
        guard let captured = try? CloudMediaAccessContext.capture(orgID: org),
              hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { return }
        let generation = UUID(); importGeneration = generation
        importing = video.id; error = nil; notice = nil
        importTask = Task {
            defer { if importGeneration == generation { importing = nil; importTask = nil } }
            var temp: URL?, saved: URL?
            defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
            do {
                guard hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { throw CloudSyncError.identityChanged }
                try CloudListingMerge.validateMedia(video.url, expiry: video.expires_at, listingID: sid, orgID: org, now: Date(), actorID: captured.actorID)
                let file = try await CloudFileDownload.fetch(video.url, kind: .video); temp = file.url
                guard hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { throw CloudSyncError.identityChanged }
                let destination = FileStore.importsDir.appendingPathComponent("cloud-\(video.id.uuidString)-\(UUID().uuidString).\(file.ext)")
                try FileManager.default.copyItem(at: file.url, to: destination); saved = destination
                var asset = try await MediaImporter.makeAsset(from: destination, isDrone: nil)
                asset.roomTags = chapters.filter { $0.asset_id == video.id }.sorted { $0.sort < $1.sort }.map { RoomTag(name: $0.label, tMs: $0.t_ms) }
                try Task.checkCancellation()
                guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified,
                      hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { throw CloudSyncError.identityChanged }
                model.assets[localID] = asset; imported.insert(video.id)
                notice = "Video saved. Open the listing and choose Create tour to edit it on your iPhone."
                saved = nil
            } catch is CancellationError { if let saved { try? FileManager.default.removeItem(at: saved) }; return }
            catch { if let saved { try? FileManager.default.removeItem(at: saved) }; if hasCurrentMediaContext(captured, localID: localID, listingID: sid) { self.error = error is CloudSyncError ? error.localizedDescription : "The video couldn't be saved. Check free space, refresh its link and try again." } }
        }
    }

    @MainActor private func importVoice(_ voice: CloudCreative.Result) {
        guard importing == nil, auth.isIdentified, let org = current.serverOrgID, let sid = current.serverID,
              let url = voice.url, let expiry = voice.expires_at, voice.state == "completed", voice.kind == "voice" else { return }
        let localID = current.id, actor = auth.userID, revision = auth.syncSessionRevision
        guard let captured = try? CloudMediaAccessContext.capture(orgID: org),
              hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { return }
        let generation = UUID(); importGeneration = generation
        importing = voice.id; error = nil; notice = nil
        importTask = Task {
            defer { if importGeneration == generation { importing = nil; importTask = nil } }
            var temporary: URL?
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            do {
                guard hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { throw CloudSyncError.identityChanged }
                try CloudListingMerge.validateMedia(url, expiry: expiry, listingID: sid, orgID: org, now: Date(), voice: true, actorID: captured.actorID)
                let file = try await CloudFileDownload.fetch(url, kind: .audio); temporary = file.url
                try Task.checkCancellation()
                guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified,
                      hasCurrentMediaContext(captured, localID: localID, listingID: sid) else { throw CloudSyncError.identityChanged }
                try CloudVoiceStore.saveVoice(voice, file: file.url, ext: file.ext, listingID: localID)
                imported.insert(voice.id); notice = "Narration saved. Open Reel Studio on this listing to use it."
            } catch is CancellationError { return }
            catch { if hasCurrentMediaContext(captured, localID: localID, listingID: sid) { self.error = error is CloudSyncError ? error.localizedDescription : "The narration couldn't be saved. Refresh its link and try again." } }
        }
    }
}

private struct CloudVideoPreview: View {
    @State private var player: AVPlayer
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View { VideoPlayer(player: player).onDisappear { player.pause() } }
}

private struct CloudAudioPreview: View {
    @State private var player: AVPlayer
    @State private var playing = false
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View {
        Button {
            if playing { player.pause() } else { player.seek(to: .zero); player.play() }
            playing.toggle()
        } label: { Label(playing ? "Stop preview" : "Play narration", systemImage: playing ? "pause.circle" : "play.circle") }
            .onDisappear { player.pause(); playing = false }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { event in
                if let item = event.object as? AVPlayerItem, item === player.currentItem { playing = false }
            }
    }
}

/// The private capability URL is the only authority sent to R2. No Supabase
/// bearer, cookie, redirect or JSON body crosses to storage.
enum CloudFileDownload {
    enum Kind { case photo, video, audio }
    struct File { let url: URL; let ext: String }
    final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func fetch(_ url: URL, kind: Kind) async throws -> File {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalCacheData
        let (temporary, response) = try await session.download(for: request, delegate: NoRedirect())
        do {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CloudSyncError.invalidResponse }
            let bytes = FileStore.fileSize(temporary), maxBytes: Int64 = kind == .video ? 2 * 1024 * 1024 * 1024 : (kind == .photo ? 25 : 64) * 1024 * 1024
            guard bytes > 0, bytes <= maxBytes else { throw CloudSyncError.invalidResponse }
            let type = http.mimeType?.lowercased() ?? ""
            let types: [String: String]
            switch kind {
            case .photo: types = ["image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"]
            case .video: types = ["video/mp4": "mp4", "video/quicktime": "mov"]
            case .audio: types = ["audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/wav": "wav", "audio/x-wav": "wav", "audio/ogg": "ogg"]
            }
            guard let ext = types[type], http.expectedContentLength < 0 || http.expectedContentLength == bytes else { throw CloudSyncError.invalidResponse }
            let owned = FileManager.default.temporaryDirectory.appendingPathComponent("rendprop-cloud-\(UUID().uuidString).\(ext)")
            try FileManager.default.moveItem(at: temporary, to: owned)
            return File(url: owned, ext: ext)
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
}

/// Private object identities never become browser links. Resolve only the exact
/// attached asset from the already checked account-scoped, expiring media page.
enum CloudFloorPlanLink {
    static func resolve(details: [String: String]?, photos: [CloudMediaPage.Photo],
                        listingID: UUID, orgID: UUID, now: Date, actorID: UUID? = nil) -> URL? {
        if let rawID = details?["floorplan_asset_id"] {
            guard let id = UUID(uuidString: rawID), let photo = photos.first(where: { $0.id == id && $0.listing_id == listingID }),
                  (try? CloudListingMerge.validateMedia(photo.url, expiry: photo.expires_at,
                      listingID: listingID, orgID: orgID, now: now, actorID: actorID)) != nil else { return nil }
            return photo.url
        }
        // Preserve a user's external plan attachment, never an old R2 alias.
        guard let raw = details?["floorplan_url"], let url = URL(string: raw),
              url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.hasSuffix(".r2.cloudflarestorage.com"),
              !host.hasSuffix(".r2.dev"),
              !["rendprop.com", "www.rendprop.com", "cdn.rendprop.com", "media.rendprop.com", "renders.rendprop.com"].contains(host),
              !url.path.split(separator: "/").contains(where: { ["renders", "uploads"].contains(String($0)) }),
              !raw.contains("X-Amz-") else { return nil }
        return url
    }
}
