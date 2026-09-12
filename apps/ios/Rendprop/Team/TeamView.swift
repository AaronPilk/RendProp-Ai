import SwiftUI

// Team — who is on this workspace, and the invite that puts them there.
//
// Reached from Settings. Nothing else in the app depends on it, and nothing in
// the app is gated behind it: a solo agent never opens this screen and never
// signs in.
//
// APP STORE, TWICE OVER:
//   * 5.1.1(v). This IS the one place Sign in with Apple is genuinely required,
//     and that is allowed — a seat belongs to a person, and an anonymous
//     session has nobody to give it to. The screen says so in those words and
//     offers nothing else. Requiring it here does not require it anywhere else.
//   * 3.1.1. No route out of the app to buy anything, ever. A full team offers
//     the StoreKit paywall and nothing more. The moment a "get more seats"
//     button points at a website, the app is rejected.
//
// NO Analytics.track CALLS IN THIS FILE. The events vocabulary is closed
// server-side and one unknown name makes /events refuse the WHOLE batch —
// which is the bug that was silently eating app_open and purchase rows until
// today. Team events go in when they are added to functions/events/schema.ts,
// not before.

struct TeamView: View {
    @ObservedObject private var auth = AuthStore.shared

    @State private var summary: TeamSummary?
    @State private var isLoading = false
    @State private var loadError: String?

    @State private var showInvite = false
    @State private var showJoin = false
    @State private var showSignIn = false
    @State private var showPaywall = false

    @State private var createdInvite: TeamInviteCreated?
    @State private var pendingRemoval: TeamSummary.Member?
    @State private var actionError: String?
    @State private var busy = false

    /// An anonymous session can see the screen but cannot hold a seat.
    private var needsIdentity: Bool { Config.enableAuth && !auth.isIdentified }

