import SwiftUI
import UIKit
import AVFoundation

// MARK: - Background URLSession bridge
// iOS relaunches the app for background-upload events; the completion handler
// must be stored here and called after the session delegate drains its events.
final class BackgroundSessionBridge {
    static let shared = BackgroundSessionBridge()
    var completionHandler: (() -> Void)?
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundSessionBridge.shared.completionHandler = completionHandler
        _ = UploadManager.shared // recreate the background session so events are delivered
    }
}

// MARK: - App state
@MainActor
final class AppModel: ObservableObject {
    // Every mutation auto-saves to disk (see `persist()`), so a listing, its video,
    // and its rendered tour all survive an app kill. `isRestoring` suppresses saves
    // while we're loading the snapshot back in.
    @Published var listings: [Listing] = []           { didSet { persist() } }
    @Published var renders: [UUID: Render] = [:]       { didSet { persist() } } // listingID → render (tier picked at submit)
    @Published var assets: [UUID: CaptureAsset] = [:]  { didSet { persist() } } // listingID → recorded/imported video

    struct RenderedTour {
        let url: URL
        let durationS: Double
        let speedFactor: Double
    }
    @Published var tours: [UUID: RenderedTour] = [:]   { didSet { persist() } } // listingID → rendered tour

    /// Listings whose local tour still needs to reach the cloud (publish
    /// failed, sign-in declined, app killed mid-upload). Persisted, so a relaunch
    /// finishes the job (decision A2). Order = FIFO.
    @Published var pendingPublish: [UUID] = []         { didSet { persist() } }

    /// A role=render upload that already landed on the server for a listing's
    /// tour file (Documents-relative path → server asset id). Lets a retried
    /// publish skip the multi-hundred-MB re-upload and keep the SAME server
    /// asset (so the publish idempotency key replays instead of minting a second
    /// tour). Cleared when the publish succeeds.
    struct UploadedRenderAsset: Codable, Hashable {
        var relPath: String
        var assetID: String
    }
    @Published var uploadedRenderAssets: [UUID: UploadedRenderAsset] = [:] { didSet { persist() } }

    // Mock by default (offline dev); LiveAPIClient when Config.useLiveBackend.
    let api: APIClient = Config.makeAPIClient()

    /// Owns every render/publish `Task` so navigating away never cancels or
    /// re-runs one (audit F-B-04 / F-D-01). Views observe it for progress.
    let renderCoordinator = RenderCoordinator()

    private var hasLoaded = false
    private var isRestoring = false
    private var syncInFlight: Set<UUID> = []
    private var publishInFlight: Set<UUID> = []
    private var uploadObserver: NSObjectProtocol?

    init() {
        renderCoordinator.model = self
        // A different Apple ID signing in means every cached server id belongs
        // to the previous account's org — drop them so publishing re-creates the
        // listings instead of 404ing forever (audit F-E-12).
        AuthStore.shared.onAccountChanged = { [weak self] in
            Task { @MainActor [weak self] in self?.forgetServerIdentities() }
        }
        // A publish upload that outlived the process (killed mid-upload, resumed
        // by UploadManager on relaunch) completes here; nobody else is waiting
        // for it, so finish the publish with the completed asset (F-B-01 e).
        uploadObserver = NotificationCenter.default.addObserver(
            forName: UploadManager.didCompleteNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let assetID = note.userInfo?["assetID"] as? String else { return }
            let serverListingID = note.userInfo?["listingID"] as? UUID
            Task { @MainActor [weak self] in
                await self?.handleUploadCompleted(assetID: assetID, serverListingID: serverListingID)
            }
        }
    }

    /// Clear every per-account server reference (called when the signed-in
    /// account changes). Local tours/assets are untouched.
    func forgetServerIdentities() {
        for i in listings.indices {
            listings[i].serverID = nil
            listings[i].shareSlug = nil
            listings[i].shareURL = nil
            listings[i].publishedRenderID = nil
            listings[i].needsServerSync = nil
        }
        uploadedRenderAssets.removeAll()
        pendingPublish.removeAll()
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        // 1. Restore the user's real listings/assets/tours from disk.
        isRestoring = true
        let saved = PersistentStore.load()
        listings = saved.listings
        assets = saved.assets
        tours = saved.tours
        renders = saved.renders
        pendingPublish = saved.pendingPublish
        uploadedRenderAssets = saved.uploadedRenderAssets
        reconcileAfterRestore()
        isRestoring = false

        // 2. Seed the demo listings for the CURRENT business type (never
        //    persisted; a venue owner sees a venue, not a house) and write the
        //    reconciled snapshot once.
        reseedSamples()
        persist()

        // 3. In the background: push local edits the server hasn't seen and
        //    finish any publish that was interrupted.
        Task { [weak self] in
            await self?.syncDirtyListings()
            await self?.resumePendingPublishes()
        }
    }

    /// The status machine has no recovery edge at runtime, so repair it on
    /// launch (decision A4):
    ///  • processing/uploading WITHOUT a tour → draft + "Render didn't finish"
    ///  • processing/uploading WITH a tour    → ready (+ queued for publish when
    ///    it has no share link yet — the user did ask for one)
    ///  • ready without a tour AND without a share link → draft (file went missing)
    private func reconcileAfterRestore() {
        for i in listings.indices where !listings[i].isSample {
            let id = listings[i].id
            let hasTour = tours[id] != nil
            let hasShare = listings[i].serverShareURL != nil
            switch listings[i].status {
            case .processing, .uploading:
                if hasTour {
                    listings[i].status = .ready
                    if !hasShare && !pendingPublish.contains(id) { pendingPublish.append(id) }
                } else {
                    listings[i].status = .draft
                    listings[i].lastError = "The render didn't finish. Open the listing to try again."
                }
            case .ready:
                if !hasTour && !hasShare {
                    listings[i].status = .draft
                    if assets[id] != nil {
                        listings[i].lastError = "The rendered tour is missing from this phone. Create it again."
                    }
                }
            case .draft, .expired:
                break
            }
        }
        // Only real listings that still have a local tour and no link can be pending.
        pendingPublish = pendingPublish.filter { id in
            guard let l = listings.first(where: { $0.id == id }), !l.isSample else { return false }
            return tours[id] != nil && l.serverShareURL == nil
        }
        uploadedRenderAssets = uploadedRenderAssets.filter { entry in
            listings.contains { $0.id == entry.key && !$0.isSample }
        }
    }

    /// Samples are DERIVED from the current business type: real listings stay,
    /// the demo rows are swapped for the current type's. Safe to call from any
    /// place the type can change (Home menu, Settings, onboarding re-pick) —
    /// samples are never persisted and ids are stable (decision A7).
    func reseedSamples() {
        guard hasLoaded else { return }   // load() seeds; seeding earlier would persist an empty snapshot
        let real = listings.filter { !$0.isSample }
        listings = real + SpaceType.current.sampleListings
    }

    // MARK: - Mutations

    private func index(of id: UUID) -> Int? {
        listings.firstIndex(where: { $0.id == id })
    }

    func add(_ listing: Listing) {
        listings.insert(listing, at: 0)   // persists via didSet
    }

    /// Local pipeline state only — never synced (the server owns its own status).
    func setStatus(_ status: Listing.Status, for id: UUID) {
        guard let i = index(of: id) else { return }
        guard listings[i].status != status else { return }
        listings[i].status = status       // persists via didSet
    }

    /// Mutate a listing in place. Marks it dirty and pushes the change to the
    /// server (when it has a server identity) unless `sync` is false.
    /// No-ops if the listing is gone.
    func modify(_ id: UUID, sync: Bool = true, _ mutate: (inout Listing) -> Void) {
        guard let i = index(of: id) else { return }
        mutate(&listings[i])              // persists via didSet
        if sync {
            markDirty(id)
            Task { [weak self] in await self?.syncListing(id) }
        }
    }

    func setSold(_ sold: Bool, for id: UUID) {
        guard let i = index(of: id), !listings[i].isSample else { return }
        listings[i].soldAt = sold ? Date() : nil   // persists via didSet
        markDirty(id)
        Task { [weak self] in await self?.syncListing(id) }
    }

