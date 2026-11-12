#!/usr/bin/env python3
"""Exercise the actual workspace runner's inventory gate without executing it.

Compiles its function and audited inventory assignments from their source AST.
Synthetic Deno output proves refusal semantics; it is not handler or SQL proof.
The separate run_workspace_selection.py gate owns that actual execution.
"""
import argparse
import ast
import copy
import hashlib
import json
from pathlib import Path
import pathlib
import re
import tempfile


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "tools/audit/run_workspace_selection.py"
SQL = ROOT / "services/supabase"


def compile_gate(tree):
    names = {"HANDLER_INVENTORY", "HANDLER_TESTS"}
    nodes = [copy.deepcopy(node) for node in tree.body if
             isinstance(node, ast.Assign) and any(
                 isinstance(target, ast.Name) and target.id in names for target in node.targets)
             or isinstance(node, ast.FunctionDef) and node.name == "assert_handler_inventory"]
    assert len(nodes) == 3, "Exactly the two actual inventory assignments and actual gate must be compiled"
    namespace = {"re": re, "pathlib": pathlib, "SQL": SQL}
    module = ast.Module(body=nodes, type_ignores=[])
    exec(compile(ast.fix_missing_locations(module), str(RUNNER), "exec"), namespace)
    return namespace["assert_handler_inventory"], namespace["HANDLER_INVENTORY"], module


def output_blocks(inventory):
    return [f"running {count} tests from {SQL / 'functions' / name}\n" +
            "".join(f"fixture case {index} ... ok (1ms)\n" for index in range(count))
            for name, count in inventory.items()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    out = args.out.resolve() if args.out else Path(tempfile.mkdtemp(prefix="rendprop-workspace-inventory-"))
    out.mkdir(parents=True, exist_ok=True)
    assert not any(out.iterdir()), "Evidence output must be empty"
    tracked = [RUNNER, Path(__file__).resolve(), *[
        SQL / "functions" / name for name in
        ("me/workspaces.test.ts", "me/billing.test.ts", "listings/create.test.ts")]]
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in tracked}
    receipt = {"passed": False, "sourceHashes": hashes, "controls": [],
               "limits": ["Synthetic output against compiled actual parser; no Deno handler, SQL, network, or provider execution"]}
    print(f"EVIDENCE: {out}", flush=True)
    try:
        tree = ast.parse(RUNNER.read_text())
        gate, inventory, module = compile_gate(tree)
        receipt["compiledFunctionAstSha256"] = hashlib.sha256(ast.dump(module).encode()).hexdigest()
        receipt["handlerInventory"] = inventory
        blocks = output_blocks(inventory)
        total = sum(inventory.values())
        billing_count = inventory["me/billing.test.ts"]
        assert billing_count > 1, "Duplicate-result control requires at least two cases"
        summary = f"ok | {total} passed | 0 failed (1ms)\n"
        valid = "".join(blocks) + summary
        gate(valid)
        receipt["validInventoryAccepted"] = True

        def refused(name, output, expected, candidate=gate):
            try:
                candidate(output)
            except AssertionError as error:
                assert str(error) == expected, (name, "Wrong refusal", str(error))
                receipt["controls"].append({"name": name, "refused": True, "namedFailure": str(error)})
                return
            raise AssertionError(f"{name}: defective inventory was accepted")

        file_registration = "Every audited handler file must register exactly once"
        file_identity = "Unexpected or duplicate handler file"
        case_inventory = "Every case in me/billing.test.ts must report one distinct pass"
        summary_inventory = "Ignored, filtered, missing or failed handler cases are refused"
        refused("missing-file", "".join(blocks[:-1]) + summary, file_registration)
        refused("duplicated-file", blocks[0] + blocks[0] + blocks[2] + summary, file_identity)
        refused("unexpected-file", valid.replace("me/billing.test.ts", "me/unrelated.test.ts"), file_identity)
        refused("wrong-file-registration", valid.replace(f"running {billing_count} tests", f"running {billing_count - 1} tests"),
                "Incomplete handler inventory for me/billing.test.ts")
        changed = list(blocks)
        changed[1] = changed[1].replace("fixture case 0 ... ok (1ms)\n", "", 1)
        refused("missing-case-result", "".join(changed) + summary, case_inventory)
        changed = list(blocks)
        changed[1] = changed[1].replace("fixture case 1 ... ok (1ms)", "fixture case 0 ... ok (1ms)", 1)
        refused("duplicated-case-result", "".join(changed) + summary, case_inventory)
        refused("incomplete-summary", "".join(blocks) + summary.replace(f"{total} passed", f"{total - 1} passed"), summary_inventory)
        for label in ("ignored", "filtered out"):
            refused(label, "".join(blocks) + summary.replace("0 failed", f"0 failed | 1 {label}"), summary_inventory)
        refused("failed-summary", "".join(blocks) + summary.replace("0 failed", "1 failed"), summary_inventory)
        refused("missing-summary", "".join(blocks), summary_inventory)
        refused("duplicated-summary", valid + summary, summary_inventory)

        # Compile actual-source mutants and prove the same controls would go red
        # if either authority check were removed, rather than merely checking
        # that some arbitrary AssertionError can be produced.
        for label, message, broken in (
            ("remove-distinct-case-pass", case_inventory, "".join(changed) + summary),
            ("remove-summary-inventory", summary_inventory,
             "".join(blocks) + summary.replace("0 failed", "0 failed | 1 ignored")),
        ):
            mutant = copy.deepcopy(tree)
            matches = [node for node in ast.walk(mutant) if isinstance(node, ast.Assert) and
                       ((isinstance(node.msg, ast.Constant) and node.msg.value == message) or
                        (isinstance(node.msg, ast.JoinedStr) and label == "remove-distinct-case-pass" and
                         any(isinstance(value, ast.Constant) and value.value == "Every case in "
                             for value in node.msg.values)))]
            assert len(matches) == 1, (label, "Exactly one actual authority assertion must be mutated")
            matches[0].test = ast.Constant(value=True)
            candidate, _, _ = compile_gate(mutant)
            candidate(broken)
            try:
                refused(label, broken, message, candidate)
            except AssertionError as error:
                assert str(error) == f"{label}: defective inventory was accepted"
                receipt.setdefault("mutationControls", []).append({"name": label, "controlWentRed": True,
                                                                     "namedFailure": str(error)})
            else:
                raise AssertionError(f"{label}: inventory proof failed to detect the compiled mutant")

        receipt["sourceHashesAfter"] = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                                      for name in hashes}
        receipt["sourceBindingsMatch"] = receipt["sourceHashesAfter"] == hashes
        assert receipt["sourceBindingsMatch"], "Source changed during inventory verification"
        receipt["passed"] = True
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"PASS: complete {total}-case inventory; {len(receipt['controls'])} refusals; two compiled guard-removal controls", flush=True)


if __name__ == "__main__":
    main()
