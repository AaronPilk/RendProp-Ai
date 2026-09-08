import SwiftUI

// The buyer's screen. What a Universal Link lands on.
//
// The owner's ask: "when someone clicks the link it should try to get them to
// download the app and then when they download the app it should sign in with
// Apple and then it should take them to that agent's listing that they were
// looking at… it should take them to that agent's profile that shows all of
// their listings."
//
// So Rendprop stops being only an agent tool at this screen. A person who
// arrives here did not create anything and has nothing to publish; they came
// to look at a house. Every decision below follows from that:
//
//  * NO SIGN-IN TO LOOK. Gating a house behind an account is how you lose the
//    buyer who just tapped a text message from their agent. The tour plays
//    immediately. Sign-in is asked for only when the buyer wants something
//    that needs an identity — saving the home, or sending the agent a message.
//  * THE PAGE IS THE PLAYER. This wraps the same hosted page the link would
//    have opened in Safari, through `PlayerWebView`. The scrub engine, the
//    room strip, the floor plan, the disclosure block and the unbranded gate
//    are all already correct there and are load-bearing for compliance; a
//    second native implementation would be a second thing to keep honest.
//    What the app adds is the chrome a web page cannot have.
//  * THE LEAD IS THE POINT. For the agent who shared the link, a buyer landing
//    here is worth something only if it can become a conversation. "Message
//    the agent" posts the same `POST /leads {slug,…}` the page's end-card
//    posts, so a lead from the app and a lead from the web are one inbox.

struct TourViewerView: View {
    let link: DeepLink

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if let url = link.pageURL {
                    PlayerWebView(remoteURL: url)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    unavailable
                }
                if link.leadSlug != nil { contactBar }
            }
            .id(link.id)
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let url = link.pageURL {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
        .onAppear {
            Analytics.track("tour_viewer_opened",
                            ["kind": link.leadSlug == nil ? "portfolio" : "tour"])
        }
    }

    /// Scroll the hosted page to its end card (agent card + lead form).
    /// Posted as a notification because `PlayerWebView` is a
    /// `UIViewRepresentable` and this view holds no reference to the WKWebView.
    private func jumpToEndCard() {
        NotificationCenter.default.post(name: PlayerWebView.scrollToEndCard, object: nil)
    }

    private var title: String {
        switch link {
        case .tour:     return "Tour"
        case .portfolio: return "Their homes"
        }
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.inkDim)
            Text("That link didn't open")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
            Text("Ask whoever sent it for the link again.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }
        .padding()
    }

    /// The one thing the app can do that the web page cannot: put a real
    /// button in front of the buyer, floating over the tour rather than waiting
    /// at the bottom of a long scroll.
    ///
    /// IT SCROLLS TO THE PAGE'S OWN FORM. It briefly did not — it opened a
    /// native sheet posting straight to `POST /leads`, which could never have
    /// worked: that route verifies Cloudflare Turnstile and FAILS CLOSED, and
    /// an iOS app cannot run a Turnstile widget, so every send would have been
    /// refused. Rather than invent a second, weaker bot-protection story for
    /// the same route, the button takes the buyer to the form that already has
    /// the right one. One lead path, one inbox, and the button is still in
    /// front of them instead of a thousand points down the page.
    private var contactBar: some View {
        HStack(spacing: 10) {
            Button {
                jumpToEndCard()
                Haptics.selection()
            } label: {
                Label("Message the agent", systemImage: "bubble.left.and.text.bubble.right.fill")
                    .font(.rpBody.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.accent).foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(ScalePressStyle())
            .accessibilityIdentifier("viewer.contact")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}
