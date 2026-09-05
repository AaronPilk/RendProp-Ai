import SwiftUI
import UIKit
import AVFoundation
// StoreKit is used for two things: `Storefront.current.countryCode` (see
// `Storefronts` at the bottom of this file) and the in-app subscriptions in
// `Purchases/` — six auto-renewable products in the `rendprop_plans` group.
// No price string is compiled into the binary; every price comes from
// `Product.displayPrice`.
import StoreKit

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
            listings[i].unbrandedShareURL = nil
            listings[i].publishedRenderID = nil
            listings[i].needsServerSync = nil
        }
        uploadedRenderAssets.removeAll()
        pendingPublish.removeAll()
        // Published compliance originals belong to the previous account's org.
        publishedOriginalAssets.removeAll()
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

    /// City/State from the geocode (never the street), plus the raw
    /// administrative area ("CA") the compliance card keys California's AB 723
    /// banner off. Local only. `stateCode: nil` leaves any stored code alone —
    /// callers that only know the label must not erase it.
    func setRegion(_ label: String?, stateCode: String? = nil, for id: UUID) {
        guard let i = index(of: id) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        listings[i].regionLabel = trimmed.isEmpty ? nil : trimmed
        if let stateCode {
            let code = stateCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty { listings[i].stateCode = code }
        }
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

    // MARK: - Compliance plumbing (W2-C3)

    /// The server's 10 MB ceiling for a `role:"render"` photo. Bigger than this
    /// and we skip rather than burn a round trip on a guaranteed 400.
    private static let maxPublishedPhotoBytes: Int64 = 9_500_000

    /// "<relPath>|<bytes>" → server asset id for originals already published
    /// this session. Five edits of the same photo publish ONE original, not
    /// five. Not persisted — a fresh launch re-publishes once, which is correct
    /// if the object was cleaned up server-side in the meantime.
    private var publishedOriginalAssets: [String: String] = [:]

    /// The SERVER listing id to anchor an AI generation's provenance row to,
    /// creating the server listing on first use if this one has never synced.
    /// Best effort and never throws: an AI edit must not fail because the audit
    /// log couldn't be anchored. Nil for samples, offline dev, a signed-out
    /// user, or a failed create — the generation then runs unlogged and the
    /// server says so in its `provenance.reason`.
    func serverListingIDForCompliance(_ id: UUID) async -> UUID? {
        guard let listing = listings.first(where: { $0.id == id }), !listing.isSample else { return nil }
        if let existing = listing.serverID { return existing }
        guard Config.useLiveBackend else { return nil }
        guard !Config.enableAuth || AuthStore.shared.isSignedIn else { return nil }
        return try? await ensureServerListing(listing)
    }

    /// Publish the UNTOUCHED original of a photo we are about to hand to the AI
    /// (`POST /uploads role:"original"`), so the tour's public "View original"
    /// link is a real file — California AB 723 requires access to the unaltered
    /// version, not just a disclosure sentence. Returns the server asset id to
    /// pass as `original_asset_id`.
    ///
    /// Best effort: nil when there is no live backend, the file is gone, or the
    /// upload failed. The edit still runs; it is simply logged without a
    /// "before", which the compliance card then shows in amber.
    func publishOriginalForDisclosure(listingServerID: UUID, fileURL: URL) async -> String? {
        guard Config.useLiveBackend else { return nil }
        let bytes = FileStore.fileSize(fileURL)
        guard bytes > 0 else { return nil }
        let memo = "\(FileStore.relativePath(for: fileURL))|\(bytes)"
        if let known = publishedOriginalAssets[memo] { return known }
        guard let assetID = try? await UploadManager.shared.uploadOriginal(
            fileURL: fileURL, listingID: listingServerID) else { return nil }
        publishedOriginalAssets[memo] = assetID
        return assetID
    }

    /// Publish the ALTERED result of an AI photo edit and attach it to its
    /// provenance row (`PATCH /me/compliance/:id {altered_asset_id}`), so the
    /// tour can print the side-by-side "Before / after" pair NorthstarMLS wants
    /// alongside the disclosure. The ORIGINAL alone already satisfies California
    /// AB 723, so this is the nice-to-have half: best effort, never throws, and
    /// runs after the edit is already on screen.
    func attachAlteredPhotoForDisclosure(provenanceID: String, listingServerID: UUID,
                                         fileURL: URL) async {
        guard Config.useLiveBackend, !provenanceID.isEmpty else { return }
        let bytes = FileStore.fileSize(fileURL)
        guard bytes > 0, bytes <= Self.maxPublishedPhotoBytes else { return }
        guard let assetID = try? await UploadManager.shared.uploadAlteredPhoto(
            fileURL: fileURL, listingID: listingServerID) else { return }
        try? await api.attachProvenanceMedia(provenanceID: provenanceID,
                                             originalAssetID: nil,
                                             alteredAssetID: assetID)
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
                // The MLS-safe twin. A server that predates the compliance wave
                // sends none — keep whatever we had rather than clearing it
                // (`serverUnbrandedURL` derives one from the slug either way).
                if let unbranded = published.unbrandedURL, !unbranded.isEmpty {
                    l.unbrandedShareURL = unbranded
                }
                if let rid = published.renderID { l.publishedRenderID = rid }
                l.lastError = nil
                l.status = .ready
                listings[i] = l   // persists via didSet
            }
            Analytics.track("tour_published", ["space_type": SpaceType.current.rawValue, "ok": "true"])
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
        Analytics.track("render_finished", ["ok": "true", "duration_s": String(Int(output.durationS))])
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

        // A snapshot we could not read is still on disk (quarantine failed):
        // writing an EMPTY state over it would finish destroying what the user
        // still has. Real content is always allowed through (audit F-C-15).
        let isEmpty = state.listings.isEmpty && state.assets.isEmpty
            && state.tours.isEmpty && state.renders.isEmpty
        if isEmpty && refusesEmptyOverwrite { return }

        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
            if !isEmpty { refusesEmptyOverwrite = false }
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

    /// Armed by `load()` when a snapshot existed on disk but could NOT be read
    /// or decoded AND could not be moved aside. While it is armed, `save()`
    /// refuses to write an EMPTY snapshot — a transient read error must never
    /// turn into "all your listings are gone" one auto-save later. Disarmed as
    /// soon as a snapshot with real content is written.
    /// Main-actor only: `load()`/`save()` are called from `AppModel` (@MainActor).
    private static var refusesEmptyOverwrite = false

    /// Move an unusable snapshot to `rendprop-state.corrupt-<unix>.json`.
    /// MOVE, not copy: once it is out of the way the next save writes a clean
    /// file and nothing the user still has is destroyed. Returns false when even
    /// the move failed — the caller then protects the file by refusing to
    /// overwrite it with an empty snapshot.
    @discardableResult
    private static func quarantineSnapshot() -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = FileStore.documents.appendingPathComponent("rendprop-state.corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
            return true
        } catch {
            // Last resort: a copy at least preserves the bytes for forensics.
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            return false
        }
    }

    static func load() -> Loaded {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            refusesEmptyOverwrite = false   // fresh install / after a wipe: nothing to protect
            return Loaded()
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            // The file is THERE but unreadable (transient I/O, protected data
            // still locked, disk pressure). Getting this wrong is what destroys
            // a user's library, so do not treat it as "no data".
            refusesEmptyOverwrite = !quarantineSnapshot()
            return Loaded()
        }
        guard let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            // Truly undecodable at the TOP level (truncated write, not JSON at
            // all) — per-collection and per-element salvage already ran inside
            // PersistedState.init, so reaching here means there was nothing to
            // salvage. Move it aside rather than let the next save clobber it.
            refusesEmptyOverwrite = !quarantineSnapshot()
            return Loaded()
        }

        // The decode succeeded but salvaged NOTHING out of a file that clearly
        // held something (an honestly-empty snapshot is ~48 bytes). Everything
        // in it was undecodable, so keep a copy before the next auto-save
        // replaces it, and don't let that save be an empty one.
        let salvagedNothing = state.listings.isEmpty && state.assets.isEmpty
            && state.tours.isEmpty && state.renders.isEmpty
        if salvagedNothing && data.count > 128 {
            _ = quarantineSnapshot()
            refusesEmptyOverwrite = true
        } else {
            refusesEmptyOverwrite = false
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

/// Decodes `T` but NEVER throws — a bad element yields `value == nil` instead
/// of aborting the whole container. Because it always succeeds, an unkeyed
/// container's cursor always advances by exactly one, so decoding can continue
/// past the damaged element (audit F-C-15).
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Decode `[T]` at `key`, losing AT MOST the elements that are undecodable.
/// Fast path first: the plain array decode is what runs on every healthy
/// launch, so the salvage loop only ever executes on a snapshot that would
/// otherwise have been thrown away wholesale.
private func rpSalvagedArray<T: Decodable, K: CodingKey>(
    _ type: T.Type, from c: KeyedDecodingContainer<K>, forKey key: K
) -> [T] {
    if let decoded = try? c.decodeIfPresent([T].self, forKey: key) { return decoded ?? [] }
    guard var u = try? c.nestedUnkeyedContainer(forKey: key) else { return [] }
    var out: [T] = []
    while !u.isAtEnd {
        guard let boxed = try? u.decode(FailableDecodable<T>.self) else { break }
        if let v = boxed.value { out.append(v) }
    }
    return out
}

/// Decode `[UUID: V]` at `key`, losing AT MOST the entries that are
/// undecodable. Swift encodes a dictionary whose Key is neither String nor Int
/// as an UNKEYED container of alternating key, value, key, value… — so the
/// salvage loop reads it in pairs and skips a pair whose key or value is bad,
/// keeping the alternation intact.
private func rpSalvagedUUIDDict<V: Decodable, K: CodingKey>(
    _ type: V.Type, from c: KeyedDecodingContainer<K>, forKey key: K
) -> [UUID: V] {
    if let decoded = try? c.decodeIfPresent([UUID: V].self, forKey: key) { return decoded ?? [:] }
    guard var u = try? c.nestedUnkeyedContainer(forKey: key) else { return [:] }
    var out: [UUID: V] = [:]
    while !u.isAtEnd {
        guard let boxedKey = try? u.decode(FailableDecodable<UUID>.self) else { break }
        guard !u.isAtEnd else { break }
        guard let boxedValue = try? u.decode(FailableDecodable<V>.self) else { break }
        if let k = boxedKey.value, let v = boxedValue.value { out[k] = v }
    }
    return out
}

extension PersistentStore.PersistedState {
    enum CodingKeys: String, CodingKey { case listings, assets, tours, renders, pendingPublish, uploadedRenderAssets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Two levels of tolerance:
        //  1. Each collection is independent — a poisoned `renders` map can't
        //     take the listings down with it.
        //  2. WITHIN a collection, decoding is element-by-element, so one bad
        //     record (a `price` that isn't {cents:Int}, an asset entry missing
        //     its relPath) costs that ONE record, not the whole library
        //     (audit F-C-15). Element structs decode field-by-field on top of
        //     that, so a bad FIELD usually costs nothing at all.
        listings = rpSalvagedArray(Listing.self, from: c, forKey: .listings)
        assets   = rpSalvagedUUIDDict(PersistentStore.PersistedAsset.self, from: c, forKey: .assets)
        tours    = rpSalvagedUUIDDict(PersistentStore.PersistedTour.self, from: c, forKey: .tours)
        renders  = rpSalvagedUUIDDict(Render.self, from: c, forKey: .renders)
        let pending = rpSalvagedArray(UUID.self, from: c, forKey: .pendingPublish)
        pendingPublish = pending.isEmpty ? nil : pending
        let uploaded = rpSalvagedUUIDDict(AppModel.UploadedRenderAsset.self,
                                          from: c, forKey: .uploadedRenderAssets)
        uploadedRenderAssets = uploaded.isEmpty ? nil : uploaded
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
    // MARK: - analytics additions (P3)
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var analyticsAuth = AuthStore.shared
    // MARK: - end analytics additions

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
            // The one paywall sheet + the StoreKit 2 lifecycle (Purchases/).
            // Mounted here so every "Upgrade plan" CTA in the app can call
            // `PaywallRouter.shared.present(reason:)` instead of owning a sheet.
            .paywallHost()
            .tint(Theme.accent)
            // System / Light / Dark — set in Settings → Appearance. nil = follow iOS.
            .preferredColorScheme((Appearance(rawValue: appearanceRaw) ?? .system).colorScheme)
            // MARK: - analytics additions (P3)
            // First-party analytics only: our own /events route, no third-party
            // SDK, no IDFA, no ATT prompt. `start` is idempotent.
            .task { Analytics.start(api: model.api as? AnalyticsAPI) }
            // Backgrounding is the one moment we KNOW the person is done, so it
            // is the most valuable flush there is.
            .onChange(of: scenePhase) { phase in Analytics.sceneChanged(phase) }
            .onChange(of: analyticsAuth.isSignedIn) { signedIn in Analytics.authChanged(signedIn) }
            // `externalSink` is `nonisolated` and hops to the main actor itself,
            // so the purchase flow keeps knowing nothing about Analytics.
            .onAppear { PaywallEvents.sink = Analytics.externalSink }
            // MARK: - end analytics additions
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
        // Resolve the App Store storefront once. Until it answers,
        // `Config.pricingURL` is nil and no upgrade CTA renders — fail closed
        // (App Store 3.1.3: external purchase CTAs are US-storefront only).
        .resolveStorefront()
        .onChange(of: spaceTypeRaw) { _ in
            model.reseedSamples()     // venue owners see venues, not houses
        }
    }
}

// MARK: - Home dashboard
// PROJECT-FIRST. Home is the user's list of homes plus ONE big obvious action:
// add another one. Every feature tile below runs the "Which home?" gate first
// (ProjectFeature / ProjectGateSheet, bottom of this file), so nothing the app
// makes — a photo, a reel, a floor plan, an aerial — can exist without a home
// to belong to. The standalone "AI Photo Studio" entry that edited loose photos
// with no home attached is GONE: its tile now opens the chosen home's own photo
// studio, where every file is saved under that home.
// Inlined here so it stays in the build target.
struct HomeDashboardView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var goToListings: () -> Void = {}

    @State private var revealed = false          // staggers the sections in on first appear
    @State private var leadCount: Int?           // from /me when signed in

    // MARK: The "Which home?" gate
    /// The one sheet the gate uses (name your first home / pick one / aerial).
    /// A single sheet slot — three separate `.sheet` modifiers on one view can
    /// fight each other for it.
    @State private var gate: ProjectGateSheet?
    /// A home chosen while a sheet was still up. Pushed in the sheet's
    /// `onDismiss`, so the navigation never races the dismissal.
    @State private var queued: ProjectRoute?
    /// What the pushed destination shows.
    @State private var route: ProjectRoute?
    @State private var showRoute = false

    private var noun: String { SpaceType.current.spaceNoun }          // home / venue / space …
    private var customer: String { SpaceType.current.customerNoun }   // buyers / guests …

    /// The homes a feature may save into: the user's own, this business type's,
    /// still active. Samples are never in here (their tools are no-ops).
    private var projects: [Listing] { model.realProjects }

    /// The seeded demo listing for the current business type — powers the live
    /// sample tour on Home. nil only for the instant before `model.load()`.
    private var demoListing: Listing? {
        model.listings.first(where: { $0.isSample })
    }

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
                homesSection
                    .modifier(Reveal(index: 1, on: revealed))
                showroomSection
                    .modifier(Reveal(index: 2, on: revealed))
                demoSection
                    .modifier(Reveal(index: 3, on: revealed))
                howItWorksSection
                    .modifier(Reveal(index: 4, on: revealed))
                // Tutorials are hidden until the videos are filmed — no "coming
                // soon" placeholder ships to App Review (2.1). Flip the flag once
                // tutorialSlot destinations play real content.
                if Config.showTutorials {
                    tutorialsSection
                        .modifier(Reveal(index: 5, on: revealed))
                }
                partnersSection
                    .modifier(Reveal(index: 6, on: revealed))
            }
            .padding()
            // The whole tab re-themes when the business type changes (top-left menu).
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: spaceTypeRaw)
        }
        .background(Theme.bg)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarLeading) { businessTypeMenu } }
        .navigationDestination(isPresented: $showRoute) { routeDestination }
        .task { await model.load() }        // idempotent — seeds the demo tour for this tab
        .task(id: auth.isSignedIn) { await loadLeadCount() }
        .onAppear { revealed = true }
        .sheet(item: $gate, onDismiss: flushQueuedRoute) { sheet in
            gateSheet(sheet)
        }
    }

    /// Top-left: the business-type switcher — the app's identity control.
    /// Picking one re-themes the ENTIRE app (Home, samples, copy, fields);
    /// RootTabView re-derives the samples on the change.
    private var businessTypeMenu: some View {
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

    private func loadLeadCount() async {
        guard Config.useLiveBackend, !Config.enableAuth || auth.isSignedIn else { leadCount = nil; return }
        guard let summary = try? await model.api.me() else { return }
        leadCount = summary.entitlements?.leads ?? summary.leadCount
    }

    // MARK: The gate — 0 homes / 1 home / many / cancelled / samples

    /// A feature tile was tapped. Nothing starts until a home is chosen:
    ///   • 0 homes → name one first, then land in the feature
    ///   • 1 home  → use it, no picker
    ///   • 2+      → "Which home?"
    /// Samples are never candidates — `projects` excludes them.
    private func open(_ feature: ProjectFeature) {
        let homes = projects
        if homes.isEmpty {
            gate = .start(feature)
        } else if homes.count == 1 {
            go(homes[0], feature)
        } else {
            gate = .pick(feature)
        }
    }

    /// Open `feature` on `listing`. The aerial tool is a sheet; everything else
    /// is a push.
    private func go(_ listing: Listing, _ feature: ProjectFeature) {
        if feature == .aerial {
            gate = .aerial(listing)
        } else {
            route = ProjectRoute(listing: listing, feature: feature)
            showRoute = true
        }
    }

    /// Runs after the gate sheet closes. Cancelling leaves `queued` nil, so
    /// cancelling really does mean nothing happens.
    private func flushQueuedRoute() {
        guard let q = queued else { return }
        queued = nil
        go(q.listing, q.feature)
    }

    @ViewBuilder private func gateSheet(_ sheet: ProjectGateSheet) -> some View {
        switch sheet {
        case .start(let feature):
            StartProjectSheet(feature: feature) { name in
                if let created = model.startProject(named: name) {
                    queued = ProjectRoute(listing: created, feature: feature)
                }
            }
            .environmentObject(model)
        case .pick(let feature):
            ProjectPickerSheet(feature: feature, projects: projects) { listing in
                queued = ProjectRoute(listing: listing, feature: feature)
            }
            .environmentObject(model)
        case .aerial(let listing):
            // The aerial is grounded on a REAL home's exterior photo.
            AerialIntroSheet(listing: listing)
                .environmentObject(model)
        }
    }

    /// Where a resolved (home + feature) lands. Every one of these saves its
    /// output under that home's id.
    @ViewBuilder private var routeDestination: some View {
        if let route {
            switch route.feature {
            case .photos:
                PhotoStudioView(listing: route.listing)
            case .reel:
                PhotoStudioView(listing: route.listing, intent: .reel)
            case .floorPlan:
                FloorPlanView(listing: route.listing)
            case .tour:
                tourDestination(route.listing)
            case .aerial:
                // The aerial is presented as a sheet and never reaches here;
                // the home itself is a safe destination if it ever does.
                FlythroughDetailView(listing: route.listing)
            }
        }
    }

    /// "Make a tour" starts with the walkthrough video. A home that has none
    /// goes straight to the video picker (→ Review & Submit → render, the
    /// unchanged flow). A home that already has a video or a rendered tour
    /// opens on ITSELF, where its own next step is already spelled out —
    /// re-pointing a finished home at a new video is destructive and stays on
    /// the home's own screen where it is explained.
    @ViewBuilder private func tourDestination(_ listing: Listing) -> some View {
        if model.assets[listing.id] == nil && model.tours[listing.id] == nil {
            AddVideoFlowView(listing: listing)
        } else {
            FlythroughDetailView(listing: listing)
        }
    }

    // MARK: Hero — animated gradient billboard

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RENDPROP")
                .font(.caption.weight(.bold)).kerning(3)
                .foregroundStyle(Color.white.opacity(0.8))
            Text("Shoot it on your phone.\nShow it like a film.")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("Film a walkthrough. Get a drone-style tour, AI photos, and one link \(customer) can scroll.")
                .font(.rpBody)
                .foregroundStyle(Color.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
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

    // MARK: My homes — the primary section. Project first, always.

    private var homesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(SpaceType.current.collectionTitle)
            if projects.isEmpty {
                emptyHomesCard
            } else {
                homesList
            }
            addHomeButton
        }
    }

    /// No homes yet: ONE sentence, ONE button (right below). Nothing else.
    private var emptyHomesCard: some View {
        Text("Add a \(noun) first — every photo, tour and reel is saved to it.")
            .font(.rpBody).foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }

    /// The three most recent homes, then a way to see the rest.
    private var homesList: some View {
        VStack(spacing: 10) {
            ForEach(Array(projects.prefix(3))) { listing in
                NavigationLink { FlythroughDetailView(listing: listing) } label: {
                    ProjectPickerRow(listing: listing)
                        .padding(12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.border))
                }
                .buttonStyle(ScalePressStyle())
                // UI walk: same id on every row is intentional — XCUITest's
                // `firstMatch` takes the topmost, which is the newest home.
                .accessibilityIdentifier("home.listing.first")
            }
            if projects.count > 3 {
                seeAllHomesButton
            }
        }
    }

    private var seeAllHomesButton: some View {
        Button(action: goToListings) {
            HStack {
                Text("See all \(projects.count) \(noun)s")
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

    /// The one big obvious action on this screen.
    private var addHomeButton: some View {
        NavigationLink { NewListingView() } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("Add a \(noun)").fontWeight(.semibold)
            }
            .font(.body)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accent)
            .foregroundStyle(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.3), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(ScalePressStyle())
        .accessibilityLabel(Text("Add a \(noun)"))
        .accessibilityIdentifier("home.addHome")
    }

    // MARK: Feature showroom — every tool, one tap in, always inside a home

    private var showroomSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Make something")
            Text("Everything you make is saved to one \(noun).")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            featureGrid
            leadsBanner
        }
    }

    private var featureGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)], spacing: 12) {
            featureButton(.tour)
            featureButton(.photos)
            featureButton(.reel)
            featureButton(.floorPlan)
            featureButton(.aerial)
            agentCardTile
        }
    }

    /// One gated tile. Tapping never starts loose work — `open` picks the home
    /// first (or asks for one).
    private func featureButton(_ feature: ProjectFeature) -> some View {
        Button { open(feature) } label: {
            featureTile(feature.actionTitle, feature.promise,
                        feature.systemImage, feature.gradient, ai: feature.usesAI)
        }
        .buttonStyle(ScalePressStyle())
        .accessibilityLabel(Text("\(feature.actionTitle). \(feature.promise)"))
        .accessibilityIdentifier("home.feature.\(feature.rawValue)")
    }

    /// The only tile that isn't per-home: your card is the same on every tour.
    private var agentCardTile: some View {
        NavigationLink { AgentCardEditorView() } label: {
            featureTile(SpaceType.current.profileCardName, "You, on every tour you send",
                        "person.text.rectangle.fill", RPGradient.agent)
        }
        .buttonStyle(ScalePressStyle())
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
                    Text("Every tour is one link with a lead form built in. Leads appear here.")
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

    // MARK: Live demo — the real scroll-scrub player, right on Home

    @ViewBuilder private var demoSection: some View {
        if let demo = demoListing {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("See it in action")
                demoPlayer(demo)
                Label("Scroll inside the video — this is the tour your \(customer) get.",
                      systemImage: "arrow.up.arrow.down")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                demoOpenLink(demo)
            }
        }
    }

    private func demoPlayer(_ demo: Listing) -> some View {
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
            Label("Sample tour", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.black.opacity(0.55), in: Capsule())
                .foregroundStyle(Color.white)
                .padding(10)
                .allowsHitTesting(false)
        }
    }

    private func demoOpenLink(_ demo: Listing) -> some View {
        NavigationLink {
            if let url = estateDemoFullURL {
                // The full hosted listing microsite — flythrough → the whole
                // auto-built landing page buyers scroll.
                PlayerWebView(remoteURL: url)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Demo listing page")
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                FlythroughDetailView(listing: demo)
            }
        } label: {
            HStack {
                Label("Watch the sample tour", systemImage: "play.rectangle.fill")
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

    // MARK: How it works — three steps, one card

    private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("How it works")
            VStack(alignment: .leading, spacing: 14) {
                // Same instruction as the capture coaching: a steady NORMAL pace
                // (the render retimes it into a glide) — not "slowly".
                step(1, "Add the \(noun)", "Give it a name or address. Everything you make is saved to it.")
                step(2, "Film it", "Walk it at a steady, normal pace on the 0.5× wide lens — or upload a clip.")
                step(3, "Share it", "One link or QR code. \(customer.capitalized) scroll it, and their questions land in Leads.")
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

// MARK: - Third-party AI consent (App Review Guideline 5.1.2(i))
//
// "You must clearly disclose where personal data will be shared with third
//  parties, INCLUDING WITH THIRD-PARTY AI, and obtain explicit permission
//  before doing so."  — App Review Guidelines 5.1.2(i)
//
// Every AI tool in Rendprop uploads a photo or a video the user picked and
// hands it to an outside model (Google's Gemini for photo edits, Google's Veo
// and Seedance for generated video, Topaz Labs for motion smoothing/upscale).
// That is personal data leaving the device for a third party, so it needs an
// explicit, affirmative opt-in BEFORE the first transmission — a line buried in
// the privacy policy is not enough, and a pre-checked box is not enough.
//
// SHAPE OF THE GATE. The consent is asked for at the DOOR of each AI surface
// (Photo Studio, Aerial intro, Reel Studio) and at the moment an AI render tier
// is picked — never mid-request. Asking at the door means nothing else is on
// screen yet; gating the network call itself would have to fight whatever sheet
// the user is already standing in.
//
// The answer is stored per-device in UserDefaults and is revocable from
// Settings → Your data → "AI processing".
@MainActor
final class AIConsent: ObservableObject {
    static let shared = AIConsent()

    /// Bumped if the set of processors or what we send them ever changes — a
    /// new suffix re-asks everyone, which is what a materially different
    /// disclosure requires.
    private static let storageKey = "ai.thirdPartyProcessing.consent.v1"

    /// Drives the disclosure overlay on whichever AI surface is open.
    @Published private(set) var isAsking = false
    /// True once the person has explicitly agreed on this device.
    @Published private(set) var isGranted: Bool

    private var waiters: [CheckedContinuation<Bool, Never>] = []

    private init() {
        isGranted = UserDefaults.standard.bool(forKey: Self.storageKey)
    }

    /// The named processors, shown verbatim in the sheet and in Settings.
    struct Processor: Identifiable {
        let id = UUID()
        let name: String
        let detail: String
    }
    static let processors: [Processor] = [
        Processor(name: "Google",
                  detail: "Gemini edits your listing photos. Veo and Seedance generate aerial intros and reel clips."),
        Processor(name: "Topaz Labs",
                  detail: "Smooths the motion in your walkthrough and upscales it to 4K."),
    ]

    /// Ask once, then never again on this device. Returns true when the person
    /// has agreed — call it before opening an AI tool, and back out on false.
    func ensureGranted() async -> Bool {
        if isGranted { return true }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            isAsking = true
        }
    }

    func grant() {
        UserDefaults.standard.set(true, forKey: Self.storageKey)
        isGranted = true
        finish(true)
        isAsking = false
    }

    func decline() {
        finish(false)
        isAsking = false
    }

    /// Leaving the screen (nav Back, swipe-dismiss of the host sheet) counts as
    /// "not now". This MUST run: a `CheckedContinuation` that is deallocated
    /// without being resumed traps at runtime, and a stale `isAsking` would show
    /// the overlay again on the next AI screen with nobody waiting on it.
    func cancelIfStillWaiting() {
        guard isAsking || !waiters.isEmpty else { return }
        isAsking = false
        finish(false)
    }

    /// Settings → "AI processing" → Turn off. The next AI tool asks again.
    func revoke() {
        UserDefaults.standard.set(false, forKey: Self.storageKey)
        isGranted = false
    }

    private func finish(_ value: Bool) {
        guard !waiters.isEmpty else { return }
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: value) }
    }
}

/// Attach to an AI surface. It shows the disclosure the first time that surface
/// asks for consent and nothing thereafter.
///
/// Deliberately an OVERLAY, not a sheet or a fullScreenCover: the AI screens
/// already stack their own presentations (PhotoStudioView alone carries two
/// fullScreenCovers, AerialIntroSheet and ReelStudioView are themselves
/// presented), and a second presentation modifier on the same view is silently
/// dropped by SwiftUI. An overlay always draws, inside a sheet or out.
struct AIConsentGate: ViewModifier {
    @ObservedObject private var consent = AIConsent.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if consent.isAsking {
                    AIConsentView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: consent.isAsking)
            // Backing out of the screen (nav Back, swipe-dismiss of the host
            // sheet) must resume whoever is awaiting `ensureGranted()` — an
            // abandoned continuation is a permanently hung Task.
            .onDisappear { consent.cancelIfStillWaiting() }
    }
}

