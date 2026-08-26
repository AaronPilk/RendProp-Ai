import SwiftUI
import AuthenticationServices

/// Render progress. Real listings run the ON-DEVICE render engine (retime →
/// 60fps → scrub-ready encode). When `Config.useLiveBackend` is on, a successful
/// on-device render is then PUBLISHED to the cloud (upload role=render →
/// /renders/publish-app) so it gets a real shareable slug — the in-app tour
/// always works either way (local-first, contract §4). Sample listings simulate.
///
/// Cinematic / 4K Premium tiers add a REAL server AI pass before publish:
/// upload the on-device master → POST /ai-video/drone (Topaz motion smoothing +
/// upscale on fal) → poll → download the enhanced mp4 → publish THAT. Any
/// failure falls back to publishing the standard on-device render — the user is
/// never dead-ended.
struct RenderStatusView: View {
    @EnvironmentObject var model: AppModel

    let listing: Listing
    @State var render: Render

    @State private var pollTask: Task<Void, Never>?
    @State private var phaseLabel = "Queued…"
    @State private var isReady = false
    @State private var isPublishing = false
    @State private var publishFailed = false
    @State private var failureMessage: String?

    // Held so publishing can resume after the Sign in with Apple sheet completes.
    @State private var renderOutput: RenderEngine.Output?
    @State private var showSignIn = false

    // Server AI enhance stage (cinematic/4K tiers, live backend only).
    @State private var enhanceDetail: String?   // caption while enhancing
    @State private var enhanceNote: String?     // shown when ready if enhance fell back
    @State private var isEnhancing = false      // true during the AI enhance wait — drives the Skip button
    @State private var didSkipEnhance = false   // user tapped "Skip AI enhance" during the wait

