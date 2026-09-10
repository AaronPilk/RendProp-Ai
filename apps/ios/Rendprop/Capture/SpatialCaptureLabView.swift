#if SPATIAL_CAPTURE_LAB
import SwiftUI

// Available only in the explicit spatial TestFlight overlay. This wrapper adds
// no account, purchase, network, analytics, or simulated-camera behavior.
struct SpatialCaptureLabView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presentation = SpatialCaptureLabPresentation()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Experimental Phase A · Saves room photos and measured camera poses on this iPhone. No upload or 3D model is generated here. Leaving stops capture and keeps partial files.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                    .accessibilityIdentifier("spatial.lab.description")
                SpatialCaptureLabController(controller: presentation.controller)
            }
            .navigationTitle("Spatial capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        // Tear down synchronously, before the dismissal animation.
                        presentation.controller.endPresentation()
                        dismiss()
                    }
                    .accessibilityIdentifier("spatial.done")
                }
            }
        }
        // A labelled exit is always available, including during permission or
        // recording. Avoid an interactive gesture racing the permission callback.
        .interactiveDismissDisabled()
    }
}

@MainActor
private final class SpatialCaptureLabPresentation: ObservableObject {
    let controller = SpatialCaptureViewController()
}

private struct SpatialCaptureLabController: UIViewControllerRepresentable {
    let controller: SpatialCaptureViewController

    func makeUIViewController(context: Context) -> SpatialCaptureViewController { controller }
    func updateUIViewController(_ uiViewController: SpatialCaptureViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: SpatialCaptureViewController, coordinator: ()) {
        // Also covers parent navigation/programmatic removal, not just Done.
        uiViewController.endPresentation()
    }
}
#endif