extension View {
    /// Guideline 5.1.2(i) gate. Put this on any screen that can reach an AI
    /// tool, and call `await AIConsent.shared.ensureGranted()` before the work.
    func aiConsentGate() -> some View { modifier(AIConsentGate()) }
}

/// The disclosure itself. Names the processors, says exactly what leaves the
/// phone and what never does, and offers a real decline.
struct AIConsentView: View {
    @ObservedObject private var consent = AIConsent.shared

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 30))
                            .foregroundStyle(Theme.accent)
                        Text("Rendprop's AI runs in the cloud")
                            .font(.rpTitle)
                            .foregroundStyle(Theme.ink)
                        Text("AI photo edits, aerial intros, reel clips and AI-upscaled tours are not made on your phone. To make one, Rendprop sends the photo or video you pick to these AI providers:")
                            .font(.rpBody)
                            .foregroundStyle(Theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(AIConsent.processors) { p in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).font(.rpHeadline).foregroundStyle(Theme.ink)
                                Text(p.detail)
                                    .font(.rpCaption)
                                    .foregroundStyle(Theme.inkDim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Theme.fillSubtle,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        bullet("checkmark.circle.fill", Theme.good,
                               "What we send: the image or video you choose, the words you type into a custom edit, and — for an aerial — the city and state only.")
                        bullet("xmark.circle.fill", Theme.bad,
                               "What we never send: your street address, your name, your email, your phone number or your device's location.")
                        bullet("clock.arrow.circlepath", Theme.inkDim,
                               "They process the file to return your result. Rendprop does not sell your media and does not use it for advertising.")
                    }

                    Link("Read the Privacy Policy",
                         destination: URL(string: "https://rendprop.com/privacy")!)
                        .font(.rpCaption.weight(.semibold))
                        .foregroundStyle(Theme.accent)

                    VStack(spacing: 10) {
                        PrimaryButton(title: "Agree and continue", systemImage: "checkmark") {
                            Haptics.success()
                            consent.grant()
                        }
                        Button("Not now") {
                            consent.decline()
                        }
                        .font(.rpBody)
                        .foregroundStyle(Theme.inkDim)
                        Text("You can turn this off any time in Settings → Your data. Capture, on-device rendering and sharing keep working either way.")
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }
                .padding(22)
            }
        }
    }

    private func bullet(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.rpBody)
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(text)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Storefront (App Review Guideline 3.1.1 / 3.1.3)
//
// Rendprop DOES sell inside the app. `Purchases/` implements StoreKit 2
// auto-renewable subscriptions — six products (Starter/Pro/Team × monthly and
// yearly) in the single App Store Connect subscription group `rendprop_plans`,
// each with a 7-day free introductory offer. The paywall
// (`Purchases/PaywallView.swift`, mounted once via `.paywallHost()`) is the
// primary and worldwide way to subscribe, and every price on it comes from
// `Product.displayPrice` — no price string is compiled into the binary.
//
// The rendprop.com pricing link still exists, and it is now SECONDARY. A link
// or button that points at that page is a "call to action that directs
// customers to purchasing mechanisms other than in-app purchase". Since
// 1 May 2025 that is expressly ALLOWED on the United States storefront —
// guideline 3.1.1(a): "These entitlements are not required for developers to
// include buttons, external links, or other calls to action in their United
// States storefront apps", and 3.1.3: "Apps in this section cannot, within the
// app, encourage users to use a purchasing method other than in-app purchase,
// except for apps on the United States storefront…".
//
// It is still a rejection EVERYWHERE ELSE. So the web link stays gated on the
// device's actual App Store storefront: US → an extra "See plans on the web"
// line next to the in-app paywall; anywhere else → in-app purchase only, with
// no link and no invitation to buy elsewhere. Fail closed (no link) until
// StoreKit answers, and if it never answers. IAP itself is never gated.
@MainActor
final class Storefronts: ObservableObject {
    static let shared = Storefronts()