    func setZillow(_ url: String, for id: UUID) {
        guard let i = index(of: id), !listings[i].isSample else { return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        listings[i].zillowURL = trimmed.isEmpty ? nil : trimmed
        markDirty(id)
        Task { [weak self] in await self?.syncListing(id) }
    }

    func setMainPhoto(_ relPath: String?, for id: UUID) {
        guard let i = index(of: id), !listings[i].isSample else { return }
        listings[i].mainPhotoRelPath = relPath
        markDirty(id)
        Task { [weak self] in await self?.syncListing(id) }
    }

    func setCoordinate(lat: Double, lon: Double, for id: UUID) {
        guard let i = index(of: id) else { return }
        listings[i].latitude = lat
        listings[i].longitude = lon
        markDirty(id)
        Task { [weak self] in await self?.syncListing(id) }
    }

    /// Exterior photo used to ground the AI aerial (Documents-relative). Local only.
    func setExteriorPhoto(_ relPath: String?, for id: UUID) {
        guard let i = index(of: id), !listings[i].isSample else { return }
        listings[i].exteriorPhotoRelPath = relPath
    }

    /// The latest generated aerial clip (Documents-relative) + timestamp. Local only.
    func setAerial(relPath: String?, generatedAt: Date?, for id: UUID) {
        guard let i = index(of: id), !listings[i].isSample else { return }
        listings[i].aerialRelPath = relPath
        listings[i].aerialGeneratedAt = generatedAt
    }

    /// City/State from the geocode (never the street). Local only.
    func setRegion(_ label: String?, for id: UUID) {
        guard let i = index(of: id) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        listings[i].regionLabel = trimmed.isEmpty ? nil : trimmed
    }

    /// Why the last render/publish failed (nil clears it). Local only.
    func setLastError(_ message: String?, for id: UUID) {
        guard let i = index(of: id) else { return }
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard listings[i].lastError != value else { return }
        listings[i].lastError = value
    }

    /// Flag a listing as having local edits the server hasn't seen. Meaningful
    /// only once it has a server identity (before first publish the create
    /// call sends the full listing anyway).
    func markDirty(_ id: UUID) {
        guard let i = index(of: id), !listings[i].isSample, listings[i].serverID != nil else { return }
        if listings[i].needsServerSync != true { listings[i].needsServerSync = true }
    }

    // MARK: - Delete

    /// Remove a listing everywhere: model maps, every file it produced, any
    /// in-flight render/publish, and (best effort) the server row — which also
    /// unpublishes its hosted tour (decision A3). Samples are never removed.
    func remove(_ id: UUID) async {
        guard let listing = listings.first(where: { $0.id == id }), !listing.isSample else { return }

        renderCoordinator.cancel(listingID: id)
        // A publish upload for THIS listing must not keep streaming a file we
        // are about to delete.
        if let s = UploadManager.shared.state, s.status != .done, s.role == "render",
           let sid = listing.serverID, s.listingID == sid {
            UploadManager.shared.cancel()
        }

        let asset = assets.removeValue(forKey: id)
        let tour = tours.removeValue(forKey: id)
        renders.removeValue(forKey: id)
        uploadedRenderAssets.removeValue(forKey: id)
        pendingPublish.removeAll { $0 == id }
        listings.removeAll { $0.id == id }

        let assetURL = asset?.localURL
        let sidecarURL = asset?.motionSidecarURL
        let assetID = asset?.id
        let tourURL = tour?.url
        await Task.detached(priority: .utility) {
            FileStore.deleteListingFiles(listingID: id, assetURL: assetURL, sidecarURL: sidecarURL,
                                         assetID: assetID, tourURL: tourURL)
        }.value

        if Config.useLiveBackend, let sid = listing.serverID {
            try? await api.deleteListing(serverID: sid)
        }
    }

    // MARK: - Server sync (local edits → PATCH /listings/:serverID, decision A6)

    /// PATCH the listing if it is dirty; clears the flag on success. Never
    /// throws — a failed sync simply stays dirty and is retried on the next
    /// mutation or launch. Re-entrant-safe per listing: a second call while one
    /// is in flight returns immediately; the in-flight loop re-checks the flag
    /// after each PATCH so an edit made mid-sync is not lost.
    func syncListing(_ id: UUID) async {
        guard Config.useLiveBackend else { return }
        guard !syncInFlight.contains(id) else { return }
        syncInFlight.insert(id)
        defer { syncInFlight.remove(id) }

        var attempts = 0
        while attempts < 3,
              let snapshot = listings.first(where: { $0.id == id }),
              !snapshot.isSample, snapshot.serverID != nil, snapshot.needsServerSync == true {
            attempts += 1
            guard !Config.enableAuth || AuthStore.shared.isSignedIn else { return }   // signed out: keep it dirty
            do {
                _ = try await api.updateListing(snapshot)
                if let i = index(of: id), listings[i] == snapshot {
                    listings[i].needsServerSync = false
                }
                // else: edited again while the PATCH was in flight → loop once more
            } catch {
                return   // stays dirty; retried later
            }
        }
    }

    /// Push every dirty listing (called on launch and by pull-to-refresh).
    func syncDirtyListings() async {
        let dirty = listings.filter { !$0.isSample && $0.serverID != nil && $0.needsServerSync == true }.map { $0.id }
        for id in dirty {
            await syncListing(id)
        }
    }

    // MARK: - Cloud publish (local-first + cloud-publish, contract §4)

    enum PublishError: LocalizedError {
        case sampleListing, listingMissing, noLocalTour, noShareURL
        var errorDescription: String? {
            switch self {
            case .sampleListing:  return "Sample tours can't be published — create your own first."
            case .listingMissing: return "That listing no longer exists on this phone."
            case .noLocalTour:    return "There's no rendered tour to publish yet — create the tour first."
            case .noShareURL:     return "The server didn't return a share link. Please try again."
            }
        }
    }

    /// Return the server listing id for a local listing, creating the server
    /// listing on first publish and adopting its id as the listing's server
    /// identity (persisted). All later server calls for this listing use it.
    func ensureServerListing(_ listing: Listing) async throws -> UUID {
        let localID = listing.id
        if let existing = listings.first(where: { $0.id == localID })?.serverID {
            return existing
        }
        // Sync using the freshest local copy (address/details may have changed).
        let live = listings.first(where: { $0.id == localID }) ?? listing
        let created = try await api.createListing(live)
        let serverID = created.id
        if let i = listings.firstIndex(where: { $0.id == localID }) {
            listings[i].serverID = serverID   // persists via didSet
        }
        return serverID
    }

    /// Room tags → tap-to-jump chapters, sorted by time. Room tags are timed
    /// against the ORIGINAL capture, but the published mp4 is retimed by
    /// `speedFactor` (a 2× walk halves timestamps). Rescale to the RENDERED
    /// timeline so the public player's dots land exactly where the in-app
    /// preview shows them (FlythroughDetailView.playbackTags does the same).
    static func chapters(from roomTags: [RoomTag], speedFactor: Double) -> [ChapterInput] {
        let sf = (speedFactor.isFinite && speedFactor > 0) ? speedFactor : 1.0
        return roomTags
            .sorted { $0.tMs < $1.tMs }
            .enumerated()
            .map { idx, tag in
                ChapterInput(label: tag.name, tMs: max(0, Int((Double(tag.tMs) / sf).rounded())), sort: idx)
            }
    }

    /// Publish the app's ON-DEVICE render as the hosted tour (contract §2.7):
    /// ensure a server listing → first-frame poster (best effort) → upload the
    /// scrub-master mp4 (role=render, reusing an already-landed asset when we
    /// have one) → POST /renders/publish-app with room-tag chapters → persist
    /// the REAL slug/URL/render id on the listing. The listing sits in
    /// `pendingPublish` for the duration so a kill mid-way resumes on relaunch.
    /// On failure `lastError` carries the server's message and the listing stays
    /// pending; the local tour keeps playing in-app either way.
    func publishTour(listing: Listing,
                     renderOutputURL: URL,
                     durationS: Double,
                     speedFactor: Double,
                     roomTags: [RoomTag],
                     enhancements: Enhancements,
                     tier: Render.Tier,
                     existingAssetID: String? = nil) async throws -> PublishedTour {
        let id = listing.id
        guard !listing.isSample else { throw PublishError.sampleListing }
        _ = enhancements   // decision A5: the wire always carries the defaults (no video restage exists)

        if !pendingPublish.contains(id) { pendingPublish.append(id) }
        publishInFlight.insert(id)
        defer { publishInFlight.remove(id) }

        do {
            // 1. Adopt (or create) the server listing identity.
            let serverID = try await ensureServerListing(listing)

            // 2. First-frame poster → og:image / video poster on the hosted page.
            //    Best effort: publishing still works without it.
            var posterAssetID: String? = nil
            var posterFile: URL? = nil
            if let poster = await PosterMaker.makePoster(from: renderOutputURL, listingID: id) {
                posterFile = poster
                posterAssetID = try? await UploadManager.shared.uploadPoster(fileURL: poster, listingID: serverID)
            }

            // 3. Upload the rendered mp4 to the PUBLIC renders bucket (or reuse).
            let relPath = FileStore.relativePath(for: renderOutputURL)
            let assetID: String
            if let existingAssetID {
                assetID = existingAssetID
            } else if let remembered = uploadedRenderAssets[id], remembered.relPath == relPath {
                assetID = remembered.assetID
            } else {
                let bytes = FileStore.fileSize(renderOutputURL)
                let meta = UploadMetadata(durationS: durationS, bytes: bytes)
                assetID = try await UploadManager.shared.upload(
                    fileURL: renderOutputURL, listingID: serverID, role: "render", metadata: meta)
            }
            uploadedRenderAssets[id] = UploadedRenderAsset(relPath: relPath, assetID: assetID)

            // 4. Publish (idempotent per listing+asset — LiveAPIClient derives the key).
            let published = try await api.publishApp(
                listingID: serverID, assetID: assetID, durationS: durationS,
                speedFactor: speedFactor, tier: tier, enhancements: Enhancements(),
                chapters: Self.chapters(from: roomTags, speedFactor: speedFactor),
                posterAssetID: posterAssetID)

            // 5. Persist the REAL server slug/URL onto the local listing (never
            //    fabricated). One assignment → one snapshot write.
            if let i = index(of: id) {
                var l = listings[i]
                l.shareSlug = published.slug
                l.shareURL = published.shareURL
                if let rid = published.renderID { l.publishedRenderID = rid }
                l.lastError = nil
                l.status = .ready
                listings[i] = l   // persists via didSet
            }
            pendingPublish.removeAll { $0 == id }
            uploadedRenderAssets.removeValue(forKey: id)
            if let posterFile { try? FileManager.default.removeItem(at: posterFile) }
            return published
        } catch {
            if !(error is CancellationError) {
                setLastError(Self.userMessage(for: error), for: id)
            }
            // A server that no longer knows the asset (or rejected it) must not
            // be handed the same id again — re-upload on the next attempt.
            if let api = error as? APIError, api.isNotFound || api.isValidation {
                uploadedRenderAssets.removeValue(forKey: id)
            }
            throw error
        }
    }

    /// Publish the EXISTING local tour — no re-render (decision A2). Used by
    /// the listing detail's "Publish tour", RenderStatusView's "Retry publish",
    /// and the launch-time resume. Returns the public share URL.
    func publishExisting(listingID id: UUID, existingAssetID: String? = nil) async throws -> URL {
        guard let listing = listings.first(where: { $0.id == id }) else { throw PublishError.listingMissing }
        guard !listing.isSample else { throw PublishError.sampleListing }
        guard let tour = tours[id] else { throw PublishError.noLocalTour }
        let render = renders[id] ?? Render(listingID: id, tier: .smooth, durationS: tour.durationS)
        let tags = assets[id]?.roomTags ?? []
        let published = try await publishTour(listing: listing,
                                              renderOutputURL: tour.url,
                                              durationS: tour.durationS,
                                              speedFactor: tour.speedFactor,
                                              roomTags: tags,
                                              enhancements: render.enhancements,
                                              tier: render.tier,
                                              existingAssetID: existingAssetID)
        if let url = URL(string: published.shareURL) { return url }
        if let url = listings.first(where: { $0.id == id })?.serverShareURL { return url }
        throw PublishError.noShareURL
    }

    /// Queue a listing for publish (idempotent). Used by the coordinator when
    /// the user declines sign-in after a render.
    func addPendingPublish(_ id: UUID) {
        guard listings.contains(where: { $0.id == id && !$0.isSample }) else { return }
        if !pendingPublish.contains(id) { pendingPublish.append(id) }
    }

    /// Finish publishes interrupted by a kill/offline moment. Runs on launch
    /// (after restore). Sequential — the upload engine allows one active upload.
    func resumePendingPublishes() async {
        guard Config.useLiveBackend else { return }
        guard !Config.enableAuth || AuthStore.shared.isSignedIn else { return }   // never prompts on its own
        for id in pendingPublish {
            guard let l = listings.first(where: { $0.id == id }), !l.isSample, tours[id] != nil else {
                pendingPublish.removeAll { $0 == id }
                continue
            }
            guard l.serverShareURL == nil else {
                pendingPublish.removeAll { $0 == id }
                continue
            }
            guard !renderCoordinator.isRunning(id), !publishInFlight.contains(id) else { continue }

            // The upload engine may still be finishing THIS listing's render upload
            // (resumed from a previous launch): let didCompleteNotification finish it.
            if let s = UploadManager.shared.state, s.role == "render",
               let sid = l.serverID, s.listingID == sid {
                switch s.status {
                case .uploading, .queued, .paused, .failed:
                    continue
                case .done:
                    if let assetID = s.assetID {
                        _ = try? await publishExisting(listingID: id, existingAssetID: assetID)
                        continue
                    }
                }
            }
            _ = try? await publishExisting(listingID: id)
        }
    }

    /// A role=render upload finished (possibly one resumed from a previous
    /// launch). If a pending listing owns it and nobody is awaiting it, publish
    /// with the completed asset — no re-upload.
    private func handleUploadCompleted(assetID: String, serverListingID: UUID?) async {
        guard Config.useLiveBackend, let serverListingID else { return }
        guard UploadManager.shared.state?.role == "render" else { return }
        guard let l = listings.first(where: { $0.serverID == serverListingID && !$0.isSample }) else { return }
        let id = l.id
        guard pendingPublish.contains(id), tours[id] != nil, l.serverShareURL == nil else { return }
        guard !renderCoordinator.isRunning(id), !publishInFlight.contains(id) else { return }   // an in-app publish is awaiting this upload
        guard !Config.enableAuth || AuthStore.shared.isSignedIn else { return }
        _ = try? await publishExisting(listingID: id, existingAssetID: assetID)
    }

    /// The text a user should see for a failed render/publish: the server's own
    /// message when it sent one, else the error's description.
    static func userMessage(for error: Error) -> String {
        if let api = error as? APIError {
            let base = api.errorDescription ?? "The server returned an error."
            if api.isUnauthorized { return "Please sign in again to publish. \(base)" }
            return base
        }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Something went wrong. Please try again." : text
    }

    private func persist() {
        guard hasLoaded, !isRestoring else { return }
        PersistentStore.save(listings: listings, assets: assets, tours: tours, renders: renders,
                             pendingPublish: pendingPublish, uploadedRenderAssets: uploadedRenderAssets)
    }
}

// MARK: - First-frame poster for the hosted page
enum PosterMaker {
    /// A 1280 px JPEG (q 0.8) of the tour's first frame in Caches. Nil on any
    /// failure — the poster is best effort.
    static func makePoster(from videoURL: URL, listingID: UUID) async -> URL? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let time = CMTime(seconds: 0.25, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        let cgImage = result.image
        let dir = FileStore.caches.appendingPathComponent("posters", isDirectory: true)
        let out = dir.appendingPathComponent("poster-\(listingID.uuidString).jpg")
        let written: Bool = await Task.detached(priority: .userInitiated) {
            guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8) else { return false }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                try data.write(to: out, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
        return written ? out : nil
    }
}

// MARK: - Render coordinator
// Owns the render → (AI enhance) → publish pipeline per listing so the work
// survives navigation, tab switches and the sign-in sheet. RenderStatusView
// only OBSERVES `jobs`; cancellation is an explicit user action.

struct RenderJobState: Equatable {
    enum Stage: String, Equatable {
        case rendering, enhancing, publishing          // running
        case rendered                                   // encoded; publish not attempted yet
        case awaitingSignIn                             // parked: publishing needs sign-in
        case published, publishFailed, failed, cancelled
    }
    var phase: String
    var fraction: Double
    var error: String?
    var isRunning: Bool
    var stage: Stage = .rendering
    /// Explanation shown when the AI enhance was skipped/fell back.
    var note: String? = nil
    /// HTTP status behind `error` when the server sent one (402 → upgrade CTA, 401 → sign in).
    var errorStatus: Int? = nil
    /// True while the AI enhance wait can be skipped ("publish the standard tour now").
    var canSkipEnhance: Bool = false
}

@MainActor
final class RenderCoordinator: ObservableObject {
    @Published var jobs: [UUID: RenderJobState] = [:]
    weak var model: AppModel?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var runs: [UUID: UUID] = [:]
    private var skipRequested: Set<UUID> = []
    private var backgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]

