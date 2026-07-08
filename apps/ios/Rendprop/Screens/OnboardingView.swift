import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var page = 0

    private let cards: [(icon: String, title: String, body: String)] = [
        ("iphone.gen3", "Just your phone.\nNothing else.",
         "Walk through the home while recording. We guide you the whole way — it's as easy as taking a video."),
        ("wand.and.stars", "We make it look\namazing.",
         "Your video becomes a smooth, professional home tour — like it was filmed with a drone."),
        ("link", "Share it anywhere.\nGet more buyers.",
         "Send one link. Buyers glide through the home on their phone and book a showing right there."),
    ]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
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
                            hasOnboarded = true
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
    }
}
