import SwiftUI
import UIKit

/// An offline, interactive guide. Reading a step never starts capture, an AI
/// job, a purchase, or a write to the user's workspace.
struct AppGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What would you like to do?").font(.rpTitle).foregroundStyle(Theme.ink)
                Text("Pick a feature and tap through its steps. Your listings stay as they are.")
                    .font(.rpBody).foregroundStyle(Theme.inkDim)
                ForEach(AppGuideTopic.allCases) { topic in
                    NavigationLink { AppGuideStepsView(topic: topic) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: topic.icon).font(.title2).foregroundStyle(Theme.accent)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(topic.title).font(.rpHeadline).foregroundStyle(Theme.ink)
                                Text(topic.summary).font(.rpCaption).foregroundStyle(Theme.inkDim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").foregroundStyle(Theme.accent)
                        }.padding(16).card()
                    }.buttonStyle(ScalePressStyle())
                        .accessibilityIdentifier("guide.\(topic.rawValue)")
                }
            }.padding()
        }.background(Theme.bg)
            .navigationTitle("App walkthrough")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private enum AppGuideTopic: String, CaseIterable, Identifiable {
    case listing, capture, photos, editing, reel, aerial, measurements, contact, sharing, leads, team, studio, plan, spatial
    var id: String { rawValue }
    var title: String {
        switch self {
        case .listing: return "Start a listing"
        case .capture: return "Film a walkthrough"
        case .photos: return "Add and choose photos"
        case .editing: return "Declutter or stage photos"
        case .reel: return "Make a social reel"
        case .aerial: return "Create an aerial opening"
        case .measurements: return "Measurements and floor plans"
        case .contact: return "Your card and client details"
        case .sharing: return "Publish and share"
        case .leads: return "Follow up on inquiries"
        case .team: return "Work with a team"
        case .studio: return "Continue on desktop"
        case .plan: return "Plans, credits and billing"
        case .spatial: return "3D features"
        }
    }
    var icon: String {
        switch self {
        case .listing: return "plus.rectangle"
        case .capture: return "video"
        case .photos: return "photo.stack"
        case .editing: return "wand.and.stars"
        case .reel: return "film.stack"
        case .aerial: return "airplane"
        case .measurements: return "ruler"
        case .contact: return "person.text.rectangle"
        case .sharing: return "square.and.arrow.up"
        case .leads: return "person.crop.circle.badge.checkmark"
        case .team: return "person.2"
        case .studio: return "desktopcomputer"
        case .plan: return "creditcard"
        case .spatial: return "rotate.3d"
        }
    }
    var summary: String { steps[0].1 }
    var steps: [(String, String)] {
        switch self {
        case .listing: return [
            ("Add a listing", "Open Listings and tap Add. Give the property an address or name first."),
            ("Check the details", "Use address suggestions or current location, then enter a unit number separately if needed. Review the property facts."),
            ("Keep everything together", "Open this listing whenever you add photos, film, make a reel or edit its contact details. Each workspace keeps its own listings.")]
        case .capture: return [
            ("Choose your property", "Open the listing, then record a walkthrough or import a video you already have."),
            ("Keep the camera steady", "For interiors, use 0.5× on a supported iPhone. Keep the phone level and walk at a steady pace. Avoid quick turns."),
            ("Preview before sharing", "Review the footage and room tags. Motion smoothing can reduce shake; it cannot guarantee drone-like movement from every recording.")]
        case .photos: return [
            ("Open Photos", "Choose a listing and open Photos. Take a photo or import from Photos or Files."),
            ("Choose your main photo", "Pick a clear exterior or another strong image as the main photo. This is the first image visitors see on the listing."),
            ("Save the version you want", "Use the photo's download action to export a JPEG for MLS, or open AI Photo Studio for version history. Check your MLS's image requirements.")]
        case .editing: return [
            ("Choose the change", "Open AI Photo Studio. Choose Declutter, a staging style or another edit, then select the photos you want to change. Review the credit quote."),
            ("Keep each version", "Original, decluttered and staged versions stay separate. You can leave the screen while an accepted job processes. Check its status when you return."),
            ("Review and export", "Check walls, windows, appliances and access to doors. Select the version for your published gallery or download it. Files exports include disclosure captions; when saving to Photos, copy the caption separately. Follow your MLS's rules.")]
        case .reel: return [
            ("Pick your photos", "Open Make a reel for a listing. Choose the photos and the format for your social post."),
            ("Choose movement and sound", "Set the clip style and voice options, then review the quote before creating. If processing stops, recover a confirmed saved request or finish a shorter reel from saved clips. Review an unconfirmed request before starting another generation."),
            ("Watch the whole result", "Review transitions, property accuracy, captions and audio. Save the finished video before posting it to social media.")]
        case .aerial: return [
            ("Choose an exterior", "Open Make an aerial shot for the listing. Use a clear exterior photo with the property in view."),
            ("Review the request", "Choose the motion and review the credit quote. Generated footage can contain errors in the building or surroundings."),
            ("Check the result", "Watch the entire clip before including it in a reel or publishing it. Keep your original footage for comparison.")]
        case .measurements: return [
            ("Enter measurements", "Open Measurements for the listing. Add rooms or draw an outline by entering measured wall lengths."),
            ("Review the worksheet", "Check closure, units, levels and area categories. Furnished rooms can still be measured manually. App calculations are not a certified survey or appraisal."),
            ("Share a plan", "Export your measurements and worksheet, or upload a PDF or image from your measuring software. Automatic 3D scanning is marked Coming soon.")]
        case .contact: return [
            ("Set up your card", "Open Profile, edit your name, photo and contact details, then tap Save. Your personal card stays yours when you join a team. Set the workspace business logo separately. Use Send business card for your contact details alone, or Share my portfolio to choose the listings to include."),
            ("Represent your client", "For a photographer's listing, open Listing contact and enter the client's name, photo and public contact details."),
            ("Choose where leads go", "Enter the client's private lead email and choose whether to hide Rendprop branding. You retain a copy of inquiries in Leads.")]
        case .sharing: return [
            ("Review your listing", "Check the main photo, gallery versions, property details, contact card and disclosures before publishing."),
            ("Choose the right link", "Share the branded link with clients or social followers. Use the unbranded link only where your MLS permits virtual-tour links."),
            ("Explore or watch", "The public page opens with the main photo and details. Visitors choose the fly-through, then either scroll to explore or play the video.")]
        case .leads: return [
            ("Open Leads", "Inquiries from published listings appear in Leads. Open an inquiry to see its contact information."),
            ("Contact the person", "Tap the phone number to call or the email address to compose an email. Check the listing so you follow up with the right client."),
            ("Check delivery", "If a client misses an inquiry email, use the available resend action and check its delivery status. Saving a lead does not guarantee an email arrived in the inbox.")]
        case .team: return [
            ("Choose a workspace", "The workspace selector separates personal work from a shared team. Confirm the selected workspace before adding a listing."),
            ("Invite or join", "Open Settings → Team to create an invitation or join using a real invitation code. A pending invitation uses a seat until accepted or revoked."),
            ("Keep access clear", "Managers and editors only see work they are authorized to access. Switching workspaces does not move your saved work automatically.")]
        case .studio: return [
            ("Sign in on desktop", "Open studio.rendprop.com and sign in with the same account you use on your iPhone."),
            ("Choose the same workspace", "Select the same workspace and listing. Uploaded media and synced changes are available there; local-only files need to upload first."),
            ("Continue producing", "Use Studio to organize assets, create content and review work with your team. On the phone, use Retry Studio sync if a listing update is still waiting.")]
        case .plan: return [
            ("Check your allowance", "Open Settings → Plan & usage to see the account's plan, feature limits and credits."),
            ("Review before purchasing", "Choose a plan and billing period. Apple's purchase sheet shows the actual price and any eligible free trial. A trial starts only after you confirm the subscription."),
            ("Manage your subscription", "Use Manage subscription to change or cancel with Apple. Restore purchases after reinstalling or signing back in. Review each AI job's quote before spending credits.")]
        case .spatial: return [
            ("Coming soon", "3D walkthroughs and automatic 3D floor-plan capture are still being tested. They are not required to create photos, videos or a published listing."),
            ("Separate phone testing", "The TestFlight Lab contains local capture experiments. Photos remain on the phone until you export them; a lab test does not publish a finished tour."),
            ("Use measurements today", "You can enter room measurements, draw measured outlines and upload an existing floor plan while the 3D features are developed.")]
        }
    }
}