    private enum EnhanceOutcome {
        case enhanced
        case fallback(masterAssetID: String?)
    }

    private enum EnhanceError: LocalizedError {
        case timeout, noVideo, failed(String)
        var errorDescription: String? {
            switch self {
            case .timeout:            return "the AI enhance took too long"
            case .noVideo:            return "the AI enhance returned no video"
            case .failed(let message): return message
            }
        }
    }

    // MARK: Queries

    func job(for id: UUID) -> RenderJobState? { jobs[id] }
    func isRunning(_ id: UUID) -> Bool { jobs[id]?.isRunning == true }
    func progress(for id: UUID) -> Double { jobs[id]?.fraction ?? 0 }
    var hasActiveJob: Bool { jobs.values.contains { $0.isRunning } }

    // MARK: Commands

    /// Render `asset` into the listing's tour, then publish (or park for
    /// sign-in). No-op while a job for the listing is already running — the
    /// same render can never be started twice.
    func start(listing: Listing, asset: CaptureAsset) {
        let id = listing.id
        guard !isRunning(id) else { return }
        let run = beginRun(id)
        jobs[id] = RenderJobState(phase: "Preparing your video…", fraction: 0.02, error: nil,
                                  isRunning: true, stage: .rendering)
        model?.setStatus(.processing, for: id)
        model?.setLastError(nil, for: id)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.runRender(listingID: id, run: run, asset: asset)
            self.endRun(id, run)
        }
    }

