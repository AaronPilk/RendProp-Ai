#!/usr/bin/env python3
"""Run actual persistence save/load against a fresh synthetic /tmp library."""
from pathlib import Path
import hashlib
import argparse
import json
import subprocess
import tempfile
from run_join import ROOT, HERE, function, read_source


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision",default="7bcc624")
    revision=parser.parse_args().revision
    out = Path(tempfile.mkdtemp(prefix="rendprop-call-persistence-", dir="/tmp"))
    print(f"EVIDENCE: {out}", flush=True)
    app = ROOT / "apps/ios/Rendprop/RendpropApp.swift"
    fs = ROOT / "apps/ios/Rendprop/Support/FileStore.swift"
    capture = ROOT / "apps/ios/Rendprop/Models/CaptureAsset.swift"
    tags = ROOT / "apps/ios/Rendprop/Models/RoomTag.swift"
    harness = HERE / "PersistenceRuntime.swift"
    paths = [app,fs,capture,tags,harness,Path(__file__),HERE/"run_join.py"]
    receipt = {"sourceCommit": subprocess.check_output(["git","rev-parse",revision],cwd=ROOT,text=True).strip(),
        "sourceHashes": {str(p.relative_to(ROOT)):hashlib.sha256(read_source(p,revision).encode()).hexdigest() for p in paths},
        "commands":[],"accepted":False}
    def run(name,args):
        p = subprocess.run(list(map(str,args)),cwd=ROOT,capture_output=True,text=True,timeout=120)
        log=out/f"{name}.log";log.write_text(p.stdout+p.stderr)
        receipt["commands"].append({"name":name,"command":list(map(str,args)),"exit":p.returncode,"log":str(log)})
        assert p.returncode==0, f"{name}: {log}"
        return p.stdout
    try:
        source = read_source(app,revision)
        store = source[source.index("enum PersistentStore {"):source.index("// MARK: - Entry")]
        dependencies = """import Foundation
enum FileStore {
    static var documents = URL(fileURLWithPath: "/tmp/unused-rendprop-persistence")
    static var recordingsDir: URL { documents.appendingPathComponent("Recordings") }
"""
        for marker in ["    static func relativePath(for url: URL) -> String {", "    static func url(fromRelativePath rel: String) -> URL {"]:
            dependencies += function(read_source(fs,revision), marker) + "\n"
        dependencies += "}\n"
        combined = out / "actual-persistence.swift"
        combined.write_text(dependencies+store+"\n"+harness.read_text())
        binary=out/"persistence-runtime"
        capture_copy=out/"CaptureAsset.swift"; capture_copy.write_text(read_source(capture,revision))
        tags_copy=out/"RoomTag.swift"; tags_copy.write_text(read_source(tags,revision))
        run("compile",["/usr/bin/xcrun","swiftc","-swift-version","5","-parse-as-library",combined,capture_copy,tags_copy,"-o",binary])
        print(run("runtime",[binary,out]),flush=True)
        result=json.loads((out/"persistence-results.json").read_text())
        receipt["results"]=result
        assert result["saved"] and result["original_bytes_preserved"] and result["restored_same_asset"]
        assert result["before_person_ranges"]==2 and result["after_person_ranges"]==0
        assert result["before_tags"]==result["after_tags"]==1
        assert not result["snapshot_has_person_key"]
        assert all(hashlib.sha256(read_source(p,revision).encode()).hexdigest()==receipt["sourceHashes"][str(p.relative_to(ROOT))] for p in paths)
        receipt["accepted"]=True
    finally:
        (out/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")


if __name__ == "__main__": main()
