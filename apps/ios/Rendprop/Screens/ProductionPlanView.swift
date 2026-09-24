import SwiftUI
import AVKit

/// Phone companion to Studio's production brief. It records human decisions,
/// preserves a recoverable local draft and uses revision-checked cloud writes.
struct ProductionPlanView: View {
    let listing: Listing
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var videoLibrary = ProductionVideoLibrary.shared
    @ObservedObject private var uploader = UploadManager.shared
    @ObservedObject private var planStore = ProductionPlanSyncStore.shared
    @State private var loadedIdentity: String?
    @State private var photoCount = 0
    @State private var showVideoPicker = false
    @State private var importingVideos = false
    @State private var previewVideo: ProductionVideoLibrary.Entry?
    @State private var busy = false
    @State private var notice: String?
    @State private var error: String?
    @State private var pendingRecipe: ProductionRecipe?
    @State private var confirmRecipe = false
    @State private var confirmLoad = false
    @State private var work: Task<Void, Never>?

    private var current: Listing { model.listings.first(where: { $0.id == listing.id }) ?? listing }
    private var owner: String { auth.userID ?? "device-only" }
    private var identity: String { "\(owner):\(auth.syncSessionRevision)" }
    private var planContext: ProductionPlanSyncStore.Context { .init(owner: owner, listingID: listing.id) }
    private var draft: ProductionPlanCache.Draft? { planStore.drafts[planContext.key] }
    private var savingPlan: Bool { planStore.saving.contains(planContext.key) }
    private var videoContext: ProductionVideoLibrary.Context { .init(owner: owner, listingID: listing.id) }
    private var videoEntries: [ProductionVideoLibrary.Entry] { videoLibrary.entries(videoContext) }
    private var uploadEngineBusy: Bool {
        guard let state = uploader.state else { return false }
        return [.uploading, .queued, .paused].contains(state.status)
    }
    private var asset: CaptureAsset? {
        guard let asset = model.assets[listing.id], FileManager.default.fileExists(atPath: asset.localURL.path) else { return nil }
        return asset
    }
    private var canSync: Bool {
        auth.isIdentified && !current.isSample && current.cloudUnavailable != true && model.api is ProductionSyncAPI
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                header
                if let draft {
                    goalCard(draft.plan)
                    inventoryCard
                    videoImportCard(draft.plan)
                    checklistCard(draft.plan)
                    notesCard(draft.plan)
                    syncCard(draft)
                } else {
                    ProgressView("Loading your plan…")
                }
                if let problem = error ?? planStore.errors[planContext.key] {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.rpCaption).foregroundStyle(Theme.warn)
                        .accessibilityIdentifier("production.error")
                }
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("Plan your video")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: identity) { await prepare() }
        .onDisappear { work?.cancel(); work = nil }
        .onChange(of: videoEntries) { _ in mergeUploadedLinks() }
        .onChange(of: busy) { active in if !active { mergeUploadedLinks() } }
        .sheet(isPresented: $showVideoPicker) { productionPicker }
        .sheet(item: $previewVideo) { entry in
            NavigationStack {
                VideoPlayer(player: AVPlayer(url: videoLibrary.file(entry, context: videoContext)))
                    .navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { previewVideo = nil } } }
            }
        }
        .confirmationDialog("Change the video plan?", isPresented: $confirmRecipe, titleVisibility: .visible) {
            Button("Change plan") {
                if let pendingRecipe, var plan = draft?.plan {
                    do { try plan.changeRecipe(pendingRecipe); update { $0 = plan } }
                    catch { self.error = "This plan has too many saved shots to change formats. Keep it or organize the shots in Studio first." }
                }
                pendingRecipe = nil
            }
            Button("Keep this plan", role: .cancel) { pendingRecipe = nil }
        } message: {
            Text("Your progress, linked files and notes are kept. Shots from the previous format that already have work become optional.")
        }
        .confirmationDialog("Load the Studio plan?", isPresented: $confirmLoad, titleVisibility: .visible) {
            Button("Replace this phone’s draft", role: .destructive) { runSync(save: false) }
            Button("Keep my draft", role: .cancel) {}
        } message: {
            Text("This replaces unsynced checklist changes and notes on this phone with the saved Studio plan. Your media files are kept.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("PHONE → STUDIO", systemImage: "iphone.and.arrow.forward")
                .font(.rpKicker).foregroundStyle(Theme.accent)
            Text("Know what to capture before you leave.")
                .font(.rpTitle).foregroundStyle(Theme.ink)
            Text(current.address).font(.rpBody).foregroundStyle(Theme.inkDim)
            Text("Choose the video you want, collect the shots, then continue editing in Studio.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func goalCard(_ plan: ProductionPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("1 · Choose your video", systemImage: "film.stack").font(.rpHeadline)
            Picker("Video type", selection: Binding(get: { plan.recipe }, set: { recipe in
                guard recipe != plan.recipe else { return }
                pendingRecipe = recipe; confirmRecipe = true
            })) {
                ForEach(ProductionRecipe.allCases) { recipe in
                    Label(recipe.title, systemImage: recipe.symbol).tag(recipe)
                }
            }
            .accessibilityIdentifier("production.recipe")
            Text(plan.recipe.subtitle).font(.rpCaption).foregroundStyle(Theme.inkDim)
            Picker("How you’ll tell the story", selection: Binding(get: { plan.presentation }, set: { value in update { $0.presentation = value } })) {
                ForEach(ProductionPresentation.allCases) { Text($0.title).tag($0) }
            }
            Text(plan.presentation.tip).font(.rpCaption).foregroundStyle(Theme.inkDim)
            Picker("Target length", selection: Binding(get: { plan.targetSeconds }, set: { value in update { $0.targetSeconds = value } })) {
                ForEach([30, 45, 60], id: \.self) { Text("\($0) seconds").tag($0) }
            }
            Text("Target length guides the edit; it doesn’t trim or generate any media.")
                .font(.caption2).foregroundStyle(Theme.inkDim)
        }
        .disabled(busy).card()
    }

    private var inventoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Already on this iPhone", systemImage: "photo.on.rectangle.angled").font(.rpHeadline)
            Text("\(photoCount) photo\(photoCount == 1 ? "" : "s") · \(asset == nil ? "No local walkthrough" : "1 local walkthrough")")
                .font(.rpBody)
            Text("These are file counts, not a coverage or quality check. Play each take back before marking it captured.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            NavigationLink {
                PhotoStudioView(listing: current, entry: .photos)
            } label: { Label("Open property photos", systemImage: "photo") }
            if current.serverID != nil && !current.isSample {
                NavigationLink { CloudMediaView(listing: current) } label: {
                    Label("See uploaded files", systemImage: "icloud")
                }
            }
            Text("Separate video takes belong in the clip library below. Your walkthrough stays in its tour tool.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var productionPicker: some View {
        let expected = identity
        let context = videoContext
        return ProductionVideoPicker(onStart: { importingVideos = true }, onFile: { url, name in
            guard identity == expected, model.listings.contains(where: { $0.id == context.listingID }) else { return }
            do { try await videoLibrary.importFile(url, name: name, context: context) }
            catch { self.error = error.localizedDescription }
        }, onFinish: { importingVideos = false }, onError: { error = $0 })
    }

    private func videoImportCard(_ plan: ProductionPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Separate video takes", systemImage: "video.badge.plus").font(.rpHeadline)
            Text("Film your shots in Camera, then select them from Photos. Rendprop keeps a separate copy of each original and uploads it to this property’s Studio library.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            Button { showVideoPicker = true } label: {
                Label(importingVideos ? "Importing videos…" : "Add videos from Photos", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered).disabled(importingVideos || busy || current.isSample)
            .accessibilityIdentifier("production.importVideos")
            if importingVideos { ProgressView("Copying originals one at a time…") }
            ForEach(videoEntries) { entry in videoRow(entry, plan: plan) }
            if !videoEntries.isEmpty {
                Button { startVideoUploads() } label: {
                    Label(videoLibrary.activeContext == videoContext ? "Uploading clips…" : "Upload remaining clips to Studio", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(!canSync || busy || importingVideos || videoLibrary.activeContext != nil || uploadEngineBusy || videoEntries.allSatisfy(\.uploaded))
                .accessibilityIdentifier("production.uploadVideos")
                Text("Uploads follow your Wi-Fi setting. Originals stay on this iPhone after an error. Uploading doesn’t mark a shot as reviewed.")
                    .font(.caption2).foregroundStyle(Theme.inkDim)
            }
            if let failure = videoLibrary.storageError { Text(failure).font(.rpCaption).foregroundStyle(Theme.warn) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func videoRow(_ entry: ProductionVideoLibrary.Entry, plan: ProductionPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { previewVideo = entry } label: { Image(systemName: "play.circle.fill").font(.title2) }
                    .accessibilityLabel("Review \(entry.name)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.rpBody.weight(.semibold)).lineLimit(2)
                    Text("\(Int(entry.duration.rounded())) sec · \(entry.width) × \(entry.height)")
                        .font(.caption2).foregroundStyle(Theme.inkDim)
                }
                Spacer()
                if entry.uploaded { Image(systemName: "icloud.fill").foregroundStyle(Theme.good).accessibilityLabel("Uploaded") }
            }
            Picker("Shot for this clip", selection: Binding(get: { entry.shotID ?? "" }, set: { shotID in
                assignVideo(entry, shotID: shotID.isEmpty ? nil : shotID)
            })) {
                Text("Choose a shot (optional)").tag("")
                ForEach(plan.shots) { Text($0.title).tag($0.id) }
                if let old = entry.shotID, !plan.shots.contains(where: { $0.id == old }) {
                    Text("Previous plan: \(old)").tag(old)
                }
            }
            .disabled(busy)
            if let state = uploader.state,
               state.filePath == FileStore.relativePath(for: videoLibrary.file(entry, context: videoContext)),
               state.status != .done {
                ProgressView(value: min(1, max(0, state.fractionComplete)))
                Text(uploadLabel(state)).font(.rpCaption).foregroundStyle(Theme.inkDim)
                if state.status == .paused {
                    Button("Resume this upload") { uploader.resume() }.buttonStyle(.bordered)
                }
            } else {
                Text(entry.uploaded ? "Uploaded to this property. Its shot assignment syncs with your plan." : "Saved on this iPhone · not uploaded")
                    .font(.caption2).foregroundStyle(entry.uploaded ? Theme.accent : Theme.inkDim)
            }
            if let failure = entry.failure { Text(failure).font(.caption2).foregroundStyle(Theme.warn) }
        }
        .padding(12).background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12))
    }

    private func uploadLabel(_ state: UploadManager.State) -> String {
        switch state.status {
        case .queued: return "Waiting for Wi-Fi. You can also allow cellular uploads in Settings."
        case .uploading: return "Uploading \(Int(min(1, max(0, state.fractionComplete)) * 100))%"
        case .paused: return "Upload paused. The original is safe."
        case .failed: return "Upload needs another try. Tap Upload remaining clips to retry."
        case .done: return "Uploaded"
        }
    }

    private func assignVideo(_ entry: ProductionVideoLibrary.Entry, shotID: String?) {
        do {
            try videoLibrary.assign(entry.id, shotID: shotID, context: videoContext)
            mergeUploadedLinks()
        } catch { self.error = "The shot assignment couldn’t be saved. Your clip is still available." }
    }

    private func mergeUploadedLinks() {
        guard !busy, let currentPlan = draft?.plan, let serverID = current.serverID else { return }
        let links = videoEntries.filter { $0.serverListingID == serverID }.map(\.link)
        let result = ProductionVideoLink.applying(links, to: currentPlan)
        guard result.plan == currentPlan || update({ $0 = result.plan }) else { return }
        do { try videoLibrary.acknowledgeLinks(result.acknowledged, context: videoContext) }
        catch { self.error = "The clip is safe, but its shot assignment couldn’t be saved. Try again before leaving." }
        if result.blocked { error = "Choose an available shot with fewer than 12 linked videos. Your extra uploads remain in Studio’s media library." }
    }

    private func startVideoUploads() {
        guard canSync, videoLibrary.activeContext == nil, !busy else { return }
        let expected = identity
        let context = videoContext
        work = Task {
            busy = true
            defer { if identity == expected { busy = false } }
            do {
                let serverID = try await model.ensureServerListing(current)
                try Task.checkCancellation()
                guard identity == expected, current.cloudUnavailable != true else { throw CloudSyncError.identityChanged }
                videoLibrary.uploadAll(context: context, serverListingID: serverID, api: model.api, identity: expected) {
                    guard identity == expected else { return }
                    mergeUploadedLinks()
                }
            } catch {
                if identity == expected { self.error = "The upload couldn’t start. \(error.localizedDescription) Your imported originals are safe." }
            }
        }
    }

    private func checklistCard(_ plan: ProductionPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("2 · Before you leave", systemImage: "checklist").font(.rpHeadline)
            Text(plan.remainingCount == 0 ? "You’ve accounted for every required shot." : "\(plan.remainingCount) required shot\(plan.remainingCount == 1 ? "" : "s") still to capture or account for.")
                .font(.rpBody.weight(.semibold)).accessibilityIdentifier("production.remaining")
            Text("Captured means you checked it yourself. It doesn’t confirm that the file is uploaded, sharp or correctly exposed.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            ForEach(plan.shots) { shot in
                shotRow(shot, recipe: plan.recipe)
                if shot.id != plan.shots.last?.id { Divider() }
            }
            Label("Clean the lens. Keep the phone level. Hold each shot at its start and end. Listen to speech playback before leaving.", systemImage: "lightbulb")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }
        .disabled(busy).card()
    }

    private func shotRow(_ shot: ProductionPlan.Shot, recipe: ProductionRecipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: shot.status == .captured ? "checkmark.circle.fill" : (shot.status == .notNeeded ? "minus.circle" : "circle"))
                    .foregroundStyle(shot.status == .captured ? Theme.good : Theme.inkDim)
                Text(shot.title).font(.rpBody.weight(.semibold))
                Spacer()
                if !shot.required { Text("Optional").font(.caption2).foregroundStyle(Theme.inkDim) }
            }
            Text(shot.guidance).font(.rpCaption).foregroundStyle(Theme.inkDim)
            if let guide = ProductionGuidance.shots(for: recipe).first(where: { $0.id == shot.id }) {
                Text("Suggested take: \(guide.suggestedSeconds)").font(.caption2).foregroundStyle(Theme.accent)
                let hints = chapterHints(guide)
                if !hints.isEmpty {
                    Text("Chapter to review in your walkthrough: \(hints.joined(separator: ", ")).")
                        .font(.caption2).foregroundStyle(Theme.inkDim)
                }
            }
            Picker("\(shot.title) progress", selection: Binding(get: { shot.status }, set: { status in
                updateShot(shot.id) { $0.status = status }
            })) {
                ForEach(ProductionShotStatus.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("production.shot.\(shot.id)")
            if !shot.sourcePhotoIds.isEmpty || !shot.sourceVideoIds.isEmpty {
                Text("\(shot.sourcePhotoIds.count) photo\(shot.sourcePhotoIds.count == 1 ? "" : "s") and \(shot.sourceVideoIds.count) video\(shot.sourceVideoIds.count == 1 ? "" : "s") linked to this shot.")
                    .font(.caption2).foregroundStyle(Theme.accent)
            }
            TextField("Shot notes for your editor", text: Binding(get: { shot.notes }, set: { value in
                updateShot(shot.id) { $0.notes = limited(value, to: 500) }
            }), axis: .vertical)
            .lineLimit(1...4).font(.rpCaption)
            .padding(10).background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func notesCard(_ plan: ProductionPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notes for the edit", systemImage: "text.bubble").font(.rpHeadline)
            TextField("What should viewers remember? Add approved facts, sources and anything the editor should avoid.", text: Binding(get: { plan.notes }, set: { value in update { $0.notes = limited(value, to: 2000) } }), axis: .vertical)
                .lineLimit(3...8).font(.rpBody)
                .accessibilityIdentifier("production.notes")
            Text("Market numbers need a source, location and date. Confirm property facts before publishing.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }
        .disabled(busy).card()
    }

    private func syncCard(_ draft: ProductionPlanCache.Draft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("3 · Continue in Studio", systemImage: "desktopcomputer").font(.rpHeadline)
            Text(savingPlan ? "Saving changes to Studio…" : (draft.dirty || draft.pendingWrite != nil) ? "Changes saved on this iPhone. They sync automatically when this property is connected." : (draft.revision > 0 ? "This plan matches saved Studio revision \(draft.revision)." : "Choose your plan, then save it to Studio."))
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            Text("Your choices and notes sync automatically for a connected property. Clips upload separately; their shot assignments join the plan after each upload finishes.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            if canSync {
                Button { runSync(save: true) } label: {
                    Label(busy || savingPlan ? "Syncing…" : "Sync plan now", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(busy || savingPlan).accessibilityIdentifier("production.save")
                Button("Load Studio plan") {
                    if draft.dirty || draft.pendingWrite != nil { confirmLoad = true } else { runSync(save: false) }
                }.buttonStyle(.bordered).disabled(busy || savingPlan)
            } else {
                Text(current.cloudUnavailable == true ? "This property’s cloud access has changed. Your local plan is still available." : "Sign in to your Rendprop account to save this plan to Studio. Your checklist remains on this iPhone.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            Link("Open Rendprop Studio", destination: URL(string: "https://studio.rendprop.com/")!)
                .font(.rpBody.weight(.semibold))
            if let message = notice ?? planStore.notices[planContext.key] { Text(message).font(.rpCaption).foregroundStyle(Theme.accent) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func chapterHints(_ guide: ProductionShotGuide) -> [String] {
        guard let asset else { return [] }
        return ProductionGuidance.matchingChapters(guide,
            names: asset.roomTags.map { ($0.name, $0.tSeconds, $0.isFromAI) }, duration: asset.durationS)
    }

    private func limited(_ value: String, to limit: Int) -> String {
        var output = "", count = 0
        for character in value {
            let length = String(character).utf16.count
            guard count + length <= limit else { break }
            output.append(character); count += length
        }
        return output
    }

    @discardableResult private func update(_ edit: (inout ProductionPlan) -> Void) -> Bool {
        guard !busy, loadedIdentity == identity, var next = draft else { return false }
        edit(&next.plan); next.dirty = true
        do {
            try planStore.replace(next, context: planContext)
            notice = nil; error = nil
            schedulePlanSync()
            return true
        } catch { self.error = "Your change couldn’t be saved on this iPhone. Try again before leaving this screen."; return false }
    }

    private func updateShot(_ id: String, _ edit: (inout ProductionPlan.Shot) -> Void) {
        update { plan in
            guard let index = plan.shots.firstIndex(where: { $0.id == id }) else { return }
            edit(&plan.shots[index])
        }
    }

    @MainActor private func prepare() async {
        let expected = identity
        work?.cancel(); work = nil; busy = false
        loadedIdentity = expected; notice = nil; error = nil
        do { try videoLibrary.load(videoContext) }
        catch { self.error = "This property’s clip library couldn’t be read. Existing files have been kept. Try again after checking free storage." }
        do {
            try planStore.load(planContext, serverID: current.serverID)
        } catch {
            // Do not overwrite an unreadable recovery draft with a blank one.
            self.error = "This iPhone’s saved plan couldn’t be read. It has been kept for recovery. Open Studio to continue with the cloud plan."
            return
        }
        let listingID = listing.id
        let count = await Task.detached(priority: .utility) { EnhancedPhoto.loadAll(listingID: listingID).count }.value
        guard identity == expected, !Task.isCancelled else { return }
        photoCount = count
        mergeUploadedLinks()
        if canSync, current.serverID != nil, current.serverOrgID != nil, draft?.dirty == false, draft?.pendingWrite == nil, !savingPlan {
            await sync(save: false)
        } else { schedulePlanSync() }
    }

    private func runSync(save: Bool) {
        guard !busy else { return }
        work = Task { await sync(save: save) }
    }

    private func schedulePlanSync() {
        guard canSync, let serverID = current.serverID, let orgID = current.serverOrgID,
              let api = model.api as? ProductionSyncAPI else { return }
        planStore.schedule(planContext, serverID: serverID, orgID: orgID, api: api, identity: identity)
    }

    @MainActor private func sync(save: Bool) async {
        guard !busy, !savingPlan, canSync, let api = model.api as? ProductionSyncAPI else { return }
        if save { mergeUploadedLinks() }
        guard draft != nil else { return }
        planStore.cancelPending(planContext)
        // Reading/replacing a plan is explicit and briefly locks the form.
        // Automatic writes use the shared snapshot writer and leave it editable.
        busy = true; error = nil; notice = nil
        let expected = identity, context = planContext
        defer { if identity == expected { busy = false } }
        do {
            if save, current.serverID == nil { _ = try await model.ensureServerListing(current) }
            if current.serverOrgID == nil { await model.refreshCloudWorkspace() }
            try Task.checkCancellation()
            guard identity == expected, auth.isIdentified, current.cloudUnavailable != true,
                  let serverID = current.serverID, let orgID = current.serverOrgID else { throw CloudSyncError.identityChanged }
            if save {
                // Shared writer survives this screen and reads the latest local
                // draft before applying its receipt. Leaving can't lose edits.
                busy = false
                _ = await planStore.save(context, serverID: serverID, orgID: orgID, api: api, identity: expected)
                return
            }
            let pullSnapshot = videoEntries.filter { $0.serverListingID == serverID }.map(\.link)
            guard let document = try await api.productionPlan(listingID: serverID, orgID: orgID) else {
                notice = "There isn’t a Studio plan yet. Your next change will sync automatically."
                return
            }
            try Task.checkCancellation()
            guard identity == expected, auth.isIdentified, current.serverID == serverID else { throw CloudSyncError.identityChanged }
            let accepted = ProductionPlanCache.Draft(plan: document.payload, revision: document.revision, dirty: false)
            try videoLibrary.reconcileLinks(remote: document.payload, pullSnapshot: pullSnapshot, context: videoContext)
            try planStore.acceptRemote(accepted, context: context)
            notice = "Studio plan loaded. Linked files and editor notes are preserved."
        } catch is CancellationError { return }
        catch {
            guard identity == expected else { return }
            self.error = "The Studio plan couldn’t be loaded. Your phone draft is unchanged. Try again when connected."
        }
    }
}
