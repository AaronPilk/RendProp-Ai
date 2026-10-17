import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join, resolve, extname } from "node:path";
import { createServer } from "node:http";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";

// Actual CreativeWorkspace "Review your edit" + PhotoFeedbackControl + feedback queue + real Studio
// transport, and the actual admin report page, against a local contract-shaped fixture server.
// Synthetic ids and images only; no hosted, provider or paid call. Set PHOTO_FEEDBACK_EVIDENCE to
// copy the screenshots to a folder.
const root = resolve(import.meta.dirname, ".."), artifacts = await mkdtemp(join(tmpdir(), "rendprop-photo-feedback-browser-")), dist = join(artifacts, "dist");
const receipt = { proof: "Actual Review your edit, feedback control/queue and admin report over the real Studio transport; isolated fixture server, no hosted or paid calls", checks: [], externalRequests: [], errors: [], status: "pending" };
const ACTOR = "11111111-1111-4111-8111-1111111111f1", ORG = "22222222-2222-4222-8222-2222222222f1", LISTING = "33333333-3333-4333-8333-3333333333f1";
const [P1, P2] = ["77777777-7777-4777-8777-0000000000a1", "77777777-7777-4777-8777-0000000000a2"], TOKEN = "Bearer closed-feedback-browser-fixture";
const PROMPT = "Remove movable clutter only; keep fixed features and actual property condition.";
const REASONS = ["Changed permanent property features", "Moved or changed an appliance", "Blocked a doorway or opening", "Inconsistent furniture between views",
  "Visible visual artifacts", "Requested edit was incomplete", "Personal style preference", "Other"];
const report = JSON.parse(await readFile(join(root, "tests/fixtures/photo-feedback-report-synthetic.json"), "utf8"));
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
const screenshots = [];

