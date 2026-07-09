import SwiftUI

/// Render progress. Real listings run the ON-DEVICE render engine (retime →
/// 60fps → scrub-ready encode). Sample listings simulate.
struct RenderStatusView: View {
    @EnvironmentObject var model: AppModel

    let listing: Listing
    @State var render: Render

    @State private var pollTask: Task<Void, Never>?
    @State private var phaseLabel = "Queued…"
    @State private var isReady = false
    @State private var failureMessage: String?

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Theme.fillSubtle, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(render.progress))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: render.progress)
                if isReady {
                    Image(systemName: "checkmark")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Theme.good)
                } else {
                    Text(render.progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .frame(width: 150, height: 150)

            VStack(spacing: 6) {
                Text(isReady ? "Your tour is ready" : (failureMessage ?? phaseLabel))
                    .font(.rpTitle)
                    .multilineTextAlignment(.center)
                Text(isReady
                     ? "Smooth, fast, and ready to fly through."
                     : "\(render.tier.displayName) · \(Formatters.duration(render.durationS)) walkthrough")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
            }
            .padding(.horizontal)

            if !isReady && failureMessage == nil {
                Text("Keep the app open — this runs right on your phone.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }

            Spacer()

            if isReady {
                NavigationLink {
                    FlythroughDetailView(listing: listing)
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("View my tour").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.accent)
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal)
                .padding(.bottom, 18)
            }
        }
        .background(Theme.bg)
        .navigationTitle("Creating Tour")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!isReady && failureMessage == nil)
        .onAppear { start() }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Drive

    private func start() {
        if let asset = model.assets[listing.id] {
            runRealRender(asset: asset)
        } else {
            runSimulation()   // sample listings only
        }
    }

    private func runRealRender(asset: CaptureAsset) {
        pollTask?.cancel()
        pollTask = Task {
            do {
                let output = try await RenderEngine.render(asset: asset) { p, label in
                    Task { @MainActor in
                        render.progress = p
                        phaseLabel = label
                    }
                }
                await MainActor.run {
                    model.tours[listing.id] = AppModel.RenderedTour(url: output.url,
                                                                    durationS: output.durationS,
                                                                    speedFactor: output.speedFactor)
                    model.setStatus(.ready, for: listing.id)
                    render.progress = 1.0
                    isReady = true
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    failureMessage = error.localizedDescription
                    render.progress = 0
                }
            }
        }
    }

    private func runSimulation() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                if let updated = try? await model.api.renderStatus(id: render.id) {
                    await MainActor.run {
                        render = updated
                        phaseLabel = updated.status == "queued" ? "Queued…" : "\(updated.status)…"
                        if updated.status == "ready" {
                            model.setStatus(.ready, for: listing.id)
                            isReady = true
                            Haptics.success()
                        }
                    }
                    if updated.status == "ready" { break }
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }
}