    var body: some View {
        List { content }
            .listStyle(.insetGrouped)
            .navigationTitle("Team")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $showSignIn) {
                SignInView.optionalUpgrade { Task { await load() } }
            }
            .sheet(isPresented: $showJoin) {
                JoinTeamView { Task { await load() } }
            }
            .sheet(item: $createdInvite) { invite in
                InviteCodeView(invite: invite)
            }
            .sheet(isPresented: $showPaywall) {
                // `.quota` is the honest reason: they hit a plan limit. It is
                // also the ONLY route this screen offers when the team is full
                // — App Store 3.1.1 makes a link out to buy an instant
                // rejection, so there is no web page to send them to.
                PaywallView(reason: .quota(feature: "seats"))
            }
            .alert("Remove from the team?",
                   isPresented: Binding(get: { pendingRemoval != nil },
                                        set: { if !$0 { pendingRemoval = nil } })) {
                Button("Remove", role: .destructive) {
                    if let m = pendingRemoval { Task { await remove(m) } }
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("\(pendingRemoval?.displayName ?? "They") lose access to this workspace. The homes, tours and leads stay here — they belong to the team, not to one person.")
            }
            .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil },
                                                           set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
    }

    // MARK: - Sections

    @ViewBuilder
    private var content: some View {
        if needsIdentity {
            identitySection
        } else if let summary {
            seatsSection(summary)
            membersSection(summary)
            if summary.canManage { invitesSection(summary) }
            joinSection
        } else if isLoading {
            Section {
                HStack {
                    Text("Loading your team…").foregroundStyle(Theme.inkDim)
                    Spacer()
                    ProgressView()
                }
            }
        } else if let loadError {
            Section {
                Text(loadError).font(.rpCaption).foregroundStyle(Theme.inkDim)
                Button("Try again") { Task { await load() } }
            }
        }
    }

    /// The one screen in the app that asks for a real identity, and the only
    /// one allowed to (App Store 5.1.1(v)) — because a seat belongs to a person.
    private var identitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("A team seat belongs to a person", systemImage: "person.2")
                    .font(.rpHeadline)
                    .foregroundStyle(Theme.ink)
                Text("Everything else in Rendprop works without an account. Teams are the exception: a seat has to belong to someone, so sign in with Apple to start a team or to join one.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showSignIn = true } label: {
                    Label("Sign in with Apple", systemImage: "apple.logo")
                        .font(.rpBody.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }

    private func seatsSection(_ s: TeamSummary) -> some View {
        Section {
            LabeledContent("Seats used", value: "\(s.seats.used) of \(s.seats.allowed)")
            if s.canManage && s.seats.isFull {
                // App Store 3.1.1: the ONLY thing offered here is the in-app
                // paywall. No link, no web page, no "contact us to add seats".
                //
                // ── 1.0.2: THE BROKERAGE ROW WAS ASKED FOR AND WAS NOT BUILT ──
                //
                // The 9 Sep pricing decision included a "Talk to us" row for
                // brokerages, sold off the App Store under 3.1.3(c) (Enterprise
                // Services). Building it here was re-examined for 1.0.2 and
                // declined. The reasoning, so nobody has to re-derive it:
                //
                // 3.1.3's own preamble governs every app that uses one of its
                // carve-outs, enterprise sales included: "Apps in this section
                // cannot, within the app, encourage users to use a purchasing
                // method other than in-app purchase. Developers can send
                // communications outside of the app to their user base about
                // purchasing methods other than in-app purchase."
                //
                // A row offering to talk about SEATS is a call to action inside
                // the app whose destination is a seat bought some other way —
                // and seats are exactly what the Team subscription sells
                // through StoreKit. It does not matter that the row carries no
                // price and opens Mail rather than a checkout: the thing it
                // starts is a sale of the same unit, and 3.1.1 already bars
                // "buttons, external links, or other calls to action that
                // direct customers to purchasing mechanisms other than in-app
                // purchase". Sitting in this section, two rows under "See plans
                // with more seats", is the adjacency that makes it read as an
                // alternative to the button beside it.
                //
                // The permitted channel is the one 3.1.3 names: OUTSIDE the
                // app. A brokerage conversation belongs in e-mail the owner
                // sends, on rendprop.com, or in a reply to the support address
                // already published in Settings (Legal & support → Contact
                // support, aaron@pilk.ai) — which a brokerage can already use
                // today without the app soliciting it.
                //
                // `Config.pricingURL` is nil for the same reason and carries
                // the same standing instruction: do not revive an external
                // purchase CTA.
                Button { showPaywall = true } label: {
                    Label("See plans with more seats", systemImage: "arrow.up.circle")
                }
            }
        } header: {
            Text(s.orgName ?? "Your team")
        } footer: {
            Text(seatsFooter(s))
        }
    }

    private func seatsFooter(_ s: TeamSummary) -> String {
        if !s.canManage {
            return "You're on this team. The owner manages who else is on it."
        }
        if s.seats.isFull {
            return "Every seat on your plan is taken. A pending invite holds a seat until it's accepted or revoked."
        }
        let n = s.seats.remaining
        return "\(n) seat\(n == 1 ? "" : "s") left. A pending invite holds one until it's accepted or revoked."
    }

    private func membersSection(_ s: TeamSummary) -> some View {
        Section {
            ForEach(s.members) { m in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.isYou ? "\(m.displayName) (you)" : m.displayName)
                            .font(.rpBody)
                            .foregroundStyle(Theme.ink)
                        Text(m.roleLabel)
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                    }
                    Spacer()
                    if s.canManage && !m.isYou && m.role != "owner" {
                        Button(role: .destructive) { pendingRemoval = m } label: {
                            Image(systemName: "person.badge.minus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("On the team")
        }
    }

    private func invitesSection(_ s: TeamSummary) -> some View {
        Section {
            ForEach(s.invites) { invite in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invite.emailLabel).font(.rpBody).foregroundStyle(Theme.ink)
                        if let e = invite.expiryLabel {
                            Text(e).font(.rpCaption).foregroundStyle(Theme.inkDim)
                        }
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) { Task { await revoke(invite) } }
                        .font(.rpCaption)
                        .buttonStyle(.borderless)
                        .disabled(busy)
                }
                .padding(.vertical, 2)
            }
            Button {
                if s.seats.isFull { showPaywall = true } else { showInvite = true }
            } label: {
                Label("Invite someone", systemImage: "person.badge.plus")
            }
            .disabled(busy)
        } header: {
            Text(s.invites.isEmpty ? "Invite" : "Waiting to join")
        } footer: {
            Text("You'll get a code to send them. They enter it in Rendprop under Settings → Team → Join a team.")
        }
        .sheet(isPresented: $showInvite) {
            NewInviteView { email, role in
                await invite(email: email, role: role)
            }
        }
    }

    private var joinSection: some View {
        Section {
            Button { showJoin = true } label: {
                Label("Join a team with a code", systemImage: "arrow.right.circle")
            }
        } footer: {
            Text("Someone on a team plan can invite you. Joining moves you to their workspace — you can only do it while your own is empty.")
        }
    }

    // MARK: - Actions

    @MainActor
    private func load() async {
        guard !needsIdentity else { summary = nil; return }
        isLoading = true
        defer { isLoading = false }
        do {
            summary = try await TeamAPI.summary()
            loadError = nil
        } catch {
            summary = nil
            loadError = (error as? TeamAPI.Failure)?.message
                ?? "Couldn't load your team. Check your connection and try again."
        }
    }

    @MainActor
    private func invite(email: String?, role: String) async {
        busy = true
        defer { busy = false }
        do {
            createdInvite = try await TeamAPI.invite(email: email, role: role)
            Haptics.success()
            await load()
        } catch let f as TeamAPI.Failure {
            // A full team is not an error to apologise for — it is the paywall,
            // reached the only way Apple allows.
            if f.isSeatLimit { showPaywall = true } else { actionError = f.message }
        } catch {
            actionError = "Couldn't create the invite. Try again."
        }
    }

    @MainActor
    private func revoke(_ invite: TeamSummary.Invite) async {
        busy = true
        defer { busy = false }
        do {
            try await TeamAPI.revoke(inviteId: invite.id)
            Haptics.selection()
            await load()
        } catch {
            actionError = (error as? TeamAPI.Failure)?.message ?? "Couldn't revoke that invite."
        }
    }

    @MainActor
    private func remove(_ member: TeamSummary.Member) async {
        pendingRemoval = nil
        busy = true
        defer { busy = false }
        do {
            try await TeamAPI.remove(userId: member.userId)
            Haptics.selection()
            await load()
        } catch {
            actionError = (error as? TeamAPI.Failure)?.message ?? "Couldn't remove them."
        }
    }
}

