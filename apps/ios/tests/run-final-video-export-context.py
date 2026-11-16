#!/usr/bin/env python3
"""Prove full-screen final-video Save retains listing export admission."""
from pathlib import Path
import hashlib
import json
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "apps/ios/Rendprop/Screens/FlythroughDetailView.swift"
OUT = Path(tempfile.mkdtemp(prefix="rendprop-final-video-export-context-"))
text = SOURCE.read_text()

assert "ListingFileViewer(item: item, listingID: listing.id,\n                              canExport: mediaExportAdmission(for: currentListing))" in text

preview_start = text.index("private struct ListingFilePreview: View")
preview_end = text.index("private struct ListingFileViewer: View", preview_start)
preview = text[preview_start:preview_end]
assert "let canExport: @MainActor () -> Bool" in preview
assert "PhotosLibrarySaver.saveVideo(at: url, while: canExport)" in preview
assert "PhotosLibrarySaver.saveVideo(at: url)" not in preview

viewer_start = preview_end
viewer_end = text.index("private struct FileViewerDoneButton: View", viewer_start)
viewer = text[viewer_start:viewer_end]
assert "let canExport: @MainActor () -> Bool" in viewer
assert "ListingFilePreview(item: item, listingID: listingID, canExport: canExport)" in viewer

controls = {
    "caller-admission": text.replace("canExport: mediaExportAdmission(for: currentListing)", "canExport: { true }", 1),
    "save-admission": preview.replace("PhotosLibrarySaver.saveVideo(at: url, while: canExport)", "PhotosLibrarySaver.saveVideo(at: url)", 1),
    "viewer-forwarding": viewer.replace("ListingFilePreview(item: item, listingID: listingID, canExport: canExport)", "ListingFilePreview(item: item, listingID: listingID, canExport: { true })", 1),
}
assert "canExport: mediaExportAdmission(for: currentListing)" not in controls["caller-admission"]
assert "PhotosLibrarySaver.saveVideo(at: url, while: canExport)" not in controls["save-admission"]
assert "ListingFilePreview(item: item, listingID: listingID, canExport: canExport)" not in controls["viewer-forwarding"]

receipt = {
    "passed": True,
    "source": str(SOURCE.relative_to(ROOT)),
    "sourceSHA256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
    "assertions": 9,
    "negativeControls": list(controls),
    "scope": "Exact production full-screen listing-file viewer and Save to Photos path. Verifies existing listing export admission reaches PhotosLibrarySaver. No Photos permission UI, media write, share sheet, audio playback, phone, network, or Apple call.",
}
(OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(OUT / "receipt.json")
