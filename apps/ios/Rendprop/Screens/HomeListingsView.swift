import SwiftUI

struct HomeListingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var isLoading = true
    @State private var search = ""

    private var filtered: [Listing] {
        guard !search.isEmpty else { return model.listings }
        return model.listings.filter { $0.address.localizedCaseInsensitiveContains(search) }
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
                            ForEach(filtered) { listing in
                                NavigationLink(value: listing) {
                                    ListingCard(listing: listing)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 6)
                        .padding(.bottom, 90)   // room for the New Listing button
                    }
                    .searchable(text: $search, prompt: "Search homes")
                    .refreshable { await model.load() }
                }
            }
            .navigationTitle("My Homes")
            .background(Theme.bg)
            .scrollContentBackground(.hidden)
            .navigationDestination(for: Listing.self) { listing in
                FlythroughDetailView(listing: listing)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(Text("Settings"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    UploadMiniBar()
                    if !model.listings.isEmpty {
                        NavigationLink {
                            NewListingView()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus")
                                Text("New Listing").fontWeight(.semibold)
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
            Image(systemName: "video.badge.plus")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Let's film your first home")
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
            Text("Walk through with your phone.\nWe turn it into a stunning video tour.")
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
        .accessibilityLabel(Text("\(listing.address), \(listing.metaLine), \(listing.status.label)"))
    }

    // Hero area — becomes the real tour poster once a render exists.
    private var hero: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.accent.opacity(0.22),
                         Theme.accent.opacity(0.08),
                         Color(red: 0.93, green: 0.90, blue: 1.0)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            // Subtle skyline watermark
            Image(systemName: "house.and.flag.fill")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(Theme.accent.opacity(0.30))
                .offset(y: 6)

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
                Text(listing.metaLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkDim)
                Spacer()
                if listing.price.cents > 0 {
                    Text(listing.price.formatted)
                        .font(.headline)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(16)
    }
}