    /// nil while unknown. Read `allowsExternalPurchaseLinks` — it fails closed.
    @Published private(set) var countryCode: String?
    @Published private(set) var didResolve = false

    private init() {}

    /// True ONLY on the US storefront, where 3.1.1(a) permits an external
    /// purchase CTA without an entitlement. Anything else — a non-US
    /// storefront, no App Store account, StoreKit unavailable — is false.
    var allowsExternalPurchaseLinks: Bool { countryCode == "USA" }

    func resolve() async {
        guard !didResolve else { return }
        // StoreKit 2 (iOS 15+). Returns a 3-letter ISO code ("USA", "GBR", …),
        // or nil when there is no App Store account on the device.
        countryCode = await StoreKit.Storefront.current?.countryCode
        didResolve = true
    }
}

extension View {
    /// Resolve the storefront once so upgrade CTAs know whether they may show.
    func resolveStorefront() -> some View {
        task { await Storefronts.shared.resolve() }
    }
}

// MARK: - project-first additions
//
// Rendprop is PROJECT-FIRST. Every photo, reel, floor plan and aerial belongs to
// ONE home (project) — never to nothing. Before this block, Home's "AI Photo
// Studio" tile opened a standalone studio with no home attached, so every photo
// edited there was an orphan: the app could not say which house it belonged to.
// That entry is gone. Home's feature tiles now run the gate below first:
//
//   0 real homes  → "Start your first home" (name it) → land in the feature
//   exactly 1     → use it, no picker, no friction
//   2 or more     → "Which home?" picker → land in that home's feature
//   samples       → never selectable (their tools are no-ops by design)
//
// Everything here is additive: no existing type or function changed.

