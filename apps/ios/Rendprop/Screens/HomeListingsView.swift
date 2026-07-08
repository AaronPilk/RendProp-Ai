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
            .navigationTitle("My Homes")
            .background(Theme.bg)
            .scrollContentBackground(.hidden)
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

struct ListingRow: View {
    let listing: Listing

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accentSoft)
                    .frame(width: 64, height: 46)
                Image(systemName: "house.fill")
                    .foregroundStyle(Theme.accent)
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
