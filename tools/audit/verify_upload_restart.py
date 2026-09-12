#!/usr/bin/env python3
"""Offline real-handler gate with assertion-failing copied source controls."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    out = Path(tempfile.mkdtemp(prefix="rendprop-upload-restart-",dir="/tmp"))
    receipt = {"accepted":False,"network":"denied; actual handler with fixture fetch","commands":[],"sourceRoot":str(root)}
    print("EVIDENCE:",out,flush=True)
    deno = shutil.which("deno")
    assert deno, "Existing Deno required"
    command = [deno,"test","--cached-only","--deny-net","--deny-run","--deny-write","--allow-read","--allow-env"]
    env = {"PATH":os.environ.get("PATH","/usr/bin:/bin"),"NO_COLOR":"1"}
    if "DENO_DIR" in os.environ: env["DENO_DIR"] = os.environ["DENO_DIR"]
    def run(name,args,cwd):
        result = subprocess.run(args,cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
        (out/(name+".log")).write_text(result.stdout)
        receipt["commands"].append({"name":name,"command":list(map(str,args)),"exit":result.returncode})
        return result
    try:
        relative = Path("services/supabase/functions/uploads/index.ts")
        files = [root/relative,root/"services/supabase/migrations/0042_upload_explicit_restart.sql",
                 *[root/"tools/audit"/name for name in ["upload_route_fixture.ts","uploads_restart_test.ts","uploads_renewal_test.ts"]]]
        receipt["sourceHashes"] = {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
        source = files[0].read_text()
        assert 'seg[1] === "restart"' in source and '"restart_upload_asset"' in source
        positive = run("all-upload-tests",command+["services/supabase/functions/uploads"],root)
        assert positive.returncode == 0 and re.search(r"ok \| 122 passed \| 0 failed",positive.stdout) and "ignored" not in positive.stdout
        receipt["tests"] = 122
        mutants = [("missing-consent", "body?.confirm_new_attempt === true", "true", "restart refuses absent false or expanded consent before RPC"),
                   ("failure-capability", "if (state.restart_required === true || state.retry_after_seconds != null) return {",
                    "if (false) return {", "expired renewal is a typed no-capability receipt without spending")]
        for name,old,new,expected in mutants:
            assert source.count(old) == 1
            copy = out/name
            # Only known source TS, never env files, media, caches, credentials or
            # the user's tree. Mutations exist solely in the owned temp fixture.
            for folder in ["services/supabase/functions/_shared","services/supabase/functions/uploads"]:
                for path in (root/folder).rglob("*.ts"):
                    target = copy/path.relative_to(root); target.parent.mkdir(parents=True,exist_ok=True)
                    shutil.copyfile(path,target)
            for path in files[2:]:
                target = copy/path.relative_to(root); target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copyfile(path,target)
            (copy/relative).write_text(source.replace(old,new,1))
            result = run("negative-"+name,command+["tools/audit/uploads_restart_test.ts"],copy)
            assert result.returncode == 1 and expected+" ... FAILED" in result.stdout and "AssertionError" in result.stdout
            assert not any(marker in result.stdout for marker in ["TS2307", "Module not found", "Requires net access", "error: Type checking failed"])
        restored = run("restored-source",command+["tools/audit/uploads_restart_test.ts"],root)
        assert restored.returncode == 0 and re.search(r"ok \| 15 passed \| 0 failed",restored.stdout)
        receipt.update(accepted=True,negativeControls=2,restoredTests=15)
        print("PASS 122 actual-handler/transport tests; two assertion-failing handler mutants; 15 restored tests",flush=True)
    finally:
        (out/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")


if __name__ == "__main__":
    main()