    /// Publish the listing's EXISTING local tour (after sign-in, or "Retry
    /// publish"). `allowEnhance` runs the AI pass first for the AI tiers when
    /// the tour hasn't been enhanced yet.
    func publish(listingID id: UUID, allowEnhance: Bool = false) {
        guard !isRunning(id), let model, model.tours[id] != nil else { return }
        let run = beginRun(id)
        jobs[id] = RenderJobState(phase: "Publishing tour…", fraction: 1, error: nil,
                                  isRunning: true, stage: .publishing)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.runPublish(listingID: id, run: run, allowEnhance: allowEnhance)
            self.endRun(id, run)
        }
    }

    /// Stop waiting for the AI enhance and publish the standard tour now.
    func skipEnhance(listingID id: UUID) {
        guard isRunning(id) else { return }
        skipRequested.insert(id)
        jobs[id]?.canSkipEnhance = false
        jobs[id]?.phase = "Finishing up…"
    }

    /// Explicit user cancel. A render in progress → listing back to draft; a
    /// publish in progress → the local tour stays (ready), just not published.
    func cancel(listingID id: UUID) {
        guard let run = runs[id] else {
            if jobs[id]?.isRunning == true { jobs[id]?.isRunning = false }
            return
        }
        tasks[id]?.cancel()
        // A publish upload that belongs to this listing must stop too (the awaited
        // continuation then resolves as failed).
        if let model, let sid = model.listings.first(where: { $0.id == id })?.serverID,
           let s = UploadManager.shared.state, s.role == "render", s.status != .done, s.listingID == sid {
            UploadManager.shared.cancel()
        }
        let hasTour = model?.tours[id] != nil
        jobs[id] = RenderJobState(phase: hasTour ? "Publish cancelled" : "Render cancelled",
                                  fraction: hasTour ? 1 : 0, error: nil, isRunning: false, stage: .cancelled)
        model?.setStatus(hasTour ? .ready : .draft, for: id)
        model?.pendingPublish.removeAll { $0 == id }   // an explicit cancel is not resumed on launch
        endRun(id, run)
    }

    /// Forget a finished job's state (e.g. when leaving the status screen).
    func clear(listingID id: UUID) {
        guard !isRunning(id) else { return }
        jobs[id] = nil
    }

    // MARK: Pipeline

    private func runRender(listingID id: UUID, run: UUID, asset: CaptureAsset) async {
        guard let model else { return }
        let output: RenderEngine.Output
        do {
            output = try await RenderEngine.render(asset: asset) { [weak self] p, label in
                Task { @MainActor [weak self] in self?.reportProgress(id, run, p, label) }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return }   // cancel() wrote the final state
            if let re = error as? RenderEngine.RenderError, case .cancelled = re { return }
            let message = AppModel.userMessage(for: error)
            model.setStatus(.draft, for: id)
            model.setLastError(message, for: id)
            update(id, run) {
                $0.stage = .failed; $0.phase = "Render didn't finish"
                $0.error = message; $0.errorStatus = nil; $0.isRunning = false; $0.fraction = 0
            }
            return
        }
        guard !Task.isCancelled, runs[id] == run else { return }

        // In-app viewing works from here on — store the local tour first.
        model.tours[id] = AppModel.RenderedTour(url: output.url, durationS: output.durationS,
                                                speedFactor: output.speedFactor)
        model.uploadedRenderAssets.removeValue(forKey: id)   // a new file: any earlier upload is stale
        model.setLastError(nil, for: id)
        update(id, run) { $0.fraction = 1; $0.stage = .rendered; $0.phase = "Rendered" }

        guard Config.useLiveBackend else {
            model.setStatus(.ready, for: id)
            update(id, run) { $0.stage = .published; $0.phase = "Your tour is ready"; $0.isRunning = false }
            Haptics.success()
            return
        }
        if Config.enableAuth && !AuthStore.shared.isSignedIn {
            // Publishing needs an account. Park it: the tour is viewable now and
            // the listing detail (or this screen after sign-in) publishes it.
            model.setStatus(.ready, for: id)
            model.addPendingPublish(id)
            update(id, run) { $0.stage = .awaitingSignIn; $0.phase = "Sign in to publish"; $0.isRunning = false }
            Haptics.success()
            return
        }
        await runPublish(listingID: id, run: run, allowEnhance: true)
    }

    private func runPublish(listingID id: UUID, run: UUID, allowEnhance: Bool) async {
        guard let model, let tour = model.tours[id] else { return }
        let render = model.renders[id] ?? Render(listingID: id, tier: .smooth, durationS: tour.durationS)

        var existingAssetID: String? = nil
        let alreadyEnhanced = tour.url.lastPathComponent.lowercased().hasPrefix("enhanced-")
        if allowEnhance, render.tier.usesServerAI, !alreadyEnhanced {
            switch await enhance(listingID: id, run: run, tour: tour, tier: render.tier) {
            case .enhanced:
                existingAssetID = nil                 // the enhanced file is uploaded fresh
            case .fallback(let masterAssetID):
                existingAssetID = masterAssetID       // reuse the master already on the server
            }
        }
        guard !Task.isCancelled, runs[id] == run else { return }

        update(id, run) {
            $0.stage = .publishing; $0.phase = "Publishing tour…"
            $0.isRunning = true; $0.canSkipEnhance = false; $0.fraction = 1
        }
        do {
            guard let live = model.listings.first(where: { $0.id == id }) else { return }
            let current = model.tours[id] ?? tour   // may have been swapped to the enhanced file
            _ = try await model.publishTour(listing: live,
                                            renderOutputURL: current.url,
                                            durationS: current.durationS,
                                            speedFactor: current.speedFactor,
                                            roomTags: model.assets[id]?.roomTags ?? [],
                                            enhancements: render.enhancements,
                                            tier: render.tier,
                                            existingAssetID: existingAssetID)
            model.setStatus(.ready, for: id)
            update(id, run) {
                $0.stage = .published; $0.phase = "Your tour is ready"
                $0.error = nil; $0.errorStatus = nil; $0.isRunning = false; $0.fraction = 1
            }
            Haptics.success()
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            // The LOCAL tour still plays in-app (local-first); only the link is missing.
            model.setStatus(.ready, for: id)
            let message = AppModel.userMessage(for: error)
            let status = (error as? APIError)?.status
            update(id, run) {
                $0.stage = .publishFailed; $0.phase = "Couldn't publish"
                $0.error = message; $0.errorStatus = status; $0.isRunning = false; $0.fraction = 1
            }
        }
    }

    /// The REAL AI stage for the Cinematic / 4K Premium tiers: pre-flight the
    /// plan (no multi-minute upload when Topaz isn't in it), upload the master
    /// (role=render, public bucket) → POST /ai-video/drone → poll every 6 s
    /// (≤ 20 min, skippable) → download the enhanced mp4 → swap the local tour
    /// to it. ANY failure falls back to the standard tour with an honest note —
    /// and hands back the master's server asset so the fallback publish doesn't
    /// upload the same file twice.
    private func enhance(listingID id: UUID, run: UUID,
                         tour: AppModel.RenderedTour, tier: Render.Tier) async -> EnhanceOutcome {
        guard let model else { return .fallback(masterAssetID: nil) }
        update(id, run) {
            $0.stage = .enhancing; $0.phase = "Checking your plan…"
            $0.isRunning = true; $0.canSkipEnhance = true; $0.note = nil
        }

        // a. Pre-flight against /me — the server's own allowance numbers.
        if let ent = (try? await model.api.me())?.entitlements {
            if !ent.canUseTopaz {
                setNote(id, run, "AI enhance is a Team plan add-on that isn't in your plan — publishing your standard tour instead.")
                return .fallback(masterAssetID: nil)
            }
            if ent.remaining("drone") <= 0 {
                setNote(id, run, "You've used all \(ent.topazPerMonth) AI enhances for this month — publishing your standard tour instead.")
                return .fallback(masterAssetID: nil)
            }
        }
        if skipRequested.contains(id) {
            setNote(id, run, "Published your standard tour — you skipped the AI enhance.")
            return .fallback(masterAssetID: nil)
        }

        var masterAssetID: String? = nil
        do {
            guard let live = model.listings.first(where: { $0.id == id }) else {
                return .fallback(masterAssetID: nil)
            }
            let serverID = try await model.ensureServerListing(live)

            // b. Upload the on-device master to the PUBLIC renders bucket so fal
            //    can fetch it (the drone route 400s on private-bucket assets).
            update(id, run) { $0.phase = "Uploading for AI enhance…" }
            let meta = UploadMetadata(durationS: tour.durationS, bytes: FileStore.fileSize(tour.url))
            let assetID = try await UploadManager.shared.upload(
                fileURL: tour.url, listingID: serverID, role: "render", metadata: meta)
            masterAssetID = assetID
            model.uploadedRenderAssets[id] = AppModel.UploadedRenderAsset(
                relPath: FileStore.relativePath(for: tour.url), assetID: assetID)
            if skipRequested.contains(id) {
                setNote(id, run, "Published your standard tour — you skipped the AI enhance.")
                return .fallback(masterAssetID: masterAssetID)
            }

            // c. Submit + poll. 4K Premium → 4k30 @ 30 fps; Cinematic → 4k60 @ 60 fps.
            update(id, run) { $0.phase = "Enhancing with AI…" }
            let job = try await model.api.aiVideoDrone(assetID: assetID,
                                                       tier: tier.droneTierParam,
                                                       targetFps: tier.droneTargetFPS,
                                                       idempotencyKey: "drone:\(run.uuidString)")
            let deadline = Date().addingTimeInterval(20 * 60)
            var enhancedRemoteURL: URL? = nil
            while enhancedRemoteURL == nil {
                if skipRequested.contains(id) || Task.isCancelled { break }
                guard Date() < deadline else { throw EnhanceError.timeout }
                try await Task.sleep(nanoseconds: 6_000_000_000)
                if skipRequested.contains(id) || Task.isCancelled { break }
                switch try await model.api.aiVideoStatus(job) {
                case .processing(let queuePosition):
                    let label = (queuePosition ?? 0) > 0
                        ? "Enhancing with AI… (#\(queuePosition ?? 0) in queue)"
                        : "Enhancing with AI…"
                    update(id, run) { $0.phase = label }
                case .completed(let videoURL):
                    enhancedRemoteURL = videoURL
                case .failed(let message):
                    throw EnhanceError.failed(message)
                }
            }
            if Task.isCancelled { return .fallback(masterAssetID: masterAssetID) }
            if skipRequested.contains(id) {
                setNote(id, run, "Published your standard tour — you skipped the AI enhance.")
                return .fallback(masterAssetID: masterAssetID)
            }
            guard let enhancedRemoteURL else { throw EnhanceError.noVideo }

            // d. Download promptly (fal result URLs expire) into Recordings.
            update(id, run) { $0.phase = "Downloading enhanced tour…"; $0.canSkipEnhance = false }
            let (tmp, resp) = try await URLSession.shared.download(from: enhancedRemoteURL)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw APIError.badResponse(http.statusCode)
            }
            let dest = FileStore.recordingsDir.appendingPathComponent("enhanced-\(id.uuidString).mp4")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)

            // Swap the local tour to the enhanced file (same duration/speed —
            // Topaz preserves duration, so chapter timestamps stay valid).
            model.tours[id] = AppModel.RenderedTour(url: dest, durationS: tour.durationS,
                                                    speedFactor: tour.speedFactor)
            return .enhanced
        } catch {
            if Task.isCancelled || error is CancellationError {
                return .fallback(masterAssetID: masterAssetID)
            }
            // e. Honest fallback, with the server's reason when it gave one.
            let reason = AppModel.userMessage(for: error)
            setNote(id, run, "AI enhance unavailable (\(reason)) — publishing your standard tour instead.")
            return .fallback(masterAssetID: masterAssetID)
        }
    }

    // MARK: Bookkeeping

    private func reportProgress(_ id: UUID, _ run: UUID, _ p: Double, _ label: String) {
        update(id, run) { $0.fraction = min(max(p, 0), 1); $0.phase = label }
    }

    private func setNote(_ id: UUID, _ run: UUID, _ text: String) {
        update(id, run) { $0.note = text; $0.canSkipEnhance = false }
    }

    /// Apply a state change only if `run` is still the listing's current run —
    /// a superseded or cancelled task can never clobber a newer job's state.
    private func update(_ id: UUID, _ run: UUID, _ change: (inout RenderJobState) -> Void) {
        guard runs[id] == run, var job = jobs[id] else { return }
        change(&job)
        jobs[id] = job
    }

    private func beginRun(_ id: UUID) -> UUID {
        let run = UUID()
        runs[id] = run
        skipRequested.remove(id)
        if backgroundTasks[id] == nil {
            let bg = UIApplication.shared.beginBackgroundTask(withName: "rendprop.job.\(id.uuidString)") { [weak self] in
                Task { @MainActor [weak self] in self?.endBackground(id) }
            }
            if bg != .invalid { backgroundTasks[id] = bg }
        }
        refreshIdleTimer()
        return run
    }

    private func endRun(_ id: UUID, _ run: UUID) {
        guard runs[id] == run else { return }
        runs[id] = nil
        tasks[id] = nil
        skipRequested.remove(id)
        endBackground(id)
        refreshIdleTimer()
    }

    private func endBackground(_ id: UUID) {
        if let bg = backgroundTasks.removeValue(forKey: id) {
            UIApplication.shared.endBackgroundTask(bg)
        }
    }

    /// Keep the screen awake while any render/publish runs; release it after.
    /// Routed through the ref-counted `IdleTimer` so a job finishing while the
    /// camera is open never drops the capture screen's own hold.
    private var holdsIdleTimer = false
    private func refreshIdleTimer() {
        if hasActiveJob && !holdsIdleTimer { IdleTimer.hold(); holdsIdleTimer = true }
        else if !hasActiveJob && holdsIdleTimer { IdleTimer.release(); holdsIdleTimer = false }
    }
}

