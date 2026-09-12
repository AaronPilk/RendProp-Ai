import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @State private var page = 0
    @State private var choosingType = false

    // Feature-first: each page is one headline feature wearing its signature
    // gradient (the same one it wears on Home's showroom).
    private let cards: [(icon: String, gradient: LinearGradient, title: String, body: String)] = [
        ("video.fill", RPGradient.drone,
         "Film with your phone.\nGet a drone-style tour.",
         "Walk through once while recording. Rendprop turns it into a smooth, cinematic flythrough people scroll to explore."),
        ("wand.and.stars", RPGradient.photo,
         "An AI photo studio\nin your pocket.",
         "Twilight skies, decluttered rooms, virtual staging — pro listing photos from the ones you already have."),
        ("film.stack", RPGradient.reel,
         "Reels and floor plans,\ndone for you.",
         "AI animates your photos into a social-ready reel. On iPhones with LiDAR, you can scan a floor plan too — or upload one."),
        ("link", RPGradient.share,
         "One link.\nReal leads.",
         "Share your tour anywhere. Your card rides along, every viewer can reach you in a tap, and their inquiries land in Leads."),
    ]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if choosingType {
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

            // Nothing in the app had ever mentioned the free week, so nobody
            // knew they were on one — and until migration 0032 there was
            // nothing to mention, because `trial` and `free` carried identical
            // entitlements. Deliberately NOT called a "7-day free trial": the
            // paywall's StoreKit introductory offer is called that, and two
            // different things under one name is how a 3.1.2 problem starts.
            //
            // The week is sized per industry (migration 0044): an agent gets
            // 3 tours, a single-location business 1. The line reads the LIVE
            // selection above — tap "Event venue" and it says "1 tour" — so
            // the promise a person reads is the one the server will keep for
            // the type they picked. The title stays word for word: the
            // screenshot walk finds this screen by it.
            VStack(spacing: 3) {
                Text("Your first week is on us")
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("\((SpaceType(rawValue: spaceTypeRaw) ?? .realEstate).freeWeekLine), free. No card, no account.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)
            .padding(.top, 14)
            .padding(.bottom, 12)

            PrimaryButton(title: "Get started", systemImage: "arrow.right") {
                hasOnboarded = true
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }
}
