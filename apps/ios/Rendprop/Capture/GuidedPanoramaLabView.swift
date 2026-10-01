#if SPATIAL_CAPTURE_LAB
import SwiftUI

struct GuidedPanoramaEntryCard: View {
    var body: some View {
        NavigationLink { GuidedPanoramaLabView() } label: {
            HStack(spacing: 14) {
                Image(systemName: "viewfinder.circle.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Guided room tour").font(.headline).foregroundStyle(Theme.ink)
                    Text("TestFlight · start in the center, photos save automatically").font(.subheadline).foregroundStyle(Theme.inkDim)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(Theme.accent)
            }
            .padding(16).background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border))
        }
        .accessibilityIdentifier("home.guidedRoomTour")
    }
}

struct GuidedPanoramaLabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [StationCaptureArchiveEntry] = []
    @State private var showCapture = false
    @State private var preview: PreviewPresentation?
    @State private var export: ExportPresentation?
    @State private var notice = ""
    @State private var loading = false
    @State private var pageOffset = 0
    @State private var hasMore = false
    @State private var previewCancellation: GuidedPanoramaPreviewCancellation?
    @State private var progress = 0.0
    @State private var progressMessage = ""
    @State private var exporting = false

    private struct PreviewPresentation: Identifiable {
        let id = UUID()
        let stations: [PanoramaPreviewStation]
    }
    private struct ExportPresentation: Identifiable { let id = UUID(); let url: URL }
    private var busy: Bool { previewCancellation != nil || exporting || loading }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("TESTFLIGHT ROOM TOUR").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                    Text("Capture a room.\nStep inside your photos.").font(.title2.bold()).foregroundStyle(Theme.ink)
                    Text("Look around one well-lit room first. The app can suggest a few standing spots, then capture 38 photos automatically from your chosen spot.")
                        .foregroundStyle(Theme.inkDim)
                    instructionRow("1", "Look around, then choose a spot", "Point toward the floor and around the room. Purple numbers suggest places to stand when enough floor is detected. Check that a spot and your way there are clear; you can choose your own clear center spot instead.")
                    instructionRow("2", "Let the phone take all 38 photos", "Follow the arrow and pause. Keep the lens over the same spot as you turn: walls, upper walls, lower walls, ceiling and floor. You do not tap for each photo.")
                    instructionRow("3", "Preview before moving", "You can finish after one viewpoint. Add another only for an area hidden from the first spot. Check door frames and furniture for gaps or doubled edges.")
                    Button { notice = ""; showCapture = true } label: {
                        Label("Start a room tour", systemImage: "viewfinder").frame(maxWidth: .infinity).padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent).tint(busy ? Theme.disabledFill : Theme.accent)
                    .foregroundStyle(busy ? Theme.disabledInk : .white).disabled(busy)
                    .accessibilityIdentifier("panorama.start")
                    Text("Saved on this iPhone. This test does not publish a tour or provide measurements. Keep the app open while scanning.")
                        .font(.footnote).foregroundStyle(Theme.inkDim)
                }
                .padding(18).background(Theme.card, in: RoundedRectangle(cornerRadius: 18))

                if !notice.isEmpty {
                    Text(notice).font(.subheadline).foregroundStyle(Theme.ink)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("panorama.notice")
                }
                if previewCancellation != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(progressMessage).font(.headline)
                        ProgressView(value: progress).tint(Theme.accent)
                        Text("Your original photos stay saved while this preview is prepared.").font(.footnote).foregroundStyle(Theme.inkDim)
                        Button("Cancel preview") { previewCancellation?.cancel() }
                            .accessibilityIdentifier("panorama.cancelPreview")
                    }.padding(16).background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                }
                if exporting { ProgressView("Checking saved files for export…") }
                HStack {
                    Text("Your room tours").font(.title3.bold())
                    Spacer()
                    if loading { ProgressView() }
                }
                if entries.isEmpty && !loading {
                    Text("Your saved room tours will appear here. You can close the app and open them again later.")
                        .foregroundStyle(Theme.inkDim)
                }
                ForEach(entries, id: \.url) { entry in tourCard(entry) }
                if hasMore {
                    Button("Load more saved tours") { loadTours(reset: false) }.disabled(busy)
                }
            }
            .padding(16)
        }
        .background(Theme.bg).foregroundStyle(Theme.ink)
        .navigationTitle("Room tour").navigationBarTitleDisplayMode(.inline)
        .task { loadTours(reset: true) }
        .onDisappear { previewCancellation?.cancel() }
        .onChange(of: scenePhase) { phase in if phase == .background { previewCancellation?.cancel() } }
        .fullScreenCover(isPresented: $showCapture) {
            GuidedPanoramaCamera { url, message in
                showCapture = false
                notice = message
                loadTours(reset: true, newestURL: url)
            }
            .ignoresSafeArea().interactiveDismissDisabled()
        }
        .fullScreenCover(item: $preview) { item in
            GuidedPanoramaViewer(stations: item.stations) { preview = nil }.ignoresSafeArea()
        }
        .sheet(item: $export) { item in GuidedPanoramaExport(url: item.url) }
    }

    private func instructionRow(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.headline).foregroundStyle(Theme.accent).frame(width: 25, height: 25)
                .background(Theme.accent.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.footnote).foregroundStyle(Theme.inkDim)
            }
        }
    }

    private func tourCard(_ entry: StationCaptureArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let manifest = entry.manifest {
                Text(tourDate(manifest.started_at)).font(.headline)
                if let issue = entry.issue {
                    Text(issue).font(.footnote).foregroundStyle(Theme.inkDim)
                }
                let completed = manifest.stations.filter { $0.status == .complete }.count
                let incomplete = manifest.stations.count - completed
                Text("\(completed) complete viewpoints\(incomplete > 0 ? " · \(incomplete) incomplete" : "") · \(manifest.frameCount) photos")
                    .font(.subheadline).foregroundStyle(Theme.inkDim)
                if completed == 0 && manifest.frameCount > 0 {
                    Text("No viewpoint finished all 38 photos. You can inspect these saved photos, but missing directions will be blank.")
                        .font(.footnote).foregroundStyle(Theme.inkDim)
                }
                Button { openTour(entry.url) } label: {
                    Label("Open room tour", systemImage: "pano").frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).tint(busy || manifest.frameCount == 0 ? Theme.disabledFill : Theme.accent)
                .foregroundStyle(busy || manifest.frameCount == 0 ? Theme.disabledInk : .white)
                .disabled(busy || manifest.frameCount == 0)
                .accessibilityIdentifier("panorama.openTour")
                Button { exportTour(entry.url) } label: { Label("Export scan files", systemImage: "square.and.arrow.up") }
                    .disabled(busy || manifest.frameCount == 0)
                    .accessibilityIdentifier("panorama.exportTour")
            } else {
                Text("Saved files need attention").font(.headline)
                Text(entry.issue ?? "This tour could not be opened. Its original files have been preserved.")
                    .font(.footnote).foregroundStyle(Theme.inkDim)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func tourDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return "Saved room tour" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func loadTours(reset: Bool, newestURL: URL? = nil) {
        guard !loading, !showCapture else { return }
        loading = true
        let offset = reset ? 0 : pageOffset
        GuidedPanoramaPreviewStore.queue.async {
            let result = Result { () -> ([StationCaptureArchiveEntry], Int) in
                var page = try StationCaptureArchive.listTours(offset: offset, limit: 30)
                let count = page.count
                // Only the inactive library recovers an abandoned epoch. Loading
                // disables Start; camera close returns after disk writes drain.
                page = page.map { entry in
                    guard entry.manifest?.status == .capturing else { return entry }
                    do {
                        return StationCaptureArchiveEntry(url: entry.url,
                            manifest: try StationCaptureArchive.recoverAbandonedTour(at: entry.url), issue: nil)
                    } catch {
                        return StationCaptureArchiveEntry(url: entry.url, manifest: entry.manifest,
                            issue: "Some saved files need attention. Originals are preserved. \(error.localizedDescription)")
                    }
                }
                if let newestURL, !page.contains(where: { $0.url == newestURL }),
                   let manifest = try? StationCaptureArchive.loadManifest(at: newestURL) {
                    page.insert(StationCaptureArchiveEntry(url: newestURL, manifest: manifest, issue: nil), at: 0)
                }
                return (page.sorted { ($0.manifest?.started_at ?? "") > ($1.manifest?.started_at ?? "") }, count)
            }
            DispatchQueue.main.async {
                loading = false
                switch result {
                case .success(let (page, count)):
                    if reset { entries = page } else {
                        entries += page.filter { candidate in !entries.contains(where: { $0.url == candidate.url }) }
                    }
                    pageOffset = offset + count; hasMore = count == 30
                case .failure(let error): notice = error.localizedDescription
                }
            }
        }
    }

    private func openTour(_ url: URL) {
        guard !busy else { return }
        let cancellation = GuidedPanoramaPreviewCancellation()
        previewCancellation = cancellation; progress = 0; progressMessage = "Preparing your room tour…"; notice = ""
        GuidedPanoramaPreviewStore.queue.async {
            let result = Result {
                try GuidedPanoramaPreviewStore.build(tourURL: url, cancellation: cancellation) { fraction, message in
                    DispatchQueue.main.async {
                        guard previewCancellation === cancellation else { return }
                        progress = fraction; progressMessage = message
                    }
                }
            }
            DispatchQueue.main.async {
                guard previewCancellation === cancellation else { return }
                previewCancellation = nil
                switch result {
                case .success(let stations):
                    if !cancellation.isCancelled { preview = PreviewPresentation(stations: stations) }
                case .failure(let error): notice = error.localizedDescription
                }
            }
        }
    }

    private func exportTour(_ url: URL) {
        guard !busy else { return }
        exporting = true
        GuidedPanoramaPreviewStore.queue.async {
            let result = Result { try StationCaptureArchive.validateForExport(at: url) }
            DispatchQueue.main.async {
                exporting = false
                switch result {
                case .success: export = ExportPresentation(url: url)
                case .failure(let error): notice = "Export could not be verified. Original files are preserved. \(error.localizedDescription)"
                }
            }
        }
    }
}

private struct GuidedPanoramaCamera: UIViewControllerRepresentable {
    let onClose: (URL?, String) -> Void
    func makeUIViewController(context: Context) -> GuidedPanoramaCaptureController {
        let controller = GuidedPanoramaCaptureController(); controller.onClose = onClose; return controller
    }
    func updateUIViewController(_ controller: GuidedPanoramaCaptureController, context: Context) {}
    static func dismantleUIViewController(_ controller: GuidedPanoramaCaptureController, coordinator: ()) {
        controller.endPresentation()
    }
}

private struct GuidedPanoramaViewer: UIViewControllerRepresentable {
    let stations: [PanoramaPreviewStation]
    let onClose: () -> Void
    func makeUIViewController(context: Context) -> PanoramaPreviewViewController {
        let controller = PanoramaPreviewViewController(stations: stations, tintColor: UIColor(Theme.accent))
        controller.onClose = onClose; return controller
    }
    func updateUIViewController(_ controller: PanoramaPreviewViewController, context: Context) {}
}

private struct GuidedPanoramaExport: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.shouldShowFileExtensions = true
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
#endif
