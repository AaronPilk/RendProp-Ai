import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// Import from Photos (PHPicker) and Files (drone exports) — always via file
/// URLs copied into the app container. Never loads video into memory.
///
/// API (callers: NewListingView / AddVideoFlowView, CaptureView):
///   • `probe(url:)`                      — duration / fps / ORIENTED width+height / drone hint.
///   • `makeAsset(from:isDrone:deleteOnFailure:) throws -> CaptureAsset`
///                                        — validates the file (see `ImportError`) and
///                                          builds the asset. `isDrone: nil` = use the
///                                          metadata heuristic (`looksLikeDrone`).
///                                          Throws `ImportError` (LocalizedError) — show
///                                          `error.localizedDescription` in an alert.
///   • `excludeFromBackup(_:)`            — `isExcludedFromBackup` on a media directory.
enum MediaImporter {
    /// Sources longer than this are refused at import (and by RenderEngine),
    /// so the user hears it before a render, not after twenty minutes.
    static let maxDurationSeconds: Double = 600
    /// Anything shorter is a tap, not a walkthrough.
    static let minDurationSeconds: Double = 0.2

    struct ProbeResult {
        var duration: Double = 0
        var fps: Double = 0
        /// Oriented (display) dimensions — a portrait phone clip reports
        /// 2160×3840 here even though its encoded frame is 3840×2160.
        var width: Int = 0
        var height: Int = 0
        var hasVideoTrack = false
        var isPlayable = true
        /// Capture-device make/model metadata names a drone maker (DJI, Autel,
        /// Skydio, Parrot…). Prefills the Review screen's handheld/drone choice.
        var looksLikeDrone = false
    }

    /// Why an import was refused. `errorDescription` is the user-facing sentence.
    enum ImportError: LocalizedError, Equatable {
        case unreadable
        case noVideoTrack
        case tooShort(Double)
        case tooLong(Double)
        case badDimensions
        case notPlayable
        case copyFailed

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "This file couldn't be read. Try exporting it again or choose a different video."
            case .noVideoTrack:
                return "This file has no video track — it might be audio-only or an unsupported format."
            case .tooShort(let s):
                return "This video is only \(String(format: "%.1f", s)) s long — that's a tap, not a walkthrough. Choose a longer clip."
            case .tooLong(let s):
                let minutes = Int(s / 60), seconds = Int(s) % 60
                return "This video is \(minutes):\(String(format: "%02d", seconds)) long. Tours work best under \(Int(MediaImporter.maxDurationSeconds / 60)) minutes — trim it and try again."
            case .badDimensions:
                return "This video reports no picture size, so it can't be rendered. Try re-exporting it."
            case .notPlayable:
                return "This video format isn't supported on this iPhone. Export it as H.264 or HEVC (MP4/MOV) and try again."
            case .copyFailed:
                return "The video couldn't be copied into Rendprop. Check free storage and try again."
            }
        }
    }

    /// Async metadata probe (duration/fps/dimensions) without decoding frames.
    static func probe(url: URL) async -> ProbeResult {
        var result = ProbeResult()
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            result.duration = duration.seconds.isFinite ? duration.seconds : 0
        }
        if let playable = try? await asset.load(.isPlayable) {
            result.isPlayable = playable
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            result.hasVideoTrack = true
            if let fps = try? await track.load(.nominalFrameRate) {
                result.fps = Double(fps)
            }
            if let size = try? await track.load(.naturalSize) {
                // Orient by the preferred transform so portrait clips come out
                // portrait (the Review screen and CaptureAsset.resolutionLabel
                // show these numbers).
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let oriented = CGRect(origin: .zero, size: size).applying(transform)
                result.width = Int(abs(oriented.width).rounded())
                result.height = Int(abs(oriented.height).rounded())
            }
        }
        result.looksLikeDrone = await looksLikeDrone(asset)
        return result
    }

    /// DJI / Autel / Skydio / Parrot / Insta360… in the make/model/software
    /// metadata → almost certainly aerial footage (decision A8 heuristic).
    static func looksLikeDrone(_ asset: AVAsset) async -> Bool {
        let makers = ["dji", "autel", "skydio", "parrot", "hubsan", "yuneec", "holy stone", "potensic"]
        guard let items = try? await asset.load(.metadata) else { return false }
        for item in items {
            let rawKey = (item.key as? NSString).map { String($0) } ?? ""
            let key = (item.commonKey?.rawValue ?? "") + " " + rawKey + " " + (item.identifier?.rawValue ?? "")
            let lowerKey = key.lowercased()
            guard lowerKey.contains("make") || lowerKey.contains("model")
                    || lowerKey.contains("software") || lowerKey.contains("encoder") else { continue }
            guard let value = try? await item.load(.stringValue) else { continue }
            let lower = value.lowercased()
            if makers.contains(where: { lower.contains($0) }) { return true }
        }
        return false
    }

    /// Build a validated CaptureAsset from a file URL inside the app container.
    /// Rejects unreadable, video-less, too-short, too-long, zero-size or
    /// unplayable files with a specific `ImportError`; when `deleteOnFailure`
    /// is true (imports — the URL is our own copy) the file is removed first so
    /// a rejected import never lingers in Documents.
    /// `isDrone == nil` → the metadata heuristic decides (the user can still
    /// flip it on Review & Submit).
    static func makeAsset(from url: URL, isDrone: Bool?, deleteOnFailure: Bool = true) async throws -> CaptureAsset {
        let probe = await probe(url: url)
        do {
            try validate(probe, at: url)
        } catch {
            if deleteOnFailure { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return CaptureAsset(localURL: url,
                            motionSidecarURL: nil,
                            durationS: probe.duration,
                            fps: probe.fps,
                            width: probe.width,
                            height: probe.height,
                            bytes: FileStore.fileSize(url),
                            isDrone: isDrone ?? probe.looksLikeDrone)
    }

    private static func validate(_ probe: ProbeResult, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path), FileStore.fileSize(url) > 0 else {
            throw ImportError.unreadable
        }
        guard probe.hasVideoTrack else { throw ImportError.noVideoTrack }
        guard probe.duration > 0 else { throw ImportError.unreadable }
        guard probe.duration >= minDurationSeconds else { throw ImportError.tooShort(probe.duration) }
        guard probe.duration <= maxDurationSeconds else { throw ImportError.tooLong(probe.duration) }
        guard probe.width > 0, probe.height > 0 else { throw ImportError.badDimensions }
        guard probe.isPlayable else { throw ImportError.notPlayable }
    }

    /// Raw captures/imports are multi-GB and re-creatable — keep them out of
    /// iCloud/iTunes backups (audit F-D-19). Safe to call repeatedly.
    static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// `import-<uuid8>-<original name>` inside Imports — unique per import so
    /// two files with the same name never overwrite each other (audit F-D-08).
    static func uniqueImportURL(originalName: String) -> URL {
        excludeFromBackup(FileStore.importsDir)
        let safeName = originalName.isEmpty ? "video.mov" : originalName
        return FileStore.importsDir
            .appendingPathComponent("import-\(UUID().uuidString.prefix(8))-\(safeName)")
    }
}

