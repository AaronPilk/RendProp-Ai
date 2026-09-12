import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { transform } from "esbuild";
import * as actual from "../src/workspace";

// Mutate the actual module in memory. A guard which never runs must not receive a green
// report merely because an independent reimplementation happens to reject the fixture.
const source = readFileSync(
  new URL("../src/workspace.ts", import.meta.url),
  "utf8",
);
const sourceHash = createHash("sha256").update(source).digest("hex");
const item = {
  id: "test-post",
  title: "Open house",
  caption: "A room\rATTENDEE:someone",
  channel: "Instagram" as const,
  date: "2026-09-15T12:30",
  createdAt: "2026-09-12T12:00:00Z",
};
type Module = typeof actual;
const controls: {
  name: string;
  before: string;
  after: string;
  probe: (module: Module) => void;
}[] = [
  {
    name: "impossible date guard removed",
    before:
      "if(year<1000||!Number.isFinite(time)||new Date(time).toISOString().slice(0,16)!==value)",
    after: "if(false)",
    probe: (module) =>
      assert.throws(() =>
        module.validatePlanItem({ ...item, date: "2026-02-30T12:30" }),
      ),
  },
  {
    name: "repeated DST hour silently defaults to first",
    before: "if(choices.length>1&&!choice)",
    after: "if(false)",
    probe: (module) =>
      assert.throws(() =>
        module.bindPlanDate("2026-11-01T01:30", "America/New_York"),
      ),
  },
  {
    name: "capacity raised to accept entry 101",
    before: "items.length>MAX_PLANS",
    after: "items.length>MAX_PLANS+1",
    probe: (module) =>
      assert.throws(() =>
        module.savePlan(
          Array.from({ length: 100 }, (_, i) => ({ ...item, id: `post-${i}` })),
          item,
        ),
      ),
  },
  {
    name: "edit appends a duplicate instead of replacing",
    before: "return existing.map((p)=>(p.id===editingId?next:p));",
    after: "return [...existing,next];",
    probe: (module) =>
      assert.equal(
        module.savePlan([item], { ...item, title: "Edited" }, item.id).length,
        1,
      ),
  },
  {
    name: "old newline escape leaves a lone carriage return",
    before: ".replace(/\\r\\n|\\r|\\n/g,",
    after: ".replace(/\\r?\\n/g,",
    probe: (module) =>
      assert.equal(
        module.calendarFile(item).replace(/\r\n/g, "").includes("\r"),
        false,
      ),
  },
  {
    name: "export ignores timezone-bound UTC instant",
    before:
      "item.scheduledAt??bindPlanDate(item.date,currentTimeZone()).scheduledAt",
    after: "bindPlanDate(item.date,currentTimeZone()).scheduledAt",
    probe: (module) => {
      const previous = process.env.TZ;
      try {
        process.env.TZ = "Asia/Tokyo";
        assert.match(
          module.calendarFile({
            ...item,
            ...module.bindPlanDate(item.date, "America/New_York"),
          }),
          /DTSTART:20260915T163000Z/,
        );
      } finally {
        if (previous === undefined) delete process.env.TZ;
        else process.env.TZ = previous;
      }
    },
  },
];
for (const [index, control] of controls.entries())
  test(`negative control catches: ${control.name}`, async () => {
    control.probe(actual);
    // Match only whitespace differences introduced by the repository formatter.
    // Exactly one actual location must still match, and its runtime defect must fail.
    const anchor = new RegExp([...control.before].map(char => char.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("\\s*"), "g");
    assert.equal(
      [...source.matchAll(anchor)].length,
      1,
      "mutant must target exactly one actual source location",
    );
    const changed = source.replace(anchor, control.after);
    assert.notEqual(changed, source);
    const { code: javascript } = await transform(changed, {
      loader: "ts",
      target: "es2022",
      format: "esm",
      keepNames: false,
    });
    const mutant = (await import(
      `data:text/javascript;base64,${Buffer.from(javascript).toString("base64")}#planner-mutant-${index}`
    )) as Module;
    assert.throws(
      () => control.probe(mutant),
      assert.AssertionError,
      "the same passing production probe must fail on the deliberate defect",
    );
  });
test("mutation receipt binds the actual source bytes and a nonzero control inventory", (context) => {
  assert.equal(controls.length, 6);
  context.diagnostic(
    JSON.stringify({
      source: "src/workspace.ts",
      sha256: sourceHash,
      negative_controls: controls.length,
    }),
  );
});