    /// Live copy so the real server share URL (set by publishTour) is picked up.
    private var currentListing: Listing {
        model.listings.first(where: { $0.id == listing.id }) ?? listing
    }

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            ZStack {
                // Theme.border (not fillSubtle) for the track — reads clearly
                // against the background in both light and dark.
                Circle()
                    .stroke(Theme.border, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(render.progress))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: render.progress)
                if isReady {
                    Image(systemName: "checkmark")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Theme.good)
                } else if isPublishing {
                    ProgressView()
                        .scaleEffect(1.4)
                } else {
                    Text(render.progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
            }
            .frame(width: 150, height: 150)
            .accessibilityElement(children: .combine)

            VStack(spacing: 6) {
                Text(isReady ? "Your tour is ready" : (failureMessage ?? phaseLabel))
                    .font(.rpTitle)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text(isReady
                     ? "Smooth, fast, and ready to fly through."
                     : "\(render.tier.displayName) · \(Formatters.duration(render.durationS)) walkthrough")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
                if isReady && publishFailed {
                    Text("Saved on your phone — we couldn't publish the share link. You can view it now and share it later.")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.center)
                }
                if isReady, let enhanceNote {
                    Text(enhanceNote)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal)

            if !isReady && failureMessage == nil {
                Text(isPublishing
                     ? (enhanceDetail ?? "Uploading and publishing your tour…")
                     : "Keep the app open — this runs right on your phone.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer()

            // Escape hatch for the up-to-20-min AI enhance wait: publish the
            // standard on-device tour NOW instead of trapping the user (the nav
            // back button is intentionally hidden while publishing).
            if isEnhancing && !isReady {
                Button {
                    didSkipEnhance = true
                    Haptics.selection()
                } label: {
                    Text(didSkipEnhance ? "Finishing up…" : "Skip AI enhance & publish now")
                        .font(.rpBody.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Theme.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(didSkipEnhance)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .accessibilityLabel(Text("Skip the AI enhancement and publish the standard tour now"))
            }

            if isReady {
                VStack(spacing: 12) {
                    NavigationLink {
                        FlythroughDetailView(listing: listing)
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("View my tour").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Theme.accent)
                        .foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    // Share the REAL server slug when the tour was published.
                    if let shareURL = currentListing.serverShareURL {
                        ShareLink(item: shareURL,
                                  subject: Text(listing.address),
                                  message: Text("Fly through \(listing.address) — scroll to walk the \(SpaceType.current.spaceNoun).")) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share tour").fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Theme.accentSoft)
                            .foregroundStyle(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 18)
            }
        }
        // Fill the whole screen: without this the VStack hugs its widest text and
        // Theme.bg paints only a centered column — the "floating gray rectangle"
        // users saw over the white window background while rendering.
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .navigationTitle("Creating Tour")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!isReady && failureMessage == nil)
        .onAppear { start() }
        .onDisappear { pollTask?.cancel() }
        .sheet(isPresented: $showSignIn, onDismiss: { onSignInSheetDismissed() }) {
            SignInView()
        }
    }

    // MARK: - Drive

    private func start() {
        if let asset = model.assets[listing.id] {
            runRealRender(asset: asset)
        } else {
            runSimulation()   // sample listings only
        }
    }

    private func runRealRender(asset: CaptureAsset) {
        pollTask?.cancel()
        pollTask = Task {
            do {
                let output = try await RenderEngine.render(asset: asset) { p, label in
                    Task { @MainActor in
                        render.progress = p
                        phaseLabel = label
                    }
                }
                await MainActor.run {
                    // In-app viewing works in BOTH cases — store the local tour now.
                    model.tours[listing.id] = AppModel.RenderedTour(url: output.url,
                                                                    durationS: output.durationS,
                                                                    speedFactor: output.speedFactor)
                    render.progress = 1.0
                    renderOutput = output
                }
                if Config.useLiveBackend {
                    await beginPublish(asset: asset, output: output)
                } else {
                    await MainActor.run { markReady() }
                }
            } catch {
                await MainActor.run {
                    failureMessage = error.localizedDescription
                    render.progress = 0
                }
            }
        }
    }

    /// Gate PUBLISHING (not app use) on Sign in with Apple, then run the
    /// publish pipeline (server AI enhance first for the AI tiers).
    @MainActor
    private func beginPublish(asset: CaptureAsset, output: RenderEngine.Output) async {
        if Config.enableAuth && !AuthStore.shared.isSignedIn {
            showSignIn = true   // publishing resumes in onSignInSheetDismissed()
            return
        }
        await runPublishPipeline(asset: asset, output: output)
    }

    /// Cinematic / 4K Premium run the on-device master through the server AI
    /// pass (Topaz via /ai-video/drone) before publishing; Smooth publishes the
    /// on-device render directly. Both paths require sign-in (already gated).
    @MainActor
    private func runPublishPipeline(asset: CaptureAsset, output: RenderEngine.Output) async {
        if Config.useLiveBackend && (render.tier == .cinematic || render.tier == .premium4k) {
            await enhanceThenPublish(asset: asset, output: output)
        } else {
            await performPublish(asset: asset, output: output)
        }
    }

    /// The REAL AI stage: upload the on-device master (role=render, public
    /// bucket) → submit /ai-video/drone → poll every 6 s (≤ 20 min) → download
    /// the enhanced mp4 into Documents → swap the local tour to it → publish
    /// the ENHANCED file through the normal path. Topaz preserves duration, so
    /// speedFactor and the rescaled room-tag chapters stay valid.
    ///
    /// ANY failure here (upload, submit, poll, timeout, download) falls back to
    /// publishing the standard on-device render — never dead-ends the user.
    @MainActor
    private func enhanceThenPublish(asset: CaptureAsset, output: RenderEngine.Output) async {
        isPublishing = true
        publishFailed = false
        enhanceNote = nil
        isEnhancing = true
        didSkipEnhance = false
        phaseLabel = "Enhancing with AI…"
        enhanceDetail = "Smoothing motion + upscaling to 4K on our render farm — this can take several minutes. Keep the app open."
        do {
            // a. Server listing identity (created on first publish, then cached).
            let serverID = try await model.ensureServerListing(listing)

            // b. Upload the on-device master to the PUBLIC renders bucket so fal
            //    can fetch it (the drone route 400s on private-bucket assets).
            phaseLabel = "Uploading for AI enhance…"
            let meta = UploadMetadata(durationS: output.durationS,
                                      bytes: FileStore.fileSize(output.url))
            let assetID = try await UploadManager.shared.upload(
                fileURL: output.url, listingID: serverID, role: "render", metadata: meta)

            // c. Submit + poll. 4K Premium → 4k30; Cinematic → 4k60.
            phaseLabel = "Enhancing with AI…"
            let tierParam = (render.tier == .premium4k) ? "4k30" : "4k60"
            let job = try await model.api.aiVideoDrone(assetID: assetID,
                                                       tier: tierParam, targetFps: 60)
            let deadline = Date().addingTimeInterval(20 * 60)
            var enhancedRemoteURL: URL?
            while enhancedRemoteURL == nil {
                if didSkipEnhance { break }
                guard Date() < deadline else {
                    throw NSError(domain: "AIVideo", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "The AI enhance took too long."])
                }
                try await Task.sleep(nanoseconds: 6_000_000_000)
                if didSkipEnhance { break }
                switch try await model.api.aiVideoStatus(job) {
                case .processing(let queuePosition):
                    if let q = queuePosition, q > 0 {
                        phaseLabel = "Enhancing with AI… (#\(q) in queue)"
                    } else {
                        phaseLabel = "Enhancing with AI…"
                    }
                case .completed(let videoURL):
                    enhancedRemoteURL = videoURL
                case .failed(let message):
                    throw NSError(domain: "AIVideo", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: message])
                }
            }

            // User tapped "Skip AI enhance": stop waiting and publish the standard
            // on-device tour now (the server fal job is stateless — it just expires
            // unused). Same honest fallback as any enhance failure, minus the wait.
            if didSkipEnhance {
                isEnhancing = false
                enhanceDetail = nil
                enhanceNote = "Published your standard tour — you skipped the AI enhance."
                await performPublish(asset: asset, output: output)
                return
            }

            guard let enhancedRemoteURL else {
                throw NSError(domain: "AIVideo", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "The AI enhance returned no video."])
            }

            // d. Download promptly (fal result URLs expire) into Documents.
            phaseLabel = "Downloading enhanced tour…"
            let (tmp, resp) = try await URLSession.shared.download(from: enhancedRemoteURL)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw APIError.badResponse(http.statusCode)
            }
            let dest = FileStore.documents
                .appendingPathComponent("enhanced-\(listing.id.uuidString).mp4")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)

            // Swap the local tour to the enhanced file (same duration/speed —
            // Topaz preserves duration, so chapter timestamps stay valid).
            model.tours[listing.id] = AppModel.RenderedTour(url: dest,
                                                            durationS: output.durationS,
                                                            speedFactor: output.speedFactor)
            let enhanced = RenderEngine.Output(url: dest,
                                               durationS: output.durationS,
                                               speedFactor: output.speedFactor,
                                               stabilized: output.stabilized)
            renderOutput = enhanced
            enhanceDetail = nil
            isEnhancing = false
            await performPublish(asset: asset, output: enhanced)
        } catch {
            if error is CancellationError { return }   // view gone — nothing to do
            // e. Honest fallback: publish the standard on-device tour instead.
            enhanceDetail = nil
            isEnhancing = false
            enhanceNote = "AI enhance unavailable — published your standard tour."
            await performPublish(asset: asset, output: output)
        }
    }

    @MainActor
    private func performPublish(asset: CaptureAsset, output: RenderEngine.Output) async {
        isPublishing = true
        publishFailed = false
        phaseLabel = "Publishing tour…"
        do {
            _ = try await model.publishTour(
                listing: listing,
                renderOutputURL: output.url,
                durationS: output.durationS,
                speedFactor: output.speedFactor,
                roomTags: asset.roomTags,
                enhancements: render.enhancements,
                tier: render.tier)
            isPublishing = false
            markReady()
        } catch {
            // Publish failed — the LOCAL tour still plays in-app (local-first).
            // Let the user view it now; the share link just isn't live yet.
            isPublishing = false
            publishFailed = true
            markReady()
        }
    }

    /// After the Sign in with Apple sheet closes: if they signed in, publish now;
    /// if they backed out, don't strand them — the local tour stays viewable, only
    /// the shareable link is deferred.
    private func onSignInSheetDismissed() {
        guard !isReady else { return }
        if AuthStore.shared.isSignedIn {
            if let output = renderOutput, let asset = model.assets[listing.id] {
                Task { await runPublishPipeline(asset: asset, output: output) }
            } else {
                markReady()   // nothing left to publish; still viewable locally
            }
        } else {
            publishFailed = true
            markReady()
        }
    }

    private func markReady() {
        model.setStatus(.ready, for: listing.id)
        render.progress = 1.0
        isReady = true
        Haptics.success()
    }

    private func runSimulation() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                if let updated = try? await model.api.renderStatus(id: render.id) {
                    await MainActor.run {
                        render = updated
                        phaseLabel = updated.status == "queued" ? "Queued…" : "\(updated.status)…"
                        if updated.status == "ready" {
                            model.setStatus(.ready, for: listing.id)
                            isReady = true
                            Haptics.success()
                        }
                    }
                    if updated.status == "ready" { break }
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }
}