private struct AppGuideStepsView: View {
    let topic: AppGuideTopic
    @State private var step = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: topic.icon).font(.system(size: 44)).foregroundStyle(Theme.accent)
                Text("Step \(step + 1) of \(topic.steps.count)").font(.rpCaption).foregroundStyle(Theme.inkDim)
                ProgressView(value: Double(step + 1), total: Double(topic.steps.count)).tint(Theme.accent)
                Text(topic.steps[step].0).font(.rpTitle).foregroundStyle(Theme.ink)
                Text(topic.steps[step].1).font(.rpBody).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Back") { step = max(0, step - 1) }
                        .disabled(step == 0)
                    Spacer()
                    if step + 1 < topic.steps.count {
                        Button("Next step") { step += 1; Haptics.selection() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    } else {
                        Label("You're ready", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    }
                }.padding(.top, 8)
                if step + 1 == topic.steps.count && topic == .listing {
                    NavigationLink("Add a listing") { NewListingView() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }.padding(22)
        }.background(Theme.bg)
            .navigationTitle(topic.title).navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("guide.steps.\(topic.rawValue)")
    }
}

struct HomeListingsView: View {
    @EnvironmentObject var model: AppModel
    // LOAD-BEARING: observing this key is what makes `filtered`/`soldCount`
    // recompute when the business type changes (they read SpaceType.current,
    // which isn't itself observable). Do not remove — filtering would silently
    // stop updating on type switch. (Samples themselves are re-derived by
    // RootTabView on the same change.)
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @AppStorage(RealEstateRoleStore.uiRevisionKey) private var realEstateRoleRevision = 0
    @State private var isLoading = true
    @State private var search = ""
    @State private var pendingDelete: Listing?
    @ObservedObject private var workspaceStore = WorkspaceStore.shared

