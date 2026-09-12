#!/usr/bin/env python3
"""Prove the real x5c encoding test has a deterministic negative precondition.

Uses actual WebCrypto certificates/JWS and actual verifier; no Apple requests,
credentials, committed signing keys, or source mutations. Mutants live in a
new retained /tmp evidence folder and must fail for the specified reason.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--deno", type=Path, default=Path("/opt/homebrew/bin/deno"))
    args = parser.parse_args()
    root, deno = args.root.resolve(), args.deno.resolve()
    shared = root / "services/supabase/functions/_shared"
    target = shared / "applejws.test.ts"
    verifier = shared / "applejws.ts"
    test_source, verifier_source = target.read_text(), verifier.read_text()
    out = Path(tempfile.mkdtemp(prefix="rendprop-apple-x5c-", dir="/tmp"))
    environment = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "NO_COLOR": "1"}
    source_hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in [target, verifier, shared / "http.ts", shared / "cors.ts"]}
    receipt = {"accepted": False, "sourceSha256": source_hashes,
               "deno": str(deno), "denoSha256": hashlib.sha256(deno.read_bytes()).hexdigest(),
               "commands": []}
    print("EVIDENCE:", out, flush=True)
    selected_name = "S1: an x5c entry in base64URL rather than base64 is refused"
    command_prefix = [str(deno), "test", "--cached-only", "--no-config", "--no-lock",
                      "--node-modules-dir=none", "--allow-env", "--allow-read",
                      "--deny-net", "--deny-run", "--deny-write"]

    def run(name, command, expected_exit=0, count=None, failure=None):
        result = subprocess.run(command, cwd=root, env=environment, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        log = out / (name + ".log")
        log.write_text(result.stdout)
        receipt["commands"].append({"name": name, "command": command,
                                    "exit": result.returncode, "log": str(log)})
        assert result.returncode == expected_exit, str(log)
        if count is not None:
            assert re.search(rf"^ok \| {count} passed \| 0 failed(?:\b|$)", result.stdout, re.M), str(log)
            assert not re.search(r"\b[1-9]\d* ignored\b", result.stdout), str(log)
        if failure:
            assert failure in result.stdout, str(log)
            assert "FAILED | 0 passed | 1 failed" in result.stdout, str(log)
        print(f"{name}: exit={result.returncode}", flush=True)

    def mutant(name, test_text=test_source, verifier_text=verifier_source):
        folder = out / name
        folder.mkdir()
        for file in ["http.ts", "cors.ts"]:
            shutil.copyfile(shared / file, folder / file)
        (folder / "applejws.ts").write_text(verifier_text)
        (folder / "applejws.test.ts").write_text(test_text)
        return folder / "applejws.test.ts"

    try:
        run("runtime-version", [str(deno), "--version"])
        # This rules out an atob runtime change before interpreting the fixture.
        probe = out / "alphabet_probe_test.ts"
        probe.write_text('''Deno.test("the runtime rejects URL-only alphabet digits", () => {
  if (atob("+/8=").charCodeAt(0) !== 251) throw new Error("standard base64 control failed");
  for (const value of ["-_8", "-_8="]) {
    let rejected = false;
    try { atob(value); } catch (e) { rejected = e instanceof DOMException && e.name === "InvalidCharacterError"; }
    if (!rejected) throw new Error("URL-only digits unexpectedly accepted");
  }
  // Overlap-alphabet strings are valid under either alphabet. They cannot
  // establish a negative test just because a helper was called b64url.
  if (atob("AA") !== atob("AA==")) throw new Error("overlap-alphabet control failed");
});
''')
        run("runtime-alphabet", [*command_prefix, str(probe)], count=1)
        assert "distinctBase64Alphabet: true" in test_source
        assert "The negative fixture must contain a URL-only base64 digit" in test_source
        run("actual-full-suite", [*command_prefix, str(target)], count=37)
        repeat = out / "repeat_actual_test.ts"
        repeat.write_text("for (let i = 0; i < 100; i++) await import(" +
                          json.dumps(target.as_uri() + "?encoding-fixture-trial=") + " + i);\n")
        run("actual-100-new-chains", [*command_prefix, "--filter", selected_name, str(repeat)], count=100)

        needle = "const bin = atob(s);"
        assert verifier_source.count(needle) == 1
        weakened = verifier_source.replace(needle, 'const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/"));')
        run("accepts-url-alphabet-mutant", [*command_prefix, "--filter", selected_name,
            str(mutant("accepts-url-alphabet", verifier_text=weakened))], 1,
            failure="Expected function to reject.")

        needle = "const encodedLeaf = b64url(chain.leafDer);"
        assert test_source.count(needle) == 1
        collision = test_source.replace(needle, "const encodedLeaf = b64(chain.leafDer);")
        run("overlap-fixture-mutant", [*command_prefix, "--filter", selected_name,
            str(mutant("overlap-fixture", test_text=collision))], 1,
            failure="The negative fixture must contain a URL-only base64 digit")

        needle = "buildChain({ distinctBase64Alphabet: true })"
        assert test_source.count(needle) == 1
        broken_chain = test_source.replace(needle, "buildChain({ distinctBase64Alphabet: true, omitLeafMarker: true })")
        run("invalid-positive-control-mutant", [*command_prefix, "--filter", selected_name,
            str(mutant("invalid-positive-control", test_text=broken_chain))], 1,
            failure="leaf is not an App Store signing certificate")

        run("restored-actual-full-suite", [*command_prefix, str(target)], count=37)
        for path, digest in source_hashes.items():
            assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest, path
        receipt["accepted"] = True
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
