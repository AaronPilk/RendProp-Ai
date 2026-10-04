// Actual public renderer + actual Edge response filter, synthetic data only.
// No credentials, customer files, HTTP, provider calls or runtime source edits.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

globalThis.fetch = async () => { throw new Error("This offline renderer fixture must not use the network"); };

const here = dirname(fileURLToPath(import.meta.url));
const host = resolve(here, "../../../edge/tour-host");
const { buildSrc } = await import(pathToFileURL(resolve(host, "scripts/build-src.mjs")).href);
const ts = createRequire(resolve(host, "package.json"))("typescript");
const source = readFileSync(resolve(here, "index.ts"), "utf8");
const start = source.indexOf("function publicListingDetails(");
const end = source.indexOf("\n}\n", start);
assert.ok(start >= 0 && end > start, "Actual response filter must exist");
const helper = source.slice(start, end + 3);
const { outputText } = ts.transpileModule(`${helper}\nexport {publicListingDetails};`, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
});
const { publicListingDetails } = await import("data:text/javascript;base64," + Buffer.from(outputText).toString("base64"));
const load = buildSrc(`floor-measurement-public-check-${process.pid}`);
const { renderTourPage, sanitizeTourForUnbranded } = await load("player");
const { buildDemoTour } = await load("demo");
const secret = "PrivateOnlyMeasurementRendererSentinel";
const privateWire = JSON.stringify({ version: 1, unit: "meters", rooms: [{ name: secret, widthMeters: 3, lengthMeters: 4 }], updatedAt: 1000 });
let renderings = 0;
for (const type of ["real_estate", "venue", "restaurant", "retail", "fitness", "other"]) {
  const tour = buildDemoTour();
  tour.space_type = type;
  const original = { ...tour.listing.details, floor_measurements_v1: privateWire, floor_measurements_v9: secret, unrelated_fact: "Public future property fact" };
  tour.listing.details = publicListingDetails(original);
  assert.equal(original.floor_measurements_v1, privateWire, "Owner details retain the private wire");
  assert.equal(tour.listing.details.unrelated_fact, original.unrelated_fact, "Unrelated public facts remain untouched");
  const sanitized = sanitizeTourForUnbranded(tour);
  assert.equal(sanitized.listing.details.floor_measurements_v1, undefined, "The unbranded input cannot recover filtered measurement data");
  for (const options of [{}, { unbranded: true }, { embed: true }, { embed: true, unbranded: true }]) {
    const html = renderTourPage(tour, "https://functions-fixture.invalid/v1", "fixture-public-key", "", options);
    assert.ok(!html.includes(secret) && !html.toLowerCase().includes("floor_measurements_"), "Measurement metadata must not reach HTML, attributes or inline scripts");
    renderings += 1;
  }
}
console.log(`PASS: ${renderings} actual branded/unbranded/embed renderer cases; private measurement metadata absent; owner details unchanged; zero network calls`);