    private var needsWorkspaceSelection: Bool { Config.useLiveBackend && workspaceStore.selected == nil }

    /// Only listings for the CURRENT business type (a gym never sees houses),
    /// active (not sold), plus search.
    private var filtered: [Listing] {
        let active = model.listings.filter { !$0.isSample && $0.belongsToCurrentType && !$0.isSold && model.isInSelectedWorkspace($0) }
        guard !search.isEmpty else { return active }
        return active.filter { $0.address.localizedCaseInsensitiveContains(search) }
    }

    /// True once the user has a listing of their own for this industry.
    private var hasRealListing: Bool {
        model.listings.contains { !$0.isSample && $0.belongsToCurrentType && model.isInSelectedWorkspace($0) }
    }

    /// Archived count for THIS industry only — real-estate sold houses don't
    /// show up in the Food or Gym archive.
    private var soldCount: Int {
        model.listings.filter { !$0.isSample && $0.belongsToCurrentType && $0.isSold && model.isInSelectedWorkspace($0) }.count
    }

    private var noun: String { SpaceType.current.spaceNoun }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && model.listings.isEmpty {
                    loadingState
                } else {
                    listBody
                }
            }
            .navigationTitle(SpaceType.current.collectionTitle)
            .background(Theme.bg)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    UploadMiniBar()
                    NavigationLink {
                        NewListingView()
                    } label: {
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
                    .disabled(needsWorkspaceSelection)
                    .padding(.horizontal)
                    .accessibilityLabel(Text("Add a \(noun)"))
                }
                .padding(.bottom, 6)
            }
            .task {
                await model.load()
                isLoading = false
            }
            .confirmationDialog(deleteTitle,
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingDelete) { l in
                Button("Delete \(noun)", role: .destructive) {
                    let id = l.id
                    Task { await model.remove(id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { l in
                Text(l.serverShareURL != nil
                     ? "Its video, tour and photos are removed from this phone and the share link stops working."
                     : "Its video, tour and photos are removed from this phone.")
            }
        }
    }

    private var deleteTitle: String {
        "Delete \(pendingDelete?.address ?? "this \(noun)")?"
    }

    /// The collection. A List (not a LazyVStack) so rows get real swipe actions;
    /// the system disclosure chevron is hidden behind an invisible link so the
    /// card keeps its own design.
    private var listBody: some View {
        List {
            WorkspaceEntry()
            if needsWorkspaceSelection {
                workspaceSelectionPrompt
                Text("Choose your own workspace to see your private listings, or a shared workspace to work with its team. Saved files stay on this iPhone.")
                    .font(.footnote).foregroundStyle(Theme.inkDim)
            }
            if let error = model.cloudSyncError {
                Label(error, systemImage: "icloud.slash")
                    .font(.footnote).foregroundStyle(Theme.inkDim)
                    .listRowBackground(Color.clear)
            } else if model.isCloudSyncing {
                HStack { ProgressView(); Text("Syncing with Studio…").font(.footnote) }
                    .listRowBackground(Color.clear)
            } else if model.pendingCloudListingCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(model.pendingCloudListingCount) listing update\(model.pendingCloudListingCount == 1 ? " is" : "s are") waiting to sync.").font(.footnote)
                    Button("Retry Studio sync") { Task { await model.refreshCloudWorkspace() } }.font(.footnote.weight(.semibold))
                }.foregroundStyle(Theme.inkDim).listRowBackground(Color.clear)
            }
            if !hasRealListing && search.isEmpty {
                firstTourCard
                    .listRowInsets(rowInsets)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if soldCount > 0 && search.isEmpty {
                ZStack {
                    NavigationLink { SoldListingsView() } label: { EmptyView() }
                        .opacity(0)
                    soldFolderRow
                }
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(filtered) { listing in
                ZStack {
                    NavigationLink { FlythroughDetailView(listing: listing) } label: { EmptyView() }
                        .opacity(0)
                    ListingCard(listing: listing)
                }
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !listing.isSample {
                        Button(role: .destructive) { pendingDelete = listing } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .contextMenu {
                    if !listing.isSample {
                        Button(role: .destructive) { pendingDelete = listing } label: {
                            Label("Delete \(noun)", systemImage: "trash")
                        }
                    } else {
                        Text("Sample \(noun) — read-only")
                    }
                }
            }
            if filtered.isEmpty && !search.isEmpty {
                emptySearchRow
                    .listRowInsets(rowInsets)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            // Room for the New Listing button.
            Color.clear
                .frame(height: 70)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Search \(noun)s")
        .refreshable { await model.refreshCloudWorkspace() }
    }

    private var workspaceSelectionPrompt: some View {
        NavigationLink("Choose a workspace") { WorkspacePickerView() }
            .accessibilityIdentifier("homes.chooseWorkspace")
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
    }

    private var loadingState: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.fillSubtle)
                        .frame(height: 230)
                        .redacted(reason: .placeholder)
                }
            }
            .padding(.horizontal)
        }
    }

    /// First-run invitation, shown above the demo samples until the user has a
    /// listing of their own — same gradient language as Home's showroom.
    private var firstTourCard: some View {
        VStack(spacing: 12) {
            Image(systemName: SpaceType.current.systemImage)
                .font(.system(size: 34, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white)
                .frame(width: 68, height: 68)
                .background(Color.white.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Your first listing\nstarts here")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
            Text(SpaceType.current.emptyStateLine)
                .font(.rpBody)
                .foregroundStyle(Color.white.opacity(0.88))
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                emptyStep("1", "Film")
                stepArrow
                emptyStep("2", "Enhance")
                stepArrow
                emptyStep("3", "Share")
            }
            .padding(.top, 4)
            Text("Add a \(noun) first. Every photo and video is saved to it.")
                .font(.rpCaption)
                .foregroundStyle(Color.white.opacity(0.9))
                .multilineTextAlignment(.center)
            NavigationLink { AppGuideView() } label: {
                Label("Show me how", systemImage: "hand.tap")
                    .font(.rpBody.weight(.semibold))
                    .padding(12)
                    .background(Color.white.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.white)
            }
            .accessibilityIdentifier("listings.appGuide")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24).padding(.horizontal, 20)
        .background(RPGradient.drone)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.3), radius: 16, x: 0, y: 8)
    }

    private func emptyStep(_ n: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Text(n)
                .font(.rpCaption.weight(.bold))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.2), in: Circle())
                .foregroundStyle(Color.white)
            Text(label).font(.rpCaption).foregroundStyle(Color.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var stepArrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.white.opacity(0.7))
    }

    private var emptySearchRow: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(Theme.inkDim)
            Text("No \(noun)s match \"\(search)\"")
                .font(.rpBody)
                .foregroundStyle(Theme.ink)
            Text("Try another word from the name or address.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var soldFolderRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(SpaceType.current.archiveNoun).font(.rpHeadline).foregroundStyle(Theme.ink)
                Text("\(soldCount) \(noun)\(soldCount == 1 ? "" : "s")")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold)).foregroundStyle(Theme.inkDim)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
    }
}