/// A feature a Home tile can open — once we know which home it is for.
enum ProjectFeature: String, Identifiable, Hashable, CaseIterable {
    case tour, photos, reel, floorPlan, aerial

    var id: String { rawValue }

    /// One clear verb. This is the words on the tile AND what happens next.
    var actionTitle: String {
        switch self {
        case .tour:      return "Make a tour"
        case .photos:    return "Take photos"
        case .reel:      return "Make a reel"
        case .floorPlan: return "Make a floor plan"
        case .aerial:    return "Make an aerial shot"
        }
    }

    /// Six words or fewer — what the feature does.
    var promise: String {
        switch self {
        case .tour:      return "Walk it once — glide forever"
        case .photos:    return "Twilight · blue sky · staging"
        case .reel:      return "Photos → one social video"
        case .floorPlan: return "Scan in 3D or upload"
        case .aerial:    return "A cinematic opening shot"
        }
    }

    var systemImage: String {
        switch self {
        case .tour:      return "video.fill"
        case .photos:    return "wand.and.stars"
        case .reel:      return "film.stack"
        case .floorPlan: return "cube.transparent"
        case .aerial:    return "airplane.departure"
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .tour:      return RPGradient.drone
        case .photos:    return RPGradient.photo
        case .reel:      return RPGradient.reel
        case .floorPlan: return RPGradient.plan
        case .aerial:    return RPGradient.aerial
        }
    }

