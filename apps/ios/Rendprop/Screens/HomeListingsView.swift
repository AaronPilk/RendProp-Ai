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
                    List { ForEach(0..<3, id: \.self) { _ in SkeletonRow() } }
                        .listStyle(.plain)
                } else if model.listings.isEmpty {
                    emptyState
                } else {
                    List(filtered) { listing in
                        NavigationLink(value: listing) {
                            ListingRow(listing: listing)
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $search, prompt: "Search listings")
                    .refreshable { await model.load() }
                }
            }
            .navigationTitle("My Listings")
            .navigationDestination(for: Listing.self) { listing in
                FlythroughDetailView(listing: listing)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        NewListingView()
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel(Text("New listing"))
                }
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
                UploadMiniBar()
            }
            .task {
                await model.load()
                isLoading = false
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Shoot your first walkthrough")
                .font(.rpTitle)
            Text("Walk it. Upload it. Fly through it.")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
            NavigationLink {
                NewListingView()
            } label: {
                Text("New Listing")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 13)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ListingRow: View {
    let listing: Listing

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 46)
                Image(systemName: "house.fill")
                    .foregroundStyle(Theme.inkDim)
                    .font(.system(size: 16))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(listing.address)
                    .font(.rpHeadline)
                    .lineLimit(1)
                Text("\(listing.metaLine) · \(listing.price.formatted)")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .lineLimit(1)
            }
            Spacer()
            StatusChip(status: listing.status)
        }
        .padding(.vertical, 4)
    }
}
