#!/usr/bin/env python3
"""Execute real paused-take AVFoundation joining on synthetic local media only.

The production join, success/failure caller, cleanup, and timestamp allocator
are copied verbatim into a macOS Swift test module. Only UI/dependency glue is
stubbed. Nothing calls a camera, provider, production service or user library.
"""
from pathlib import Path
import hashlib
import json
import argparse
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent


def function(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    count = 1
    i = opening + 1
    while count:
        count += (text[i] == "{") - (text[i] == "}")
        i += 1
    return text[start:i]


def read_source(path, revision=None):
    if revision and str(path.relative_to(ROOT)).startswith("apps/"):
        return subprocess.check_output(["git", "show", f"{revision}:{path.relative_to(ROOT)}"], cwd=ROOT).decode()
    return path.read_text()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="7bcc624", help="Audited source revision; default is the preserved NO-GO baseline")
    args = parser.parse_args()
    revision = args.revision
    out = Path(tempfile.mkdtemp(prefix="rendprop-call-join-", dir="/tmp"))
    print(f"EVIDENCE: {out}", flush=True)
    src = ROOT / "apps/ios/Rendprop/Capture/CaptureView.swift"
    file_src = ROOT / "apps/ios/Rendprop/Support/FileStore.swift"
    original = read_source(src, revision)
    paths = [src, file_src, HERE / "JoinRuntime.swift", Path(__file__)]
    receipt = {"sourceCommit": subprocess.check_output(["git", "rev-parse", revision], cwd=ROOT, text=True).strip(),
               "sourceHashes": {str(p.relative_to(ROOT)): hashlib.sha256(read_source(p, revision).encode()).hexdigest() for p in paths},
               "commands": [], "accepted": False}
    env = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C"}

    def run(name, args, timeout=120):
        p = subprocess.run(list(map(str,args)), cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
        log = out / f"{name}.log"
        log.write_text(p.stdout + p.stderr)
        receipt["commands"].append({"name":name,"exit":p.returncode,"log":str(log),"command":list(map(str,args))})
        assert p.returncode == 0, f"{name} failed: {log}"
        return p.stdout

    try:
        allocator = function(read_source(file_src, revision), "    static func newRecordingURL() -> URL {")
        deps = """import Foundation
import AVFoundation
enum FileStore {
    static var documents = URL(fileURLWithPath: "/tmp/unused-rendprop-join")
    static var recordingsDir: URL { documents.appendingPathComponent("Recordings") }
""" + allocator + "\n}\n"
        harness = (HERE / "JoinRuntime.swift").read_text()
        harness = harness.replace("    // PRODUCTION_HANDLER", function(original, "    private func handleFinished(_ urls: [URL]) {"))
        harness = harness.replace("    // PRODUCTION_DELETE", function(original, "    static func deleteTake(_ url: URL) {"))
        flags = "\n".join(function(original, marker) for marker in [
            "    private var isRecording: Bool {", "    private var isPaused: Bool {",
            "    private var takeInProgress: Bool {", "    private var isFinalizing: Bool {"])
        harness = harness.replace("    // PRODUCTION_FLAGS", flags)
        button = function(original, "    private var recordButton: some View {")
        disabled = re.search(r"\.disabled\((.*?)\)\s*\.accessibilityLabel",button,re.S).group(1)
        harness = harness.replace("    // PRODUCTION_DISABLED", "    var recordDisabled: Bool { "+disabled+" }")
        action = function(button, "        Button {")[len("        Button {"):-1]
        harness = harness.replace("    // PRODUCTION_RECORD_ACTION", "    func pressRecord() { "+action+" }")
        compiled = out / "actual-join.swift"
        compiled.write_text(deps + "\n" + original[original.index("enum TakeJoiner {"):] + "\n" + harness)
        binary = out / "join-runtime"
        run("compile", ["/usr/bin/xcrun","swiftc","-swift-version","5","-parse-as-library", compiled,"-o",binary])
        for name, size in [("fixture","320x240"),("different-size","640x480")]:
            run(name,["/opt/homebrew/bin/ffmpeg","-hide_banner","-loglevel","error","-f","lavfi","-i",
                      f"testsrc2=size={size}:rate=30:duration=0.3","-an","-c:v","libx264","-pix_fmt","yuv420p",out/f"{name}.mov"])
        for name, seconds in [("long",599.75),("one-second",1)]:
            run(name,["/opt/homebrew/bin/ffmpeg","-hide_banner","-loglevel","error","-f","lavfi","-i",
                      f"color=blue:size=32x32:rate=4:duration={seconds}","-an","-c:v","libx264","-pix_fmt","yuv420p",out/f"{name}.mov"])
        print(run("runtime",[binary,out]), flush=True)
        results = json.loads((out / "join-results.json").read_text())
        receipt["results"] = results
        normal, partial, collision, mismatch, over_cap, fallback, interleave = results
        assert normal["presented_exists"] and abs(normal["duration"]-0.6)<0.01
        assert partial["warning"] is None and partial["sources_exist"] == [False,False,False]
        assert abs(partial["duration"]-0.6)<0.01
        assert collision["presented_is_input"] and not collision["presented_exists"], collision
        assert abs(over_cap["duration"] - 600.75) < 0.01 and over_cap["warning"] is None
        assert fallback["presented_is_first_only"] and fallback["sources_exist"] == [True,True] and fallback["warning"]
        assert interleave["joining_at_press"] and not interleave["record_disabled_at_press"]
        assert interleave["start_calls"]==1 and interleave["presented_tags"]==0
        assert all(hashlib.sha256(read_source(p, revision).encode()).hexdigest() == receipt["sourceHashes"][str(p.relative_to(ROOT))] for p in paths)
        receipt["accepted"] = True
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")


if __name__ == "__main__":
    main()
