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
UPLOADS=ROOT/"services/supabase/functions/uploads"
# Audited actual registration inventory: imported route/Worker tests are
# registered under these six entrypoint files by Deno, not separate modules.
UPLOAD_INVENTORY={"completion_race.test.ts":1,"content_type.test.ts":16,
                  "gateway_contract.test.ts":14,"publication.test.ts":6,
                  "publication_route.test.ts":36,"transport_route.test.ts":41}
UPLOAD_TESTS=sum(UPLOAD_INVENTORY.values())

def assert_upload_inventory(output):
    registrations=list(re.finditer(r"^running (\d+) tests? from ([^\r\n]+)$",output,re.MULTILINE))
    assert len(registrations)==len(UPLOAD_INVENTORY),"Every audited uploads file must register exactly once"
    observed={}
    for i,registration in enumerate(registrations):
        name=Path(registration.group(2)).resolve().relative_to(UPLOADS).as_posix()
        assert name in UPLOAD_INVENTORY and name not in observed,"Unexpected or duplicate uploads file"
        observed[name]=int(registration.group(1))
        assert observed[name]==UPLOAD_INVENTORY[name],f"Incomplete uploads inventory for {name}"
        block=output[registration.end():registrations[i+1].start()if i+1<len(registrations)else len(output)]
        passed_names=re.findall(r"^(.*?) \.\.\. ok \([^\r\n]+\)$",block,re.MULTILINE)
        assert len(passed_names)==observed[name] and len(set(passed_names))==observed[name],f"Every case in {name} must report one distinct pass"
    assert observed==UPLOAD_INVENTORY,"The complete audited uploads inventory must run"
    summaries=re.findall(r"^ok \| .*$",output,re.MULTILINE)
    assert len(summaries)==1 and re.fullmatch(rf"ok \| {UPLOAD_TESTS} passed \| 0 failed \([^\r\n]+\)",summaries[0]),"Ignored, filtered, missing or failed uploads cases are refused"

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--tsc",type=Path)
    parser.add_argument("--deno-dir",type=Path,required=True)
    parser.add_argument("--inject-fault",choices=["no-final-byte-guard"])
    parser.add_argument("--output-directory",type=Path)
    args=parser.parse_args()
    deno=shutil.which("deno")
    if not deno or not args.deno_dir.is_dir(): raise RuntimeError("Existing Deno and cache are required; no install fallback")
    if not args.inject_fault and (not args.tsc or not args.tsc.is_file()): raise RuntimeError("Existing TypeScript compiler is required")
    out=args.output_directory.resolve()if args.output_directory else Path(tempfile.mkdtemp(prefix="rendprop-upload-offline-",dir="/tmp"))
    out.mkdir(parents=True,exist_ok=True)
    if any(out.iterdir()):parser.error("The output directory must be empty")
    # Bind actual imported fixture/runtime dependencies as well as the gate.
    # Cached third-party dependencies are not production-network proof.
    tracked=[Path(__file__).resolve(),*sorted(UPLOADS.glob("*.ts")),
             *sorted((ROOT/"services/supabase/functions/_shared").glob("*.ts")),
             *sorted((ROOT/"services/edge/upload-gateway").glob("*.ts")),
             ROOT/"services/edge/upload-gateway/tsconfig.json",
             *sorted((ROOT/"tools/audit").glob("uploads_*_test.ts")),ROOT/"tools/audit/upload_route_fixture.ts"]
    hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest()for path in tracked}
    receipt={"accepted":False,"commands":[],"network":"denied for tests","evidence":str(out),
             "sourceHashes":hashes,"handlerInventory":UPLOAD_INVENTORY,
             "limits":["Actual handlers against synthetic transport/storage fixtures; no native Worker binding or provider execution",
                       "Cached third-party imports are not live deployment evidence"]}
    env={"PATH":os.environ.get("PATH","/usr/bin:/bin"),"DENO_DIR":str(args.deno_dir),"NO_COLOR":"1","DENO_NO_PROMPT":"1"}
    test=[deno,"test","--cached-only","--deny-net","--deny-run","--deny-write","--allow-read","--allow-env"]
    def run(name,command):
        result=subprocess.run(command,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
        log=out/(name+".log");log.write_text(result.stdout)
        receipt["commands"].append({"name":name,"command":command,"exit":result.returncode,
                                    "log":str(log),"sha256":hashlib.sha256(log.read_bytes()).hexdigest()})
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
        if not args.inject_fault:
            positive=run("uploads",test+[str(UPLOADS)])
            if positive.returncode!=0:raise RuntimeError("The actual complete uploads suite failed")
            assert_upload_inventory(positive.stdout)
            typed=run("native-worker-typecheck",[str(args.tsc),"-p","services/edge/upload-gateway/tsconfig.json"])
            if typed.returncode!=0:raise RuntimeError("Native Worker adapter did not typecheck")
            assert all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in hashes.items()),"Source changed during uploads verification"
            receipt.update(accepted=True,tests=UPLOAD_TESTS,failed=0,skipped=0)
    finally:
        receipt["sourceHashesAfter"]={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest()for name in hashes}
        receipt["sourceBindingsMatch"]=receipt["sourceHashesAfter"]==hashes
        receipt["accepted"]=receipt["accepted"] and receipt["sourceBindingsMatch"]
        (out/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
    assert receipt["sourceBindingsMatch"],"Source changed during uploads verification"
    if args.inject_fault:return 1
    assert receipt["accepted"],"Uploads verification did not complete"
    print(f"PASS: {UPLOAD_TESTS} tests; native adapter typecheck; deliberately defective stream exited 1")
    return 0

if __name__=="__main__":
    raise SystemExit(main())