// §4.1/§4.2 behavior of the photo-feedback edge function, enough to observe the client honestly.
const state = { received: [], rows: new Map(), bound: new Map(), signalRows: new Map(), admin: [], hold: false, held: [], reportMode: "ok" };
function feedback(body) {
  const id = body.output.provenance_id, key = body.client_key, owner = state.bound.get(key), row = state.rows.get(id);
  if (owner && owner !== id) return [409, { error: "fixture", code: "feedback_key_conflict" }];
  const reply = (status, value) => [200, { feedback_id: `f-${id}`, provenance_id: id, revision: value.revision, revision_count: value.revision_count, state: status, verdict: value.verdict,
    reasons: value.reasons, note: value.note ?? null, attribution: { basis: "evidence", evidence_id: null, edit: "custom", provider: null, model: null, generation_stage: null, recipe_revision: null, prompt_sha256: null, attempts_known: false } }];
  const content = { verdict: body.verdict, reasons: body.reasons, note: body.note ?? null };
  if (!row) { const created = { client_key: key, revision: body.revision, revision_count: 1, ...content }; state.rows.set(id, created); state.bound.set(key, id); return reply("recorded", created); }
  if (row.client_key !== key) return [409, { error: "fixture", code: "feedback_exists", client_key: row.client_key, revision: row.revision, revision_count: row.revision_count }];
  if (body.revision <= row.revision) return body.revision < row.revision || JSON.stringify(content) === JSON.stringify({ verdict: row.verdict, reasons: row.reasons, note: row.note })
    ? reply("replayed", row) : [409, { error: "fixture", code: "feedback_revision_conflict" }];
  Object.assign(row, content, { revision: body.revision, revision_count: row.revision_count + 1 });
  return reply("revised", row);
}
function signal(body) {
  const prior = state.signalRows.get(body.client_key);
  if (prior && prior.provenance !== body.output.provenance_id) return [409, { error: "fixture", code: "feedback_key_conflict" }];
  if (!prior) state.signalRows.set(body.client_key, { provenance: body.output.provenance_id, signal: body.signal, detail: body.detail });
  return [200, { signal_id: `s-${body.client_key}`, state: prior ? "replayed" : "recorded" }];
}
async function api(req, res, url) {
  const send = ([status, value]) => { res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" }); res.end(JSON.stringify(value)); };
  if (req.headers.authorization !== TOKEN || req.headers.apikey !== "sb_publishable_OFFLINE_FIXTURE_NOT_A_REAL_KEY") return send([401, { error: "fixture", code: "unauthorized" }]);
  if (url.pathname === "/functions/v1/me/workspaces") return send([200, { actor_id: ACTOR, own_org_id: ORG, billing_org_id: ORG, active_org_id: ORG, can_switch_agent_libraries: false,
    workspaces: [{ id: ORG, name: "Fixture office", role: "owner", access_mode: "own", library_owner_user_id: ACTOR, billing_org_id: ORG, can_read: true, can_write: true, can_manage_subscription: true }] }]);
  if (url.pathname === "/functions/v1/me") return send([200, { user: { id: ACTOR, email: null, name: "Agent", avatar_url: null }, org: { id: ORG, name: "Fixture office", space_type: "real_estate", handle: null },
    billing: { org_id: ORG, content_org_id: ORG, serving_org_id: ORG, role: "owner", can_manage_subscription: true }, plan: "team", plan_raw: "team", trial_ends_at: null, plan_expires_at: null,
    usage: { listings: 1, leads: 0, leads_new: 0, renders: 0 } }]);
  if (url.pathname === "/functions/v1/listings") return send([200, { actor_id: ACTOR, total: 1, next_offset: null, listings: [{ id: LISTING, org_id: ORG, library_org_id: ORG, space_type: "real_estate",
    address: "10 Fixture Lane", tagline: null, details: {}, status: "ready", created_at: "2026-10-17T00:00:00Z", deleted_at: null, main_photo_key: null, beds: 3, baths: 2, sqft: 1800, price_cents: null }] }]);
  if (url.pathname === "/functions/v1/admin/photo-feedback" && req.method === "GET") {
    state.admin.push({ window: url.searchParams.get("window"), org: req.headers["x-org-id"] });
    return send(state.reportMode === "deny" ? [403, { error: "Admin access is required for this console.", code: "forbidden", reason: "not_admin" }] : [200, { ...report, window: url.searchParams.get("window") }]);
  }
  if (req.method === "POST" && (url.pathname === "/functions/v1/photo-feedback" || url.pathname === "/functions/v1/photo-feedback/signal")) {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const raw = Buffer.concat(chunks).toString("utf8"), body = JSON.parse(raw), entry = { path: url.pathname, raw, body, org: req.headers["x-org-id"], answered: false };
    state.received.push(entry);
    const answer = () => { entry.answered = true; send(url.pathname.endsWith("/signal") ? signal(body) : feedback(body)); };
    if (state.hold) state.held.push(answer); else answer();
    return;
  }
  send([404, { error: "fixture", code: "not_found" }]);
}
const posts = path => state.received.filter(entry => entry.path === `/functions/v1/photo-feedback${path}`);

let browser, server, page;
try {
  await build({ configFile: false, root, publicDir: false, logLevel: "error", build: { outDir: dist, rollupOptions: { input: join(root, "tests/photo-feedback-fixture.html") } } });
  server = createServer(async (req, res) => {
    const url = new URL(req.url, "http://local");
    if (url.pathname.startsWith("/functions/v1/")) return api(req, res, url).catch(error => { res.writeHead(500).end(); receipt.errors.push(`fixture server: ${error.message}`); });
    const path = resolve(dist, `.${url.pathname}`);
    if (!path.startsWith(`${dist}/`) || req.method !== "GET") return res.writeHead(400).end();
    try { res.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css" })[extname(path)] ?? "application/octet-stream"); res.end(await readFile(path)); } catch { res.writeHead(404).end(); }
  });
  await new Promise(done => server.listen(0, "127.0.0.1", done)); const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, serviceWorkers: "block", acceptDownloads: true });
  // Same-origin traffic is never intercepted, so offline emulation applies to it unchanged.
  await context.route(url => url.origin !== origin, route => { receipt.externalRequests.push(route.request().url()); return route.abort(); });
  page = await context.newPage(); page.setDefaultTimeout(15000); page.on("pageerror", error => receipt.errors.push(error.message));
  const shot = async (target, name, fullPage = false) => { const path = join(artifacts, name); await target.screenshot(fullPage ? { path, fullPage } : { path }); screenshots.push(path); };
  await page.goto(`${origin}/tests/photo-feedback-fixture.html`);
  await expect(page.getByText("Your saved draft is ready", { exact: true })).toBeVisible();
  const source = await page.evaluate(() => { const canvas = document.createElement("canvas"); canvas.width = 800; canvas.height = 600; const draw = canvas.getContext("2d"); draw.fillStyle = "#2f5fb3"; draw.fillRect(0, 0, 800, 600); return canvas.toDataURL("image/png").split(",")[1]; });
  await page.locator('input[type="file"]').first().setInputFiles({ name: "living-room.png", mimeType: "image/png", buffer: Buffer.from(source, "base64") });
  await page.getByRole("button", { name: /^Ask for anything\s+Describe/ }).click();
  await page.getByRole("textbox", { name: "Your edit", exact: true }).fill(PROMPT);
  await page.getByRole("button", { name: "Generate preview", exact: true }).click();
  const review = page.locator("section").filter({ has: page.getByRole("heading", { name: "Review your edit", exact: true }) }).last();
  const control = review.getByRole("group", { name: "Rate this edit", exact: true }), status = control.getByRole("status");
  const ack = review.getByRole("checkbox", { name: /I compared the preview with the original/ }), save = review.getByRole("button", { name: "Save version", exact: true });
  await expect(control).toBeVisible();
  await expect(control.getByRole("button", { name: "Useful", exact: true })).toHaveAttribute("aria-pressed", "false");
  await expect(control.getByRole("button", { name: "Needs work", exact: true })).toHaveAttribute("aria-pressed", "false");
  await expect(ack).not.toBeChecked(); await expect(save).toBeDisabled(); await expect(review.getByRole("button", { name: "Download photo", exact: true })).toBeDisabled();
  receipt.checks.push("A custom edit's Review your edit shows the optional Useful / Needs work control below the actions; the fixed-features acknowledgment still gates Save and Download");

  // Offline: the verdict is stored before any request and shown as waiting; nothing reaches the server.
  await context.setOffline(true);
  assert.equal(await page.evaluate(() => navigator.onLine), false);
  await control.getByRole("button", { name: "Needs work", exact: true }).click();
  const reasons = control.getByRole("group", { name: "What needs work?", exact: true });
  assert.deepEqual(await reasons.getByRole("checkbox").evaluateAll(boxes => boxes.map(box => box.closest("label").textContent.trim())), REASONS);
  await expect(control.getByRole("button", { name: "Send feedback", exact: true })).toBeDisabled();
  await reasons.getByRole("checkbox", { name: "Moved or changed an appliance", exact: true }).check();
  await reasons.getByRole("checkbox", { name: "Other", exact: true }).check();
  await control.getByRole("textbox", { name: "Tell us more (optional)", exact: true }).fill("The fridge moved to the left wall.");
  await control.getByRole("button", { name: "Send feedback", exact: true }).click();
  await expect(status).toHaveText("Will send when online");
  await page.waitForTimeout(500);
  assert.equal(state.received.length, 0, "offline: no feedback request reached the server");
  const stored = await page.evaluate(() => Object.entries(localStorage).filter(([key]) => key.startsWith("rendprop-photo-feedback-v1:")));
  assert.equal(stored.length, 1); const queued = JSON.parse(stored[0][1]);
  assert.equal(stored[0][0], `rendprop-photo-feedback-v1:${ACTOR}:${ORG}:${P1}`);
  assert.equal(queued.state, "queued"); assert.match(queued.body.client_key, /^studio:[0-9a-f-]{36}$/); assert.equal(queued.body.revision, 1);
  assert.deepEqual([queued.body.verdict, queued.body.reasons, queued.body.note], ["needs_work", ["moved_or_changed_appliance", "other"], "The fridge moved to the left wall."]);
  const editedBytes = (await page.evaluate(() => window.feedbackFixture.edited())).map(b64 => Buffer.from(b64, "base64"));
  assert.deepEqual(queued.body.output, { provenance_id: P1, output_sha256: sha(editedBytes[0]) }, "pinned to the exact output bytes on screen");
  await expect(save).toBeDisabled();
  receipt.checks.push("Offline Needs work (two reasons + bounded note) is stored before any request with its own client_key, revision 1 and the output's SHA-256; status says Will send when online; zero requests; Save stays gated by the acknowledgment");

  // Back online: the online event flushes the same stored body exactly once.
  await context.setOffline(false);
  await expect.poll(() => posts("").length).toBe(1);
  await expect(status).toHaveText("Saved");
  await page.waitForTimeout(1500);
  assert.equal(posts("").length, 1, "flushed exactly once");
  assert.equal(posts("")[0].raw, JSON.stringify(queued.body), "the delivered body is byte-identical to the stored one");
  assert.equal(posts("")[0].org, ORG, "the selected library travels as X-Org-Id");
  assert.deepEqual([state.rows.get(P1).revision, state.rows.get(P1).revision_count], [1, 1]);
  // Re-render the workspace: a delivered verdict must never stand in for the acknowledgment.
  await page.getByRole("textbox", { name: "Room or view", exact: true }).fill("Living room");
  await expect(save).toBeDisabled(); await expect(review.getByRole("button", { name: "Download photo", exact: true })).toBeDisabled(); await expect(ack).not.toBeChecked();
  receipt.checks.push("Reconnecting fires one delivery of the byte-identical stored body (no other trigger); the status changes to Saved and no duplicate follows; after a re-render the delivered verdict still does not unlock Save or Download");

  // Feedback requests held open must not delay the acknowledgment, save or download.
  state.hold = true;
  await ack.check(); await expect(save).toBeEnabled();
  await control.getByRole("button", { name: "Useful", exact: true }).click();
  await expect(control.getByRole("button", { name: "Useful", exact: true })).toHaveAttribute("aria-pressed", "true");
  await save.click(); await expect(review.getByRole("button", { name: "Version saved", exact: true })).toBeDisabled();
  await review.getByRole("button", { name: "Download photo", exact: true }).click();
  const panel = review.getByRole("region", { name: "Download photos", exact: true });
  await expect(panel.getByRole("button", { name: "Download photo package", exact: true })).toBeEnabled();
  const downloaded = page.waitForEvent("download"); await panel.getByRole("button", { name: "Download photo package", exact: true }).click();
  const download = await downloaded, zipPath = join(artifacts, "review-download.zip"); await download.saveAs(zipPath);
  const zip = await readFile(zipPath); assert(zip.length > editedBytes[0].length / 4, "the download is a real file"); assert(zip.includes(Buffer.from(P1)), "the ZIP's provenance.json names the reviewed output");
  const unanswered = state.received.filter(entry => !entry.answered);
  assert(unanswered.length >= 1 && unanswered.length === state.held.length, "feedback traffic was still held open");
  assert.deepEqual(state.received.filter(entry => entry.answered), [posts("")[0]], "only the earlier delivery had been answered");
  const saveCalls = (await page.evaluate(() => window.feedbackFixture.calls())).filter(call => call.method !== "GET").map(call => call.path.replace(/[0-9a-f-]{36}/g, "<id>"));
  assert.deepEqual(saveCalls.slice(-4), ["/functions/v1/uploads", "/functions/v1/uploads/<id>/complete", "/functions/v1/me/compliance/<id>", "/functions/v1/studio/photos"]);
  assert(!saveCalls.some(path => path.includes("photo-feedback")), "feedback never travels with the save");
  receipt.checks.push("With every feedback request held open, checking the acknowledgment, Save version (upload → compliance → studio/photos) and the ZIP download all complete unchanged");

  state.hold = false; state.held.splice(0).forEach(answer => answer());
  await expect.poll(() => state.received.filter(entry => !entry.answered).length).toBe(0);
  await expect.poll(() => [...state.signalRows.values()].map(row => `${row.signal}/${row.detail}`).sort().join()).toBe("accuracy_ack/custom_review,export/download,manual_selection/gallery_save");
  await expect(status).toHaveText("Saved");
  await page.waitForTimeout(1000);
  const signalPosts = posts("/signal");
  assert.equal(signalPosts.length, 3, "each signal was sent once"); assert(signalPosts.every(entry => entry.body.output.provenance_id === P1 && entry.body.client_key === `studio:${entry.body.signal}:${P1}`));
  assert.deepEqual([state.rows.size, state.rows.get(P1).revision, state.rows.get(P1).revision_count, state.rows.get(P1).verdict, state.rows.get(P1).client_key], [1, 2, 2, "useful", queued.body.client_key]);
  assert.equal(posts("").length, 2, "one delivery per revision");
  receipt.checks.push("After release: accuracy_ack/custom_review, manual_selection/gallery_save and export/download each arrive once, after their actions; the changed verdict is revision 2 of the same key and row");

  // A second output gets a fresh control and its own key; the first output's row is untouched.
  await review.getByRole("button", { name: "Edit original again", exact: true }).click();
  await page.getByRole("button", { name: "Generate preview", exact: true }).click();
  await expect(review.getByRole("img", { name: "AI edited photo preview" })).toHaveAttribute("src", `data:image/png;base64,${editedBytes[1].toString("base64")}`);
  await expect(control.getByRole("button", { name: "Useful", exact: true })).toHaveAttribute("aria-pressed", "false");
  await expect(status).toHaveText("");
  await control.getByRole("button", { name: "Useful", exact: true }).click();
  await expect.poll(() => posts("").length).toBe(3);
  const second = posts("").at(-1).body;
  assert.deepEqual(second.output, { provenance_id: P2, output_sha256: sha(editedBytes[1]) }); assert.notEqual(second.client_key, queued.body.client_key);
  assert.deepEqual([state.rows.get(P1).verdict, state.rows.get(P1).revision, state.bound.get(queued.body.client_key), state.bound.get(second.client_key)], ["useful", 2, P1, P2]);
  receipt.checks.push("A new output starts with an empty control; its verdict carries its own provenance id, output hash and client_key, and the first output's row is unchanged");

  // Screenshots of the control (desktop and phone width).
  await control.getByRole("button", { name: "Needs work", exact: true }).click();
  await control.getByRole("checkbox", { name: "Changed permanent property features", exact: true }).check();
  await control.scrollIntoViewIfNeeded(); await shot(review, "feedback-control-desktop.png");
  await page.setViewportSize({ width: 390, height: 844 });
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 2), "no horizontal scroll at 390px");
  await control.scrollIntoViewIfNeeded(); await shot(page, "feedback-control-mobile.png");
  await page.setViewportSize({ width: 1440, height: 1000 });
  receipt.checks.push("The control fits a 390px viewport without horizontal overflow");

  // Admin report: the server gates it, and every figure shows its denominator.
  await page.goto(`${origin}/tests/photo-feedback-fixture.html?view=report`);
  await expect(page.getByRole("heading", { name: "Photo feedback report", exact: true })).toBeVisible();
  for (const text of ["Observational, not proof", "internal ledger estimates, not reconciled supplier invoices", "88.2% (15 of 17)", "47.1% (8 of 17) · small sample", "$0.43", "$2.98 behind reviewed results ÷ 7 results judged useful",
    "2 delivered results without a verdict", "Reason mentions: Property fidelity 7 · Personal style 2 · Other 1", "2026-09-17 to 2026-10-17 (UTC), 30d window", report.basis, report.cost.basis, report.sample_note, report.signals.note])
    await expect(page.getByText(text, { exact: false }).first()).toBeVisible();
  await expect(page.getByRole("row", { name: /stage 5 5 28\.6% \(2 of 7\) · small sample/ })).toBeVisible();
  await expect(page.getByRole("row", { name: /Unknown \(not recorded\) 2 2 50% \(1 of 2\)/ }).first()).toBeVisible();
  assert.deepEqual(state.admin.at(-1), { window: "30d", org: ORG });
  await shot(page, "feedback-report-desktop.png", true);
  await page.getByRole("button", { name: "7 days", exact: true }).click();
  await expect(page.getByText("7d window", { exact: false })).toBeVisible(); assert.equal(state.admin.at(-1).window, "7d");
  await page.setViewportSize({ width: 390, height: 844 });
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 2), "report: no horizontal page scroll at 390px");
  await shot(page, "feedback-report-mobile.png", true); await page.setViewportSize({ width: 1440, height: 1000 });
  receipt.checks.push("Admin report renders the synthetic §5 answer with date range, coverage, unreviewed count, useful rate with n, small-sample flags, fidelity/style split, breakdowns, cost per useful and the honesty wording; window switch refetches; fits 390px");
  state.reportMode = "deny"; await page.reload();
  await expect(page.getByRole("alert")).toHaveText("This report is only available to Rendprop administrators.");
  await expect(page.getByRole("heading", { name: "Explicit feedback" })).toHaveCount(0); await expect(page.getByText("88.2%", { exact: false })).toHaveCount(0);
  receipt.checks.push("A 403 from GET /admin/photo-feedback shows only an access message and no report content");

  assert.deepEqual(receipt.errors, []); assert.deepEqual(receipt.externalRequests, []);
  receipt.status = "passed";
} catch (error) {
  receipt.status = "failed"; receipt.failure = error.stack ?? String(error); process.exitCode = 1;
  if (page) { receipt.visibleText = await page.locator("body").innerText().catch(() => ""); await page.screenshot({ path: join(artifacts, "failure.png"), fullPage: true }).catch(() => {}); }
} finally {
  await browser?.close(); if (server) await new Promise(done => server.close(done));
  receipt.requests = state.received.map(entry => ({ path: entry.path, answered: entry.answered, body: entry.body }));
  if (process.env.PHOTO_FEEDBACK_EVIDENCE) { await mkdir(process.env.PHOTO_FEEDBACK_EVIDENCE, { recursive: true }); for (const path of screenshots) await copyFile(path, join(process.env.PHOTO_FEEDBACK_EVIDENCE, path.split("/").at(-1))); }
  await writeFile(join(artifacts, "receipt.json"), JSON.stringify({ ...receipt, screenshots }, null, 2));
  console.log(JSON.stringify({ status: receipt.status, checks: receipt.checks, errors: receipt.errors, externalRequests: receipt.externalRequests, failure: receipt.failure, screenshots, artifacts }, null, 2));
}
