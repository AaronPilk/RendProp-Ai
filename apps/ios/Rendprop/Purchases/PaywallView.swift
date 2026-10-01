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
    @ObservedObject private var auth = AuthStore.shared

    @State private var period: BillingPeriod = .monthly
    @State private var selectedPlan: RendpropPlan = .pro

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    billingWorkspace
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
        .task(id: "\(auth.userID ?? "none"):\(auth.syncSessionRevision)") {
            PurchaseManager.shared.start()
            await purchases.refreshBillingContext()
            // `source`, not `reason`: the server's per-event props whitelist
            // (services/supabase/functions/events/schema.ts) allows only
            // `source` and `plan` on paywall_viewed, and drops anything else.
            PaywallEvents.track("paywall_viewed", ["source": reason.analyticsValue])
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(purchases.activePlan == nil ? "Choose your Rendprop plan" : "Change your Rendprop plan")
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let line = reason.contextLine {
                Text(line)
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Choose a plan, then confirm with Apple. A free trial starts only after that confirmation, if you’re eligible.")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var billingWorkspace: some View {
        if let context = purchases.billingContext {
            VStack(alignment: .leading, spacing: 6) {
                Label(context.name, systemImage: "person.2.fill").font(.rpHeadline)
                Text(context.canManageSubscription ? "New subscriptions apply to this workspace. Apple manages payment and cancellation. An existing Apple subscription stays with the workspace that owns it." : context.unavailableMessage)
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }.frame(maxWidth: .infinity, alignment: .leading).card()
        } else if let error = purchases.billingError {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.rpCaption).foregroundStyle(Theme.warn)
                Button("Refresh billing access") { Task { await purchases.refreshBillingContext() } }
            }.card()
        } else { ProgressView("Checking workspace billing…") }
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
        }
        messageBlock
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
        let offer = planOffer(for: plan)
        Button {
            Haptics.selection()
            selectedPlan = plan
        } label: {
            PlanCardBody(plan: plan,
                         period: offer.period,
                         priceText: Self.priceText(offer.product, period: offer.period),
                         note: offer.note,
                         isSelected: selectedPlan == plan,
                         isCurrent: purchases.activeProductID == offer.product?.id)
        }
        .buttonStyle(.plain)
        .disabled(offer.product == nil)
        .opacity(offer.product == nil ? 0.45 : 1)
        .accessibilityElement(children: .combine)
    }

    /// What one card offers while the picker is on `period`.
    ///
    /// A plan doesn't have to sell both periods. Team has no yearly product at
    /// launch (`RendpropProducts.notSoldAtLaunch`), so on the Yearly tab its
    /// card falls back to the monthly product: a real price, "Billed every
    /// month.", and a small "Monthly only" note — never an empty card, and
    /// never a Subscribe button pointed at a product that isn't for sale.
    private struct PlanOffer {
        let product: Product?
        /// The period actually on offer — what the price suffix, the billing
        /// note, and the purchase all use.
        let period: BillingPeriod
        /// Set only when that differs from the tab the user is on.
        let note: String?
    }

    private func planOffer(for plan: RendpropPlan) -> PlanOffer {
        guard let sold = plan.soldPeriod(for: period) else {
            return PlanOffer(product: nil, period: period, note: nil)
        }
        return PlanOffer(product: purchases.product(for: plan.productID(for: sold)),
                         period: sold,
                         note: sold == period ? nil : sold.onlyNote)
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
        buyBarContent(planOffer(for: selectedPlan))
    }

    private func buyBarContent(_ offer: PlanOffer) -> some View {
        VStack(spacing: 10) {
            if let product = offer.product {
                Text("Selected: \(selectedPlan.displayName) · \(offer.period.pickerLabel)")
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                buyButton(product)
                // `offer.period`, not the picker: the button buys what the card
                // shows, so the billing sentence has to match the card too.
                Text(disclosure(for: product, period: offer.period))
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Only some of the products came back. Say so instead of
                // offering a button that would buy the wrong plan.
                Text("That plan isn't available right now. Pick another one above.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 20) {
                restoreButton
                Button("Manage subscription") { Task { await purchases.manageSubscriptions() } }
                    .font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("paywall.manage")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private func buyButton(_ product: Product) -> some View {
        PrimaryButton(title: buyTitle(for: product),
                      isDisabled: purchases.isPurchasing || purchases.isRestoring ||
                        (purchases.activeProductID != product.id && Config.useLiveBackend && purchases.billingContext?.canManageSubscription != true)) {
            Task {
                if purchases.activeProductID == product.id { await purchases.manageSubscriptions() }
                else { await purchases.purchase(product, expectedOrgID: purchases.billingContext?.orgID) }
            }
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
        .disabled(purchases.isRestoring || purchases.isPurchasing)
        .accessibilityIdentifier("paywall.restore")
        .foregroundStyle(Theme.accent)
    }

    /// "Start 7-day free trial" ONLY when the customer is eligible AND the
    /// product actually carries an introductory offer. Otherwise "Subscribe".
    private func buyTitle(for product: Product) -> String {
        if purchases.activeProductID == product.id { return "Manage current subscription" }
        if purchases.activePlan != nil { return "Confirm plan change with Apple" }
        return purchases.showsIntroOffer(for: product) ? "Start 7-day free trial" : "Subscribe with Apple"
    }

    private func disclosure(for product: Product, period: BillingPeriod) -> String {
        if purchases.activeProductID == product.id { return "This is the subscription on this Apple ID. Apple shows its renewal date and cancellation options; its original workspace keeps the plan." }
        return SubscriptionOfferPolicy.disclosure(sevenDayTrial: purchases.showsIntroOffer(for: product),
            price: product.displayPrice, period: period.priceSuffix)
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
    /// The period this card is actually offering, which is not always the tab
    /// the user is on — see `PaywallView.PlanOffer`.
    let period: BillingPeriod
    let priceText: String
    /// "Monthly only" when this plan sells only the other period. nil normally.
    let note: String?
    let isSelected: Bool
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            priceRow
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

    private var priceRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(priceText)
                .font(.rpTitle)
                .foregroundStyle(Theme.ink)
            if let note {
                Text(note)
                    .font(.rpKicker)
                    .foregroundStyle(Theme.inkDim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.fillSubtle, in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(plan.displayName)
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
            if isCurrent {
                badge("On this Apple ID", tint: Theme.good)
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
