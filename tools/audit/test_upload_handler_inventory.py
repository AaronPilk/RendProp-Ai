#!/usr/bin/env python3
"""Synthetic output controls for the compiled actual uploads inventory gate.

This gate does not run handlers, SQL, network or providers. The full actual
uploads transport/typecheck/stream mutation proof lives in verify_upload_transport.py.
"""
import argparse
import ast
import copy
import hashlib
import json
from pathlib import Path
import re
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "tools/audit/verify_upload_transport.py"
UPLOADS = ROOT / "services/supabase/functions/uploads"


def compiled_gate(tree):
    assignments = {"UPLOAD_INVENTORY", "UPLOAD_TESTS"}
    nodes = [copy.deepcopy(node) for node in tree.body if
             (isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and
                                                  target.id in assignments for target in node.targets)) or
             (isinstance(node, ast.FunctionDef) and node.name == "assert_upload_inventory")]
    assert len(nodes) == 3, "Compile exactly the actual inventory assignments and gate"
    module = ast.fix_missing_locations(ast.Module(body=nodes, type_ignores=[]))
    namespace = {"Path": Path, "re": re, "UPLOADS": UPLOADS}
    exec(compile(module, str(RUNNER), "exec"), namespace)
    return namespace["assert_upload_inventory"], namespace["UPLOAD_INVENTORY"], module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    out = args.out.resolve() if args.out else Path(tempfile.mkdtemp(prefix="rendprop-uploads-inventory-"))
    out.mkdir(parents=True, exist_ok=True)
    assert not any(out.iterdir()), "Evidence output must be empty"
    tracked = [RUNNER, Path(__file__).resolve()]
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in tracked}
    receipt = {"passed": False, "sourceHashes": hashes, "controls": [], "mutationControls": [],
               "limits": ["Synthetic output against compiled actual inventory gate; not actual handler/SQL/network/provider evidence"]}
    print(f"EVIDENCE: {out}", flush=True)
    try:
        tree = ast.parse(RUNNER.read_text())
        gate, inventory, module = compiled_gate(tree)
        receipt["compiledFunctionAstSha256"] = hashlib.sha256(ast.dump(module).encode()).hexdigest()
        receipt["handlerInventory"] = inventory
        blocks = [f"running {count} tests from {UPLOADS / name}\n" +
                  "".join(f"fixture case {index} ... ok (1ms)\n" for index in range(count))
                  for name, count in inventory.items()]
        summary = f"ok | {sum(inventory.values())} passed | 0 failed (1ms)\n"
        valid = "".join(blocks) + summary
        gate(valid)
        # Case titles may mention ignored fields; only ignored results and the
        # summary are disallowed, never an arbitrary word inside a test name.
        gate(valid.replace("fixture case 0", "ignored field case 0"))
        receipt["validInventoryAccepted"] = True
        chosen = "gateway_contract.test.ts"
        index = list(inventory).index(chosen)
        count = inventory[chosen]
        assert count > 1, "Duplicate pass control requires two actual registrations"

        def refusal(name, output, expected, candidate=gate):
            try:
                candidate(output)
            except AssertionError as error:
                assert str(error) == expected, (name, "Wrong named refusal", str(error))
                receipt["controls"].append({"name": name, "refused": True, "namedFailure": str(error)})
                return
            raise AssertionError(f"{name}: defective inventory was accepted")

        files = "Every audited uploads file must register exactly once"
        identity = "Unexpected or duplicate uploads file"
        cases = f"Every case in {chosen} must report one distinct pass"
        summaries = "Ignored, filtered, missing or failed uploads cases are refused"
        refusal("missing-file", "".join(blocks[:-1]) + summary, files)
        duplicate = list(blocks); duplicate[1] = duplicate[0]
        refusal("duplicated-file", "".join(duplicate) + summary, identity)
        refusal("unexpected-file", valid.replace(chosen, "unrelated.test.ts"), identity)
        registration = f"running {count} tests from {UPLOADS / chosen}"
        refusal("wrong-file-registration", valid.replace(registration, registration.replace(f"{count} tests", f"{count - 1} tests")),
                f"Incomplete uploads inventory for {chosen}")
        missing = list(blocks); missing[index] = missing[index].replace("fixture case 0 ... ok (1ms)\n", "", 1)
        refusal("missing-case-result", "".join(missing) + summary, cases)
        repeated = list(blocks); repeated[index] = repeated[index].replace("fixture case 1 ... ok (1ms)", "fixture case 0 ... ok (1ms)", 1)
        refusal("duplicated-case-result", "".join(repeated) + summary, cases)
        refusal("incomplete-summary", "".join(blocks) + summary.replace(f"{sum(inventory.values())} passed", "1 passed"), summaries)
        for label in ("ignored", "filtered out"):
            refusal(label, "".join(blocks) + summary.replace("0 failed", f"0 failed | 1 {label}"), summaries)
        refusal("failed-summary", "".join(blocks) + summary.replace("0 failed", "1 failed"), summaries)
        refusal("missing-summary", "".join(blocks), summaries)
        refusal("duplicated-summary", valid + summary, summaries)

        for label, message, broken in (
            ("remove-distinct-case-pass", cases, "".join(repeated) + summary),
            ("remove-summary-inventory", summaries, "".join(blocks) + summary.replace("0 failed", "0 failed | 1 ignored")),
        ):
            mutant = copy.deepcopy(tree)
            matches = [node for node in ast.walk(mutant) if isinstance(node, ast.Assert) and
                       ((isinstance(node.msg, ast.Constant) and node.msg.value == message) or
                        (isinstance(node.msg, ast.JoinedStr) and label == "remove-distinct-case-pass" and
                         any(isinstance(value, ast.Constant) and value.value == "Every case in " for value in node.msg.values)))]
            assert len(matches) == 1, (label, "Mutate exactly one actual authority assertion")
            matches[0].test = ast.Constant(value=True)
            candidate, _, _ = compiled_gate(mutant)
            candidate(broken)
            try:
                refusal(label, broken, message, candidate)
            except AssertionError as error:
                assert str(error) == f"{label}: defective inventory was accepted"
                receipt["mutationControls"].append({"name": label, "controlWentRed": True, "namedFailure": str(error)})
            else:
                raise AssertionError(f"{label}: proof failed to detect the compiled mutant")

        receipt["sourceHashesAfter"] = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in hashes}
        receipt["sourceBindingsMatch"] = receipt["sourceHashesAfter"] == hashes
        assert receipt["sourceBindingsMatch"], "Source changed during uploads inventory verification"
        receipt["passed"] = True
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"PASS: complete {sum(inventory.values())}-case inventory; 12 refusals; two compiled guard-removal controls", flush=True)


if __name__ == "__main__":
    main()
