import SwiftUI
import StoreKit

// MARK: - The paywall
//
// One screen. One obvious action. Everything a person needs to decide, and
// nothing else:
//
//   • what they get                (headline + per-plan bullets from Products.swift)
//   • what it costs                (StoreKit's `displayPrice` — never a string we typed)
//   • how often they're charged    ("/month" · "/year" + the auto-renew sentence)
//   • how to stop                  (cancel line + Apple's Manage Subscriptions)
//   • the two links App Review requires for auto-renewables (3.1.2)
//
// Every failure state is a sentence, not a spinner: products can legitimately
// come back empty (simulator with no StoreKit configuration attached, no App
// Store account, products still awaiting review) and the screen has to say so
// and offer Retry.

struct PaywallView: View {
    var reason: PaywallReason = .upgrade

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var purchases = PurchaseManager.shared

    @State private var period: BillingPeriod = .monthly
    @State private var selectedPlan: RendpropPlan = .pro

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    content
                    legalBlock
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { buyBar }
            .accessibilityIdentifier("paywall.root")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            PurchaseManager.shared.start()
            // `source`, not `reason`: the server's per-event props whitelist
            // (services/supabase/functions/events/schema.ts) allows only
            // `source` and `plan` on paywall_viewed, and drops anything else.
            PaywallEvents.track("paywall_viewed", ["source": reason.analyticsValue])
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Turn any phone walkthrough into a cinematic tour")
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let line = reason.contextLine {
                Text(line)
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Pick a plan. Cancel any time.")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Body states

    @ViewBuilder
    private var content: some View {
        if purchases.products.isEmpty && !purchases.didLoadProducts {
            loadingCard
        } else if purchases.products.isEmpty {
            unavailableCard
        } else {
            periodPicker
            planCards
            messageBlock
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Loading plans…")
                .font(.rpBody)
                .foregroundStyle(Theme.inkDim)
            Spacer()
        }
        .card()
    }

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plans aren't available right now")
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            Text(unavailableDetail)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            SecondaryButton(title: "Try again", systemImage: "arrow.clockwise") {
                Task { await PurchaseManager.shared.loadProducts() }
            }
        }
        .card()
    }

    private var unavailableDetail: String {
        if let error = purchases.lastError, !error.isEmpty { return error }
        return "The App Store didn't send the plans back. Check your connection and try again — nothing has been charged."
    }

    // MARK: Monthly / Yearly

    private var periodPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Billing period", selection: $period) {
                ForEach(BillingPeriod.allCases) { p in
                    Text(p.pickerLabel).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Text("How often you're charged"))

            HStack(spacing: 6) {
                Image(systemName: "gift.fill")
                    .font(.rpCaption)
                Text("Yearly: \(BillingPeriod.annualBadge)")
                    .font(.rpKicker)
            }
            .foregroundStyle(Theme.accent)
        }
    }

    // MARK: Plan cards

    private var planCards: some View {
        VStack(spacing: 12) {
            ForEach(RendpropPlan.allCases) { plan in
                planCard(plan)
            }
        }
    }

    @ViewBuilder
    private func planCard(_ plan: RendpropPlan) -> some View {
        let productID = plan.productID(for: period)
        let product = purchases.product(for: productID)
        Button {
            Haptics.selection()
            selectedPlan = plan
        } label: {
            PlanCardBody(plan: plan,
                         period: period,
                         priceText: Self.priceText(product, period: period),
                         isSelected: selectedPlan == plan,
                         isCurrent: isCurrentPlan(plan))
        }
        .buttonStyle(.plain)
        .disabled(product == nil)
        .opacity(product == nil ? 0.45 : 1)
        .accessibilityElement(children: .combine)
    }

    /// StoreKit's price string, or a plain dash when that product didn't load.
    /// NEVER a hardcoded number.
    private static func priceText(_ product: Product?, period: BillingPeriod) -> String {
        guard let product else { return "—" }
        return product.displayPrice + period.priceSuffix
    }

    private func isCurrentPlan(_ plan: RendpropPlan) -> Bool {
        RendpropProducts.plan(fromPlanName: purchases.activePlan) == plan
    }

    // MARK: Errors / notices

    @ViewBuilder
    private var messageBlock: some View {
        if let notice = purchases.notice, !notice.isEmpty {
            Label(notice, systemImage: "clock.fill")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = purchases.lastError, !error.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                if purchases.unsyncedCount > 0 {
                    Button("Try again") {
                        Task { await PurchaseManager.shared.retryUnsynced() }
                    }
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    // MARK: Buy bar

    @ViewBuilder
    private var buyBar: some View {
        if !purchases.products.isEmpty {
            VStack(spacing: 10) {
                if let product = selectedProduct {
                    buyButton(product)
                    Text(disclosure(for: product))
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Only some of the six products came back. Say so instead
                    // of offering a button that would buy the wrong plan.
                    Text("That plan isn't available right now. Pick another one above.")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                restoreButton
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(.bar)
        }
    }

    private func buyButton(_ product: Product) -> some View {
        PrimaryButton(title: buyTitle(for: product),
                      isDisabled: purchases.isPurchasing) {
            Task { await PurchaseManager.shared.purchase(product) }
        }
        .overlay(alignment: .trailing) {
            if purchases.isPurchasing {
                ProgressView()
                    .tint(Color.white)
                    .padding(.trailing, 18)
            }
        }
    }

    /// App Review expects Restore to be reachable wherever the purchase is.
    private var restoreButton: some View {
        Button {
            Task { await PurchaseManager.shared.restore() }
        } label: {
            if purchases.isRestoring {
                ProgressView()
            } else {
                Text("Restore purchases")
                    .font(.rpCaption.weight(.semibold))
            }
        }
        .disabled(purchases.isRestoring)
        .foregroundStyle(Theme.accent)
    }

    private var selectedProduct: Product? {
        purchases.product(for: selectedPlan.productID(for: period))
    }

    /// "Start 7-day free trial" ONLY when the customer is eligible AND the
    /// product actually carries an introductory offer. Otherwise "Subscribe".
    private func buyTitle(for product: Product) -> String {
        purchases.showsIntroOffer(for: product) ? "Start 7-day free trial" : "Subscribe"
    }

    private func disclosure(for product: Product) -> String {
        if purchases.showsIntroOffer(for: product) {
            return PaywallLegal.trialDisclosure + " " + PaywallLegal.autoRenewDisclosure
        }
        return period.billingNote + " " + PaywallLegal.autoRenewDisclosure
    }

    // MARK: Legal (App Review 3.1.2)

    private var legalBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PaywallLegal.autoRenewDisclosure)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                if let terms = PaywallLegal.termsURL {
                    Link("Terms of Use", destination: terms)
                }
                if let privacy = PaywallLegal.privacyURL {
                    Link("Privacy Policy", destination: privacy)
                }
                Spacer(minLength: 0)
            }
            .font(.rpCaption.weight(.semibold))
            .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - One plan card
//
// Split out of `PaywallView` so the SwiftUI type-checker only ever sees a small
// body (this file's neighbours have a history of solver timeouts).

private struct PlanCardBody: View {
    let plan: RendpropPlan
    let period: BillingPeriod
    let priceText: String
    let isSelected: Bool
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            Text(priceText)
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
            Text(period.billingNote)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(plan.benefits, id: \.self) { line in
                    benefitRow(line)
                }
            }
            Text(plan.tagline)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacing)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Theme.border,
                              lineWidth: isSelected ? 2 : 1)
        )
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(plan.displayName)
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            if isCurrent {
                badge("Your plan", tint: Theme.good)
            } else if plan.isMostPopular {
                badge("Most popular", tint: Theme.accent)
            }
            Spacer(minLength: 0)
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.rpBody)
                .foregroundStyle(isSelected ? Theme.accent : Theme.inkDim)
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.rpKicker)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func benefitRow(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.rpCaption.weight(.bold))
                .foregroundStyle(Theme.accent)
            Text(line)
                .font(.rpCaption)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
