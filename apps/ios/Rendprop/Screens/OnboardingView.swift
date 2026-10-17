import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @State private var page = 0
    @State private var choosingType = false
    @State private var choosingRole = false
    @State private var selectedRole: RealEstateRole = .agent

    // Feature-first: each page is one headline feature wearing its signature
    // gradient (the same one it wears on Home's showroom).
    private let cards: [(icon: String, gradient: LinearGradient, title: String, body: String)] = [
        ("house.fill", RPGradient.drone,
         "Start with your home.\nAdd the details.",
         "Enter the address and property details. Your photos, video, website and leads stay grouped with that home."),
        ("wand.and.stars", RPGradient.photo,
         "Landscape photos.\nOptional AI edits.",
         "Add landscape photos and keep the camera level. Use 0.5× when needed and available. Keep your Originals and review optional AI edits."),
        ("film.stack", RPGradient.reel,
         "Make a Listing video.\nReview the result.",
         "Choose landscape Listing or portrait Social media. Your selected order is kept, with automatic camera motion. Voice and music are optional."),
        ("link", RPGradient.share,
         "Your website.\nShare and follow up.",
         "Choose your gallery and cover, check video and contact details, then publish. Share the link and follow up in Leads. Recorded walkthroughs are optional."),
    ]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if choosingRole {
                rolePicker
            } else if choosingType {
                typePicker
            } else {
                cardsView
            }
        }
    }

    private var cardsView: some View {
        VStack(spacing: 0) {
            Text("RENDPROP")
                .font(.caption.weight(.bold))
                .kerning(4)
                .foregroundStyle(Theme.inkDim)
                .padding(.top, 24)

            TabView(selection: $page) {
                ForEach(cards.indices, id: \.self) { i in
                    VStack(spacing: 24) {
                        Image(systemName: cards[i].icon)
                            .font(.system(size: 40, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.white)
                            .frame(width: 92, height: 92)
                            .background(cards[i].gradient,
                                        in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)
                        Text(cards[i].title)
                            .font(.rpLargeTitle)
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.center)
                        Text(cards[i].body)
                            .font(.rpBody)
                            .foregroundStyle(Theme.inkDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .tag(i)
                    .padding(.bottom, 60)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            // Give the page dots a capsule backing — the bare dots are
            // near-invisible on the light background.
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 12) {
                PrimaryButton(title: page < cards.count - 1 ? "Continue" : "Get started",
                              systemImage: page < cards.count - 1 ? nil : "arrow.right") {
                    if page < cards.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        withAnimation { choosingType = true }
                    }
                }
                // App Store 2.3.1 / 3.1: no price, no purchase invitation, and
                // no promise the plan gates contradict. It states the two facts
                // that are true on every plan: capture + on-device rendering are
                // free, and the cloud AI tools are metered.
                Text("Filming and rendering your tour are free.\nCloud AI tools use your monthly allowance.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private var typePicker: some View {
        VStack(spacing: 0) {
            Text("RENDPROP")
                .font(.caption.weight(.bold))
                .kerning(4)
                .foregroundStyle(Theme.inkDim)
                .padding(.top, 24)

            VStack(spacing: 8) {
                Text("What do you\nshowcase?")
                    .font(.rpLargeTitle)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text("We'll tailor the app to your business. You can change this anytime from the menu at the top of the Home tab, or in Settings.")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .padding(.top, 18)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(SpaceType.allCases) { type in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { spaceTypeRaw = type.rawValue }
                            Haptics.selection()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: type.systemImage)
                                    .font(.system(size: 16, weight: .semibold))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(Color.white)
                                    .frame(width: 38, height: 38)
                                    .background(RPGradient.drone,
                                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                Text(type.displayName).font(.rpHeadline).foregroundStyle(Theme.ink)
                                Spacer()
                                if spaceTypeRaw == type.rawValue {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(14)
                            .background(spaceTypeRaw == type.rawValue ? Theme.accentSoft : Theme.card,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(spaceTypeRaw == type.rawValue ? Theme.accent : Theme.border))
                        }
                        .buttonStyle(ScalePressStyle())
                        .accessibilityAddTraits(spaceTypeRaw == type.rawValue ? [.isSelected] : [])
                    }
                }
                .padding()
            }

            // Trial access starts through StoreKit confirmation, never merely
            // by completing onboarding or creating an anonymous workspace.
            VStack(spacing: 3) {
                Text("Choose a plan. Confirm with Apple.")
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("Eligible subscriptions include 7 days free. Apple shows the offer and renewal price before you confirm. Exploring the app does not start a trial.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)
            .padding(.top, 14)
            .padding(.bottom, 12)

            PrimaryButton(title: spaceTypeRaw == SpaceType.realEstate.rawValue ? "Continue" : "Explore the app", systemImage: "arrow.right") {
                if spaceTypeRaw == SpaceType.realEstate.rawValue { withAnimation { choosingRole = true } }
                else { finish(showPlans: false) }
            }
            .accessibilityIdentifier("onboarding.explore")
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            Button("See plans") {
                if spaceTypeRaw == SpaceType.realEstate.rawValue { withAnimation { choosingRole = true } }
                else { finish(showPlans: true) }
            }
                .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("onboarding.choosePlan")
                .padding(.bottom, 24)
        }
    }

    private var rolePicker: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("How do you work?").font(.rpLargeTitle).foregroundStyle(Theme.ink)
            Text("We'll tailor your real estate workflow.").font(.rpBody).foregroundStyle(Theme.inkDim)
            RealEstateRoleChoice(selected: $selectedRole)
            Spacer()
            PrimaryButton(title: "Explore the app", systemImage: "arrow.right") { finish(showPlans: false) }
                .accessibilityIdentifier("onboarding.role.explore")
            Button("See plans") { finish(showPlans: true) }
                .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("onboarding.role.choosePlan")
            Button("Back") { choosingRole = false }.font(.rpCaption).foregroundStyle(Theme.inkDim)
        }.padding(24)
    }
    private func finish(showPlans: Bool) {
        guard NativeAccountLaunchAdmission.allows(signedIn: AuthStore.shared.isSignedIn,
            identified: AuthStore.shared.isIdentified, actorID: AuthStore.shared.userID,
            offlineFixture: Config.isOfflineAccountFixture) else { return }
        if spaceTypeRaw == SpaceType.realEstate.rawValue { RealEstateRoleStore.choose(selectedRole, owner: AuthStore.shared.userID) }
        hasOnboarded = true
        if showPlans { PaywallRouter.shared.present(reason: .upgrade) }
    }
}
