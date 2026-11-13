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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WebsiteDesignIntroduction(previewAvailable: currentListing.serverShareURL != nil)
                ForEach(WebsiteDesign.allCases) { design in
                    WebsiteDesignCard(
                        design: design,
                        selected: activeState?.theme == design,
                        unlocked: activeState?.premium.unlocked == true,
                        previewEnabled: currentListing.serverShareURL != nil && isCurrent,
                        selectionDisabled: !isCurrent || isLoading || purchases.isBusy || activeState?.theme == design ||
                            (design.isPremium && activeState?.premium.testOnly == true),
                        onPreview: { preview(design) },
                        onSelect: { Task { await select(design) } }
                    )
                }
                upgradeSection
                if let error {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(Theme.ink)
                        Button { Task { await reload() } } label: {
                            Label("Try again", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                        }
                        .modifier(RendpropActionAppearance(primary: false))
                    }
                    .padding(20).modifier(RendpropContentSurface())
                }
                if isLoading || purchases.isBusy {
                    ProgressView("Updating website…")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 28)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("Website design")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
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

    private var upgradeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Luxury website upgrade", systemImage: "sparkles")
                .font(.headline).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if activeState?.premium.unlocked == true {
                Text(activeState?.premium.testOnly == true
                    ? "This test purchase is recorded. It doesn't change the public website; use Preview to review the luxury designs."
                    : "Unlocked for this property. Both luxury designs are included.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if activeState?.premium.canPurchase(environment: purchases.environment) == true, let product = purchases.product {
                Text("Unlock both luxury designs for this property.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    guard let context else { return }
                    Task { await purchases.purchase(context: context); await reload() }
                } label: {
                    Label("Upgrade this property · \(product.displayPrice)", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .modifier(RendpropActionAppearance())
                .disabled(!isCurrent || isLoading || purchases.isBusy)
            } else {
                Text(currentListing.serverShareURL == nil
                    ? "Luxury purchases are being prepared. Classic is included with paid access; live previews become available after your website is published."
                    : "Luxury purchases are being prepared. You can preview both designs now; your included website stays available.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button { showRecoveryConfirmation = true } label: {
                Label("Recover website purchase", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .modifier(RendpropActionAppearance(primary: false))
            .disabled(!isCurrent || isLoading || purchases.isBusy)
            if let visibleMessage { Text(visibleMessage).font(.footnote).foregroundStyle(.secondary) }
            Text("Upgrades apply to this property only. Hosting follows your plan and its hosting grace period.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20).modifier(RendpropContentSurface())
    }

    private func preview(_ design: WebsiteDesign) {
        guard isCurrent, let url = currentListing.serverShareURL, let preview = design.previewURL(canonical: url, address: currentListing.spaceType == .realEstate ? currentListing.address : nil) else { return }
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


/// A design sample is deliberately separate from a live property preview.
/// It never loads listing media or publishes a private draft.
private struct WebsiteDesignIntroduction: View {
    let previewAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your website’s look")
                .font(.title2.weight(.bold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Classic is included with paid access. Every design has video, photos, location and contact pages.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !previewAvailable {
                Label {
                    Text("Live previews are available after you publish your website. These samples don’t publish your draft.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "eye.slash").foregroundStyle(Theme.accent)
                }
                .font(.footnote).foregroundStyle(Theme.ink)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct WebsiteDesignCard: View {
    let design: WebsiteDesign
    let selected: Bool
    let unlocked: Bool
    let previewEnabled: Bool
    let selectionDisabled: Bool
    let onPreview: () -> Void
    let onSelect: () -> Void

    private var locked: Bool { design.isPremium && !unlocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(design.title).font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Label(selected ? "Current design" : design.isPremium ? (unlocked ? "Unlocked" : "Luxury upgrade") : "Included",
                      systemImage: selected ? "checkmark.circle.fill" : design.isPremium ? "sparkles" : "checkmark.seal")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Theme.accentSoft, in: Capsule())
            }
            WebsiteDesignSample(design: design)
                .accessibilityHidden(true)
            Text(design.summary).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if locked || selected {
                previewAction
                if locked {
                    Label("Upgrade required", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("\(design.title) requires a luxury website upgrade")
                }
            } else {
                VStack(spacing: 12) { previewAction; selectionAction }
            }
        }
        .padding(18)
        .modifier(RendpropContentSurface())
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private var previewAction: some View {
        Button(action: onPreview) {
            Label("Preview", systemImage: "eye")
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(RendpropActionAppearance(primary: false))
        .disabled(!previewEnabled)
        .accessibilityLabel("Preview \(design.title)")
        .accessibilityHint(previewEnabled ? "Opens this property’s website in the selected design without changing it."
                           : "Publish your website with paid access first. This does not publish a draft.")
    }

    private var selectionAction: some View {
        Button(action: onSelect) {
            Label("Use design", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(RendpropActionAppearance())
        .disabled(selectionDisabled)
        .accessibilityLabel("Use \(design.title)")
    }

}

private struct WebsiteDesignSample: View {
    let design: WebsiteDesign

    // Preserve the existing design palettes; these samples are not new themes.
    private var paper: Color {
        design == .signatureEstate ? Color(red: 0.96, green: 0.93, blue: 0.87)
            : design == .coastalLuxe ? Color(red: 0.91, green: 0.96, blue: 0.94) : Color(.secondarySystemBackground)
    }
    private var accent: Color {
        design == .signatureEstate ? Color(red: 0.44, green: 0.32, blue: 0.20)
            : design == .coastalLuxe ? Color(red: 0.06, green: 0.30, blue: 0.30) : .purple
    }
    private var previewFont: Font.Design { design == .signatureEstate ? .serif : .default }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3) { _ in Circle().fill(accent.opacity(0.25)).frame(width: 4, height: 4) }
                Spacer()
                Text("Design sample").font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(accent.opacity(0.05))
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Text(design.title)
                        .font(.system(size: 16, weight: .semibold, design: previewFont))
                        .foregroundStyle(accent)
                    Spacer(minLength: 8)
                    Image(systemName: "line.3.horizontal").font(.system(size: 12)).foregroundStyle(accent)
                }
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: design == .coastalLuxe ? 24 : 8, style: .continuous)
                            .fill(LinearGradient(colors: [accent.opacity(0.12), accent.opacity(0.27)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "house.fill")
                            .font(.system(size: 42, weight: .light)).foregroundStyle(accent.opacity(0.75))
                    }
                    .frame(width: 94, height: 82)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A place to call home")
                            .font(.system(size: 15, weight: .semibold, design: previewFont))
                            .foregroundStyle(accent)
                            .fixedSize(horizontal: false, vertical: true)
                        RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.14)).frame(height: 4)
                        RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.10)).frame(width: 58, height: 4)
                        Capsule().fill(accent).frame(width: 64, height: 17)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(["Home", "Gallery", "Location", "Contact"], id: \.self) { title in
                        Text(title).font(.system(size: 9, weight: .medium))
                            .foregroundStyle(accent).frame(maxWidth: .infinity)
                            .padding(.vertical, 5).background(accent.opacity(0.08), in: Capsule())
                    }
                }
            }
            .padding(14)
        }
        .background(paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(accent.opacity(0.12)))
        .environment(\.layoutDirection, .leftToRight)
    }
}