// MARK: - Compose an invite

private struct NewInviteView: View {
    let send: (String?, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role = "agent"
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Their email (optional)", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Role", selection: $role) {
                        Text("Agent").tag("agent")
                        Text("Admin").tag("admin")
                        Text("Marketing").tag("marketing")
                    }
                } footer: {
                    Text("The email is only so you can see who you invited — the code is what lets them in, and you can send it however you like. An admin can invite and remove people; an agent can't.")
                }
            }
            .navigationTitle("Invite someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create code") {
                        sending = true
                        Task {
                            await send(email.isEmpty ? nil : email, role)
                            sending = false
                            dismiss()
                        }
                    }
                    .disabled(sending)
                }
            }
        }
    }
}

// MARK: - The code, shown once

private struct InviteCodeView: View {
    let invite: TeamInviteCreated
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Text(invite.code)
                    .font(.system(.title, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
                Text("Send this to \(invite.email ?? "them"). They enter it in Rendprop under Settings → Team → Join a team.")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                // Shown once and never again: the code is not stored in a form
                // anything can read back, so a lost one is revoked and reissued.
                Text("You won't see this code again. If it goes missing, revoke the invite and make a new one.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = invite.code
                        copied = true
                        Haptics.selection()
                    } label: {
                        Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    ShareLink(item: "Join my Rendprop team with this code: \(invite.code)") {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            .navigationTitle("Invite code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Join with a code

struct JoinTeamView: View {
    var onJoined: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthStore.shared
    @State private var code = ""
    @State private var joining = false
    @State private var errorMessage: String?
    @State private var joinedName: String?
    @State private var showSignIn = false

    private var needsIdentity: Bool { Config.enableAuth && !auth.isIdentified }

    var body: some View {
        NavigationStack {
            Form {
                if needsIdentity {
                    Section {
                        Text("Sign in with Apple first — a team seat belongs to a person, not to one phone.")
                            .font(.rpCaption)
                            .foregroundStyle(Theme.inkDim)
                        Button { showSignIn = true } label: {
                            Label("Sign in with Apple", systemImage: "apple.logo")
                        }
                    }
                } else {
                    Section {
                        TextField("XXXX-XXXX-XXXX", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                            .disabled(joining)
                    } footer: {
                        Text("The owner of the team sends you this code. Joining moves you to their workspace, and it only works while your own workspace is empty.")
                    }
                    if let errorMessage {
                        Section {
                            Text(errorMessage).font(.rpCaption).foregroundStyle(Theme.warn)
                        }
                    }
                }
            }
            .navigationTitle("Join a team")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSignIn) { SignInView.optionalUpgrade() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(joining)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(joining ? "Joining…" : "Join") { Task { await join() } }
                        .disabled(joining || needsIdentity || code.count < 12)
                }
            }
            .alert("You're on the team", isPresented: Binding(get: { joinedName != nil },
                                                             set: { if !$0 { joinedName = nil } })) {
                Button("OK") { joinedName = nil; onJoined(); dismiss() }
            } message: {
                Text("You've joined \(joinedName ?? "the team"). Their homes, tours and leads are yours to work on now.")
            }
        }
    }

    @MainActor
    private func join() async {
        joining = true
        defer { joining = false }
        do {
            let joined = try await TeamAPI.join(code: code)
            Haptics.success()
            joinedName = joined.orgName ?? "the team"
            errorMessage = nil
        } catch let f as TeamAPI.Failure {
            errorMessage = f.message
        } catch {
            errorMessage = "Couldn't join with that code. Check it and try again."
        }
    }
}

// `sheet(item:)` needs identity; the invite's own id is it.
extension TeamInviteCreated: Identifiable {}
