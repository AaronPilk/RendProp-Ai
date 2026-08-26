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
         "AI animates your photos into a social-ready reel, and your phone scans a real floor plan."),
        ("link", RPGradient.share,
         "One link.\nReal leads.",
         "Share your tour anywhere. Your card rides along, and every viewer can reach you in a tap."),
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
                Text("Your first video tour is free.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
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
                Text("We'll tailor the app to your business. You can change this anytime in Settings.")
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

            PrimaryButton(title: "Get started", systemImage: "arrow.right") {
                hasOnboarded = true
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }
}
