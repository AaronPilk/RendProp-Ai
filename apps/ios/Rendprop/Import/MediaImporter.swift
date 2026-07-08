import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// Import from Photos (PHPicker) and Files (drone exports) — always via file
/// URLs copied into the app container. Never loads video into memory.
enum MediaImporter {
    struct ProbeResult {
        var duration: Double = 0
        var fps: Double = 0
        var width: Int = 0
        var height: Int = 0
    }

    /// Async metadata probe (duration/fps/dimensions) without decoding frames.
    static func probe(url: URL) async -> ProbeResult {
        var result = ProbeResult()
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            result.duration = duration.seconds.isFinite ? duration.seconds : 0
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let fps = try? await track.load(.nominalFrameRate) {
                result.fps = Double(fps)
            }
            if let size = try? await track.load(.naturalSize) {
                result.width = Int(abs(size.width))
                result.height = Int(abs(size.height))
            }
        }
        return result
    }

    /// Build a CaptureAsset from an imported file URL.
    static func makeAsset(from url: URL, isDrone: Bool) async -> CaptureAsset {
        let probe = await probe(url: url)
        return CaptureAsset(localURL: url,
                            motionSidecarURL: nil,
                            durationS: probe.duration,
                            fps: probe.fps,
                            width: probe.width,
                            height: probe.height,
                            bytes: FileStore.fileSize(url),
                            isDrone: isDrone)
    }
}

// MARK: - Photos picker (videos only, file representation)
struct PhotoVideoPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else { return }

            // loadFileRepresentation streams to a temp file — no memory spike.
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url else { return }
                let dest = FileStore.importsDir
                    .appendingPathComponent("import-\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    DispatchQueue.main.async { self.onPicked(dest) }
                } catch {
                    // Temp file vanished or copy failed — surface nothing; user retries.
                }
            }
        }
    }
}

// MARK: - Files picker (drone clips), asCopy = sandbox-safe copy
struct FilesVideoPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.movie], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            // asCopy:true already copied it to our sandbox; move into Imports.
            let dest = FileStore.importsDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                onPicked(dest)
            } catch {
                onPicked(url) // fall back to the picker's copy location
            }
        }
    }
}
