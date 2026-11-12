/* Pure source/transform controls only. No browser, build, or media generation. */
import assert from "node:assert/strict";
import test from "node:test";
import {readFile} from "node:fs/promises";
import {createHash} from "node:crypto";
import {join, resolve, relative, extname} from "node:path";
import {EXPORT_SOURCE_PATHS} from "./export-source-binding.mjs";
import {simulatedUnsupportedEncoderPlugin, simulatedFinalizeHangPlugin,
  reducedOutputCapacityPlugin} from "./export-backend-observer.mjs";
import {assertSeekCentroidMapping} from "./export-webcodecs-oracles.mjs";

const root = resolve(import.meta.dirname, "..");
test("receipt inventory includes the actual main/worker exporter import graph", async () => {
  const seen = new Set(), pending = ["src/editor/export.ts"];
  while (pending.length) {
    const path = pending.pop();
    if (seen.has(path)) continue;
    seen.add(path);
    assert(EXPORT_SOURCE_PATHS.includes(path), "Missing actual export dependency " + path);
    const code = await readFile(join(root, path), "utf8");
    for (const match of code.matchAll(/(?:from\s*|import\s*\(\s*)["'](\.\/[^"']+)["']/g)) {
      let target = resolve(join(root, path, ".."), match[1].split("?")[0]);
      if (!extname(target)) target += ".ts";
      pending.push(relative(root, target));
    }
  }
  assert(seen.has("src/editor/encoder-worker.ts"));
  assert(seen.has("src/editor/export-pcm-worklet.js"));
});

for (const [name, make, path, before, after] of [
  ["unsupported", simulatedUnsupportedEncoderPlugin, "encoder-worker.ts",
    "if (!await isEncoderConfigurationSupported(config))",
    "if (!await isEncoderConfigurationSupported(config).then(() => false))"],
  ["finalize", simulatedFinalizeHangPlugin, "encoder-worker.ts",
    "await output!.finalize();",
    'self.postMessage({__rendpropExportTest:"finalize-entered"}); await new Promise<void>(()=>{});'],
  ["capacity", reducedOutputCapacityPlugin, "encoder-output.ts",
    "MAX_EXTENT=PAGE_BYTES*MAX_PAGES", "MAX_EXTENT=256"],
]) test(name + " control changes only its exact intended compiled source seam", async () => {
  const file = join(root, "src/editor", path), code = await readFile(file, "utf8"), plugin = make();
  assert.equal(plugin.transform(code, "/unrelated.ts"), undefined);
  const changed = plugin.transform(code, file);
  assert.equal(changed, code.replace(before, after));
  assert.equal(plugin.matchedSourceCount, 1);
  assert.throws(() => make().transform(code.replace(before, ""), file));
  assert.throws(() => make().transform(code + "\n" + before, file));
});

test("integrated combined oracle keeps the reviewed strict decoded-media body", async () => {
  const code = await readFile(join(root, "tests/export-webcodecs-oracles.mjs"), "utf8");
  const body = code.slice(code.indexOf("const RATE"), code.indexOf("export function verifyPlannedOutput")).trim();
  assert.equal(createHash("sha256").update(body).digest("hex"),
    "c4053b4578e8e72add593a8e5b388f595b3f1d60d2955bf4d4bc53a5ea5283de");
});

test("exact120fps seek oracle accepts matched frames and rejects duplicated or shifted source frames", () => {
  const source = Array.from({length: 120}, (_, index) => 55.5 + 6 * index);
  const output = source.slice(30, 90).map(value => 1.6 * (value + .5) - .5);
  assert.equal(assertSeekCentroidMapping(source, output).maximumError, 0);
  assert.throws(() => assertSeekCentroidMapping(source,
    output.map((_, index) => output[index - index % 2])), /wrong120fps|repeated or skipped/);
  assert.throws(() => assertSeekCentroidMapping(source, output.map(value => value + 9.6)), /wrong120fps/);
  assert.throws(() => assertSeekCentroidMapping(source.map(() => source[0]), output), /six pixels/);
});
