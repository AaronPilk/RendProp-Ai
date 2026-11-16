#!/usr/bin/env python3
"""Closed native backup/restore acceptance plus exact source-byte admission."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
source = (root / "apps/ios/Rendprop/Upload/DirectUploader.swift").read_text()

def block(marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError("unclosed actual uploader method: " + marker)

parts = [block(marker) for marker in (
    "    enum BrowserPhotoFailure:",
    "    struct BrowserPhoto:",
    "    static func browserPhoto(",
    "    static func retainedPhoto(",
    "    private static func measuredPhoto(",
)]

with tempfile.TemporaryDirectory(prefix="rendprop-native-backup-") as temp:
    test_dir = Path(temp)
    admission = test_dir / "ActualPrivatePhotoAdmission.swift"
    admission.write_text('''import Foundation
import CryptoKit
import Darwin
enum DirectUploader {
''' + "\n".join(parts) + '''
}
@main struct ActualPrivatePhotoAdmission {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let heic = root.appendingPathComponent("orig-with-legacy-name.jpg")
        let exact = Data([0, 0, 0, 0] + Array("ftypheic".utf8) + [1, 2, 3])
        try exact.write(to: heic)
        let descriptor = try DirectUploader.retainedPhoto(heic)
        precondition(descriptor.contentType == "image/heic" && descriptor.bytes == Int64(exact.count))
        precondition(descriptor.sha256 == SHA256.hash(data: exact).map { String(format: "%02x", $0) }.joined())
        do { _ = try DirectUploader.browserPhoto(heic); preconditionFailure("HEIC admitted for public browser gallery") }
        catch DirectUploader.BrowserPhotoFailure.unsupportedFormat {}
        let heif = root.appendingPathComponent("orig-heif.jpg")
        try Data([0, 0, 0, 0] + Array("ftypmif1".utf8) + [1]).write(to: heif)
        let heifDescriptor = try DirectUploader.retainedPhoto(heif)
        precondition(heifDescriptor.contentType == "image/heif")
        let tooLarge = root.appendingPathComponent("large.jpg")
        FileManager.default.createFile(atPath: tooLarge.path, contents: Data([0xff, 0xd8, 0xff]))
        let handle = try FileHandle(forWritingTo: tooLarge)
        try handle.truncate(atOffset: 50 * 1024 * 1024 + 1)
        try handle.close()
        do { _ = try DirectUploader.retainedPhoto(tooLarge); preconditionFailure("over-50-MiB private photo admitted") }
        catch DirectUploader.BrowserPhotoFailure.unsupportedFormat {}
        let link = root.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: heic)
        do { _ = try DirectUploader.retainedPhoto(link); preconditionFailure("symlink followed") }
        catch DirectUploader.BrowserPhotoFailure.unsupportedFormat {}
        print("actual private byte admission PASS")
    }
}
''')
    output = test_dir / "admission"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(admission), "-o", str(output)], check=True)
    subprocess.run([str(output), str(test_dir)], check=True)
    output = test_dir / "backup-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                    str(root / "apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift"),
                    str(root / "apps/ios/Rendprop/Photos/PhotoVersionHistory.swift"),
                    str(root / "apps/ios/Rendprop/Photos/NativePhotoBackup.swift"),
                    str(root / "apps/ios/tests/NativePhotoBackupTests.swift"),
                    "-o", str(output)], check=True)
    subprocess.run([str(output)], check=True)
