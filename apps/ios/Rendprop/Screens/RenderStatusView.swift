import SwiftUI

/// Simulated render pipeline progress (MockAPIClient drives it): step labels,
/// progress, celebratory ready state → flythrough.
struct RenderStatusView: View {
    @EnvironmentObject var model: AppModel

    let listing: Listing
    @State var render: Render

    @State private var pollTask: Task<Void, Never>?

    private var steps: [String] { render.pipelineSteps }

    private var isReady: Bool { render.status == "ready" }

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
                    .animation(.easeInOut(duration: 0.4), value: render.progress)
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
                Text(isReady ? "Your flythrough is ready" : (render.status == "queued" ? "Queued…" : "\(render.status)…"))
                    .font(.rpTitle)
                Text(isReady
                     ? "Buttery. Drone-smooth. Ready to share."
                     : "\(render.tier.displayName) · \(Formatters.duration(render.durationS)) walkthrough")
                    .font(.rpBody)
                    .foregroundStyle(Theme.inkDim)
            }

            // Step timeline
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps.indices, id: \.self) { i in
                    let stepProgress = Double(i + 1) / Double(steps.count)
                    let stepDone = render.progress >= stepProgress
                    let isCurrent = !stepDone && render.progress >= Double(i) / Double(steps.count)
                    HStack(spacing: 10) {
                        Image(systemName: stepDone ? "checkmark.circle.fill" : (isCurrent ? "circle.dotted" : "circle"))
                            .foregroundStyle(stepDone ? Theme.good : (isCurrent ? Theme.accent : Theme.inkDim))
                        Text(steps[i])
                            .font(.rpBody)
                            .foregroundStyle(stepDone || isCurrent ? Theme.ink : Theme.inkDim)
                        Spacer()
                    }
                }
            }
            .card()
            .padding(.horizontal)

            Spacer()

            if isReady {
                NavigationLink {
                    FlythroughDetailView(listing: listing)
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("View flythrough").fontWeight(.semibold)
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
        .navigationTitle("Render")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!isReady)
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                if let updated = try? await model.api.renderStatus(id: render.id) {
                    await MainActor.run {
                        render = updated
                        if updated.status == "ready" {
                            model.setStatus(.ready, for: listing.id)
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