// MARK: - Persistence
// Lives here (not a standalone file) so it's always in the build target — a new
// .swift file only compiles if xcodegen re-adds it, and a stale project silently
// drops it. Disk-backed snapshot of the user's real data (listings, their
// recorded/imported assets, and rendered tours) so nothing is lost on relaunch.
// File paths are stored RELATIVE to Documents (iOS changes the container base
// between launches/reinstalls) and rebuilt on load; missing-file entries drop.
enum PersistentStore {

    private static var fileURL: URL {
        FileStore.documents.appendingPathComponent("rendprop-state.json")
    }

    // fileprivate (not private) so the tolerant-decoding extensions at the
    // bottom of this file can name these nested types.
    fileprivate struct PersistedAsset: Codable {
        var id: UUID
        var relPath: String
        var motionRelPath: String?
        var durationS: Double
        var fps: Double
        var width: Int
        var height: Int
        var bytes: Int64
        var isDrone: Bool
        var roomTags: [RoomTag]
    }

    fileprivate struct PersistedTour: Codable {
        var relPath: String
        var durationS: Double
        var speedFactor: Double
    }

    fileprivate struct PersistedState: Codable {
        var listings: [Listing] = []
        var assets: [UUID: PersistedAsset] = [:]
        var tours: [UUID: PersistedTour] = [:]
        var renders: [UUID: Render] = [:]
        // Added 2026-09-03 — Optional so snapshots from older builds decode.
        var pendingPublish: [UUID]? = nil
        var uploadedRenderAssets: [UUID: AppModel.UploadedRenderAsset]? = nil
    }

