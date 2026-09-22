import SwiftUI
import AVKit
import UIKit

/// On-demand access keeps an office's large originals off cellular until the
/// agent chooses a file. Successful imports use the existing Photo/Review tools.
struct CloudMediaView: View {
    let listing: Listing
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

    private var current: Listing { model.listings.first(where: { $0.id == listing.id }) ?? listing }
    private var floorPlanURL: URL? {
        guard let raw = current.details?["floorplan_url"], let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        return url
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Files from your phone and Studio").font(.title2.bold())
                Text("Preview the shared files here. Save a photo or use a video when you want to edit it on this iPhone.")
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155))], spacing: 16) {
                        ForEach(photos) { photo in
                            VStack(alignment: .leading, spacing: 10) {
                                AsyncImage(url: photo.url) { image in image.resizable().scaledToFill() }
                                    placeholder: { ZStack { Theme.fillSubtle; Image(systemName: "photo") } }
                                    .frame(height: 145).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(photo.caption?.isEmpty == false ? photo.caption! : "Listing photo").font(.subheadline.weight(.medium))
                                if photo.is_staged { Text("Virtually staged").font(.caption).foregroundStyle(.orange) }
                                if photo.is_altered == true && photo.original_url == nil {
                                    Text("The original must be attached before this edit can be imported.").font(.caption).foregroundStyle(Theme.inkDim)
                                }
                                Button { importPhoto(photo) } label: {
                                    Label(imported.contains(photo.id) ? "Saved on iPhone" : "Save to Photo Studio", systemImage: imported.contains(photo.id) ? "checkmark" : "arrow.down.circle")
                                        .font(.caption.weight(.semibold))
                                }
                                .disabled(importing != nil || imported.contains(photo.id) || (photo.original_url == nil && photo.is_altered != false))
                            }.padding(12).background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14))
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
                        guard auth.isIdentified, current.serverID != nil else { return }
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
        importTask?.cancel(); photos = []; videos = []; chapters = []; imported = []
        creative = nil; creativeError = nil; notice = nil; replaceVideo = nil
    }

    @MainActor private func load(more: Bool = false) async {
        guard !loading, importing == nil else { return }
        loading = true; error = nil
        defer { loading = false }
        if !more { photos = []; videos = []; chapters = []; nextOffset = nil; creative = nil; creativeError = nil }
        guard auth.isIdentified else { error = "Connect the same Apple account you use in Studio to see shared files."; return }
        if current.serverOrgID == nil { await model.refreshCloudWorkspace() }
        guard let sid = current.serverID, let org = current.serverOrgID, current.cloudUnavailable != true,
              let cloud = model.api as? WorkspaceSyncAPI else { error = "This listing hasn't reached your cloud workspace yet. Publish or upload it first."; return }
        let actor = auth.userID, revision = auth.syncSessionRevision
        do {
            let offset = more ? (nextOffset ?? 0) : 0
            let page = try await cloud.cloudMedia(listingID: sid, orgID: org, offset: offset)
            guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified, current.serverID == sid else { throw CloudSyncError.identityChanged }
            guard Set(photos.map(\.id)).isDisjoint(with: page.photos.map(\.id)), Set(videos.map(\.id)).isDisjoint(with: page.videos.map(\.id)) else { throw CloudSyncError.incomplete }
            photos += page.photos; videos += page.videos; nextOffset = page.next_offset
            if page.unavailable_count > 0 { notice = "Some files are still processing or no longer available. Refresh after the upload finishes." }
            if !more {
                let state = try await cloud.cloudListingState(listingID: sid, orgID: org, offset: 0)
                guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified else { throw CloudSyncError.identityChanged }
                chapters = state.chapters
                do {
                    let saved = try await cloud.cloudCreative(listingID: sid, orgID: org)
                    guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified else { throw CloudSyncError.identityChanged }
                    creative = saved
                } catch {
                    if auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified {
                        creativeError = "Studio scripts and narration couldn't be loaded. Refresh to try again."
                    }
                }
            }
        } catch is CancellationError { return }
        catch { if auth.userID == actor && auth.syncSessionRevision == revision { self.error = error is CloudSyncError ? error.localizedDescription : "Cloud files couldn't be loaded. Refresh to try again." } }
    }

    @MainActor private func importPhoto(_ photo: CloudMediaPage.Photo) {
        guard importing == nil, let org = current.serverOrgID, let sid = current.serverID,
              let originalURL = photo.original_url ?? (photo.is_altered == false ? photo.url : nil) else { return }
        let localID = current.id, actor = auth.userID, revision = auth.syncSessionRevision
        importing = photo.id; error = nil; notice = nil
        importTask = Task {
            defer { importing = nil; importTask = nil }
            var temporary: [URL] = []
            defer { for url in temporary { try? FileManager.default.removeItem(at: url) } }
            do {
                try CloudListingMerge.validateMedia(originalURL, expiry: photo.expires_at, listingID: sid, orgID: org, now: Date())
                let original = try await CloudFileDownload.fetch(originalURL, kind: .photo); temporary.append(original.url)
                let enhanced = photo.url == originalURL ? original : try await CloudFileDownload.fetch(photo.url, kind: .photo)
                if enhanced.url != original.url { temporary.append(enhanced.url) }
                try Task.checkCancellation()
                guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified,
                      model.listings.contains(where: { $0.id == localID && $0.serverID == sid }) else { throw CloudSyncError.identityChanged }
                let directory = EnhancedPhoto.directory(for: localID)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = "cloud-\(photo.id.uuidString)"
                let originalDest = directory.appendingPathComponent("orig-\(name).\(original.ext)")
                let enhancedDest = directory.appendingPathComponent("enh-\(name).\(enhanced.ext)")
                if !FileManager.default.fileExists(atPath: originalDest.path) { try FileManager.default.copyItem(at: original.url, to: originalDest) }
                if !FileManager.default.fileExists(atPath: enhancedDest.path) { try FileManager.default.copyItem(at: enhanced.url, to: enhancedDest) }
                guard let ownerID = actor.flatMap(UUID.init(uuidString:)) else { throw CloudSyncError.identityChanged }
                // Bind the response's genuine ID to the imported bytes, never to
                // a filename that happens to contain a UUID.
                try await CloudPhotoReferences.shared.save(sourceID: photo.id, fileURL: enhanced.url,
                    ownerID: ownerID, orgID: org, listingID: sid)
                guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified else { throw CloudSyncError.identityChanged }
                if current.mainPhotoURL == nil { model.modify(localID, sync: false) { $0.mainPhotoRelPath = FileStore.relativePath(for: enhancedDest) } }
                imported.insert(photo.id); notice = "Photo and its original are available in this listing's Photo Studio."
            } catch is CancellationError { return }
            catch { if auth.userID == actor { self.error = error is CloudSyncError ? error.localizedDescription : "The photo couldn't be saved. Refresh its private link and try again." } }
        }
    }

    @MainActor private func importVideo(_ video: CloudMediaPage.Video) {
        guard importing == nil, let org = current.serverOrgID, let sid = current.serverID else { return }
        let localID = current.id, actor = auth.userID, revision = auth.syncSessionRevision
        importing = video.id; error = nil; notice = nil
        importTask = Task {
            defer { importing = nil; importTask = nil }
            var temp: URL?, saved: URL?
            defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
            do {
                try CloudListingMerge.validateMedia(video.url, expiry: video.expires_at, listingID: sid, orgID: org, now: Date())
                let file = try await CloudFileDownload.fetch(video.url, kind: .video); temp = file.url
                let destination = FileStore.importsDir.appendingPathComponent("cloud-\(video.id.uuidString)-\(UUID().uuidString).\(file.ext)")
                try FileManager.default.copyItem(at: file.url, to: destination); saved = destination
                var asset = try await MediaImporter.makeAsset(from: destination, isDrone: nil)
                asset.roomTags = chapters.filter { $0.asset_id == video.id }.sorted { $0.sort < $1.sort }.map { RoomTag(name: $0.label, tMs: $0.t_ms) }
                try Task.checkCancellation()
                guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified,
                      model.listings.contains(where: { $0.id == localID && $0.serverID == sid }) else { throw CloudSyncError.identityChanged }
                model.assets[localID] = asset; imported.insert(video.id)
                notice = "Video saved. Open the listing and choose Create tour to edit it on your iPhone."
                saved = nil
            } catch is CancellationError { if let saved { try? FileManager.default.removeItem(at: saved) }; return }
            catch { if let saved { try? FileManager.default.removeItem(at: saved) }; if auth.userID == actor { self.error = error is CloudSyncError ? error.localizedDescription : "The video couldn't be saved. Check free space, refresh its link and try again." } }
        }
    }

    @MainActor private func importVoice(_ voice: CloudCreative.Result) {
        guard importing == nil, auth.isIdentified, let org = current.serverOrgID, let sid = current.serverID,
              let url = voice.url, let expiry = voice.expires_at, voice.state == "completed", voice.kind == "voice" else { return }
        let localID = current.id, actor = auth.userID, revision = auth.syncSessionRevision
        importing = voice.id; error = nil; notice = nil
        importTask = Task {
            defer { importing = nil; importTask = nil }
            var temporary: URL?
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            do {
                try CloudListingMerge.validateMedia(url, expiry: expiry, listingID: sid, orgID: org, now: Date(), voice: true)
                let file = try await CloudFileDownload.fetch(url, kind: .audio); temporary = file.url
                try Task.checkCancellation()
                guard auth.userID == actor, auth.syncSessionRevision == revision, auth.isIdentified,
                      model.listings.contains(where: { $0.id == localID && $0.serverID == sid }) else { throw CloudSyncError.identityChanged }
                try CloudVoiceStore.saveVoice(voice, file: file.url, ext: file.ext, listingID: localID)
                imported.insert(voice.id); notice = "Narration saved. Open Reel Studio on this listing to use it."
            } catch is CancellationError { return }
            catch { if auth.userID == actor { self.error = error is CloudSyncError ? error.localizedDescription : "The narration couldn't be saved. Refresh its link and try again." } }
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
private enum CloudFileDownload {
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
