#!/usr/bin/env python3
"""Execute the shipped photos-first transition with an in-memory model boundary."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile
from run import ROOT, block


def main():
    target = ROOT / "apps/ios/Rendprop/Screens/NewListingView.swift"
    parser = argparse.ArgumentParser()
    parser.add_argument('--revision', help='Reproduce defects at Git revision; omit to test the repaired checkout')
    args = parser.parse_args()
    source_text = subprocess.check_output(['git', 'show', f'{args.revision}:{target.relative_to(ROOT)}'], cwd=ROOT, text=True) if args.revision else target.read_text()
    actual = block(source_text, "    private func startWithPhotos()")
    out = Path(tempfile.mkdtemp(prefix="rendprop-call-photos-first-"))
    code = r'''
import Foundation
struct Coordinate { var latitude: Double; var longitude: Double }
struct Listing { var id = UUID(); var address: String; var latitude: Double?; var longitude: Double? }
struct Form {
    var address = ""
    var isValid: Bool { !address.isEmpty }
    func apply(to listing: inout Listing) { listing.address = address }
    func makeListing(coordinate: Coordinate?) -> Listing {
        Listing(address: address, latitude: coordinate?.latitude, longitude: coordinate?.longitude)
    }
}
final class Model {
    var listings: [Listing] = []
    func add(_ listing: Listing) { listings.append(listing) }
    func modify(_ id: UUID, sync: Bool, _ mutation: (inout Listing) -> Void) {
        if let i = listings.firstIndex(where: { $0.id == id }) { mutation(&listings[i]) }
    }
}
enum SpaceType: String { case realEstate; static let current = SpaceType.realEstate }
enum Analytics { static func track(_ name: String, _ attributes: [String: String]) {} }
enum Haptics { static func selection() {} }
final class Flow {
    let model = Model()
    var form = Form()
    var addressFocused = false
    var photosListing: Listing?
    var createdListing: Listing?
    var goToPhotos = false
    var pendingCoord: Coordinate?
__ACTUAL__
    func tap() { startWithPhotos() }
}
@main struct Checks {
    static func main() throws {
        let flow = Flow()
        flow.tap()
        precondition(flow.addressFocused && flow.model.listings.isEmpty)
        flow.form.address = "100 Original Avenue"
        flow.pendingCoord = Coordinate(latitude: 27.7, longitude: -82.6)
        flow.tap()
        let id = flow.model.listings[0].id
        precondition(flow.goToPhotos && flow.model.listings.count == 1)
        flow.tap()
        precondition(flow.model.listings.count == 1, "Repeated tap must not duplicate listing")
        flow.goToPhotos = false
        flow.form.address = "200 Corrected Avenue"
        flow.pendingCoord = Coordinate(latitude: 28.0, longitude: -82.0)
        flow.tap()
        let stored = flow.model.listings[0]
        precondition(stored.id == id && stored.address == "100 Original Avenue" && stored.latitude == 27.7)
        precondition(flow.photosListing?.address == "100 Original Avenue")
        let result: [String: Any] = ["empty_form_blocks":true,"repeated_tap_duplicates":false,
            "entered_address":flow.form.address,"stored_address":stored.address,
            "destination_address":flow.photosListing!.address,"stored_latitude":stored.latitude!,
            "changed_latitude":flow.pendingCoord!.latitude,"corrected_form_discarded":true]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]), encoding: .utf8)!)
    }
}
'''.replace("__ACTUAL__", actual)
    if not args.revision:
        code = code.replace('stored.address == "100 Original Avenue" && stored.latitude == 27.7', 'stored.address == "200 Corrected Avenue" && stored.latitude == 28.0')
        code = code.replace('flow.photosListing?.address == "100 Original Avenue"', 'flow.photosListing?.address == "200 Corrected Avenue"')
        code = code.replace('"corrected_form_discarded":true', '"corrected_form_discarded":false')
    source, binary = out / "PhotosFirst.swift", out / "photos-first"
    source.write_text(code)
    receipt = {"source": str(target.relative_to(ROOT)), "sha256": hashlib.sha256(source_text.encode()).hexdigest(),
        "scope": "exact startWithPhotos method; in-memory storage/form boundary, no SwiftUI rendering", "commands": []}
    print("EVIDENCE:", out, flush=True)
    for label, cmd in [("compile", ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(source), "-o", str(binary)]),
                       ("execute", [str(binary)])]:
        r = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        (out / (label + ".log")).write_text(r.stdout)
        receipt["commands"].append({"label":label,"exit":r.returncode,"command":cmd})
        print(label, r.returncode, r.stdout[-4000:], flush=True)
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        if r.returncode: raise SystemExit(r.returncode)
        if label == "execute": receipt["results"] = json.loads(r.stdout)
    receipt["completed"] = True
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__": main()
