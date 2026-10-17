import SwiftUI

/// Optional "Useful / Needs work" for the exact version on screen. It sits
/// below the required review checks and never changes them, the photo, the
/// listing selection, an export or a publication.
struct PhotoFeedbackControl: View {
    let version: PhotoVersionHistory.Version
    let directory: URL
    let cloudListing: Bool
    /// Values the review screen already shows. They change after its own
    /// review, selection and save actions; the control then reads saved history
    /// and records those outcomes as separate signals. Never written back.
    let listingSelected: Bool
    let exportOpened: Bool

    @ObservedObject private var queue = PhotoFeedbackQueue.shared
    @State private var saved: PhotoFeedbackStore.FeedbackRecord?
    @State private var choosingReasons = false
    @State private var reasons: Set<PhotoFeedback.Reason> = []
    @State private var note = ""
    @State private var saveFailed = false
    @State private var baseline: PhotoFeedback.LocalOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("How did this edit turn out?")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("Optional. It won't change this photo or your listing.")
                    .font(.caption).foregroundStyle(Theme.inkDim)
            }
            .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { verdictButton(.useful); verdictButton(.needsWork) }
                VStack(spacing: 8) { verdictButton(.useful); verdictButton(.needsWork) }
            }
            if choosingReasons {
                reasonPicker
            } else if let saved, saved.verdict == .needsWork {
                Text(saved.reasons.map(\.label).joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status {
                Text(status)
                    .font(.caption).foregroundStyle(saveFailed ? Theme.warn : Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("photoVersion.feedback.status")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photoVersion.feedback")
        .onAppear {
            saved = queue.savedFeedback(for: version)
            if baseline == nil {
                baseline = PhotoFeedback.localOutcome(versionID: version.id, directory: directory)?.outcome
            }
        }
        .onChange(of: queue.changeCount) { _ in saved = queue.savedFeedback(for: version) }
        .onChange(of: listingSelected) { _ in noticeReviewOutcome() }
        .onChange(of: exportOpened) { _ in noticeReviewOutcome() }
    }

    private var shownVerdict: PhotoFeedback.Verdict? { choosingReasons ? .needsWork : saved?.verdict }

    private var status: String? {
        if saveFailed { return "Your feedback couldn't be saved on this phone. Try again." }
        guard let saved, !choosingReasons else { return nil }
        if saved.delivered { return "Saved" }
        return queue.isOnline ? "Saved on this phone. Sending now." : "Saved on this phone. It will send when you're online."
    }

    private func verdictButton(_ verdict: PhotoFeedback.Verdict) -> some View {
        let selected = shownVerdict == verdict
        let useful = verdict == .useful
        return Button { choose(verdict) } label: {
            Label(useful ? "Useful" : "Needs work",
                  systemImage: (useful ? "hand.thumbsup" : "hand.thumbsdown") + (selected ? ".fill" : ""))
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(selected ? Theme.accent : Theme.ink)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? Theme.accentSoft : Theme.fillSubtle, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Theme.accent.opacity(0.3) : Theme.border))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(useful ? "Useful edit" : "Edit needs work")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(useful ? "photoVersion.feedback.useful" : "photoVersion.feedback.needsWork")
    }

    private var reasonPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("What needs work? Choose all that apply.")
                .font(.caption).foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(PhotoFeedback.Reason.allCases) { reason in
                reasonRow(reason)
            }
            TextField("Add a note (optional)", text: $note, axis: .vertical)
                .lineLimit(1...4)
                .font(.subheadline)
                .padding(10)
                .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 6)
                .accessibilityIdentifier("photoVersion.feedback.note")
                .onChange(of: note) { value in
                    if value.unicodeScalars.count > PhotoFeedback.maxNoteScalars {
                        note = String(String.UnicodeScalarView(value.unicodeScalars.prefix(PhotoFeedback.maxNoteScalars)))
                    }
                }
            PrimaryButton(title: "Save feedback", systemImage: "checkmark", isDisabled: reasons.isEmpty, isCompact: true) {
                saveNeedsWork()
            }
            .disabled(reasons.isEmpty)
            .padding(.top, 6)
            .accessibilityIdentifier("photoVersion.feedback.save")
        }
    }

    private func reasonRow(_ reason: PhotoFeedback.Reason) -> some View {
        let on = reasons.contains(reason)
        return Button {
            if on { _ = reasons.remove(reason) } else { _ = reasons.insert(reason) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(on ? Theme.accent : Theme.inkDim)
                Text(reason.label).font(.subheadline).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reason.label)
        .accessibilityValue(on ? "Selected" : "Not selected")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("photoVersion.feedback.reason." + reason.rawValue)
    }

    private func choose(_ verdict: PhotoFeedback.Verdict) {
        Haptics.selection()
        saveFailed = false
        switch verdict {
        case .useful:
            choosingReasons = false
            submit(PhotoFeedback.Draft(verdict: .useful))
        case .needsWork:
            // A second tap closes the list without saving anything.
            if choosingReasons {
                choosingReasons = false
                return
            }
            let earlier = saved?.verdict == .needsWork ? saved : nil
            reasons = Set(earlier?.reasons ?? [])
            note = earlier?.note ?? ""
            choosingReasons = true
        }
    }

    private func saveNeedsWork() {
        let draft = PhotoFeedback.Draft(verdict: .needsWork, reasons: Array(reasons), note: note)
        guard draft.isComplete else { return }
        if submit(draft) { choosingReasons = false }
    }

    @discardableResult
    private func submit(_ draft: PhotoFeedback.Draft) -> Bool {
        guard let record = queue.submit(draft, for: version) else {
            saveFailed = true
            return false
        }
        saved = record
        saveFailed = false
        return true
    }

    private func noticeReviewOutcome() {
        baseline = queue.recordLocalChanges(versionID: version.id, directory: directory, since: baseline,
                                            cloudListing: cloudListing)
    }
}
