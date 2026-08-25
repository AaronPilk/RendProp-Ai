import SwiftUI
import AuthenticationServices

/// Render progress. Real listings run the ON-DEVICE render engine (retime →
/// 60fps → scrub-ready encode). When `Config.useLiveBackend` is on, a successful
/// on-device render is then PUBLISHED to the cloud (upload role=render →
/// /renders/publish-app) so it gets a real shareable slug — the in-app tour
/// always works either way (local-first, contract §4). Sample listings simulate.
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

    /// Live copy so the real server share URL (set by publishTour) is picked up.
    private var currentListing: Listing {
        model.listings.first(where: { $0.id == listing.id }) ?? listing
    }

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Theme.fillSubtle, lineWidth: 8)
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
                }
            }
            .frame(width: 150, height: 150)

            VStack(spacing: 6) {
                Text(isReady ? "Your tour is ready" : (failureMessage ?? phaseLabel))
                    .font(.rpTitle)
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
            }
            .padding(.horizontal)

            if !isReady && failureMessage == nil {
                Text(isPublishing
                     ? "Uploading and publishing your tour…"
                     : "Keep the app open — this runs right on your phone.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }

            Spacer()

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

    /// Gate PUBLISHING (not app use) on Sign in with Apple, then publish.
    @MainActor
    private func beginPublish(asset: CaptureAsset, output: RenderEngine.Output) async {
        if Config.enableAuth && !AuthStore.shared.isSignedIn {
            showSignIn = true   // publishing resumes in onSignInSheetDismissed()
            return
        }
        await performPublish(asset: asset, output: output)
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
                Task { await performPublish(asset: asset, output: output) }
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
            .signInWithAppleButtonStyle(.black)
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