    /// AI does the work here (shows the AI pill).
    var usesAI: Bool {
        switch self {
        case .tour, .photos, .reel, .aerial: return true
        case .floorPlan:                     return false
        }
    }
}

/// A home + the feature to open in it. The result of the gate.
struct ProjectRoute: Identifiable, Hashable {
    let listing: Listing
    let feature: ProjectFeature
    var id: String { "\(listing.id.uuidString)-\(feature.rawValue)" }
}

/// What the Home gate is asking right now. ONE sheet modifier drives all three
/// states, so they can never fight each other for the presentation slot.
enum ProjectGateSheet: Identifiable {
    case start(ProjectFeature)      // no homes yet — name one
    case pick(ProjectFeature)       // 2+ homes — which one?
    case aerial(Listing)            // the aerial tool is itself a sheet

    var id: String {
        switch self {
        case .start(let f):  return "start-\(f.rawValue)"
        case .pick(let f):   return "pick-\(f.rawValue)"
        case .aerial(let l): return "aerial-\(l.id.uuidString)"
        }
    }
}

extension AppModel {
    /// The homes a feature may actually save into: the user's own, this business
    /// type's, still active. Samples are excluded on purpose — every tool is a
    /// no-op on a sample, so offering one as a destination would be a lie.
    var realProjects: [Listing] {
        listings.filter { !$0.isSample && $0.belongsToCurrentType && !$0.isSold }
    }

