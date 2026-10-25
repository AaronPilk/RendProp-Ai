import SwiftUI

/// The Home dashboard's first-project guide — "Your first <home> in five
/// steps." Progress is read straight from `FirstProjectGuide`, never set by
/// a tap here; this view only ever renders what's already true and hands
/// the resolved action for the current step (or a next win) back to
/// `onRun`, which `HomeDashboardView` wires into the SAME "which home?" gate
/// every feature tile already uses (see RendpropApp.swift).
///
/// Disappears forever once step 5 (the share link) is real
/// (`FirstProjectGuide.isHiddenForever`, latched below so a listing deleted
/// afterwards can never bring a graduated user's card back). "Hide" only
/// ever hides it for this app launch — `hiddenThisSession` is plain view
/// state, never written to disk.
struct FirstProjectCard: View {
    @EnvironmentObject var model: AppModel

    /// Run a step's or a next win's action. This view never navigates on its
    /// own — see the file header.
    var onRun: (FirstProjectGuideAction) -> Void

    @State private var hiddenThisSession = false

    private var noun: String { SpaceType.current.spaceNoun }
    private var progress: FirstProjectGuide.Progress { FirstProjectGuide.progress(model: model) }

    var body: some View {
        Group {
            if !hiddenThisSession && !progress.isFullyDone {
                cardBody
            }
        }
        .onAppear { latchIfDone() }
        .onChange(of: progress.isFullyDone) { done in if done { latchIfDone() } }
    }

    /// Permanently hides the card the moment all five steps are real —
    /// independent of `hiddenThisSession`, so finishing the guide while it's
    /// hidden for the session still latches correctly. Never runs under
    /// `-uiTesting`, so a screenshot run can't pollute a real device's flag.
    private func latchIfDone() {
        guard !Config.isUITesting, progress.isFullyDone, !FirstProjectGuide.Storage.dismissedForever else { return }
        FirstProjectGuide.Storage.dismissedForever = true
        Analytics.track("guide_completed", ["space_type": SpaceType.current.rawValue])
    }

    // MARK: - Card

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ProgressView(value: Double(progress.completedCount),
                         total: Double(FirstProjectGuideStep.allCases.count))
                .progressViewStyle(.linear)
                .tint(Theme.accent)
            VStack(spacing: 8) {
                ForEach(FirstProjectGuideStep.allCases) { step in
                    if progress.isDone(step) {
                        doneRow(step.title)
                    } else if step == progress.nextStep {
                        nextStepRow(step)
                    }
                }
            }
            if !FirstProjectGuideWin.allCases.allSatisfy({ progress.isDone($0) }) {
                Divider().overlay(Theme.border)
                winsSection
            }
        }
        .padding(Theme.spacing)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.border)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 4)
        .accessibilityIdentifier("guide.card")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your first \(noun) in five steps")
                    .font(.rpHeadline).foregroundStyle(Theme.ink)
                Text("\(progress.completedCount) of \(FirstProjectGuideStep.allCases.count)")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            Spacer()
            Button("Hide") {
                Haptics.selection()
                hiddenThisSession = true
            }
            .font(.rpCaption.weight(.semibold))
            .foregroundStyle(Theme.inkDim)
            .accessibilityLabel(Text("Hide the first \(noun) guide for now"))
        }
    }

    private func doneRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.good)
            Text(title)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
                .strikethrough()
            Spacer()
        }
    }

    private func nextStepRow(_ step: FirstProjectGuideStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(Theme.accentSoft, in: Circle())
                Text(step.title)
                    .font(.rpBody.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            PrimaryButton(title: "Do it", systemImage: "arrow.right") {
                Analytics.track("guide_step_tapped",
                                 ["step": String(step.stepNumber), "space_type": SpaceType.current.rawValue])
                onRun(FirstProjectGuide.action(for: step, model: model))
            }
            .accessibilityIdentifier("guide.doIt")
            DisclosureGroup {
                Text(step.tip)
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } label: {
                Text("Show me how")
                    .font(.rpCaption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .tint(Theme.inkDim)
        }
        .padding(12)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Next wins

    private var winsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("While you're at it")
                .font(.rpCaption.weight(.semibold))
                .foregroundStyle(Theme.inkDim)
            ForEach(FirstProjectGuideWin.allCases) { win in
                if progress.isDone(win) {
                    doneRow(win.title)
                } else {
                    winButton(win)
                }
            }
        }
    }

    private func winButton(_ win: FirstProjectGuideWin) -> some View {
        Button {
            Analytics.track("guide_step_tapped",
                             ["step": "win-\(win.rawValue)", "space_type": SpaceType.current.rawValue])
            onRun(FirstProjectGuide.action(for: win, model: model))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: win.systemImage)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(win.title).font(.rpCaption.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(win.tip).font(.caption2).foregroundStyle(Theme.inkDim).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.inkDim)
            }
        }
        .buttonStyle(ScalePressStyle())
    }
}