// MARK: - Photos picker (videos only, file representation)
struct PhotoVideoPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    /// Import progress 0…1 while Photos exports/downloads the file (a 4K or
    /// iCloud video can take a while — without this the UI looks frozen).
    /// Called on the main thread.
    var onProgress: ((Double) -> Void)? = nil
    /// Called on the main thread when the import fails, so the UI can reset.
    var onFailed: (() -> Void)? = nil
    /// Same moment as `onFailed`, with the provider's own error text (when it
    /// gave one) so the alert can say more than "try again".
    var onFailedWithMessage: ((String?) -> Void)? = nil

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        // `.current` hands over the file as stored — no silent transcode of a
        // 4K HEVC/HDR clip to a smaller H.264 (audit F-D-29).
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onProgress: onProgress,
                    onFailed: onFailed, onFailedWithMessage: onFailedWithMessage)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (URL) -> Void
        let onProgress: ((Double) -> Void)?
        let onFailed: (() -> Void)?
        let onFailedWithMessage: ((String?) -> Void)?
        private var progressObservation: NSKeyValueObservation?
        /// Main-thread flag: once finished, late progress callbacks are dropped
        /// so a straggler can't resurrect the progress UI.
        private var isFinished = false

        init(onPicked: @escaping (URL) -> Void,
             onProgress: ((Double) -> Void)?,
             onFailed: (() -> Void)?,
             onFailedWithMessage: ((String?) -> Void)?) {
            self.onPicked = onPicked
            self.onProgress = onProgress
            self.onFailed = onFailed
            self.onFailedWithMessage = onFailedWithMessage
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else { return }

            onProgress?(0)   // delegate runs on main — show the import UI immediately

            // loadFileRepresentation streams to a temp file — no memory spike.
            // Its returned Progress covers the Photos export (and any iCloud
            // download), which is the long silent part for big 4K videos.
            let progress = provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                var copied: URL?
                if let url {
                    let dest = MediaImporter.uniqueImportURL(originalName: url.lastPathComponent)
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        copied = dest
                    } catch {
                        // Temp file vanished or copy failed — fall through; user retries.
                    }
                }
                let message = error?.localizedDescription
                DispatchQueue.main.async {
                    self.isFinished = true
                    self.progressObservation = nil
                    if let copied {
                        self.onPicked(copied)
                    } else {
                        self.onFailedWithMessage?(message)
                        self.onFailed?()
                    }
                }
            }
            progressObservation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] prog, _ in
                let fraction = prog.fractionCompleted
                DispatchQueue.main.async {
                    guard let self, !self.isFinished else { return }
                    self.onProgress?(fraction)
                }
            }
        }
    }
}

// MARK: - Files picker (drone clips, AirDrop, iCloud Drive), asCopy = sandbox-safe copy
struct FilesVideoPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    /// Called on the main thread when the picked file couldn't be moved into
    /// the app container (message is user-facing).
    var onFailed: ((String) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.movie], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked, onFailed: onFailed) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        let onFailed: ((String) -> Void)?
        init(onPicked: @escaping (URL) -> Void, onFailed: ((String) -> Void)?) {
            self.onPicked = onPicked
            self.onFailed = onFailed
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            // asCopy:true already copied it to our sandbox; move into Imports
            // under a UNIQUE name — two "DJI_0001.MP4" imports used to clobber
            // each other (and another listing's raw video with it).
            let dest = MediaImporter.uniqueImportURL(originalName: url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                onPicked(dest)
            } catch {
                // The picker's own copy is in a tmp inbox that iOS may purge;
                // try a plain copy before giving up.
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    onPicked(dest)
                } else {
                    onFailed?(MediaImporter.ImportError.copyFailed.localizedDescription)
                }
            }
        }
    }
}