    /// Start a home from just its name or address, so a feature always has one
    /// to save into. The walkthrough video is added later, from the home itself.
    /// Returns nil for an empty name.
    @discardableResult
    func startProject(named name: String) -> Listing? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let listing = Listing(address: trimmed,
                              beds: 0, baths: 0, sqft: 0,
                              price: Money(cents: 0),
                              status: .draft,
                              spaceTypeRaw: SpaceType.current.rawValue)
        add(listing)
        Analytics.track("home_created", ["space_type": SpaceType.current.rawValue])
        return listing
    }
}

// MARK: Cover thumbnail

/// A home's cover photo for the picker rows. Falls back to the type's icon —
/// a brand-new home has no photo yet, and that is a normal state.
struct ProjectCoverThumb: View {
    let listing: Listing
    var side: CGFloat = 54

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Theme.accentSoft
                Image(systemName: listing.spaceType.systemImage)
                    .font(.system(size: side * 0.38, weight: .semibold))
                    .foregroundStyle(Theme.accent.opacity(0.7))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: listing.mainPhotoRelPath) {
            guard let url = listing.mainPhotoURL else { image = nil; return }
            if let cached = ImageThumbnails.cached(url) { image = cached; return }
            let decoded = await ImageThumbnails.load(url)
            if !Task.isCancelled { image = decoded }
        }
    }
}

