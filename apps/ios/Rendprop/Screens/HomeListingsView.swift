import SwiftUI
import UIKit

struct HomeListingsView: View {
    @EnvironmentObject var model: AppModel
    // LOAD-BEARING: observing this key is what makes `filtered`/`soldCount`
    // recompute when the business type changes (they read SpaceType.current,
    // which isn't itself observable). Do not remove — filtering would silently
    // stop updating on type switch. (Samples themselves are re-derived by
    // RootTabView on the same change.)
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @State private var isLoading = true
    @State private var search = ""
    @State private var pendingDelete: Listing?

    /// Only listings for the CURRENT business type (a gym never sees houses),
    /// active (not sold), plus search.
    private var filtered: [Listing] {
        let active = model.listings.filter { $0.belongsToCurrentType && !$0.isSold }
        guard !search.isEmpty else { return active }
        return active.filter { $0.address.localizedCaseInsensitiveContains(search) }
    }

    /// True once the user has a listing of their own for this industry.
    private var hasRealListing: Bool {
        model.listings.contains { !$0.isSample && $0.belongsToCurrentType }
    }

    /// Archived count for THIS industry only — real-estate sold houses don't
    /// show up in the Food or Gym archive.
    private var soldCount: Int {
        model.listings.filter { $0.belongsToCurrentType && $0.isSold }.count
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
        .refreshable { await model.syncDirtyListings() }
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
            Text("Your first tour is\n10 minutes away")
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
            Text("The \(noun)s below are samples — scroll one to see the result.")
                .font(.rpCaption)
                .foregroundStyle(Color.white.opacity(0.8))
                .multilineTextAlignment(.center)
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
        model.listings.filter { $0.belongsToCurrentType && $0.isSold }
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
