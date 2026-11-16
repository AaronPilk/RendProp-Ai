import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// Ordinary library imports are unlimited, ordered and file-backed. The
/// explicit one-photo initializer remains available for an aerial reference.
struct LibraryImagePicker: UIViewControllerRepresentable {
    var selectionLimit: Int
    private let onPicked: (([UIImage]) -> Void)?
    private let onImport: ((PhotoImportBatch) -> Void)?
    private let onBegin: ((UUID, Int, PhotoImportCancellation) -> Bool)?
    private let onProgress: ((UUID, Int, Int) -> Void)?
    private let onCancel: (() -> Void)?
    private let onFailed: ((String) -> Void)?

    init(selectionLimit: Int, onFailed: ((String) -> Void)? = nil,
         onPicked: @escaping ([UIImage]) -> Void) {
        precondition(selectionLimit == 1, "Multi-photo imports must use the file-backed initializer")
        self.selectionLimit = selectionLimit; self.onPicked = onPicked
        onImport = nil; onBegin = nil; onProgress = nil; onCancel = nil; self.onFailed = onFailed
    }

    init(onBegin: @escaping (UUID, Int, PhotoImportCancellation) -> Bool,
         onProgress: @escaping (UUID, Int, Int) -> Void,
         onCancel: @escaping () -> Void,
         onImport: @escaping (PhotoImportBatch) -> Void) {
        selectionLimit = 0; onPicked = nil; onFailed = nil
        self.onBegin = onBegin; self.onProgress = onProgress; self.onCancel = onCancel; self.onImport = onImport
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = selectionLimit
        config.selection = .ordered
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let callbacks: LibraryImagePicker
        init(_ callbacks: LibraryImagePicker) { self.callbacks = callbacks }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let id = UUID(), cancellation = PhotoImportCancellation()
            let context = PhotoImportContext(owner: AuthStore.shared.userID,
                revision: AuthStore.shared.syncSessionRevision, workspace: WorkspaceContext.selectedOrgID)
            guard !results.isEmpty else { callbacks.onCancel?(); callbacks.onPicked?([]); return }
            if let onBegin = callbacks.onBegin, !onBegin(id, results.count, cancellation) { return }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Rendprop-photo-import-\(id.uuidString)", isDirectory: true)
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch {
                let failures = results.indices.map { PhotoImportFailure(position: $0, message: "Couldn't prepare photo import storage. Free some space and try again.") }
                finish(PhotoImportBatch(id: id, requestedCount: results.count, items: [], failures: failures,
                    directory: nil, context: context, cancellation: cancellation))
                return
            }
            PhotoImportSerialLoader.start(count: results.count, cancellation: cancellation, load: { position, complete in
                Task { @MainActor in
                    guard context.matches(owner: AuthStore.shared.userID,
                        revision: AuthStore.shared.syncSessionRevision, workspace: WorkspaceContext.selectedOrgID) else {
                        complete(.failure(CancellationError())); return
                    }
                    let provider = results[position].itemProvider
                    guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
                        complete(.failure(Self.failure("Photos couldn't provide this image file. Try exporting it from Photos first."))); return
                    }
                    provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                        guard let url else {
                            complete(.failure(error ?? Self.failure("This photo couldn't be downloaded from Photos or iCloud. Try again when it is available."))); return
                        }
                        // The provider's URL expires as this callback returns.
                        // Copy bytes now; decoding waits for serial ingestion.
                        let ext = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "image") : url.pathExtension
                        let saved = directory.appendingPathComponent("\(position).\(ext)")
                        do {
                            try FileManager.default.copyItem(at: url, to: saved)
                            complete(.success(saved))
                        } catch { complete(.failure(Self.failure("Couldn't copy this photo. Free some space and try again."))) }
                    }
                }
            }, progress: { completed in
                Task { @MainActor in self.callbacks.onProgress?(id, completed, results.count) }
            }, completion: { items, failures in
                let batch = PhotoImportBatch(id: id, requestedCount: results.count, items: items, failures: failures,
                    directory: directory, context: context, cancellation: cancellation)
                Task { @MainActor in self.finish(batch) }
            })
        }

        nonisolated private static func failure(_ message: String) -> NSError {
            NSError(domain: "RendpropPhotoImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        private func finish(_ batch: PhotoImportBatch) {
            if let onImport = callbacks.onImport { onImport(batch); return }
            // This compatibility path is used only by the one-photo exterior
            // selector. Ordinary imports never accumulate full-size images here.
            guard batch.context.matches(owner: AuthStore.shared.userID,
                revision: AuthStore.shared.syncSessionRevision, workspace: WorkspaceContext.selectedOrgID) else {
                batch.removeTemporaryFiles(); callbacks.onFailed?("The account or workspace changed. Choose the photo again."); return
            }
            var images: [UIImage] = [], failures = batch.failures
            for item in batch.items {
                if let image = UIImage(contentsOfFile: item.url.path) { images.append(image) }
                else { failures.append(PhotoImportFailure(position: item.position, message: "This photo couldn't be decoded. Choose another image.")) }
            }
            batch.removeTemporaryFiles()
            if let message = PhotoImportReport(requestedCount: batch.requestedCount,
                savedPositions: batch.items.filter { item in !failures.contains { $0.position == item.position } }.map(\.position),
                failures: failures).message { callbacks.onFailed?(message) }
            callbacks.onPicked?(images)
        }
    }
}
