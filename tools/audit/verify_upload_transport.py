#!/usr/bin/env python3
"""Offline transport gate + a genuinely failing copied-source implementation.

No installs/network/provider calls; the caller supplies an existing tsc. The
negative mode exits 1. All small fixture sources/logs stay in a new /tmp folder.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--tsc",type=Path)
    parser.add_argument("--deno-dir",type=Path,required=True)
    parser.add_argument("--inject-fault",choices=["no-final-byte-guard"])
    args=parser.parse_args()
    deno=shutil.which("deno")
    if not deno or not args.deno_dir.is_dir(): raise RuntimeError("Existing Deno and cache are required; no install fallback")
    if not args.inject_fault and (not args.tsc or not args.tsc.is_file()): raise RuntimeError("Existing TypeScript compiler is required")
    out=Path(tempfile.mkdtemp(prefix="rendprop-upload-offline-",dir="/tmp"))
    receipt={"accepted":False,"commands":[],"network":"denied for tests","evidence":str(out)}
    env={"PATH":os.environ.get("PATH","/usr/bin:/bin"),"DENO_DIR":str(args.deno_dir),"NO_COLOR":"1"}
    test=[deno,"test","--cached-only","--deny-net","--deny-run","--deny-write","--allow-read","--allow-env"]
    def run(name,command):
        result=subprocess.run(command,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
        (out/(name+".log")).write_text(result.stdout)
        receipt["commands"].append({"name":name,"command":command,"exit":result.returncode})
        return result
    print("EVIDENCE:",out,flush=True)
    try:
        source=ROOT/"services/supabase/functions/uploads/gateway_contract.ts"
        original=source.read_text()
        first=r"if \(value.byteLength > 1\) \{\s*await writer.write\(value.subarray\(0, value.byteLength - 1\)\);\s*\}"
        last="await writer.write(last);"
        if len(re.findall(first,original))!=1 or original.count(last)!=1: raise RuntimeError("Negative-control source anchors changed")
        mutant=re.sub(first,"await writer.write(value); // deliberately releases final byte before EOF",original)
        mutant=mutant.replace(last,"// deliberate mutant: final byte was already released")
        (out/"gateway_contract.ts").write_text(mutant)
        shutil.copyfile(source.with_name("gateway_contract.test.ts"),out/"gateway_contract.test.ts")
        receipt["sourceSHA256"]=hashlib.sha256(original.encode()).hexdigest()
        broken=run("negative-final-byte",test+[str(out/"gateway_contract.test.ts")])
        # The failure must be the prefix-commit assertion, not an import/type error.
        if broken.returncode!=1 or "An invalid stream released its commit-enabling last byte" not in broken.stdout:
            raise RuntimeError("Deliberately defective stream implementation was not detected")
        receipt["negativeControlDetected"]=True
        if args.inject_fault:return 1
        positive=run("uploads",test+["services/supabase/functions/uploads"])
        if positive.returncode!=0 or not re.search(r"ok \| 122 passed \| 0 failed",positive.stdout) or "ignored" in positive.stdout:
            raise RuntimeError("Expected all 122 transport/publication/restart tests, no skips")
        typed=run("native-worker-typecheck",[str(args.tsc),"-p","services/edge/upload-gateway/tsconfig.json"])
        if typed.returncode!=0:raise RuntimeError("Native Worker adapter did not typecheck")
        receipt.update(accepted=True,tests=122,failed=0,skipped=0)
        print("PASS: 122 tests; native adapter typecheck; deliberately defective stream exited 1")
        return 0
    finally:(out/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")

if __name__=="__main__":
    raise SystemExit(main())