// MARK: - Sign in with Apple (publish gate)
// Lives here (not a standalone file) so it's always in the Xcode target without
// re-running xcodegen — see the repo's new-file-not-in-target rule.

/// Publish-time Sign in with Apple gate. Shown only when the user attempts to
/// PUBLISH while `Config.enableAuth && !AuthStore.shared.isSignedIn` — capture
/// and on-device render stay fully usable offline (local-first, contract §4).
///
/// Uses the native `SignInWithAppleButton`: generate a fresh nonce, send its
/// SHA256 as the request `nonce`, then exchange the returned identity token with
/// Supabase using the RAW nonce (`AuthStore.exchangeAppleIdentityToken`).
struct SignInView: View {
    /// Called once the Supabase session is established (publish can proceed).
    var onSignedIn: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var rawNonce = ""
    @State private var isExchanging = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Theme.accent)

            VStack(spacing: 8) {
                Text("Sign in to publish")
                    .font(.rpTitle)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text("Your tour is ready on this phone. Sign in with Apple to publish it and get a shareable link.")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            SignInWithAppleButton(.signIn) { request in
                let raw = AuthStore.randomNonceString()
                rawNonce = raw
                request.requestedScopes = [.fullName, .email]
                request.nonce = AuthStore.sha256(raw)
            } onCompletion: { result in
                handle(result)
            }
            // Black button on light bg, white on dark — a .black button would
            // disappear into the near-black dark-mode background.
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .padding(.horizontal)
            .disabled(isExchanging)

            if isExchanging {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Signing in…").foregroundStyle(Theme.inkDim)
                }
                .font(.rpCaption)
            }

            Button("Not now") { dismiss() }
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .padding(.top, 4)
                .disabled(isExchanging)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .interactiveDismissDisabled(isExchanging)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            // A user cancel isn't worth an error banner.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = error.localizedDescription
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Apple didn't return a usable credential. Please try again."
                return
            }
            let nonce = rawNonce
            isExchanging = true
            errorMessage = nil
            Task {
                do {
                    try await AuthStore.shared.exchangeAppleIdentityToken(idToken: idToken, nonce: nonce)
                    await MainActor.run {
                        isExchanging = false
                        onSignedIn()
                        dismiss()
                    }
                } catch {
                    await MainActor.run {
                        isExchanging = false
                        errorMessage = "Couldn't sign in: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
