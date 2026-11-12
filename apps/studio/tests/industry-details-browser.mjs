import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, writeFile, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "node:http";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";

const root = fileURLToPath(new URL("../", import.meta.url)), artifacts = await mkdtemp(join(tmpdir(), "rendprop-industry-browser-")), dist = join(artifacts, "dist");
const receipt = { proof: "Actual Studio business forms with closed synthetic account transport; no live customer or provider requests", checks: [], externalRequests: [], errors: [] };
async function sourceManifest() {
  const files = [];
  async function visit(dir) { for (const entry of await readdir(join(root, dir), { withFileTypes: true })) { const name = `${dir}/${entry.name}`; if (entry.isDirectory()) await visit(name); else files.push(name); } }
  await visit("src"); await visit("tests");
  files.push("package.json", "package-lock.json", "tsconfig.json", "index.html");
  return Object.fromEntries(await Promise.all([...new Set(files)].sort().map(async path => [path, createHash("sha256").update(await readFile(join(root,path))).digest("hex")])));
}
receipt.sourceHashes = await sourceManifest();
let browser, server;
try {
  await build({ configFile: false, root, publicDir: false, logLevel: "error", build: { outDir: dist, rollupOptions: { input: join(root, "tests/listing-workflow-fixture.html") } } });
  server = createServer(async (request, response) => { const path = resolve(dist, `.${new URL(request.url, "http://localhost").pathname}`); if (!path.startsWith(`${dist}/`)) return response.writeHead(400).end(); try { response.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css" })[extname(path)] ?? "application/octet-stream"); response.end(await readFile(path)); } catch { response.writeHead(404).end(); } });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, serviceWorkers: "block" });
  await context.route("**/*", (route) => { if (new URL(route.request().url()).origin === origin && route.request().method() === "GET") return route.continue(); receipt.externalRequests.push(route.request().url()); return route.abort(); });
  const page = await context.newPage(); page.on("pageerror", (e) => receipt.errors.push(e.message)); page.setDefaultTimeout(6000);
  const tab = () => page.getByRole("tab",{name:/Details/});
  await page.goto(`${origin}/tests/listing-workflow-fixture.html?industry=venue`);await tab().click();
  await expect(page.getByLabel("Max seated guests",{exact:true})).toHaveValue("20");await expect(page.getByLabel("Bedrooms",{exact:true})).toBeHidden();await expect(page.getByRole("button",{name:"Mark sold",exact:true})).toBeHidden();await expect(page.getByRole("button",{name:"Look up property facts",exact:true})).toBeHidden();
  await page.getByLabel("Max seated guests",{exact:true}).fill("45");await page.getByLabel("Booking / inquiry link",{exact:true}).fill("https://new.fixture.invalid");
  await page.evaluate(()=>window.listingFixture.phoneDetails({hours:"Phone-side opening hours"}));
  await page.getByRole("button",{name:"Save business details",exact:true}).click();await expect(page.getByRole("button",{name:"Save business details",exact:true})).toBeEnabled();
  let state=await page.evaluate(()=>window.listingFixture.snapshot());assert.equal(state.listings[0].details.capacitySeated,"45");assert.equal(state.listings[0].details.hours,"Phone-side opening hours");assert.deepEqual(state.listings[0].details.imported_nested,{source:"MLS",pending:null});assert.equal(state.listings[0].priceCents,45000000);assert.equal(state.listings[0].beds,3);
  let call=(await page.evaluate(()=>window.listingFixture.calls())).filter(c=>c.path.endsWith("/facts")).at(-1);assert.deepEqual(call.body.changes,{});assert.deepEqual(call.body.details_expected,{capacitySeated:{present:true,value:20},bookingUrl:{present:true,value:"https://old.fixture.invalid"}});
  receipt.checks.push("Venue form hides housing facts/sold/public-record controls, preserves typed raw expectations, unrelated phone details and existing facts");
  await page.getByLabel("Max seated guests",{exact:true}).fill("46");await page.evaluate(()=>window.listingFixture.phoneDetails({capacitySeated:"50"}));await page.getByRole("button",{name:"Save business details",exact:true}).click();await expect(page.getByRole("button",{name:"Save business details",exact:true})).toBeDisabled();await expect(page.getByLabel("Max seated guests",{exact:true})).toHaveValue("46");await page.getByRole("button",{name:"Reload latest details and discard these field edits"}).click();await expect(page.getByLabel("Max seated guests",{exact:true})).toHaveValue("50");
  receipt.checks.push("Same business-detail conflict retains the Studio draft and requires explicit reload of the phone winner");
  await tab().click();await page.getByLabel("Business type",{exact:true}).selectOption("restaurant");await expect(page.getByLabel("Reservations link",{exact:true})).toBeVisible();await expect(page.getByLabel("Max seated guests",{exact:true})).toBeHidden();await page.getByLabel("Reservations link",{exact:true}).fill("https://tables.fixture.invalid");await page.getByRole("button",{name:"Save business details",exact:true}).click();await expect(page.getByRole("button",{name:"Save business details",exact:true})).toBeEnabled();state=await page.evaluate(()=>window.listingFixture.snapshot());assert.equal(state.listings[0].spaceType,"restaurant");assert.equal(state.listings[0].details.reservationUrl,"https://tables.fixture.invalid");assert.equal(state.listings[0].details.capacitySeated,"50");
  receipt.checks.push("Deliberate industry change shows matching controls and preserves hidden previous industry details");
  for(const [industry,label,value]of[["restaurant","Reservations link","https://table.fixture.invalid"],["retail","Online store / website","https://store.fixture.invalid"],["fitness","Booking / schedule link","https://gym.fixture.invalid"],["other","Website","https://business.fixture.invalid"]]){
    await page.goto(`${origin}/tests/listing-workflow-fixture.html?industry=${industry}`);await tab().click();await expect(page.getByLabel("Bedrooms",{exact:true})).toBeHidden();await page.getByLabel(label,{exact:true}).fill(value);await page.getByRole("button",{name:"Save business details",exact:true}).click();await expect(page.getByRole("button",{name:"Save business details",exact:true})).toBeEnabled();const request=(await page.evaluate(()=>window.listingFixture.calls())).filter(c=>c.path.endsWith("/facts")).at(-1);assert.equal(Object.values(request.body.details_changes)[0],value);assert.deepEqual(request.body.changes,{});receipt.checks.push(`${industry} matching form saves one explicit business field through facts CAS`);
  }
  await page.setViewportSize({width:390,height:844});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),true);await page.screenshot({path:join(artifacts,"business-form-mobile.png"),fullPage:true});assert.deepEqual(receipt.errors,[]);assert.deepEqual(receipt.externalRequests,[]);assert.deepEqual(await sourceManifest(),receipt.sourceHashes,"Source changed during browser verification");receipt.status="passed";await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2));console.log(JSON.stringify({...receipt,artifacts},null,2));
} finally { await browser?.close(); if (server) await new Promise((done) => server.close(done)); }
