#!/usr/bin/env python3
"""Prove the actual deletion test captures/restores data and accessor serve.

No production code changes or sockets. The fixture replaces only Deno.serve's
property shape and imports the unchanged actual handler regression module.
Both deliberately broken test-harness variants must fail specifically.
"""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    out = Path(tempfile.mkdtemp(prefix="rendprop-deletion-descriptor-", dir="/tmp"))
    functions = root / "services/supabase/functions"
    target = functions / "me/deletion.test.ts"
    original = target.read_text()
    receipt = {"accepted": False, "commands": [], "source": str(target),
               "sourceSha256": hashlib.sha256(target.read_bytes()).hexdigest()}
    env = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "NO_COLOR": "1"}
    deno = ["/opt/homebrew/bin/deno", "test", "--cached-only", "--no-config", "--no-lock",
            "--node-modules-dir=none", "--allow-env", "--allow-read", "--deny-net", "--deny-run", "--deny-write"]
    print("EVIDENCE:", out, flush=True)

    def wrapper(name, test_path, accessor):
        path = out / (name + "_test.ts")
        shape = "{ get: fixtureGetter, configurable: true, enumerable: true }" if accessor else \
                "{ value: forbiddenServer, writable: true, configurable: true, enumerable: true }"
        assertion = 'restored.get !== fixtureGetter || "value" in restored' if accessor else \
                    'restored.value !== forbiddenServer || "get" in restored'
        path.write_text('''const prior = Object.getOwnPropertyDescriptor(Deno, "serve")!;
const forbiddenServer = () => { throw new Error("A real server must not start in this fixture"); };
const fixtureGetter = () => forbiddenServer;
Object.defineProperty(Deno, "serve", ''' + shape + ''');
try {
  await import(''' + json.dumps(test_path.as_uri()) + ''');
  const restored = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  if (''' + assertion + ''') throw new Error("Actual deletion test failed to restore the original serve descriptor");
} finally { Object.defineProperty(Deno, "serve", prior); }
''')
        return path

    def run(name, path, expected, needle=None):
        command = [*deno, str(path)]
        result = subprocess.run(command, cwd=root, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
        log = out / (name + ".log"); log.write_text(result.stdout)
        receipt["commands"].append({"name": name, "command": command, "exit": result.returncode, "log": str(log)})
        assert result.returncode == expected, str(log)
        if expected == 0:
            assert re.search(r"^ok \| 27 passed \| 0 failed", result.stdout, re.MULTILINE), str(log)
        else:
            assert needle in result.stdout, str(log)
        print(f"{name}: exit={result.returncode}", flush=True)

    try:
        for accessor in [False, True]:
            name = "accessor" if accessor else "data"
            run(name, wrapper(name, target, accessor), 0)
        # Mutants alter the actual harness, while using the actual handler and
        # helpers. Runtime errors have to match the failure under investigation.
        needle = 'configurable: true, enumerable: serve.enumerable,'
        assert original.count(needle) == 1
        mutations = [
            ("descriptor-hybrid", original.replace(needle, "...serve,"),
             "Cannot both specify accessors and a value or writable attribute"),
            ("missing-restore", original.replace('Object.defineProperty(Deno, "serve", serve);', ''),
             "Actual deletion test failed to restore the original serve descriptor"),
        ]
        for name, changed, message in mutations:
            assert changed != original
            folder = out / name / "me"; folder.mkdir(parents=True)
            (folder.parent / "_shared").symlink_to(functions / "_shared", target_is_directory=True)
            for sibling in (functions / "me").glob("*.ts"):
                if sibling != target:
                    shutil.copyfile(sibling, folder / sibling.name)
            modified = folder / "deletion.test.ts"; modified.write_text(changed)
            run(name, wrapper(name, modified, True), 1, message)
        run("restored-accessor", wrapper("restored-accessor", target, True), 0)
        assert hashlib.sha256(target.read_bytes()).hexdigest() == receipt["sourceSha256"]
        receipt["accepted"] = True
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
