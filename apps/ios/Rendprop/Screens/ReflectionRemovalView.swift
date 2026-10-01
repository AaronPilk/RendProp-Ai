import SwiftUI
import AVKit

struct ReflectionRemovalView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: ReflectionRemoval
    let listing: Listing
    var onAccepted: (CaptureAsset) -> Void
    @State private var clips: [ReflectionClip] = []
    @State private var selected: Set<UUID> = []
    @State private var showOriginal = false
    @State private var player: AVPlayer?

    private var chosen: [ReflectionClip] { clips.filter { selected.contains($0.id) } }
    private var seconds: Double { chosen.reduce(0) { $0 + $1.durationS } }
    private var canStart: Bool {
        guard let quote = controller.quote, quote.available else { return false }
        return !chosen.isEmpty && chosen.count <= quote.remainingClips && seconds <= quote.maximumSeconds
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    if controller.accountMatches {
                        Text("Remove people and reflections")
                            .font(.rpHeadline).foregroundStyle(Theme.ink)
                        Text("AI edits only the intervals you choose. Your complete original stays saved. Detection can miss people, so check the video yourself too.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim)
                        if controller.canPreview {
                            preview
                        } else if controller.work?.cancellationRequested == true && controller.work?.cancellationConfirmed != true {
                            Text("Cancellation is waiting for a connection. No new edit will start.")
                            PrimaryButton(title: "Retry cancellation", systemImage: "arrow.clockwise", isDisabled: controller.isBusy) {
                                controller.cancel(model: model)
                            }
                        } else if controller.work == nil || controller.work?.cancellationConfirmed == true {
                            intervalPicker
                        } else if !controller.isBusy {
                            PrimaryButton(title: "Continue saved edit", systemImage: "arrow.clockwise") {
                                controller.start(clips: chosen, model: model, listing: listing)
                            }
                            Text("Continues the same jobs. It does not submit another paid pass.")
                                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        }
                        if controller.isBusy {
                            ProgressView().tint(Theme.accent)
                        }
                        if !controller.message.isEmpty {
                            Text(controller.message).font(.rpBody).foregroundStyle(Theme.inkDim)
                        }
                        if let error = controller.error {
                            Text(error).font(.rpBody).foregroundStyle(Theme.warn)
                        }
                        if controller.work != nil && controller.work?.applied != true && controller.work?.cancellationConfirmed != true {
                            Button("Cancel edit and keep original") { controller.cancel(model: model) }
                                .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
                                .disabled(controller.work?.cancellationRequested == true && controller.isBusy)
                        }
                        ShareLink(item: controller.source.localURL) {
                            Label("Export original video", systemImage: "square.and.arrow.up")
                        }
                        .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
                    } else {
                        Text("Sign back in to the account that owns this recording to continue.")
                            .font(.rpBody).foregroundStyle(Theme.ink)
                    }
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Reflection removal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                if clips.isEmpty {
                    clips = ReflectionVideo.plan(ranges: controller.source.personVisibleRanges, duration: controller.source.durationS)
                    selected = Set(clips.map(\.id))
                }
                await controller.loadQuote(model: model, listing: listing)
                refreshPlayer()
            }
            .onChange(of: controller.resultURL) { _ in refreshPlayer() }
            .onChange(of: showOriginal) { _ in refreshPlayer() }
            .onChange(of: controller.accountMatches) { _ in refreshPlayer() }
            .onDisappear { player?.pause() }
        }
    }

    private var intervalPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose intervals to edit").font(.rpHeadline)
            ForEach(clips) { clip in
                Toggle(isOn: Binding(get: { selected.contains(clip.id) }, set: { value in
                    if value { selected.insert(clip.id) } else { selected.remove(clip.id) }
                })) {
                    Text("\(Formatters.duration(clip.startS))–\(Formatters.duration(clip.endS)) · \(String(format: "%.1f", clip.durationS)) seconds")
                        .font(.rpBody)
                }
                .tint(Theme.accent)
            }
            Text("\(String(format: "%.1f", seconds)) seconds selected · Uses \(chosen.count) AI clip\(chosen.count == 1 ? "" : "s") from your plan.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            if let quote = controller.quote {
                Text("\(quote.remainingClips) AI clips available. Up to \(String(format: "%.1f", quote.maximumSeconds)) seconds per edit.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                if !canStart && !chosen.isEmpty {
                    Text("Deselect some intervals to fit the available allowance.")
                        .font(.rpCaption).foregroundStyle(Theme.warn)
                }
            } else {
                Button("Check available AI clips") {
                    Task { await controller.loadQuote(model: model, listing: listing) }
                }
            }
            PrimaryButton(title: "Remove from selected intervals", systemImage: "person.crop.rectangle.badge.xmark",
                          isDisabled: !canStart || controller.isBusy) {
                controller.start(clips: chosen, model: model, listing: listing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Version", selection: $showOriginal) {
                Text("Edited").tag(false)
                Text("Original").tag(true)
            }.pickerStyle(.segmented)
            if let player {
                VideoPlayer(player: player).frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text("Watch the edited intervals and check the surrounding details. Accepting saves both videos online and links the unedited original in your tour's AI disclosure. Anyone with that link can view the original.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            if let disclosure = controller.work?.disclosure {
                Text(disclosure).font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            PrimaryButton(title: controller.work?.applied == true ? "Use saved edit" : "Accept edited video",
                          systemImage: "checkmark.circle", isDisabled: controller.isBusy) {
                controller.accept(model: model) { asset in
                    onAccepted(asset)
                    dismiss()
                }
            }
        }
    }

    private func refreshPlayer() {
        let position = player?.currentTime() ?? .zero
        player?.pause()
        guard controller.accountMatches else {
            player = nil
            return
        }
        let url = showOriginal ? controller.source.localURL : controller.resultURL ?? controller.source.localURL
        player = AVPlayer(url: url)
        player?.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
