import SwiftUI

/// One place to see shared AI usage and buy verified, nonexpiring top-ups.
/// Prices are StoreKit's localized displayPrice, never a typed dollar string.
struct CreditWalletView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var wallet = CreditWalletStore.shared
    @State private var context: CreditWalletContext?
    @State private var loading = false

    private var visible: CreditWalletSnapshot? {
        guard let context, context.isCurrent, wallet.snapshotContext == context else { return nil }
        return wallet.snapshot
    }
    private var visibleMessage: String? {
        guard let context, context.isCurrent, wallet.messageContext == context else { return nil }
        return wallet.message
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                introduction
                if let visible {
                    balanceCard(visible)
                    purchaseCard(visible)
                } else if !auth.isSignedIn {
                    Label("Sign in to see the credits for your workspace.", systemImage: "person.crop.circle")
                        .font(.subheadline).foregroundStyle(Theme.inkDim)
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(RendpropContentSurface())
                } else if loading {
                    ProgressView("Loading credits…")
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    retryCard
                }
                if let visibleMessage {
                    Label(visibleMessage, systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 36)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .task(id: auth.syncSessionRevision) { await reload() }
        .refreshable { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in
            context = nil
            dismiss()
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Make more with credits")
                .font(.title2.weight(.bold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Your workspace shares one balance. Declutter shows its credit cost before you start an edit.")
                .font(.subheadline).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func balanceCard(_ wallet: CreditWalletSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Available now", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            Text(wallet.balance.totalAvailable.formatted())
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .accessibilityLabel("\(wallet.balance.totalAvailable) credits available")
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                balanceDetail("This month", value: wallet.balance.monthlyAvailable)
                Spacer(minLength: 8)
                balanceDetail("Purchased", value: wallet.balance.topupAvailable)
            }
            if wallet.balance.held > 0 {
                Text("\(wallet.balance.held) credits are held for work in progress. Unused holds return when a job settles.")
                    .font(.footnote).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Purchased credits do not expire. They remain with this workspace if its subscription changes.")
                .font(.footnote).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RendpropContentSurface())
    }

    private func balanceDetail(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.inkDim)
            Text("\(value) credits").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
        }
    }

    private func purchaseCard(_ snapshot: CreditWalletSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add credits")
                .font(.headline).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Buy more only when you need them. Your plan and its monthly allowance stay the same.")
                .font(.subheadline).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            if !snapshot.canPurchase {
                Text("Only a workspace owner or admin can buy credits. Ask one to add credits for the team.")
                    .font(.subheadline).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let product = wallet.product,
               let offer = snapshot.products.first(where: { $0.productID == product.id }) {
                Button {
                    guard let context else { return }
                    Task { await wallet.purchase(context: context) }
                } label: {
                    Label("Add \(offer.credits) credits · \(product.displayPrice)", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .modifier(RendpropActionAppearance())
                .disabled(wallet.isBusy || loading || context?.isCurrent != true)
                .accessibilityIdentifier("credits.buy")
            } else {
                Text("Credit purchases are not available from the App Store right now. Your existing work remains available.")
                    .font(.subheadline).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                guard let context else { return }
                Task { await wallet.recover(context: context) }
            } label: {
                Label(wallet.isBusy ? "Checking purchase…" : "Check pending purchase", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .modifier(RendpropActionAppearance(primary: false))
            .disabled(wallet.isBusy || loading || context?.isCurrent != true)
            .accessibilityIdentifier("credits.recover")
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RendpropContentSurface())
    }

    private var retryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your credit balance could not load.")
                .font(.subheadline).foregroundStyle(Theme.ink)
            Button { Task { await reload() } } label: {
                Label("Try again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .modifier(RendpropActionAppearance(primary: false))
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RendpropContentSurface())
    }

    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        guard let captured = try? CreditWalletContext.capture() else { context = nil; return }
        context = captured
        await wallet.load(context: captured)
    }
}
