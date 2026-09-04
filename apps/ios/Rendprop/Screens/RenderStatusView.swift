import SwiftUI
import UIKit
import Combine
import AuthenticationServices

/// Render progress. The work itself lives in `AppModel.renderCoordinator`
/// (started by ReviewSubmitView) — this screen only OBSERVES it, so backing
/// out, switching tabs or re-opening it never cancels or re-runs a render
/// (audit F-B-04 / F-D-01). Cancel is an explicit button.
///
/// Live backend: a successful on-device render is PUBLISHED to the cloud
/// (upload role=render → /renders/publish-app) so it gets a real shareable
/// slug; the in-app tour works either way (local-first, contract §4). The AI
/// tiers add the server Topaz pass first (skippable). Publishing needs Sign in
/// with Apple: "Not now" parks the tour as "publish later" — the listing
/// detail's "Publish tour" (or this screen after signing in) finishes it, no
/// re-render.
struct RenderStatusView: View {
    @EnvironmentObject var model: AppModel

    let listing: Listing
    @State var render: Render

    var body: some View {
        RenderStatusContent(coordinator: model.renderCoordinator, listing: listing, render: render)
    }
}

private struct RenderStatusContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var uploads: UploadManager
    @ObservedObject var coordinator: RenderCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    let listing: Listing
    let render: Render

    @State private var showSignIn = false
    @State private var didPromptSignIn = false
    @State private var declinedSignIn = false
    @State private var showCancelConfirm = false
    /// The encode is CPU-bound for minutes; on a hot phone iOS throttles it and
    /// the ring visibly crawls. Say so rather than looking stuck. (Seeded in
    /// `onAppear` — a `@State` default can't read a type member here.)
    @State private var isThrottled = false

    /// Live copy so the real server share URL (set by publishTour) is picked up.
    private var currentListing: Listing {
        model.listings.first(where: { $0.id == listing.id }) ?? listing
    }
    private var job: RenderJobState? { coordinator.jobs[listing.id] }
    private var tour: AppModel.RenderedTour? { model.tours[listing.id] }
    private var shareURL: URL? { currentListing.serverShareURL }
    private var noun: String { SpaceType.current.spaceNoun }

    private enum Mode { case working, ready, failed, needsSignIn, publishLater, idle }

    private var mode: Mode {
        if let job {
            if job.isRunning { return .working }
            switch job.stage {
            case .failed:
                return .failed
            case .awaitingSignIn:
                return declinedSignIn ? .publishLater : .needsSignIn
            case .published, .publishFailed, .rendered:
                return .ready
            case .cancelled:
                return tour != nil ? .ready : .failed
            case .rendering, .enhancing, .publishing:
                return .working
            }
        }
        // No job in memory (e.g. the app relaunched): decide from the model.
        return tour != nil ? .ready : .idle
    }

    private var isWorking: Bool { mode == .working }
    private var publishFailed: Bool { job?.stage == .publishFailed }

    private static var thermallyThrottled: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    /// This listing's publish upload is parked waiting for Wi-Fi — the user's
    /// "ask before uploading on cellular" setting, or a very large file. The
    /// tour is finished and on the phone; only the share link is waiting
    /// (audit F-B-08). It finishes by itself on Wi-Fi.
    private var cellularParked: Bool {
        guard uploads.pendingCellularConfirmation,
              let upload = uploads.state,
              upload.status == .queued, upload.role == "render",
              let serverID = currentListing.serverID else { return false }
        return upload.listingID == serverID
    }

    private var fraction: Double {
        if let job { return job.fraction }
        return tour != nil ? 1 : 0
    }

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            ring
            titleBlock
            captionBlock
            Spacer()
            actions
        }
        // Fill the whole screen: without this the VStack hugs its widest text and
        // Theme.bg paints only a centered column.
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .navigationTitle(isWorking ? "Creating Tour" : "Your Tour")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWorking)
        .onAppear {
            syncSignInPrompt()
            isThrottled = Self.thermallyThrottled
        }
        .onChange(of: job?.stage) { _ in syncSignInPrompt() }
        // `.receive(on:)` is not optional here: the thermal notification is
        // posted on an arbitrary queue, and touching @State off the main thread
        // is a SwiftUI violation.
        .onReceive(NotificationCenter.default
                    .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                    .receive(on: DispatchQueue.main)) { _ in
            isThrottled = Self.thermallyThrottled
        }
        .sheet(isPresented: $showSignIn, onDismiss: onSignInSheetDismissed) {
            SignInView()
        }
        .confirmationDialog(tour == nil ? "Cancel this render?" : "Cancel publishing?",
                            isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button(tour == nil ? "Cancel render" : "Stop publishing", role: .destructive) { cancelNow() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text(tour == nil
                 ? "Your video stays on the \(noun) — you can render it again any time."
                 : "The tour stays on your phone. Publish it later from the \(noun) to get a share link.")
        }
    }

    // MARK: - Pieces

    private var ring: some View {
        ZStack {
            // Theme.border (not fillSubtle) for the track — reads clearly
            // against the background in both light and dark.
            Circle()
                .stroke(Theme.border, lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: fraction)
            switch mode {
            case .ready, .needsSignIn, .publishLater:
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.good)
                    // The one earned "delight" beat in the whole flow — the
                    // check pops in on the same frame Haptics.success() fires.
                    .transition(reduceMotion
                                ? .opacity
                                : .scale(scale: 0.7).combined(with: .opacity))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.warn)
            case .working:
                if job?.stage == .rendering {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                } else {
                    ProgressView().scaleEffect(1.4)
                }
            case .idle:
                Image(systemName: "play.circle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.inkDim)
            }
        }
        .frame(width: 150, height: 150)
        .animation(reduceMotion
                   ? .easeOut(duration: 0.2)
                   : .spring(response: 0.42, dampingFraction: 0.62),
                   value: mode == .ready)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch mode {
        case .working:       return job?.phase ?? "Working…"
        case .ready, .needsSignIn, .publishLater:
            return "Your tour is ready"
        case .failed:        return job?.error ?? "The render didn't finish"
        case .idle:          return "Ready to render"
        }
    }

    private var subtitle: String {
        switch mode {
        case .working, .idle:
            return "\(render.tier.displayName) · \(Formatters.duration(render.durationS)) walkthrough"
        case .ready, .needsSignIn, .publishLater:
            return "Smooth, fast, and ready to fly through."
        case .failed:
            return "Nothing was lost — your video is still on this \(noun)."
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    @ViewBuilder private var captionBlock: some View {
        VStack(spacing: 8) {
            switch mode {
            case .working:
                Text(workingCaption)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                if isThrottled {
                    Text("Your phone is hot, so this is running slower than usual. It will finish — leave it plugged in or let it cool if you can.")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.center)
                }
            case .publishLater:
                Text("Saved on your phone. Sign in and tap Publish on the \(noun) whenever you're ready — no re-render needed.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
            case .needsSignIn:
                Text("Sign in with Apple to publish it and get a shareable link.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
            case .ready:
                if cellularParked {
                    Text("Your tour is saved on this phone. The share link finishes uploading on its own as soon as you're on Wi-Fi.")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.center)
                } else if publishFailed, shareURL == nil, let message = job?.error {
                    // `shareURL == nil` matters: a publish that later finished
                    // out of band (resumed upload, Wi-Fi) must not keep showing
                    // the old failure next to a working Share button.
                    Text("Saved on your phone — we couldn't publish the share link. \(message)")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.center)
                    if job?.errorStatus == 402, let pricing = Config.pricingURL {
                        Link("Upgrade plan", destination: pricing)
                            .font(.rpCaption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                if let note = job?.note {
                    Text(note)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.center)
                }
            case .failed:
                if model.assets[listing.id] == nil {
                    Text("The walkthrough video is missing from this phone. Add a video to render again.")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .multilineTextAlignment(.center)
                }
            case .idle:
                Text("The render isn't running. Start it to build your tour on this phone.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 28)
    }

    private var workingCaption: String {
        switch job?.stage {
        case .enhancing:
            return "Smoothing motion + upscaling on our render farm — this can take several minutes. Keep the app open."
        case .publishing:
            return "Uploading and publishing your tour…"
        default:
            return "Keep the app open — this runs right on your phone."
        }
    }

    /// The MLS-safe twin of the share link, right where an agent grabs a link
    /// the moment a tour goes live (W2-C1). The branded page carries the agent
    /// card, the CTA and the lead form — unbranded virtual-tour rules ban all
    /// three, and the unbranded field is what syndicates to Zillow/Realtor.com.
    /// Pasting the branded link there is the fineable mistake.
    @ViewBuilder private var mlsLinkRow: some View {
        if let mls = currentListing.serverUnbrandedURL {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    UIPasteboard.general.url = mls
                    Haptics.success()
                } label: {
                    HStack {
                        Image(systemName: "building.columns.fill")
                        Text("Copy MLS link (unbranded)").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.fillSubtle)
                    .foregroundStyle(Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Label("Never put your branded link in an MLS unbranded field — most MLSs fine for that.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 12) {
            switch mode {
            case .working:
                // Escape hatch for the up-to-20-min AI enhance wait: publish the
                // standard on-device tour NOW instead of trapping the user.
                if job?.canSkipEnhance == true {
                    SecondaryButton(title: "Skip AI enhance & publish now", systemImage: "forward.fill") {
                        coordinator.skipEnhance(listingID: listing.id)
                    }
                    .accessibilityLabel(Text("Skip the AI enhancement and publish the standard tour now"))
                }
                Button(role: .destructive) { showCancelConfirm = true } label: {
                    Text("Cancel")
                        .font(.rpBody.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .foregroundStyle(Theme.bad)

            case .failed:
                if model.assets[listing.id] != nil {
                    PrimaryButton(title: "Try again", systemImage: "arrow.clockwise") { tryAgain() }
                }
                SecondaryButton(title: "Cancel", systemImage: "xmark") {
                    coordinator.clear(listingID: listing.id)
                    dismiss()
                }

            case .idle:
                if model.assets[listing.id] != nil {
                    PrimaryButton(title: "Start render", systemImage: "sparkles") { tryAgain() }
                } else {
                    SecondaryButton(title: "Back", systemImage: "chevron.left") { dismiss() }
                }

            case .ready, .needsSignIn, .publishLater:
                viewTourButton
                if let shareURL {
                    ShareLink(item: shareURL,
                              subject: Text(listing.address),
                              message: Text("Fly through \(listing.address) — scroll to walk the \(noun).")) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share your link").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Theme.accentSoft)
                        .foregroundStyle(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    mlsLinkRow
                } else if mode == .publishLater || mode == .needsSignIn {
                    SecondaryButton(title: "Sign in & publish", systemImage: "link") {
                        declinedSignIn = false
                        didPromptSignIn = true
                        showSignIn = true
                    }
                } else if cellularParked {
                    // The parked upload finishes the publish by itself through
                    // UploadManager.didCompleteNotification, so this only has to
                    // release it — never start a second one.
                    SecondaryButton(title: "Upload now on cellular", systemImage: "antenna.radiowaves.left.and.right") {
                        uploads.confirmCellularAndStart()   // SecondaryButton taps the haptic itself
                    }
                } else if publishFailed {
                    if job?.errorStatus == 401 {
                        SecondaryButton(title: "Sign in to publish", systemImage: "link") {
                            didPromptSignIn = true
                            showSignIn = true
                        }
                    } else {
                        SecondaryButton(title: "Retry publish", systemImage: "arrow.clockwise") {
                            coordinator.publish(listingID: listing.id)
                        }
                    }
                } else if Config.useLiveBackend, tour != nil {
                    // Rendered but never published (e.g. publish cancelled).
                    SecondaryButton(title: "Publish tour", systemImage: "link") {
                        if Config.enableAuth && !AuthStore.shared.isSignedIn {
                            didPromptSignIn = true
                            showSignIn = true
                        } else {
                            coordinator.publish(listingID: listing.id, allowEnhance: true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 18)
    }

    private var viewTourButton: some View {
        NavigationLink {
            FlythroughDetailView(listing: currentListing)
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
    }

    // MARK: - Actions

    /// Show the sign-in sheet exactly once when the pipeline parks for it.
    private func syncSignInPrompt() {
        guard job?.stage == .awaitingSignIn, !didPromptSignIn, !declinedSignIn else { return }
        didPromptSignIn = true
        showSignIn = true
    }

    /// After the Sign in with Apple sheet closes: signed in → publish now (the
    /// coordinator owns the task, so leaving this screen can't cancel it);
    /// backed out → "publish later" — the local tour stays viewable and the
    /// listing detail's Publish button (pendingPublish) finishes it any time.
    private func onSignInSheetDismissed() {
        if !Config.enableAuth || AuthStore.shared.isSignedIn {
            declinedSignIn = false
            if tour != nil, shareURL == nil, !coordinator.isRunning(listing.id) {
                coordinator.publish(listingID: listing.id, allowEnhance: true)
            }
        } else {
            declinedSignIn = true
            model.setStatus(.ready, for: listing.id)
            model.addPendingPublish(listing.id)
        }
    }

    /// No haptic here: both callers are `PrimaryButton`, which taps one itself —
    /// firing a second made "Try again" buzz twice (audit F-D-25's rule).
    private func tryAgain() {
        guard let asset = model.assets[listing.id] else { return }
        coordinator.start(listing: currentListing, asset: asset)
    }

    private func cancelNow() {
        let hadTour = tour != nil
        coordinator.cancel(listingID: listing.id)
        Haptics.selection()
        if !hadTour {
            coordinator.clear(listingID: listing.id)
            dismiss()   // render cancelled → back to Review (the video is still there)
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
    /// Why we're asking. Defaults to the publish story (the original caller);
    /// the AI tools pass their own so the sheet never promises a share link to
    /// someone who just tapped "Twilight sky".
    var title: String = "Sign in to publish"
    var subtitle: String = "Your tour is ready on this phone. Sign in with Apple to publish it and get a shareable link."

    /// What "Not now" costs the user. Publish parks the tour; an AI tool simply
    /// doesn't run, so promising "publish it later" there would be nonsense.
    var dismissNote: String = "Not now keeps the tour on your phone — you can publish it later from the \(SpaceType.current.spaceNoun)."

    /// Ready-made copy for the AI tools (photo edits, aerials, reels).
    static func forAI(_ what: String, onSignedIn: @escaping () -> Void = {}) -> SignInView {
        SignInView(onSignedIn: onSignedIn,
                   title: "Sign in to use \(what)",
                   subtitle: "The AI runs on your account, so it needs a free sign-in. Nothing is charged — your plan's allowance covers it.",
                   dismissNote: "Not now closes this — everything you set up stays here, and nothing is generated.")
    }

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
                Text(title)
                    .font(.rpTitle)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text(subtitle)
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

            Text(dismissNote)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

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
            // Apple returns the name ONLY on the first authorization — keep it
            // (it seeds the account row; the public card never falls back to an email).
            let displayName = credential.fullName.flatMap { components -> String? in
                let text = PersonNameComponentsFormatter().string(from: components)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            // TN3194: the single-use authorizationCode must reach the backend
            // so DELETE /me can revoke the Apple grant. This sheet is the app's
            // ONLY sign-in surface, so capturing it here is what makes account
            // deletion actually sever Apple (audit P0-4 — it was being dropped).
            let authCode = credential.authorizationCode
                .flatMap { String(data: $0, encoding: .utf8) }
            isExchanging = true
            errorMessage = nil
            Task {
                do {
                    try await AuthStore.shared.exchangeAppleIdentityToken(idToken: idToken, nonce: nonce)
                    // Best-effort, after the session exists (the POST needs the
                    // fresh JWT). Never blocks or fails sign-in.
                    if let authCode {
                        await AuthStore.submitAppleAuthorizationCode(authCode)
                    }
                    await MainActor.run {
                        if let displayName {
                            AuthStore.shared.userName = displayName
                            UserDefaults.standard.set(displayName, forKey: "auth.userName")
                        }
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
