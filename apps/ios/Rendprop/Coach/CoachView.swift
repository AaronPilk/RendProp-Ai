import SwiftUI

// coach — the chat screen. Plain UI in the app's own design language: bubbles,
// action chips under an assistant message, one input bar, starter chips
// before the first reply, suggested-reply chips after. Presented as a sheet
// from two entry points (Home's "Ask the coach" button, Settings' "Coach &
// help" row) — see docs/handoff/coach.md for both call sites at file:line.

struct CoachView: View {
    @StateObject private var coachModel: CoachModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    /// `model` and `originScreen` are passed explicitly by the presenter
    /// (never read from `@EnvironmentObject`) so `CoachModel` — a
    /// `@StateObject`, created exactly once — can be built right here with
    /// everything it needs from the very first frame.
    init(model: AppModel, originScreen: String? = nil, starters: [String]? = nil) {
        _coachModel = StateObject(wrappedValue: CoachModel(model: model,
                                                          originScreen: originScreen,
                                                          starters: starters))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                Divider()
                inputBar
            }
            .background(Theme.bg)
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("coach.root")
        // What the person types is answered by Anthropic or OpenAI on the
        // server, so the screen carries the same 5.1.2(i) consent sheet every
        // other AI tool carries. Unlike the studio, declining does not dismiss:
        // CoachModel falls back to the on-device answers.
        .aiConsentGate()
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(coachModel.messages) { message in
                        CoachBubble(message: message) { action in
                            coachModel.perform(action)
                            dismiss()
                        }
                        .id(message.id)
                    }
                    if coachModel.isSending {
                        CoachTypingIndicator()
                    }
                }
                .padding()
            }
            .onChange(of: coachModel.messages.count) { _ in
                guard let last = coachModel.messages.last?.id else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: coachModel.isSending) { sending in
                guard sending, let last = coachModel.messages.last?.id else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coachModel.messages.count <= 1 {
                chipRow(coachModel.starterChips) { coachModel.send($0) }
            } else if let replies = coachModel.messages.last?.suggestedReplies, !replies.isEmpty {
                chipRow(replies) { coachModel.send($0) }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask the coach…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                    .accessibilityIdentifier("coach.input")
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Theme.accent : Theme.inkDim.opacity(0.35))
                }
                .disabled(!canSend)
                .accessibilityIdentifier("coach.send")
                .accessibilityLabel(Text("Send"))
            }
            Text("The coach can make mistakes — check the app.")
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.bg)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coachModel.isSending
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = draft
        draft = ""
        coachModel.send(text)
    }

    private func chipRow(_ items: [String], onTap: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button(item) { onTap(item) }
                        .font(.rpCaption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.accentSoft, in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 1)   // keeps the first chip's shadow/edge from clipping
        }
    }
}

// MARK: - One chat bubble

private struct CoachBubble: View {
    let message: CoachMessage
    var onAction: (CoachResponse.Action) -> Void

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            Text(message.text)
                .font(.rpBody)
                .foregroundStyle(isUser ? Color.white : Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isUser ? Theme.accent : Theme.card,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: 280, alignment: isUser ? .trailing : .leading)

            // At most one — the server clamps to MAX_ACTIONS = 1 and the
            // client never assumes otherwise; `.offset` needs no uniqueness
            // guarantee from `label` even so.
            ForEach(Array(message.actions.enumerated()), id: \.offset) { _, action in
                Button {
                    onAction(action)
                } label: {
                    Text(action.label).font(.rpCaption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

private struct CoachTypingIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Coach is thinking…").font(.rpCaption).foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
