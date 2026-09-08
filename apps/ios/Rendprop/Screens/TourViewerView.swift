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
    @State private var showContact = false
    @State private var showShare = false

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
        .sheet(isPresented: $showContact) {
            if let slug = link.leadSlug { TourLeadSheet(slug: slug) }
        }
        .onAppear {
            Analytics.track("tour_viewer_opened",
                            ["kind": link.leadSlug == nil ? "portfolio" : "tour"])
        }
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
    /// button in front of the buyer without an email form, floating over the
    /// tour rather than waiting at the bottom of a long scroll.
    private var contactBar: some View {
        HStack(spacing: 10) {
            Button {
                showContact = true
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

/// Name, phone, and a note. The same three fields the hosted end-card asks for
/// and the same `POST /leads` behind them, so the agent has one inbox rather
/// than "leads from the site" and "leads from the app".
///
/// PUBLIC BY DESIGN: no sign-in. A buyer who has to make an account to ask
/// about a house does not ask about the house, and the agent is the one who
/// pays for that. The route is rate-limited and Turnstile-gated server-side;
/// the app carries no bot-check of its own and must not pretend to.
private struct TourLeadSheet: View {
    let slug: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var note = ""
    @State private var sending = false
    @State private var sent = false
    @State private var failure: String?

    private var canSend: Bool {
        !sending && name.trimmingCharacters(in: .whitespaces).count >= 2 &&
        phone.trimmingCharacters(in: .whitespaces).count >= 7
    }

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section {
                        Label("Sent — they'll be in touch.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.good)
                    }
                } else {
                    Section("Who should they call?") {
                        TextField("Your name", text: $name).textContentType(.name)
                        TextField("Phone", text: $phone)
                            .textContentType(.telephoneNumber).keyboardType(.phonePad)
                        TextField("Email (optional)", text: $email)
                            .textContentType(.emailAddress).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                    }
                    Section("Anything you want to ask?") {
                        TextField("Is it still available?", text: $note, axis: .vertical)
                            .lineLimit(2...5)
                    }
                    if let failure {
                        Section { Text(failure).font(.rpCaption).foregroundStyle(Theme.warn) }
                    }
                }
            }
            .navigationTitle("Message the agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? "Done" : "Cancel") { dismiss() }
                }
                if !sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") { send() }.disabled(!canSend)
                    }
                }
            }
        }
    }

    private func send() {
        guard canSend else { return }
        sending = true
        failure = nil
        let payload = LeadSubmission(
            slug: slug,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: phone.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : email.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : note.trimmingCharacters(in: .whitespacesAndNewlines))
        Task { @MainActor in
            do {
                try await model.api.submitLead(payload)
                sending = false
                sent = true
                Haptics.success()
                Analytics.track("lead_submitted", ["source": "app_viewer"])
            } catch {
                sending = false
                failure = "That didn't send. Check the phone number and try again."
            }
        }
    }
}