    static func save(listings: [Listing],
                     assets: [UUID: CaptureAsset],
                     tours: [UUID: AppModel.RenderedTour],
                     renders: [UUID: Render],
                     pendingPublish: [UUID] = [],
                     uploadedRenderAssets: [UUID: AppModel.UploadedRenderAsset] = [:]) {
        var state = PersistedState()
        state.listings = listings.filter { !$0.isSample }
        let realIDs = Set(state.listings.map { $0.id })

        for (id, a) in assets where realIDs.contains(id) {
            state.assets[id] = PersistedAsset(
                id: a.id,
                relPath: FileStore.relativePath(for: a.localURL),
                motionRelPath: a.motionSidecarURL.map { FileStore.relativePath(for: $0) },
                durationS: a.durationS, fps: a.fps, width: a.width, height: a.height,
                bytes: a.bytes, isDrone: a.isDrone, roomTags: a.roomTags)
        }
        for (id, t) in tours where realIDs.contains(id) {
            state.tours[id] = PersistedTour(
                relPath: FileStore.relativePath(for: t.url),
                durationS: t.durationS, speedFactor: t.speedFactor)
        }
        state.renders = renders.filter { realIDs.contains($0.key) }
        let pending = pendingPublish.filter { realIDs.contains($0) }
        state.pendingPublish = pending.isEmpty ? nil : pending
        let uploaded = uploadedRenderAssets.filter { realIDs.contains($0.key) }
        state.uploadedRenderAssets = uploaded.isEmpty ? nil : uploaded

        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch { /* non-fatal: files are safe, only this snapshot is lost */ }
    }

    struct Loaded {
        var listings: [Listing] = []
        var assets: [UUID: CaptureAsset] = [:]
        var tours: [UUID: AppModel.RenderedTour] = [:]
        var renders: [UUID: Render] = [:]
        var pendingPublish: [UUID] = []
        var uploadedRenderAssets: [UUID: AppModel.UploadedRenderAsset] = [:]
    }

    static func load() -> Loaded {
        guard let data = try? Data(contentsOf: fileURL) else { return Loaded() }
        guard let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            // Keep the unreadable snapshot for forensics instead of letting the
            // next save silently overwrite it with an empty one.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = FileStore.documents.appendingPathComponent("rendprop-state.corrupt-\(stamp).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            return Loaded()
        }
        var out = Loaded()
        out.listings = state.listings

        for (id, a) in state.assets {
            let localURL = FileStore.url(fromRelativePath: a.relPath)
            guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
            out.assets[id] = CaptureAsset(
                id: a.id, localURL: localURL,
                motionSidecarURL: a.motionRelPath.map { FileStore.url(fromRelativePath: $0) },
                durationS: a.durationS, fps: a.fps, width: a.width, height: a.height,
                bytes: a.bytes, isDrone: a.isDrone, roomTags: a.roomTags)
        }
        for (id, t) in state.tours {
            let url = FileStore.url(fromRelativePath: t.relPath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            out.tours[id] = AppModel.RenderedTour(url: url, durationS: t.durationS, speedFactor: t.speedFactor)
        }
        let ids = Set(out.listings.map { $0.id })
        out.renders = state.renders.filter { ids.contains($0.key) }
        out.pendingPublish = (state.pendingPublish ?? []).filter { ids.contains($0) }
        out.uploadedRenderAssets = (state.uploadedRenderAssets ?? [:]).filter { ids.contains($0.key) }
        return out
    }
}

// MARK: - Tolerant decoding for persisted snapshots
// The snapshot decode used to be all-or-nothing: ONE missing key or one bad
// entry anywhere (a field added by a newer/older build, an unknown enum raw
// value) threw, load() returned empty, and every listing "vanished" on update.
// These inits decode field-by-field with safe defaults, and the top-level state
// salvages each collection independently — a poisoned renders map can no longer
// take the listings down with it. Extensions keep the memberwise inits that
// save() uses; encoding stays synthesized, so the JSON shape is unchanged.
extension PersistentStore.PersistedAsset {
    enum CodingKeys: String, CodingKey {
        case id, relPath, motionRelPath, durationS, fps, width, height, bytes, isDrone, roomTags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        relPath       = try c.decode(String.self, forKey: .relPath)   // useless without a path
        motionRelPath = try c.decodeIfPresent(String.self, forKey: .motionRelPath)
        durationS     = try c.decodeIfPresent(Double.self, forKey: .durationS) ?? 0
        fps           = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 30
        width         = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height        = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        bytes         = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        isDrone       = try c.decodeIfPresent(Bool.self, forKey: .isDrone) ?? false
        // Losing chapters beats losing the video: salvage what decodes.
        roomTags      = ((try? c.decodeIfPresent([RoomTag].self, forKey: .roomTags)) ?? nil) ?? []
    }
}

extension PersistentStore.PersistedTour {
    enum CodingKeys: String, CodingKey { case relPath, durationS, speedFactor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        relPath     = try c.decode(String.self, forKey: .relPath)     // useless without a path
        durationS   = try c.decodeIfPresent(Double.self, forKey: .durationS) ?? 0
        speedFactor = try c.decodeIfPresent(Double.self, forKey: .speedFactor) ?? 1
    }
}

extension PersistentStore.PersistedState {
    enum CodingKeys: String, CodingKey { case listings, assets, tours, renders, pendingPublish, uploadedRenderAssets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Each collection is salvaged independently (`try?`): if one is
        // malformed, only it degrades to empty — the rest still load.
        listings = ((try? c.decodeIfPresent([Listing].self, forKey: .listings)) ?? nil) ?? []
        assets   = ((try? c.decodeIfPresent([UUID: PersistentStore.PersistedAsset].self,
                                            forKey: .assets)) ?? nil) ?? [:]
        tours    = ((try? c.decodeIfPresent([UUID: PersistentStore.PersistedTour].self,
                                            forKey: .tours)) ?? nil) ?? [:]
        renders  = ((try? c.decodeIfPresent([UUID: Render].self, forKey: .renders)) ?? nil) ?? [:]
        pendingPublish = (try? c.decodeIfPresent([UUID].self, forKey: .pendingPublish)) ?? nil
        uploadedRenderAssets = (try? c.decodeIfPresent([UUID: AppModel.UploadedRenderAsset].self,
                                                       forKey: .uploadedRenderAssets)) ?? nil
    }
}

// MARK: - Entry

/// App appearance — System follows iOS; Light/Dark force a scheme.
/// Stored raw in @AppStorage("appearance"); every Theme token is adaptive, so
/// switching re-themes the whole app instantly.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil       // follow the device
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@main
struct RendpropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var uploads = UploadManager.shared
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue

    init() {
        // @AppStorage defaults are display-only; the upload engine reads the
        // key directly, so register the real default (F-C-07).
        UserDefaults.standard.register(defaults: ["wifiOnlyUploads": true, "maxQualityCapture": false])
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasOnboarded {
                    RootTabView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(model)
            .environmentObject(uploads)
            .tint(Theme.accent)
            // System / Light / Dark — set in Settings → Appearance. nil = follow iOS.
            .preferredColorScheme((Appearance(rawValue: appearanceRaw) ?? .system).colorScheme)
        }
    }
}

// MARK: - Root tab bar
// First tab wears the current business type's identity (Homes/Venues/Places/
// Stores/Studios/Spaces + matching icon) and re-renders live on type change.
// This is the ONE place samples are re-derived when the business type changes
// (Home menu, Settings, or a re-pick in the intro all land here).
struct RootTabView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeDashboardView(goToListings: { tab = 1 }) }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)
            HomeListingsView()
                .tabItem {
                    Label("\(SpaceType.current.spaceNounCap)s",
                          systemImage: SpaceType.current.systemImage)
                }
                .tag(1)
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
                .tag(2)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .task {
            await model.load()        // idempotent
            model.reseedSamples()     // the intro may have changed the type before this mounted
        }
        .onChange(of: spaceTypeRaw) { _ in
            model.reseedSamples()     // venue owners see venues, not houses
        }
    }
}

