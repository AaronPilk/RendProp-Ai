#!/usr/bin/env python3
"""Exercise actual repaired persistence, legacy and partially malformed saves."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile
from run_join import ROOT,HERE,function


def main():
    out=Path(tempfile.mkdtemp(prefix="rendprop-call-persistence-fixed-",dir="/tmp"))
    print(f"EVIDENCE: {out}",flush=True)
    app=ROOT/"apps/ios/Rendprop/RendpropApp.swift"
    fs=ROOT/"apps/ios/Rendprop/Support/FileStore.swift"
    capture=ROOT/"apps/ios/Rendprop/Models/CaptureAsset.swift"
    tags=ROOT/"apps/ios/Rendprop/Models/RoomTag.swift"
    harness=HERE/"PersistenceRegressionRuntime.swift"
    deps_file=HERE/"PersistenceRuntime.swift"
    paths=[app,fs,capture,tags,harness,deps_file,Path(__file__),HERE/"run_join.py"]
    receipt={"sourceHashes":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
             "commands":[],"accepted":False}
    def run(name,args):
        p=subprocess.run(list(map(str,args)),cwd=ROOT,capture_output=True,text=True,timeout=120)
        log=out/f"{name}.log";log.write_text(p.stdout+p.stderr)
        receipt["commands"].append({"name":name,"exit":p.returncode,"log":str(log),"command":list(map(str,args))})
        assert p.returncode==0,f"{name}: {log}"
        return p.stdout
    try:
        source=app.read_text()
        store=source[source.index("enum PersistentStore {"):source.index("// MARK: - Entry")]
        deps='''import Foundation
enum FileStore {
    static var documents = URL(fileURLWithPath:"/tmp/unused-persistence-regression")
    static var recordingsDir: URL { documents.appendingPathComponent("Recordings") }
'''
        for marker in ["    static func relativePath(for url: URL) -> String {","    static func url(fromRelativePath rel: String) -> URL {"]:
            deps+=function(fs.read_text(),marker)+"\n"
        deps+="}\n"+deps_file.read_text().split("@main struct")[0]
        combined=out/"actual-persistence-fixed.swift"
        combined.write_text(deps+store+"\n"+harness.read_text())
        binary=out/"persistence-fixed"
        run("compile",["/usr/bin/xcrun","swiftc","-swift-version","5","-parse-as-library",combined,capture,tags,"-o",binary])
        print(run("runtime",[binary,out]),flush=True)
        receipt["results"]=json.loads((out/"regression-results.json").read_text())
        assert all(hashlib.sha256(p.read_bytes()).hexdigest()==receipt["sourceHashes"][str(p.relative_to(ROOT))] for p in paths)
        receipt["accepted"]=True
    finally:
        (out/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")


if __name__=="__main__": main()
