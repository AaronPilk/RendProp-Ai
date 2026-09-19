#!/usr/bin/env python3
"""Actual repaired join/controller/journal regressions; synthetic local media."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile
from run_join import ROOT, HERE, function


def main():
    out=Path(tempfile.mkdtemp(prefix="rendprop-call-join-fixed-",dir="/tmp"))
    print(f"EVIDENCE: {out}",flush=True)
    src=ROOT/"apps/ios/Rendprop/Capture/CaptureView.swift"
    fs=ROOT/"apps/ios/Rendprop/Support/FileStore.swift"
    recovery=ROOT/"apps/ios/Rendprop/Capture/TakeRecoveryStore.swift"
    capture=ROOT/"apps/ios/Rendprop/Models/CaptureAsset.swift"
    tags=ROOT/"apps/ios/Rendprop/Models/RoomTag.swift"
    harness=HERE/"JoinRegressionRuntime.swift"
    paths=[src,fs,recovery,capture,tags,harness,Path(__file__),HERE/"run_join.py"]
    receipt={"sourceHashes":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
             "commands":[],"accepted":False}
    def run(name,args):
        p=subprocess.run(list(map(str,args)),cwd=ROOT,capture_output=True,text=True,timeout=120)
        log=out/f"{name}.log";log.write_text(p.stdout+p.stderr)
        receipt["commands"].append({"name":name,"exit":p.returncode,"log":str(log),"command":list(map(str,args))})
        assert p.returncode==0,f"{name}: {log}"
        return p.stdout
    try:
        original=src.read_text()
        deps='''import Foundation
import AVFoundation
enum FileStore {
    static var documents = URL(fileURLWithPath:"/tmp/unused-join-regression")
    static var recordingsDir: URL { documents.appendingPathComponent("Recordings") }
'''
        for marker in ["    static func newRecordingURL() -> URL {", "    static func relativePath(for url: URL) -> String {"]:
            deps+=function(fs.read_text(),marker)+"\n"
        deps+="}\n"
        test=harness.read_text()
        methods=["    private func refreshSavedTakes() {", "    private func makeRecovery(_ urls: [URL], seconds: Double, sidecar: URL?) -> RecoverableTake {",
                 "    private func handleFinished(_ urls: [URL]) {", "    private func joinSavedTake(_ take: RecoverableTake) {"]
        test=test.replace("    // PRODUCTION_METHODS","\n".join(function(original,m) for m in methods))
        flags=["    private var isRecording: Bool {","    private var isPaused: Bool {",
               "    private var takeInProgress: Bool {","    private var isFinalizing: Bool {"]
        test=test.replace("    // PRODUCTION_FLAGS","\n".join(function(original,m) for m in flags))
        button=function(original,"    private var recordButton: some View {")
        disabled=re.search(r"\.disabled\((.*?)\)\s*\.accessibilityLabel",button,re.S).group(1)
        test=test.replace("    // PRODUCTION_DISABLED","    var recordDisabled: Bool { "+disabled+" }")
        action=function(button,"        Button {")[len("        Button {"):-1]
        test=test.replace("    // PRODUCTION_RECORD_ACTION","    func pressRecord() { "+action+" }")
        combined=out/"actual-join-fixed.swift"
        combined.write_text(deps+original[original.index("enum TakeJoiner {"):]+"\n"+test)
        binary=out/"join-fixed"
        run("compile",["/usr/bin/xcrun","swiftc","-swift-version","5","-parse-as-library",combined,recovery,capture,tags,"-o",binary])
        for name,size in [("fixture","320x240"),("different-size","640x480")]:
            run(name,["/opt/homebrew/bin/ffmpeg","-hide_banner","-loglevel","error","-f","lavfi","-i",
                f"testsrc2=size={size}:rate=30:duration=0.3","-an","-c:v","libx264","-pix_fmt","yuv420p",out/f"{name}.mov"])
        for name,seconds in [("long",599.75),("one-second",1)]:
            run(name,["/opt/homebrew/bin/ffmpeg","-hide_banner","-loglevel","error","-f","lavfi","-i",
                f"color=blue:size=32x32:rate=4:duration={seconds}","-an","-c:v","libx264","-pix_fmt","yuv420p",out/f"{name}.mov"])
        print(run("runtime",[binary,out]),flush=True)
        receipt["results"]=json.loads((out/"regression-results.json").read_text())
        assert all(hashlib.sha256(p.read_bytes()).hexdigest()==receipt["sourceHashes"][str(p.relative_to(ROOT))] for p in paths)
        receipt["accepted"]=True
    finally:
        (out/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")


if __name__=="__main__": main()