// MARK: - Home dashboard
// The real "home" tab is a SHOWROOM, not a brochure: an animated hero, the LIVE
// demo tour you can scrub right here, and one bold gradient card per feature
// that jumps straight into it. Orient in three seconds, playing in five.
// Inlined here so it stays in the build target.
struct HomeDashboardView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var goToListings: () -> Void = {}

    @State private var revealed = false          // staggers the sections in on first appear
    @State private var showAerial = false        // aerial intro sheet from the showroom
    @State private var leadCount: Int?           // from /me when signed in

    private var noun: String { SpaceType.current.spaceNoun }          // home / venue / space …
    private var customer: String { SpaceType.current.customerNoun }   // buyers / guests …

    /// The seeded demo listing for the current business type — powers the live
    /// sample tour on Home. nil only for the instant before `model.load()`.
    private var demoListing: Listing? {
        model.listings.first(where: { $0.isSample })
    }
    /// The user's own most recent ACTIVE listing for this industry (never a
    /// sample, never a sold/archived one).
    private var firstRealListing: Listing? {
        model.listings.first(where: { !$0.isSample && $0.belongsToCurrentType && !$0.isSold })
    }
    /// Best listing to open the share banner on: the user's own, else the demo.
    private var heroListing: Listing? { firstRealListing ?? demoListing }

    /// The hosted demo listing page (real estate only). The Home card shows just
    /// the flythrough hero (?embed=1); "Open the full demo tour" opens the whole
    /// auto-generated listing microsite — exactly what buyers get from a shared
    /// link. Other business types keep the bundled sample player.
    private var estateDemoEmbedURL: URL? {
        SpaceType.current == .realEstate
            ? URL(string: "https://rendprop.com/f/estate-demo?embed=1") : nil
    }
    private var estateDemoFullURL: URL? {
        SpaceType.current == .realEstate
            ? URL(string: "https://rendprop.com/f/estate-demo") : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                heroCard
                    .modifier(Reveal(index: 0, on: revealed))
                demoSection
                    .modifier(Reveal(index: 1, on: revealed))
                showroomSection
                    .modifier(Reveal(index: 2, on: revealed))
                howItWorksSection
                    .modifier(Reveal(index: 3, on: revealed))
                // Tutorials are hidden until the videos are filmed — no "coming
                // soon" placeholder ships to App Review (2.1). Flip the flag once
                // tutorialSlot destinations play real content.
                if Config.showTutorials {
                    tutorialsSection
                        .modifier(Reveal(index: 4, on: revealed))
                }
                partnersSection
                    .modifier(Reveal(index: 5, on: revealed))
                listingsShortcut
                    .modifier(Reveal(index: 6, on: revealed))
            }
            .padding()
            // The whole tab re-themes when the business type changes (top-left menu).
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: spaceTypeRaw)
        }
        .background(Theme.bg)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Top-left: the business-type switcher — the app's identity control.
            // Picking one re-themes the ENTIRE app (Home, samples, copy, fields);
            // RootTabView re-derives the samples on the change.
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Picker("Business type", selection: $spaceTypeRaw) {
                        ForEach(SpaceType.allCases) { type in
                            Label(type.displayName, systemImage: type.systemImage)
                                .tag(type.rawValue)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: SpaceType.current.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                        Text(SpaceType.current.displayName)
                            .font(.rpCaption.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .opacity(0.7)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.accentSoft, in: Capsule())
                    .foregroundStyle(Theme.accent)
                }
                .onChange(of: spaceTypeRaw) { _ in Haptics.selection() }
            }
        }
        .task { await model.load() }        // idempotent — seeds the demo tour for this tab
        .task(id: auth.isSignedIn) { await loadLeadCount() }
        .onAppear { revealed = true }
        .sheet(isPresented: $showAerial) {
            // Only ever a REAL listing — the aerial is grounded on the property.
            if let l = firstRealListing {
                AerialIntroSheet(listing: l)
                    .environmentObject(model)
            }
        }
    }

    private func loadLeadCount() async {
        guard Config.useLiveBackend, !Config.enableAuth || auth.isSignedIn else { leadCount = nil; return }
        guard let summary = try? await model.api.me() else { return }
        leadCount = summary.entitlements?.leads ?? summary.leadCount
    }

    // MARK: Hero — animated gradient billboard

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RENDPROP")
                .font(.caption.weight(.bold)).kerning(3)
                .foregroundStyle(Color.white.opacity(0.8))
            Text("Shoot it on your phone.\nShow it like a film.")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("A walkthrough video goes in. A drone-style tour comes out — with AI photos, reels, and a link \(customer) scroll like it's social.")
                .font(.rpBody)
                .foregroundStyle(Color.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            NavigationLink { NewListingView() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.viewfinder")
                    Text("Create a tour").fontWeight(.semibold)
                }
                .font(.rpBody)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Color.white, in: Capsule())
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(ScalePressStyle())
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(animatedHeroBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius + 4, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.35), radius: 18, x: 0, y: 10)
    }

    /// Slow, subtle motion: the purple→indigo wash drifts a few degrees of hue
    /// while a soft highlight orbits. Alive, never distracting; 20fps cap and
    /// fully paused under Reduce Motion (no 20 Hz re-render for a static wash).
    private var animatedHeroBackground: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(
                    colors: [Color(red: 109/255, green: 40/255, blue: 217/255),
                             Theme.accent,
                             Color(red: 79/255, green: 70/255, blue: 229/255)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(
                    colors: [Color.white.opacity(0.22), Color.clear],
                    center: UnitPoint(x: 0.5 + 0.42 * cos(t / 5), y: 0.35 + 0.3 * sin(t / 4)),
                    startRadius: 8, endRadius: 260)
            }
            .hueRotation(.degrees(sin(t / 6) * 10))
        }
    }

    // MARK: Live demo — the real scroll-scrub player, right on Home

    @ViewBuilder private var demoSection: some View {
        if let demo = demoListing {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("See it in action")
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let url = estateDemoEmbedURL {
                            PlayerWebView(remoteURL: url)   // hosted estate flythrough
                        } else {
                            PlayerWebView(listing: demo)    // bundled sample (other types)
                        }
                    }
                        .id(spaceTypeRaw)   // demo re-renders when the business type changes
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                                .strokeBorder(Theme.border)
                        )
                    Label("Live demo", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(Color.white)
                        .padding(10)
                        .allowsHitTesting(false)
                }
                Label("Scroll inside the video — this is the tour your \(customer) get.",
                      systemImage: "arrow.up.arrow.down")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                NavigationLink {
                    if let url = estateDemoFullURL {
                        // The full hosted listing microsite — flythrough → the
                        // whole auto-built landing page buyers scroll.
                        PlayerWebView(remoteURL: url)
                            .ignoresSafeArea(edges: .bottom)
                            .navigationTitle("Demo listing page")
                            .navigationBarTitleDisplayMode(.inline)
                    } else {
                        FlythroughDetailView(listing: demo)
                    }
                } label: {
                    HStack {
                        Label("Open the full demo tour", systemImage: "play.rectangle.fill")
                            .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.rpCaption.weight(.bold)).foregroundStyle(Theme.accent)
                    }
                    .padding(14)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(ScalePressStyle())
            }
        }
    }

    // MARK: Feature showroom — every headline feature, one tap in

    private var showroomSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Everything Rendprop does")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                NavigationLink { NewListingView() } label: {
                    featureTile("Drone Tour", "Walk it once — glide forever",
                                "video.fill", RPGradient.drone, ai: true)
                }
                .buttonStyle(ScalePressStyle())

                NavigationLink { AIPhotoStudioView() } label: {
                    featureTile("AI Photo Studio", "Twilight · blue sky · staging",
                                "wand.and.stars", RPGradient.photo, ai: true)
                }
                .buttonStyle(ScalePressStyle())

                reelTile
                floorPlanTile
                aerialTile

                NavigationLink { AgentCardEditorView() } label: {
                    featureTile(SpaceType.current.profileCardName, "You, on every tour you send",
                                "person.text.rectangle.fill", RPGradient.agent)
                }
                .buttonStyle(ScalePressStyle())
            }
            leadsBanner
        }
    }

    /// Reel Studio starts from a listing's photos — with no real listing yet,
    /// the card routes to Listings to create one (and says so honestly).
    @ViewBuilder private var reelTile: some View {
        if let real = firstRealListing {
            NavigationLink { PhotoStudioView(listing: real, intent: .reel) } label: {
                featureTile("Reel Studio", "Photos → one social video",
                            "film.stack", RPGradient.reel, ai: true)
            }
            .buttonStyle(ScalePressStyle())
        } else {
            Button { goToListings() } label: {
                featureTile("Reel Studio", "Create a \(noun) first",
                            "film.stack", RPGradient.reel, ai: true)
            }
            .buttonStyle(ScalePressStyle())
        }
    }

    /// Floor plans attach to a listing too — same honest fallback.
    @ViewBuilder private var floorPlanTile: some View {
        if let real = firstRealListing {
            NavigationLink { FloorPlanView(listing: real) } label: {
                featureTile("Floor Plans", "Scan in 3D or upload",
                            "cube.transparent", RPGradient.plan)
            }
            .buttonStyle(ScalePressStyle())
        } else {
            Button { goToListings() } label: {
                featureTile("Floor Plans", "Create a \(noun) first",
                            "cube.transparent", RPGradient.plan)
            }
            .buttonStyle(ScalePressStyle())
        }
    }

    /// The aerial is grounded on a REAL property's exterior photo — never
    /// generated against the demo listing (AI budget on a sample, orphaned file).
    @ViewBuilder private var aerialTile: some View {
        if firstRealListing != nil {
            Button { showAerial = true } label: {
                featureTile("Aerial Intro", "A cinematic opening shot",
                            "airplane.departure", RPGradient.aerial, ai: true)
            }
            .buttonStyle(ScalePressStyle())
        } else {
            Button { goToListings() } label: {
                featureTile("Aerial Intro", "Create a \(noun) first",
                            "airplane.departure", RPGradient.aerial, ai: true)
            }
            .buttonStyle(ScalePressStyle())
        }
    }

    /// Wide banner: the payoff — every tour is a share link that captures
    /// leads, and the leads land right here.
    private var leadsBanner: some View {
        NavigationLink {
            LeadsView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.white)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(leadsTitle).font(.rpHeadline).foregroundStyle(Color.white)
                    Text("Every tour is one link with a lead form built in. Leads appear here; email alerts are coming.")
                        .font(.rpCaption).foregroundStyle(Color.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.rpCaption.weight(.bold)).foregroundStyle(Color.white.opacity(0.9))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RPGradient.share)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(ScalePressStyle())
        .accessibilityLabel(Text("\(leadsTitle). Opens your leads."))
    }

    private var leadsTitle: String {
        guard let n = leadCount else { return "Leads" }
        return n == 1 ? "1 lead" : "\(n) leads"
    }

    /// One showroom tile: signature gradient, white hierarchical icon, name,
    /// a short promise, and an AI badge where AI does the work.
    private func featureTile(_ title: String, _ promise: String, _ icon: String,
                             _ gradient: LinearGradient, ai: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.white)
                Spacer()
                if ai { AIPill() }
            }
            Spacer(minLength: 10)
            Text(title)
                .font(.rpHeadline)
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(promise)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 128)
        .background(gradient)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    // MARK: How it works — three steps, one card

    private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("How it works")
            VStack(alignment: .leading, spacing: 14) {
                // Same instruction as the capture coaching: a steady NORMAL pace
                // (the render retimes it into a glide) — not "slowly".
                step(1, "Film", "Walk the \(noun) at a steady, normal pace on the 0.5× wide lens — or upload a clip.")
                step(2, "Enhance", "Rendprop renders the glide tour on your phone; add AI photos and staged listing shots.")
                step(3, "Share", "One link or QR code — \(customer) scroll to explore, and their inquiries land in Leads.")
            }
            .card()
        }
    }

    // MARK: Tutorials — honest "coming soon" slots (no fake videos)

    private var tutorialsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Tutorials").font(.rpKicker).foregroundStyle(Theme.inkDim)
                Text("COMING SOON")
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(0.5)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accentSoft, in: Capsule())
                    .foregroundStyle(Theme.accent)
                Spacer()
            }
            VStack(spacing: 10) {
                tutorialSlot("figure.walk", "Shoot the perfect walkthrough", "2 min")
                tutorialSlot("wand.and.stars", "Get the most from AI edits", "3 min")
            }
        }
    }

    private var listingsShortcut: some View {
        Button(action: goToListings) {
            HStack {
                Label("My \(SpaceType.current.spaceNounCap.lowercased())s",
                      systemImage: SpaceType.current.systemImage)
                    .font(.rpHeadline).foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            .padding(16)
            .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ScalePressStyle())
    }

    // MARK: More from us — the Pilk.ai family, quietly cross-promoted

    private var partnersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("More from us")
            VStack(spacing: 10) {
                partnerRow("Pilk.ai", "Custom sites, apps & AI marketing systems",
                           "sparkles", "https://pilk.ai/")
                partnerRow("Wholesale Mortgage Lending", "Get your buyers pre-approved fast",
                           "banknote", "https://wsmlending.com/")
                partnerRow("Tract", "The real estate system we built",
                           "map", "https://tractrealestate.com/")
            }
        }
    }

    @ViewBuilder
    private func partnerRow(_ name: String, _ sub: String, _ icon: String, _ urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 42, height: 42)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.rpHeadline).foregroundStyle(Theme.ink)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text(sub).font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.rpCaption.weight(.bold)).foregroundStyle(Theme.inkDim)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(ScalePressStyle())
        }
    }

    // MARK: Small pieces

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.rpKicker).foregroundStyle(Theme.inkDim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ n: Int, _ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.rpHeadline).foregroundStyle(Color.white)
                .frame(width: 30, height: 30).background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rpHeadline).foregroundStyle(Theme.ink)
                Text(sub).font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func tutorialSlot(_ icon: String, _ title: String, _ len: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.inkDim)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rpHeadline).foregroundStyle(Theme.inkDim)
                Text("\(len) · not filmed yet").font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            Spacer()
            Image(systemName: icon).foregroundStyle(Theme.inkDim)
        }
        .padding(14)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Shared visual language
