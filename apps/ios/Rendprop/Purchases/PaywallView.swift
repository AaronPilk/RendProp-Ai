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
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in
            Task { await purchases.refreshBillingContext() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropPlanChanged)) { _ in
            Task { await purchases.refreshBillingContext() }
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
            } else if purchases.billingContext?.isCeilingMode == true {
                Text("Apple handles payment and cancellation. Your first published listing is free; a plan adds AI photo edits, reels, aerial intros and more listings.")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
            } else {
                Text("Choose a plan and check trial availability before reviewing any reserved terms. New paid subscriptions are temporarily unavailable. Restore and subscription management remain available.")
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
                if context.showsServicePending {
                    Text(ServingActivationSummary.pendingTitle).font(.rpHeadline)
                    Text(ServingActivationSummary.pendingExplanation).font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
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
            // Monthly only today: no picker, so nobody sees a "Yearly" tab
            // that falls back to monthly prices.
            if RendpropProducts.sellsAnnual { periodPicker }
            planCards
            trialDetails
            if purchases.billingContext?.servingActivation?.available != false {
                SelectedPlanDetails(plan: selectedPlan, period: planOffer(for: selectedPlan).period,
                                    afterTrial: purchases.billingContext?.trialUsage != nil || selectedHasIntroOffer)
            }
        }
        messageBlock
    }

    private var selectedHasIntroOffer: Bool {
        planOffer(for: selectedPlan).product.map { purchases.showsIntroOffer(for: $0) } ?? false
    }

    @ViewBuilder private var trialDetails: some View {
        if let trial = purchases.billingContext?.trialUsage {
            VStack(alignment: .leading, spacing: 10) {
                Text(trial.statusLabel).font(.rpHeadline).foregroundStyle(Theme.ink)
                ForEach(trial.rows, id: \.title) { row in
                    LabeledContent(row.title, value: row.value).font(.rpCaption)
                }
                if let end = trial.endDate {
                    Text("Trial access ends \(end.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
                Text(TrialUsageSummary.explanation).font(.rpCaption).foregroundStyle(Theme.inkDim)
            }.frame(maxWidth: .infinity, alignment: .leading).card()
                .accessibilityIdentifier("paywall.recordedTrial")
        } else if selectedHasIntroOffer, purchases.billingContext?.isCeilingMode == true {
            VStack(alignment: .leading, spacing: 10) {
                Text("7-day free trial").font(.rpHeadline).foregroundStyle(Theme.ink)
                Text("Confirm your subscription with Apple to start the trial. Your workspace's plan and usage limits apply to AI tools and publishing. Reaching a usage limit does not bring forward Apple's charge date.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).card()
                .accessibilityIdentifier("paywall.appleTrial")
        } else if selectedHasIntroOffer, let product = planOffer(for: selectedPlan).product,
                  let offer = purchases.heldTrialOffer(for: product),
                  offer.enabled, !offer.benefitLines.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Trial includes").font(.rpHeadline).foregroundStyle(Theme.ink)
                ForEach(offer.benefitLines, id: \.self) { line in
                    Label(line, systemImage: "checkmark").font(.rpCaption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Up to 7 days, or until the included usage is used. Each allowance is separate and does not reset. Usage does not bring forward Apple's charge date. Your saved work remains available under your workspace's access and retention terms.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }.frame(maxWidth: .infinity, alignment: .leading).card()
                .accessibilityIdentifier("paywall.trialIncludes")
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
            .accessibilityIdentifier("paywall.period")

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
        .accessibilityIdentifier("paywall.plan.\(plan.rawValue)")
        .accessibilityAddTraits(selectedPlan == plan ? [.isSelected] : [])
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
                    .accessibilityIdentifier("paywall.selection")
                buyButton(product)
                if purchases.activeProductID != product.id, !purchases.canStartNewPurchase(for: product) {
                    Text(purchases.canCheckTrialAvailability(for: product)
                         ? "Check availability to reserve this plan's trial terms before Apple's confirmation. Checking does not start Apple billing."
                         : purchases.trialEligibility(for: product) == false
                            ? PurchaseDispatchAdmission.paidUnavailableMessage
                            : TrialPurchaseAdmission.unavailableMessage)
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("paywall.trialUnavailable")
                }
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
                        (purchases.activeProductID != product.id && Config.useLiveBackend &&
                            (purchases.billingContext?.canManageSubscription != true ||
                             (!purchases.canStartNewPurchase(for: product) && !purchases.canCheckTrialAvailability(for: product))))) {
            let continuingHeldTrial = purchases.billingContext?.isCeilingMode != true && purchases.showsIntroOffer(for: product)
            let checkingAvailability = !purchases.canStartNewPurchase(for: product) && purchases.canCheckTrialAvailability(for: product)
            let expectedOrgID = purchases.billingContext?.orgID
            Task {
                if purchases.activeProductID == product.id { await purchases.manageSubscriptions() }
                else if checkingAvailability {
                    await purchases.checkTrialAvailability(product, expectedOrgID: expectedOrgID)
                } else {
                    await purchases.purchase(product, expectedOrgID: expectedOrgID,
                                             continuingHeldTrial: continuingHeldTrial)
                }
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
    /// product has confirmed held terms. New paid purchases stay unavailable
    /// until their own funding admission exists; Manage remains reachable.
    private func buyTitle(for product: Product) -> String {
        if purchases.activeProductID == product.id { return "Manage current subscription" }
        if purchases.billingContext?.isCeilingMode == true {
            if purchases.ceilingShowsIntroOffer(for: product) { return "Start 7-day free trial" }
            if purchases.activePlan != nil { return "Confirm plan change with Apple" }
            return "Subscribe with Apple"
        }
        if Config.useLiveBackend && !Config.isUITesting,
           purchases.trialEligibility(for: product) == false { return "Paid subscriptions unavailable" }
        if purchases.trialEligibility(for: product) != false && !purchases.canStartNewPurchase(for: product) {
            return purchases.canCheckTrialAvailability(for: product) ? "Check trial availability" : "Trial unavailable"
        }
        if purchases.showsIntroOffer(for: product) { return "Continue with Apple" }
        if purchases.activePlan != nil { return "Confirm plan change with Apple" }
        return "Subscribe with Apple"
    }

    private func disclosure(for product: Product, period: BillingPeriod) -> String {
        if purchases.activeProductID == product.id { return "This is the subscription on this Apple ID. Apple shows its renewal date and cancellation options; its original workspace keeps the plan." }
        if purchases.billingContext?.isCeilingMode == true {
            return SubscriptionOfferPolicy.disclosure(sevenDayTrial: purchases.ceilingShowsIntroOffer(for: product),
                price: product.displayPrice, period: period.priceSuffix)
        }
        if Config.useLiveBackend && !Config.isUITesting,
           purchases.trialEligibility(for: product) == false { return PurchaseDispatchAdmission.paidUnavailableMessage }
        if purchases.trialEligibility(for: product) != false && !purchases.canStartNewPurchase(for: product) {
            return "Trial availability depends on a funded reservation and Apple's current eligibility. Checking does not start Apple billing. Review the reserved terms and Apple's confirmation before continuing."
        }
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
        VStack(alignment: .leading, spacing: 6) {
            titleRow
            priceRow
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
                .font(.rpHeadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
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

}

/// The selected plan's full allowance list stays visible without repeating it
/// inside every choice. Price and actual billing period remain on each row.
private struct SelectedPlanDetails: View {
    let plan: RendpropPlan
    let period: BillingPeriod
    var afterTrial: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(afterTrial ? "After the trial · \(plan.displayName)" : "Included with \(plan.displayName)").font(.rpHeadline).foregroundStyle(Theme.ink)
            Text(plan.tagline).font(.rpCaption).foregroundStyle(Theme.inkDim)
            ForEach(plan.benefits, id: \.self) { line in
                Label(line, systemImage: "checkmark")
                    .font(.rpCaption).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("How video allowances work") {
                Text(PlanAllowances.videoAllowanceExplanation)
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }.font(.rpCaption).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("paywall.videoAllowances")
            Text(period.billingNote).font(.rpCaption).foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
        .accessibilityIdentifier("paywall.selectedDetails")
    }
}
