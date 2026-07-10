import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @State private var page = 0
    @State private var choosingType = false

    private let cards: [(icon: String, title: String, body: String)] = [
        ("iphone.gen3", "Just your phone.\nNothing else.",
         "Walk through the space while recording. We guide you the whole way — it's as easy as taking a video."),
        ("wand.and.stars", "We make it look\namazing.",
         "Your video becomes a smooth, professional tour — like it was filmed with a drone."),
        ("link", "Share it anywhere.\nWin more customers.",
         "Send one link. People glide through your space on their phone and reach out right there."),
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
                    VStack(spacing: 22) {
                        Image(systemName: cards[i].icon)
                            .font(.system(size: 54, weight: .light))
                            .foregroundStyle(Theme.accent)
                        Text(cards[i].title)
                            .font(.rpLargeTitle)
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
                            spaceTypeRaw = type.rawValue
                            Haptics.selection()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: type.systemImage)
                                    .font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
                                Text(type.displayName).font(.rpHeadline).foregroundStyle(Theme.ink)
                                Spacer()
                                if spaceTypeRaw == type.rawValue {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(16)
                            .background(spaceTypeRaw == type.rawValue ? Theme.accentSoft : Theme.card,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(spaceTypeRaw == type.rawValue ? Theme.accent : Theme.border))
                        }
                        .buttonStyle(.plain)
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
