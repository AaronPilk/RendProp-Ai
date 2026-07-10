import SwiftUI

struct HomeListingsView: View {
    @EnvironmentObject var model: AppModel
    // LOAD-BEARING: observing this key is what makes `filtered`/`soldCount`
    // recompute when the business type changes (they read SpaceType.current,
    // which isn't itself observable). Do not remove — filtering would silently
    // stop updating on type switch.
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @State private var isLoading = true
    @State private var search = ""

    /// Only listings for the CURRENT business type (a gym never sees houses),
    /// active (not sold), plus search.
    private var filtered: [Listing] {
        let active = model.listings.filter { $0.belongsToCurrentType && !$0.isSold }
        guard !search.isEmpty else { return active }
        return active.filter { $0.address.localizedCaseInsensitiveContains(search) }
    }

    /// Archived count for THIS industry only — real-estate sold houses don't
    /// show up in the Food or Gym archive.
    private var soldCount: Int {
        model.listings.filter { $0.belongsToCurrentType && $0.isSold }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && model.listings.isEmpty {
                    loadingState
                } else if model.listings.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            if soldCount > 0 {
                                NavigationLink { SoldListingsView() } label: { soldFolderRow }
                                    .buttonStyle(.plain)
                            }
                            ForEach(filtered) { listing in
                                NavigationLink {
                                    FlythroughDetailView(listing: listing)
                                } label: {
                                    ListingCard(listing: listing)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 6)
                        .padding(.bottom, 90)   // room for the New Listing button
                    }
                    .searchable(text: $search, prompt: "Search \(SpaceType.current.spaceNoun)s")
                    .refreshable { await model.load() }
                }
            }
            .onChange(of: spaceTypeRaw) { _ in
                model.reseedSamples()   // venue owners see venues, not houses
            }
            .navigationTitle(SpaceType.current.collectionTitle)
            .background(Theme.bg)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    UploadMiniBar()
                    if !model.listings.isEmpty {
                        NavigationLink {
                            NewListingView()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus")
                                Text(SpaceType.current.newItemTitle).fontWeight(.semibold)
                            }
                            .font(.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Theme.accent)
                            .foregroundStyle(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: Theme.accent.opacity(0.3), radius: 10, x: 0, y: 4)
                        }
                        .padding(.horizontal)
                        .accessibilityLabel(Text("Start a new listing"))
                    }
                }
                .padding(.bottom, 6)
            }
            .task {
                await model.load()
                isLoading = false
            }
        }
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: SpaceType.current.systemImage)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Let's film your first \(SpaceType.current.spaceNoun)")
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
            Text(SpaceType.current.emptyStateLine)
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            NavigationLink {
                NewListingView()
            } label: {
                Text("Get Started")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 15)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(Color.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var soldFolderRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(SpaceType.current.archiveNoun).font(.rpHeadline).foregroundStyle(Theme.ink)
                Text("\(soldCount) \(SpaceType.current.spaceNoun)\(soldCount == 1 ? "" : "s")")
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

    private var sold: [Listing] {
        model.listings.filter { $0.belongsToCurrentType && $0.isSold }
            .sorted { ($0.soldAt ?? .distantPast) > ($1.soldAt ?? .distantPast) }
    }

    var body: some View {
        Group {
            if sold.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(Theme.inkDim)
                    Text("Nothing here yet.").font(.rpBody).foregroundStyle(Theme.inkDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(sold) { listing in
                            NavigationLink {
                                FlythroughDetailView(listing: listing)
                            } label: {
                                ListingCard(listing: listing)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(SpaceType.current.archiveNoun)
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.bg)
    }
}

// MARK: - Aesthetic listing card

struct ListingCard: View {
    let listing: Listing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
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
        .accessibilityLabel(Text("\(listing.address), \(listing.subtitleLine), \(listing.status.label)"))
    }

    // Hero area — shows the main listing photo once one is set, else a branded placeholder.
    private var hero: some View {
        ZStack {
            if let url = listing.mainPhotoURL, let ui = UIImage(contentsOfFile: url.path) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                LinearGradient(colors: [.clear, Color.black.opacity(0.18)],
                               startPoint: .center, endPoint: .bottom)
            } else {
                LinearGradient(
                    colors: [Theme.accent.opacity(0.22),
                             Theme.accent.opacity(0.08),
                             Color(red: 0.93, green: 0.90, blue: 1.0)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: SpaceType.current == .realEstate
                                  ? "house.and.flag.fill"
                                  : SpaceType.current.systemImage)
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
            StatusChip(status: listing.status)
                .padding(10)
        }
        .overlay(alignment: .bottomLeading) {
            if listing.status == .ready {
                Label("Tour ready to share", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.85), in: Capsule())
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

            // Per-industry info chips: a venue shows "Seats 220 · From $3,500",
            // a restaurant "Italian · $$$ · Tue–Sun", a gym "$49/mo · Open 24/7".
            if !listing.cardChips.isEmpty {
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
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
    }
}
