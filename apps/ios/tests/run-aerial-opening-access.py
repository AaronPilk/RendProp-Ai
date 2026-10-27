#!/usr/bin/env python3
"""Compile the opening screen's actual /me access classifier without a live account."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SOURCE = (ROOT / "apps/ios/Rendprop/Screens/AerialOpeningView.swift").read_text()
needle = "enum AerialOpeningCreationAccess: Equatable {"
start = SOURCE.index(needle)
opening = SOURCE.index("{", start)
depth = 1
end = opening + 1
while depth:
    depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
    end += 1
classifier = SOURCE[start:end]

fixture = r"""
import Foundation
@main struct OpeningAccessChecks {
    static func main() {
        func expect(_ result: AerialOpeningCreationAccess, _ expected: AerialOpeningCreationAccess) {
            guard result == expected else { fatalError("Expected \(expected), got \(result)") }
        }
        let access = AerialOpeningCreationAccess.resolve
        expect(access(0, 0, true, false), .planRequired) // free/trial
        expect(access(2, 2, true, false), .available) // ordinary paid
        expect(access(4, 1, true, false), .available)
        expect(access(Int.max, Int.max, true, false), .available) // private sponsored QA
        expect(access(2, 0, true, false), .allowanceUsed)
        expect(access(0, 0, false, true), .activationPending) // recorded paid, activation pending
        expect(access(2, 2, false, false), .unavailable)
        expect(access(2, 2, nil, false), .unavailable)
        expect(access(nil, nil, true, false), .unavailable) // old/failed /me payload
        expect(access(-1, 1, true, false), .unavailable)
        print("PASS: 10 Aerial /me access states")
    }
}
"""
with tempfile.TemporaryDirectory(prefix="rendprop-aerial-access-") as directory:
    source = Path(directory) / "OpeningAccess.swift"
    binary = Path(directory) / "opening-access"
    source.write_text("import Foundation\n" + classifier + "\n" + fixture)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
