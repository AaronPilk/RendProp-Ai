#!/usr/bin/env python3
"""Run the production cloud-copy Photos callback against nullable PhotoKit requests."""

from pathlib import Path
import hashlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
source = root / "apps/ios/Rendprop/Screens/FlythroughDetailView.swift"
before = hashlib.sha256(source.read_bytes()).hexdigest()
text = source.read_text()


def block(start: str) -> str:
    offset = text.index(start)
    opening = text.index("{", offset)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (text[cursor] == "{") - (text[cursor] == "}")
        cursor += 1
    return text[offset:cursor]


receipt = block("private final class PhotoLibraryChangeReceipt:")
save = block("@MainActor static func saveCloudCopyFile(")
fixture = """import Foundation
struct NativeMediaExportContext { var isCurrent: Bool { true } }
final class PHAssetChangeRequest {
    static func creationRequestForAssetFromImage(atFileURL url: URL) -> PHAssetChangeRequest? {
        url.lastPathComponent == "accepted.jpg" ? PHAssetChangeRequest() : nil
    }
}
final class PHPhotoLibrary {
    static func shared() -> PHPhotoLibrary { PHPhotoLibrary() }
    func performChanges(_ changes: @escaping @Sendable () -> Void) async throws { changes() }
}
""" + receipt + """
enum PhotosLibrarySaver {
    struct ContextChanged: Error {}
    private static func ensureAddAccess() async throws {}
""" + save + """
}
@main struct CloudPhotoSaveTests {
    @MainActor static func main() async throws {
        let accepted = URL(fileURLWithPath: "/tmp/accepted.jpg")
        let refused = URL(fileURLWithPath: "/tmp/refused.jpg")
        try await PhotosLibrarySaver.saveCloudCopyFile(at: accepted, while: { true })
        do {
            try await PhotosLibrarySaver.saveCloudCopyFile(at: refused, while: { true })
            fatalError("Nullable PhotoKit request was reported as a saved photo")
        } catch is PhotoLibraryChangeReceipt.MissingRequest {}
        do {
            try await PhotosLibrarySaver.saveCloudCopyFile(at: accepted, while: { false })
            fatalError("Changed account was allowed to write to Photos")
        } catch is PhotosLibrarySaver.ContextChanged {}
        print("Cloud photo save: accepted request, nil request, and context fence passed")
    }
}
"""

with tempfile.TemporaryDirectory(prefix="rendprop-cloud-photo-save-") as folder:
    file = Path(folder) / "CloudPhotoSaveTests.swift"
    binary = Path(folder) / "cloud-photo-save-tests"
    file.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(file), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

assert hashlib.sha256(source.read_bytes()).hexdigest() == before, "Production source changed during test"