// Gradients, press feedback, and reveal animation used by Home, the listing
// toolbox, onboarding, and the photo studio. Inlined here (not a new file) per
// the new-file-not-in-target rule.

/// Feature-card gradients — one signature wash per feature, reused everywhere
/// that feature appears, so the color IS the feature.
enum RPGradient {
    static let drone  = LinearGradient(
        colors: [Color(red: 124/255, green: 58/255,  blue: 237/255),
                 Color(red: 67/255,  green: 56/255,  blue: 202/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let photo  = LinearGradient(
        colors: [Color(red: 249/255, green: 115/255, blue: 22/255),
                 Color(red: 236/255, green: 72/255,  blue: 153/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let reel   = LinearGradient(
        colors: [Color(red: 20/255,  green: 184/255, blue: 166/255),
                 Color(red: 59/255,  green: 130/255, blue: 246/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let plan   = LinearGradient(
        colors: [Color(red: 34/255,  green: 197/255, blue: 94/255),
                 Color(red: 13/255,  green: 148/255, blue: 136/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let aerial = LinearGradient(
        colors: [Color(red: 14/255,  green: 165/255, blue: 233/255),
                 Color(red: 99/255,  green: 102/255, blue: 241/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let agent  = LinearGradient(
        colors: [Color(red: 236/255, green: 72/255,  blue: 153/255),
                 Color(red: 244/255, green: 63/255,  blue: 94/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let share  = LinearGradient(
        colors: [Color(red: 245/255, green: 158/255, blue: 11/255),
                 Color(red: 234/255, green: 88/255,  blue: 12/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let rooms  = LinearGradient(
        colors: [Color(red: 139/255, green: 92/255,  blue: 246/255),
                 Color(red: 124/255, green: 58/255,  blue: 237/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Crisp press-down for any card-shaped button. A near-critically-damped
/// spring (no visible overshoot) reads as a quick ease-out while staying
/// interruptible for rapid taps — a toy-like bounce on a discrete tap is
/// exactly the kind of motion Apple's own controls avoid.
struct ScalePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.85),
                       value: configuration.isPressed)
    }
}

/// Small "AI" badge for AI-powered feature cards (sits on gradient tiles).
struct AIPill: View {
    var body: some View {
        Text("AI")
            .font(.system(size: 10, weight: .heavy))
            .kerning(0.5)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.white.opacity(0.22), in: Capsule())
            .foregroundStyle(Color.white)
    }
}

/// Staggered fade-up on first appear — flip `on` once and each indexed section
/// springs in with a small cascade. Honors Reduce Motion: the vertical travel
/// is dropped for a plain staggered fade so nothing slides for those users.
struct Reveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let on: Bool
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on || reduceMotion ? 0 : 18)
            .animation(.spring(response: 0.55, dampingFraction: 0.85)
                        .delay(Double(index) * 0.07), value: on)
    }
}