// MARK: "Which home?" picker

/// Shown only when the user has two or more homes. Address + cover photo, one
/// tap, nothing else on the screen.
struct ProjectPickerSheet: View {
    let feature: ProjectFeature
    let projects: [Listing]
    /// Called with the chosen home; the sheet dismisses itself right after.
    var onPick: (Listing) -> Void

    @Environment(\.dismiss) private var dismiss

    private var noun: String { SpaceType.current.spaceNoun }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(projects) { listing in
                        Button {
                            onPick(listing)
                            dismiss()
                        } label: {
                            ProjectPickerRow(listing: listing)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(feature.actionTitle) for which \(noun)?")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Pick a \(noun)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// One row of the picker: cover photo, address, and what it has so far.
struct ProjectPickerRow: View {
    let listing: Listing

    private var detail: String {
        let sub = listing.subtitleLine.trimmingCharacters(in: .whitespaces)
        return sub.isEmpty ? listing.status.label : sub
    }

    var body: some View {
        HStack(spacing: 12) {
            ProjectCoverThumb(listing: listing)
            VStack(alignment: .leading, spacing: 3) {
                Text(listing.address)
                    .font(.rpHeadline).foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(detail)
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.rpCaption.weight(.bold)).foregroundStyle(Theme.inkDim)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: First home

/// No homes yet. One field, one button — then straight into the feature the
/// user tapped. The video comes later, from the home's own screen.
struct StartProjectSheet: View {
    let feature: ProjectFeature
    /// Called with the typed name; the sheet dismisses itself right after.
    var onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var space: SpaceType { SpaceType.current }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headline
                    field
                    PrimaryButton(title: "Save and continue",
                                  systemImage: "arrow.right",
                                  isDisabled: trimmed.isEmpty) {
                        onCreate(trimmed)
                        dismiss()
                    }
                    Text("You can add the walkthrough video later.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Add a \(space.spaceNoun)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name this \(space.spaceNoun) first")
                .font(.rpTitle).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Everything you make is saved to it.")
                .font(.rpBody).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(space.showsPropertyDetails
                      ? "Type the home's address"
                      : "Name or address of your \(space.spaceNoun)",
                      text: $name)
                .textContentType(space.showsPropertyDetails ? .fullStreetAddress : .organizationName)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($focused)
                .font(.body)
                .padding(14)
                .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Next: \(feature.actionTitle.lowercased()).")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }
    }
}
// MARK: - end project-first additions
