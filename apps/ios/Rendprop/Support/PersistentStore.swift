import Foundation

/// Disk-backed snapshot of the app's real data — listings, their recorded/imported
/// assets, and their rendered tours — so nothing is lost when the app is killed and
/// relaunched. Before v1 of this, everything lived in memory only, so a render done
/// yesterday vanished on the next launch and the UI fell back to the sample tour.
///
/// URL pitfall handled here: iOS can change the app-container base path between
/// launches (and definitely across reinstalls/restores). We therefore persist every
/// file path RELATIVE to the Documents directory and rebuild absolute URLs at load
/// time. On load we also drop any entry whose file no longer exists.
enum PersistentStore {

    private static var fileURL: URL {
        FileStore.documents.appendingPathComponent("rendprop-state.json")
    }

    // MARK: - Codable DTOs (relativized, decoupled from runtime models)

    private struct PersistedAsset: Codable {
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

    private struct PersistedTour: Codable {
        var relPath: String
        var durationS: Double
        var speedFactor: Double
    }

    private struct PersistedState: Codable {
        var listings: [Listing] = []          // real listings only (never samples)
        var assets: [UUID: PersistedAsset] = [:]
        var tours: [UUID: PersistedTour] = [:]
        var renders: [UUID: Render] = [:]
    }

    // MARK: - Save

    static func save(listings: [Listing],
                     assets: [UUID: CaptureAsset],
                     tours: [UUID: AppModel.RenderedTour],
                     renders: [UUID: Render]) {
        var state = PersistedState()
        state.listings = listings.filter { !$0.isSample }
        let realIDs = Set(state.listings.map { $0.id })

        for (id, a) in assets where realIDs.contains(id) {
            state.assets[id] = PersistedAsset(
                id: a.id,
                relPath: FileStore.relativePath(for: a.localURL),
                motionRelPath: a.motionSidecarURL.map { FileStore.relativePath(for: $0) },
                durationS: a.durationS,
                fps: a.fps,
                width: a.width,
                height: a.height,
                bytes: a.bytes,
                isDrone: a.isDrone,
                roomTags: a.roomTags)
        }
        for (id, t) in tours where realIDs.contains(id) {
            state.tours[id] = PersistedTour(
                relPath: FileStore.relativePath(for: t.url),
                durationS: t.durationS,
                speedFactor: t.speedFactor)
        }
        state.renders = renders.filter { realIDs.contains($0.key) }

        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Non-fatal: worst case we lose persistence for this mutation, not the files.
        }
    }

    // MARK: - Load

    struct Loaded {
        var listings: [Listing] = []
        var assets: [UUID: CaptureAsset] = [:]
        var tours: [UUID: AppModel.RenderedTour] = [:]
        var renders: [UUID: Render] = [:]
    }

    static func load() -> Loaded {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return Loaded()
        }

        var out = Loaded()
        out.listings = state.listings

        for (id, a) in state.assets {
            let localURL = FileStore.url(fromRelativePath: a.relPath)
            guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
            out.assets[id] = CaptureAsset(
                id: a.id,
                localURL: localURL,
                motionSidecarURL: a.motionRelPath.map { FileStore.url(fromRelativePath: $0) },
                durationS: a.durationS,
                fps: a.fps,
                width: a.width,
                height: a.height,
                bytes: a.bytes,
                isDrone: a.isDrone,
                roomTags: a.roomTags)
        }
        for (id, t) in state.tours {
            let url = FileStore.url(fromRelativePath: t.relPath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            out.tours[id] = AppModel.RenderedTour(
                url: url,
                durationS: t.durationS,
                speedFactor: t.speedFactor)
        }
        // Keep renders only for listings we still have.
        let ids = Set(out.listings.map { $0.id })
        out.renders = state.renders.filter { ids.contains($0.key) }
        return out
    }
}
