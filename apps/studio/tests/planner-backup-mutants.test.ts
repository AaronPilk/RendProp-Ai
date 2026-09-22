import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { transform } from "esbuild";
import * as actual from "../src/workspace";

const source = readFileSync(new URL("../src/workspace.ts", import.meta.url), "utf8");
const item: actual.PlanItem = {
  id: "test-post", title: "Open house", caption: "Preview caption",
  channel: "Instagram", date: "2026-09-15T12:30", createdAt: "2026-09-12T12:00:00Z",
};
const envelope = { format: "rendprop-content-plans", version: 1, exportedAt: "2026-09-12T12:00:00Z", plans: [item] };
type Module = typeof actual;
const controls: { name: string; before: string; after: string; probe: (module: Module) => void | Promise<void> }[] = [
  {
    name: "unknown backup version accepted",
    before: 'value.format!=="rendprop-content-plans"||value.version!==1',
    after: 'value.format!=="rendprop-content-plans"',
    probe: (module) => assert.throws(() => module.parsePlanBackup(JSON.stringify({ ...envelope, version: 2 }))),
  },
  {
    name: "merge silently creates duplicate IDs",
    before: "if(overlaps)", after: "if(false)",
    probe: (module) => assert.throws(() => module.previewPlanImport([item], [item], "merge")),
  },
  {
    name: "merge permits combined count 101",
    before: "if(existing.length+incoming.length>MAX_PLANS)", after: "if(false)",
    probe: (module) => assert.throws(() => module.previewPlanImport(
      Array.from({ length: 100 }, (_, i) => ({ ...item, id: `p-${i}` })), [item], "merge")),
  },
  {
    name: "stale replace preview overwrites a newer edit",
    before: "if(planImportSnapshot(current)!==reviewedSnapshot)", after: "if(false)",
    probe: (module) => assert.throws(() => module.confirmPlanImport(
      [{ ...item, title: "Newer edit" }], [], "replace", module.planImportSnapshot([item]), () => {})),
  },
  {
    name: "invalid UTF-8 silently replaces caption bytes",
    before: 'new TextDecoder("utf-8",{fatal:true})', after: 'new TextDecoder("utf-8",{fatal:false})',
    probe: async (module) => {
      const bytes = new TextEncoder().encode(JSON.stringify(envelope));
      const position = Buffer.from(bytes).indexOf(Buffer.from("Preview caption"));
      assert(position > 0, "the invalid byte must be inside the actual caption string");
      bytes[position] = 0xff;
      await assert.rejects(module.readPlanBackupFile(new Blob([bytes])));
    },
  },
  {
    name: "escape-heavy import writes a draft that cannot reopen",
    before: 'if(text.length>500_000)throw new Error("These plans exceed browser draft storage limits. Existing plans were not changed.");',
    after: "",
    probe: (module) => {
      const plans = Array.from({ length: 100 }, (_, i) => ({ ...item, id: `p-${i}`, caption: "\u0001".repeat(2200) }));
      let writes = 0;
      assert.throws(() => module.writePlans({ getItem: () => null, setItem: () => { writes++; } }, "local", plans));
      assert.equal(writes, 0);
    },
  },
];
for (const [index, control] of controls.entries()) {
  test(`backup negative control catches: ${control.name}`, async () => {
    await control.probe(actual);
    const anchor = new RegExp([...control.before].map((char) => char.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("\\s*"), "g");
    assert.equal([...source.matchAll(anchor)].length, 1, "control must mutate exactly one actual source location");
    const changed = source.replace(anchor, control.after);
    assert.notEqual(changed, source);
    const { code } = await transform(changed, { loader: "ts", target: "es2022", format: "esm", keepNames: false });
    const mutant = await import(`data:text/javascript;base64,${Buffer.from(code).toString("base64")}#backup-${index}`) as Module;
    await assert.rejects(async () => control.probe(mutant), assert.AssertionError,
      "the identical positive probe must fail on the deliberate source defect");
  });
}
test("backup mutation receipt binds actual source and six executed controls", (context) => {
  assert.equal(controls.length, 6);
  context.diagnostic(JSON.stringify({ source: "src/workspace.ts", sha256: createHash("sha256").update(source).digest("hex"), negative_controls: controls.length }));
});
