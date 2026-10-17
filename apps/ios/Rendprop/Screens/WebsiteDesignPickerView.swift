import SwiftUI

struct WebsiteDesignPickerView: View {
    let listing: Listing
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var purchases = WebsiteUpgradeStore.shared
    @State private var context: WebsiteDesignContext?
    @State private var state: WebsiteDesignState?
    @State private var isLoading = false
    @State private var error: String?
    @State private var showRecoveryConfirmation = false

    private var currentListing: Listing { model.listings.first(where: { $0.id == listing.id }) ?? listing }
    private var api: WebsiteDesignAPI? { model.api as? WebsiteDesignAPI }
    private var isCurrent: Bool {
        guard let context else { return false }
        return context.isCurrent && currentListing.serverID == context.listingID &&
            currentListing.cloudUnavailable != true && !currentListing.isSample
    }
    private var activeState: WebsiteDesignState? { isCurrent ? state : nil }
    private var visibleMessage: String? {
        purchases.messageContext == context && isCurrent ? purchases.message : nil
    }

    var body: some View {
        List {
            Section {
                Text("Choose the look of this property's website. Every design includes Home, Gallery, Location and Contact pages, with your selected property video.")
                Text("Classic is included. A luxury upgrade applies to this property only and lets you switch between both luxury designs. Hosting follows your plan and its hosting grace period.")
                    .foregroundStyle(.secondary)
            }
            ForEach(WebsiteDesign.allCases) { design in
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: design == .basic ? "house" : "sparkles")
                                .foregroundStyle(.purple)
                            Text(design.title).font(.headline)
                            Spacer()
                            if activeState?.theme == design { Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple) }
                        }
                        designSwatch(design)
                        Text(design.summary).font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Button("Preview") { preview(design) }
                                .disabled(currentListing.serverShareURL == nil || !isCurrent)
                            Spacer()
                            if design.isPremium && activeState?.premium.unlocked != true {
                                Text("Luxury upgrade").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button(activeState?.theme == design ? "Selected" : "Use this design") {
                                    Task { await select(design) }
                                }
                                .disabled(!isCurrent || isLoading || purchases.isBusy || activeState?.theme == design ||
                                    (design.isPremium && activeState?.premium.testOnly == true))
                            }
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 6)
                }
            }
            if currentListing.serverShareURL == nil {
                Section { Text("Publish your included website first to preview these designs with your own property. A preview never publishes a private draft.").foregroundStyle(.secondary) }
            }
            Section("Luxury website upgrade") {
                if activeState?.premium.unlocked == true {
                    Text(activeState?.premium.testOnly == true
                        ? "This test purchase is recorded. It doesn't change the public website; use Preview to review the luxury designs."
                        : "Unlocked for this property. Both luxury designs are included.")
                } else if activeState?.premium.canPurchase(environment: purchases.environment) == true, let product = purchases.product {
                    Button("Upgrade this property · \(product.displayPrice)") {
                        guard let context else { return }
                        Task { await purchases.purchase(context: context); await reload() }
                    }
                    .disabled(!isCurrent || isLoading || purchases.isBusy)
                } else {
                    Text("Luxury purchases are being prepared. You can preview both designs now; your included website stays available.")
                        .foregroundStyle(.secondary)
                }
                Button("Recover website purchase") { showRecoveryConfirmation = true }
                    .disabled(!isCurrent || isLoading || purchases.isBusy)
                if let visibleMessage { Text(visibleMessage).font(.footnote).foregroundStyle(.secondary) }
            }
            if let error { Section { Text(error).foregroundStyle(.secondary); Button("Retry") { Task { await reload() } } } }
            if isLoading || purchases.isBusy { Section { ProgressView("Updating website…") } }
        }
        .navigationTitle("Website design")
        .task(id: currentListing.serverID) { await reload(); await purchases.loadProduct() }
        .refreshable { await reload() }
        .onChange(of: auth.syncSessionRevision) { _ in clearAndDismiss() }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in clearAndDismiss() }
        .onChange(of: purchases.isBusy) { busy in
            if !busy { Task { await reload() } }
        }
        .confirmationDialog("Recover a website purchase for this property?", isPresented: $showRecoveryConfirmation, titleVisibility: .visible) {
            Button("Recover for this property") {
                guard let context else { return }
                Task { await purchases.recover(context: context); await reload() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A saved purchase remains assigned to its original property. If this iPhone has an unassigned purchase after reinstalling, recovery assigns it to this property once. It does not charge you again.")
        }
    }

    @ViewBuilder private func designSwatch(_ design: WebsiteDesign) -> some View {
        let background: Color = design == .signatureEstate ? Color(red: 0.96, green: 0.93, blue: 0.87)
            : design == .coastalLuxe ? Color(red: 0.91, green: 0.96, blue: 0.94) : Color(.secondarySystemBackground)
        let accent: Color = design == .signatureEstate ? Color(red: 0.44, green: 0.32, blue: 0.20)
            : design == .coastalLuxe ? Color(red: 0.06, green: 0.30, blue: 0.30) : .purple
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: design == .coastalLuxe ? 14 : 3).fill(accent).frame(width: 45, height: 45)
            VStack(alignment: .leading, spacing: 6) {
                Text(design.title).font(.system(.title3, design: design == .signatureEstate ? .serif : .default)).foregroundStyle(accent)
                Text("Home   Gallery   Location   Contact").font(.caption2).foregroundStyle(accent.opacity(0.85))
            }
            Spacer()
        }.padding(14).background(background, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("\(design.title) design palette; open Preview to see the full website")
    }

    private func preview(_ design: WebsiteDesign) {
        guard isCurrent, let url = currentListing.serverShareURL, let preview = design.previewURL(canonical: url) else { return }
        openURL(preview)
    }
    private func clearAndDismiss() {
        state = nil; context = nil; error = nil; showRecoveryConfirmation = false
        dismiss()
    }
    @MainActor private func reload() async {
        guard !isLoading else { return }
        state = nil; context = nil; error = nil
        guard !currentListing.isSample, currentListing.cloudUnavailable != true,
              let serverID = currentListing.serverID, let api else {
            error = "Save this property's details to your account before choosing a website design."
            return
        }
        isLoading = true; defer { isLoading = false }
        do {
            let frozen = try WebsiteDesignContext.capture(listingID: serverID)
            context = frozen
            let response = try await api.websiteDesignState(context: frozen).checked(for: frozen)
            guard frozen.isCurrent, currentListing.serverID == frozen.listingID else { return }
            state = response
        } catch {
            guard context?.isCurrent == true else { return }
            self.error = "Website designs couldn't be loaded. Your current website is unchanged."
        }
    }
    @MainActor private func select(_ design: WebsiteDesign) async {
        guard isCurrent, !isLoading, let context, let api else { return }
        isLoading = true; error = nil; defer { isLoading = false }
        do {
            let response = try await api.selectWebsiteDesign(design, context: context).checked(for: context)
            guard context.isCurrent, currentListing.serverID == context.listingID else { return }
            state = response
        } catch {
            guard context.isCurrent else { return }
            self.error = "This design couldn't be applied. Your current website is unchanged."
        }
    }
}