// MARK: - Sold folder

struct SoldListingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingDelete: Listing?

    private var sold: [Listing] {
        model.listings.filter { $0.belongsToCurrentType && $0.isSold && model.isInSelectedWorkspace($0) }
            .sorted { ($0.soldAt ?? .distantPast) > ($1.soldAt ?? .distantPast) }
    }

    private var noun: String { SpaceType.current.spaceNoun }

    var body: some View {
        Group {
            if sold.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(Theme.inkDim)
                    Text("Nothing here yet.").font(.rpBody).foregroundStyle(Theme.inkDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sold) { listing in
                        ZStack {
                            NavigationLink { FlythroughDetailView(listing: listing) } label: { EmptyView() }
                                .opacity(0)
                            ListingCard(listing: listing)
                        }
                        .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !listing.isSample {
                                Button(role: .destructive) { pendingDelete = listing } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            if !listing.isSample {
                                Button(role: .destructive) { pendingDelete = listing } label: {
                                    Label("Delete \(noun)", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(SpaceType.current.archiveNoun)
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.bg)
        .confirmationDialog("Delete \(pendingDelete?.address ?? "this \(noun)")?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { l in
            Button("Delete \(noun)", role: .destructive) {
                let id = l.id
                Task { await model.remove(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { l in
            Text(l.serverShareURL != nil
                 ? "Its video, tour and photos are removed from this phone and the share link stops working."
                 : "Its video, tour and photos are removed from this phone.")
        }
    }
}

// MARK: - Aesthetic listing card

struct ListingCard: View {
    let listing: Listing
    /// Downsampled hero, decoded once off the main thread (never a full-res
    /// `UIImage(contentsOfFile:)` inside `body`).
    @State private var hero: UIImage?

    private var heroImage: UIImage? {
        if let hero { return hero }
        if let url = listing.mainPhotoURL { return ImageThumbnails.cached(url) }
        return nil
    }

    private var statusText: String {
        listing.needsAttention ? "needs attention" : listing.status.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroView
            info
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.border)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 16, x: 0, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(listing.address), \(listing.subtitleLine), \(statusText)"))
        .task(id: listing.mainPhotoRelPath) {
            guard let url = listing.mainPhotoURL else { hero = nil; return }
            if let cached = ImageThumbnails.cached(url) { hero = cached; return }
            let decoded = await ImageThumbnails.load(url)
            if !Task.isCancelled { hero = decoded }
        }
    }

    // Hero area — shows the main listing photo once one is set, else a branded placeholder.
    private var heroView: some View {
        ZStack {
            if let ui = heroImage {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                LinearGradient(colors: [.clear, Color.black.opacity(0.18)],
                               startPoint: .center, endPoint: .bottom)
            } else {
                // All-adaptive purple wash — the old hardcoded lavender stop
                // glowed like a light leak on dark cards.
                LinearGradient(
                    colors: [Theme.accent.opacity(0.22),
                             Theme.accent.opacity(0.08),
                             Theme.accentSoft],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: listing.spaceType == .realEstate
                                  ? "house.and.flag.fill"
                                  : listing.spaceType.systemImage)
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(Theme.accent.opacity(0.30))
                    .offset(y: 6)
            }

            if listing.status == .ready {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                        .offset(x: 2)
                }
            }
        }
        .frame(height: 150)
        .clipped()
        .overlay(alignment: .topTrailing) {
            // Material halo keeps the chips readable over any photo.
            VStack(alignment: .trailing, spacing: 6) {
                StatusChip(status: listing.status)
                    .padding(3)
                    .background(.ultraThinMaterial, in: Capsule())
                if listing.needsAttention {
                    AttentionChip()
                        .padding(3)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(8)
        }
        .overlay(alignment: .bottomLeading) {
            if listing.status == .ready {
                // Material (not hardcoded white) so the badge frosts correctly
                // over any photo in both modes — same halo as the status chip.
                Label(listing.serverShareURL != nil ? "Tour ready to share" : "Tour ready",
                      systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(listing.address)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.inkDim)
            }
            HStack {
                Text(listing.subtitleLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkDim)
                Spacer()
                if listing.price.cents > 0 {
                    Text(listing.price.formatted)
                        .font(.headline)
                        .foregroundStyle(Theme.accent)
                }
            }

            if let error = listing.lastError, listing.needsAttention {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.warn)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Per-industry info chips: a venue shows "Seats 220 · From $3,500",
            // a restaurant "Italian · $$$ · Tue–Sun", a gym "$49/mo · Open 24/7".
            if !listing.cardChips.isEmpty {
                // Horizontal scroll so chips never squeeze or truncate at
                // large Dynamic Type — they just run off-card and pan.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(listing.cardChips.enumerated()), id: \.offset) { _, chip in
                            Text(chip)
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Theme.accentSoft, in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
        .padding(16)
    }
}
