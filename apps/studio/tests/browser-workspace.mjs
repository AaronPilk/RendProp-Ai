#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { chromium, expect } from "@playwright/test";

// Run against an already-built preview. An explicit flag permits only our own
// deployed Studio origin; fixtures remain in a fresh isolated browser context.
const args = process.argv.slice(2);
const baseArg = args
  .find((argument) => argument.startsWith("--base-url="))
  ?.slice("--base-url=".length);
assert.ok(
  args.every(
    (argument) =>
      argument === "--start-preview" || argument === "--deployed-preview" || argument.startsWith("--base-url="),
  ),
  "Supported arguments: --start-preview --base-url=http://127.0.0.1:4179, or --deployed-preview --base-url=https://studio.rendprop.com",
);
const base = new URL(
  baseArg ?? process.env.STUDIO_BASE_URL ?? "http://127.0.0.1:4179",
);
const deployedPreview = args.includes("--deployed-preview");
assert.ok(deployedPreview
  ? base.origin === "https://studio.rendprop.com"
  : base.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(base.hostname),
  "Use a local HTTP origin, or explicitly select the exact deployed Studio origin.");
assert.ok(!(deployedPreview && args.includes("--start-preview")), "A deployed test cannot start a local preview.");
assert.ok(base.pathname === "/" && !base.username && !base.password && !base.search && !base.hash, "Use only an origin without credentials or query.");
const artifacts = await mkdtemp(join(tmpdir(), "rendprop-workspace-browser-"));
const receipt = {
  target: base.origin,
  deployedPreview,
  startedAt: new Date().toISOString(),
  artifacts,
  checks: [],
  pages: [],
  externalRequests: [],
  consoleErrors: [],
  disallowedRequests: [],
  authVerification:
    "Not run. Fresh local unsigned fixtures only; no provider settings changed.",
  status: "running",
};
let browser, previewProcess, activePage;
let previewOutput = "";
const appDirectory = fileURLToPath(new URL("../", import.meta.url));

async function waitForPreview() {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (previewProcess && previewProcess.exitCode !== null)
      throw new Error(`Preview process exited: ${previewOutput}`);
    try {
      const response = await fetch(base, { signal: AbortSignal.timeout(1000) });
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(
    `Built preview was not available within 15 seconds at ${base.origin}.`,
  );
}

function check(name) {
  receipt.checks.push(name);
}
async function isolatedContext(options = {}) {
  const context = await browser.newContext({
    acceptDownloads: true,
    serviceWorkers: "block",
    timezoneId: "America/New_York",
    ...options,
  });
  context.setDefaultTimeout(10000);
  await context.route("**/*", (route) => {
    const url = new URL(route.request().url());
    const request = route.request();
    if (url.origin === base.origin && ["GET", "HEAD"].includes(request.method()) && !request.redirectedFrom()) return route.continue();
    receipt.disallowedRequests.push(`${request.method()} ${url.origin}${url.pathname}`);
    receipt.externalRequests.push(`${url.origin}${url.pathname}`);
    return route.abort("blockedbyclient");
  });
  await context.routeWebSocket("**/*", (socket) => { receipt.disallowedRequests.push("WebSocket"); socket.close(); });
  context.on("page", (page) => {
    page.on("pageerror", (error) => {
      receipt.consoleErrors.push(error.message);
    });
    page.on("console", (message) => {
      if (message.type() === "error")
        receipt.consoleErrors.push(message.text());
    });
  });
  return context;
}
async function navigate(page, label, heading) {
  await navButton(page, label).click();
  await expect(
    page.getByRole("heading", { name: heading, level: 1, exact: true }),
  ).toBeVisible();
}
function navButton(page, label) {
  return page
    .getByRole("navigation", { name: "Studio navigation" })
    .getByRole("button", { name: new RegExp(`^${label}(?:\\s*NEW)?$`) });
}
async function assertNoOverflow(page, name) {
  const dimensions = await page.evaluate(() => ({
    width: innerWidth,
    scroll: document.documentElement.scrollWidth,
  }));
  assert.ok(
    dimensions.scroll <= dimensions.width + 1,
    `${name} overflows horizontally: ${dimensions.scroll} > ${dimensions.width}`,
  );
}
const routes = [
  ["Overview", "Make your next impression."],
  ["Video editor", "Video editor"],
  ["Content library", "Content library"],
  ["Content planner", "Content planner"],
  ["Workspace", "Workspace"],
];

try {
  if (args.includes("--start-preview")) {
    let occupied = false;
    try {
      await fetch(base, { signal: AbortSignal.timeout(1000) });
      occupied = true;
    } catch {}
    assert.equal(
      occupied,
      false,
      "The requested preview port is already occupied. Choose another --base-url or use its existing server without --start-preview.",
    );
    // Like the export suite, serve the single coordinated production build.
    // Rebuilding here could change dist while another browser gate reads it.
    previewProcess = spawn(
      process.execPath,
      [
        join(appDirectory, "node_modules/vite/bin/vite.js"),
        "preview",
        "--host",
        base.hostname,
        "--port",
        base.port || "4179",
        "--strictPort",
      ],
      { cwd: appDirectory, stdio: ["ignore", "pipe", "pipe"] },
    );
    const collect = (data) => {
      previewOutput = (previewOutput + data.toString()).slice(-12000);
    };
    previewProcess.stdout.on("data", collect);
    previewProcess.stderr.on("data", collect);
  }
  await waitForPreview();
  const servedHTML = await (
    await fetch(base, { signal: AbortSignal.timeout(5000) })
  ).text();
  assert.equal(
    servedHTML,
    await readFile(join(appDirectory, "dist/index.html"), "utf8"),
    "Preview must serve this workspace’s built dist.",
  );
  receipt.builtEntrySha256 = createHash("sha256")
    .update(servedHTML)
    .digest("hex");
  receipt.buildMode = args.includes("--start-preview")
    ? "frozen dist served by owned preview; no rebuild"
    : "existing frozen dist preview";
  browser = await chromium.launch({
    headless: true,
    ...(process.env.STUDIO_BROWSER_EXECUTABLE
      ? { executablePath: process.env.STUDIO_BROWSER_EXECUTABLE }
      : {}),
  });
  receipt.browserVersion = browser.version();
  const context = await isolatedContext({
    viewport: { width: 1440, height: 1000 },
  });
  const page = await context.newPage();
  activePage = page;
  await page.goto(base.href, { waitUntil: "networkidle" });
  assert.equal(
    await page.locator('script[src*="@vite/client"]').count(),
    0,
    "Use the built dist preview, not Vite HMR.",
  );
  await expect(
    page.getByRole("link", { name: "Rendprop website" }),
  ).toBeVisible();
  await expect(page.locator(".brand img")).toHaveJSProperty(
    "naturalWidth",
    1024,
  );
  await expect(
    page.getByRole("heading", { name: "Make your next impression.", level: 1 }),
  ).toBeVisible();
  await expect(
    page.getByText("Local mode", { exact: true }).first(),
  ).toBeVisible();
  await page.screenshot({
    path: join(artifacts, "desktop-overview.png"),
    fullPage: true,
  });
  check("built preview, original brand asset and honest local mode");

  for (const [label, heading] of routes) {
    await navigate(page, label, heading);
    await assertNoOverflow(page, `desktop ${label}`);
    receipt.pages.push(`desktop:${label}`);
  }
  check("all five desktop pages navigate without horizontal overflow");

  const trigger = page.locator(".account-button");
  await expect(trigger).toHaveAccessibleName(/Sign in$/);
  await trigger.click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();
  await expect(
    dialog.getByRole("button", { name: "Close sign in" }),
  ).toBeFocused();
  assert.equal(
    await page.locator(".sidebar").evaluate((element) => element.inert),
    true,
  );
  assert.equal(
    await page.locator(".main-shell").evaluate((element) => element.inert),
    true,
  );
  await page.keyboard.press("Shift+Tab");
  await expect(
    dialog.getByRole("button", { name: /Continue with local files/ }),
  ).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(
    dialog.getByRole("button", { name: "Close sign in" }),
  ).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
  await expect(trigger).toBeFocused();
  assert.equal(
    await page.locator(".main-shell").evaluate((element) => element.inert),
    false,
  );
  check(
    "sign-in modal Tab trap, Escape, inert background and trigger focus restoration",
  );

  await navigate(page, "Content planner", "Content planner");
  const title = "Browser fixture café";
  const caption =
    "Fixture caption, with punctuation; café\nManual posting only.";
  await page.getByLabel("Post title", { exact: true }).fill(title);
  await page
    .getByRole("combobox", { name: /^Channel/ })
    .selectOption("LinkedIn");
  await page
    .getByLabel(/^(?:Your local date & time|Date & time)$/)
    .fill("2030-10-10T10:30");
  await page.getByRole("textbox", { name: /^Caption/ }).fill(caption);
  await page
    .getByRole("button", { name: "Save post plan", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: title, exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText(/has not been scheduled on social media/),
  ).toBeVisible();
  const plannedBefore = await page.evaluate(() =>
    localStorage.getItem("rendprop-studio:v1:local:planner"),
  );
  assert.equal(JSON.parse(plannedBefore).length, 1);
  await page.reload({ waitUntil: "networkidle" });
  await navigate(page, "Content planner", "Content planner");
  await expect(
    page.getByRole("heading", { name: title, exact: true }),
  ).toBeVisible();
  assert.equal(
    await page.evaluate(() =>
      localStorage.getItem("rendprop-studio:v1:local:planner"),
    ),
    plannedBefore,
  );
  const calendarDownload = page.waitForEvent("download");
  await page
    .getByRole("button", { name: "Calendar reminder", exact: true })
    .click();
  const download = await calendarDownload;
  const calendarPath = join(artifacts, "fixture-reminder.ics");
  await download.saveAs(calendarPath);
  const calendar = (await readFile(calendarPath, "utf8")).replace(/\r\n /g, "");
  assert.match(calendar, /BEGIN:VCALENDAR\r\n/);
  assert.match(calendar, /DTSTART:20301010T143000Z/);
  assert.ok(calendar.includes(`SUMMARY:LinkedIn: ${title}`));
  assert.ok(
    calendar.includes(
      "Fixture caption\\, with punctuation\\; café\\nManual posting only.",
    ),
  );
  assert.ok(
    calendar.includes("Rendprop has not scheduled this post on LinkedIn."),
  );
  await page.screenshot({
    path: join(artifacts, "desktop-planner.png"),
    fullPage: true,
  });
  check(
    "planner saves, reloads unchanged, and downloads a valid escaped UTC manual calendar reminder",
  );

  const backupEvent = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export plans backup", exact: true }).click();
  const backupDownload = await backupEvent;
  const backupPath = join(artifacts, "fixture-plans-backup.json");
  await backupDownload.saveAs(backupPath);
  const backupBytes = await readFile(backupPath);
  const backup = JSON.parse(backupBytes.toString("utf8"));
  assert.equal(backup.format, "rendprop-content-plans");
  assert.equal(backup.version, 1);
  assert.deepEqual(backup.plans, JSON.parse(plannedBefore));
  const inputBackup = async (text) => page.getByLabel("Choose plans backup JSON", { exact: true }).setInputFiles({
    name: "offline-plans.json", mimeType: "application/json", buffer: Buffer.from(text),
  });
  const plansNow = () => page.evaluate(() => localStorage.getItem("rendprop-studio:v1:local:planner"));
  await inputBackup(backupBytes);
  await expect(page.getByRole("alert").filter({ hasText: "Merge cannot overwrite or duplicate" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Confirm merge import", exact: true })).toBeDisabled();
  assert.equal(await plansNow(), plannedBefore);
  await page.getByRole("button", { name: "Cancel import", exact: true }).click();
  check("actual JSON backup download preserves all plans and timezone; duplicate merge refuses without writes");

  const mergedPlan = { ...backup.plans[0], id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", title: "Portable second plan" };
  const incoming = JSON.stringify({ ...backup, plans: [mergedPlan] });
  await inputBackup(incoming);
  await expect(page.getByRole("button", { name: "Confirm merge import", exact: true })).toBeEnabled();
  assert.equal(await plansNow(), plannedBefore, "Preview must never write");
  await page.getByRole("button", { name: "Cancel import", exact: true }).click();
  assert.equal(await plansNow(), plannedBefore, "Cancel preserves existing plans");
  await inputBackup(incoming);
  await page.getByRole("button", { name: "Confirm merge import", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Portable second plan", exact: true })).toBeVisible();
  assert.deepEqual(JSON.parse(await plansNow()), [...backup.plans, mergedPlan]);
  await inputBackup("{not json");
  await expect(page.getByRole("status").filter({ hasText: "not valid JSON" })).toBeVisible();
  assert.deepEqual(JSON.parse(await plansNow()), [...backup.plans, mergedPlan]);
  await inputBackup(backupBytes);
  await page.getByRole("combobox", { name: "Import mode", exact: true }).selectOption("replace");
  assert.equal(JSON.parse(await plansNow()).length, 2, "Replace preview must never write");
  await page.getByRole("button", { name: "Confirm replace import", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Portable second plan", exact: true })).toHaveCount(0);
  assert.equal(await plansNow(), plannedBefore);
  check("merge and explicit replace persist exact plans; preview, cancellation, and malformed input preserve originals");

  await inputBackup(incoming);
  await expect(page.getByRole("button", { name: "Confirm merge import", exact: true })).toBeEnabled();
  await page.evaluate(() => {
    const write = Storage.prototype.setItem;
    window.__restorePlannerStorage = () => { Storage.prototype.setItem = write; };
    Storage.prototype.setItem = function(key, value) {
      if (key === "rendprop-studio:v1:local:planner") throw new DOMException("Fixture planner storage full", "QuotaExceededError");
      return write.call(this, key, value);
    };
  });
  await page.getByRole("button", { name: "Confirm merge import", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "Fixture planner storage full" })).toBeVisible();
  assert.equal(await plansNow(), plannedBefore, "Storage rejection preserves durable plans");
  await expect(page.getByRole("heading", { name: "Portable second plan", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Confirm merge import", exact: true })).toBeVisible();
  await page.evaluate(() => window.__restorePlannerStorage());
  await page.getByRole("button", { name: "Cancel import", exact: true }).click();
  check("quota failure leaves saved plans, rendered queue and import preview intact for retry or cancel");

  const originalPlan = JSON.parse(plannedBefore)[0];
  await page.getByRole("button", { name: "Edit plan", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Edit post plan", exact: true }),
  ).toBeVisible();
  await page
    .getByLabel("Post title", { exact: true })
    .fill("Updated browser fixture");
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Updated browser fixture", exact: true }),
  ).toBeVisible();
  const updatedPlans = JSON.parse(
    await page.evaluate(() =>
      localStorage.getItem("rendprop-studio:v1:local:planner"),
    ),
  );
  assert.equal(updatedPlans.length, 1);
  assert.equal(updatedPlans[0].id, originalPlan.id);
  assert.equal(updatedPlans[0].createdAt, originalPlan.createdAt);
  await page
    .getByRole("combobox", { name: /^Filter channel/ })
    .selectOption("Instagram");
  await expect(
    page.getByRole("heading", { name: "No plans in this view.", exact: true }),
  ).toBeVisible();
  await page
    .getByRole("combobox", { name: /^Filter channel/ })
    .selectOption("All");
  await page.getByRole("button", { name: "Remove plan", exact: true }).click();
  await page.getByRole("button", { name: "Keep plan", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Updated browser fixture", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Remove plan", exact: true }).click();
  await page
    .getByRole("button", { name: "Confirm remove", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "Updated browser fixture", exact: true }),
  ).toHaveCount(0);
  assert.deepEqual(
    JSON.parse(
      await page.evaluate(() =>
        localStorage.getItem("rendprop-studio:v1:local:planner"),
      ),
    ),
    [],
  );
  check(
    "planner edit preserves identity, channel filter selects correctly, removal can be cancelled or confirmed",
  );

  await page
    .getByLabel("Post title", { exact: true })
    .fill("DST browser fixture");
  await page
    .getByLabel(/^(?:Your local date & time|Date & time)$/)
    .fill("2026-03-08T02:30");
  await expect(
    page.getByText(
      "This local time does not exist because the clocks change. Choose another time.",
      { exact: true },
    ),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Save post plan", exact: true }),
  ).toBeDisabled();
  await page
    .getByLabel(/^(?:Your local date & time|Date & time)$/)
    .fill("2026-11-01T01:30");
  const repeatedTime = page.getByRole("combobox", {
    name: /^This clock time occurs twice/,
  });
  await expect(repeatedTime).toBeVisible();
  await repeatedTime.selectOption({ index: 2 });
  await page
    .getByRole("button", { name: "Save post plan", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "DST browser fixture", exact: true }),
  ).toBeVisible();
  const boundPlans = JSON.parse(
    await page.evaluate(() =>
      localStorage.getItem("rendprop-studio:v1:local:planner"),
    ),
  );
  assert.equal(boundPlans[0].scheduledAt, "2026-11-01T06:30:00.000Z");
  assert.equal(boundPlans[0].timeZone, "America/New_York");
  check(
    "planner refuses a nonexistent DST time and binds an explicitly selected repeated time to its UTC instant",
  );

  await navigate(page, "Video editor", "Video editor");
  await expect(page.getByLabel("Title overlay", { exact: true })).toBeVisible();
  const fixtureBase64 = await page.evaluate(() => {
    const canvas = document.createElement("canvas");
    canvas.width = 640;
    canvas.height = 360;
    const context = canvas.getContext("2d");
    context.fillStyle = "#6741a5";
    context.fillRect(0, 0, 640, 360);
    context.fillStyle = "#ede5fc";
    context.fillRect(80, 70, 480, 220);
    context.fillStyle = "#201633";
    context.font = "32px sans-serif";
    context.fillText("OFFLINE TEST FIXTURE", 130, 190);
    return canvas.toDataURL("image/png").split(",")[1];
  });
  // Trailing bytes keep both versions valid PNGs with identical filename, size,
  // dimensions and displayed pixels. Only a full-content hash detects the change.
  const fixture = Buffer.concat([
    Buffer.from(fixtureBase64, "base64"),
    Buffer.alloc(16, 65),
  ]);
  const wrongFixture = Buffer.from(fixture);
  wrongFixture[wrongFixture.length - 1] = 66;
  const payload = (buffer) => ({
    name: "studio-fixture.png",
    mimeType: "image/png",
    buffer,
  });
  await page
    .getByLabel("Add photos or videos", { exact: true })
    .setInputFiles(payload(fixture));
  await expect(
    page.getByRole("button", { name: /^Select clip 1: studio-fixture.png/ }),
  ).toBeVisible();
  await expect(page.getByLabel("Title overlay", { exact: true })).toBeEnabled();
  await page
    .getByLabel("Title overlay", { exact: true })
    .fill("Retain this saved title");
  await page
    .getByLabel("Clip caption", { exact: false })
    .fill("Retain the clip caption");
  const draftKey = "rendprop-studio:v1:local:edit";
  await expect
    .poll(() =>
      page.evaluate(
        (key) => JSON.parse(localStorage.getItem(key) ?? "{}").title,
        draftKey,
      ),
    )
    .toBe("Retain this saved title");
  const savedDraft = JSON.parse(
    await page.evaluate((key) => localStorage.getItem(key), draftKey),
  );
  assert.equal(savedDraft.clips.length, 1);
  assert.equal(savedDraft.clips[0].caption, "Retain the clip caption");
  assert.match(savedDraft.clips[0].source.sha256, /^[0-9a-f]{64}$/);
  await page.reload({ waitUntil: "networkidle" });
  await navigate(page, "Video editor", "Video editor");
  await expect(page.getByLabel("Title overlay", { exact: true })).toHaveValue(
    "Retain this saved title",
  );
  await expect(page.getByLabel("Clip caption", { exact: false })).toHaveValue(
    "Retain the clip caption",
  );
  await expect(
    page.getByText("1 original file needs reselection.", { exact: true }),
  ).toBeVisible();
  assert.deepEqual(
    JSON.parse(
      await page.evaluate((key) => localStorage.getItem(key), draftKey),
    ),
    savedDraft,
    "Mounting a restored editor must not overwrite its saved draft.",
  );
  const exportButton = page.locator(".rp-editor-export-button");
  await expect(exportButton).toBeDisabled();
  await page
    .getByRole("button", { name: "Reselect original file", exact: true })
    .click();
  await page
    .getByLabel("Reselect original media", { exact: true })
    .setInputFiles(payload(wrongFixture));
  await expect(
    page.getByText(/This is a different file/).first(),
  ).toBeVisible();
  await expect(exportButton).toBeDisabled();
  assert.deepEqual(
    JSON.parse(
      await page.evaluate((key) => localStorage.getItem(key), draftKey),
    ),
    savedDraft,
    "Rejected media must not modify the saved edit.",
  );
  await page
    .getByRole("button", { name: "Reselect original file", exact: true })
    .click();
  await page
    .getByLabel("Reselect original media", { exact: true })
    .setInputFiles(payload(fixture));
  await expect(
    page
      .getByText("Original media verified and reconnected.", { exact: true })
      .first(),
  ).toBeVisible();
  await expect(exportButton).toBeEnabled();
  await page.screenshot({
    path: join(artifacts, "desktop-restored-editor.png"),
    fullPage: true,
  });
  check(
    "editor imports a local photo and reloads saved title/caption/revision without overwriting",
  );
  check(
    "same-name/same-size altered media fails full-hash reselection; original media reconnects",
  );

  const plannerKey='rendprop-studio:v1:local:planner';
  const malformedPlannerContext=await isolatedContext({viewport:{width:1440,height:1000}});
  await malformedPlannerContext.addInitScript(({draftKey,plannerKey,savedDraft,origin})=>{
    if(location.origin!==origin)return;
    localStorage.setItem(draftKey,JSON.stringify(savedDraft));localStorage.setItem(plannerKey,'{broken planner fixture');
  },{draftKey,plannerKey,savedDraft,origin:base.origin});
  const mixed=await malformedPlannerContext.newPage();activePage=mixed;await mixed.goto(base.href,{waitUntil:'networkidle'});
  await navigate(mixed,'Video editor','Video editor');
  await expect(mixed.getByLabel('Title overlay',{exact:true})).toHaveValue(savedDraft.title);
  assert.deepEqual(JSON.parse(await mixed.evaluate(key=>localStorage.getItem(key),draftKey)),savedDraft,'A broken planner must not replace a valid saved edit.');
  await mixed.getByLabel('Title overlay',{exact:true}).fill('Valid edit survives broken planner');
  await expect.poll(()=>mixed.evaluate(key=>JSON.parse(localStorage.getItem(key)).title,draftKey)).toBe('Valid edit survives broken planner');
  assert.equal(await mixed.evaluate(key=>localStorage.getItem(key),plannerKey),'{broken planner fixture');
  await malformedPlannerContext.close();
  check('malformed planner data neither prevents valid editor restoration nor overwrites its saved edit');

  const malformedEditContext=await isolatedContext({viewport:{width:1440,height:1000}});
  await malformedEditContext.addInitScript(({draftKey,plannerKey,originalPlan,origin})=>{
    if(location.origin!==origin)return;
    localStorage.setItem(draftKey,'{broken edit fixture');localStorage.setItem(plannerKey,JSON.stringify([originalPlan]));
  },{draftKey,plannerKey,originalPlan,origin:base.origin});
  const corrupt=await malformedEditContext.newPage();activePage=corrupt;await corrupt.goto(base.href,{waitUntil:'networkidle'});
  await navigate(corrupt,'Video editor','Video editor');
  await expect(corrupt.getByLabel('Title overlay',{exact:true})).toBeVisible();
  await corrupt.getByLabel('Title overlay',{exact:true}).fill('Do not overwrite unreadable stored data');
  await corrupt.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  assert.equal(await corrupt.evaluate(key=>localStorage.getItem(key),draftKey),'{broken edit fixture','An unreadable edit must remain intact even when the visible editor changes.');
  const repairedDraft={...savedDraft,id:'99999999-9999-4999-8999-999999999999',title:'Repaired draft from disk',revision:7,clips:[savedDraft.clips[0],{...savedDraft.clips[0],id:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',caption:'Second recovered clip'}]};
  await corrupt.evaluate(({draftKey,repairedDraft})=>localStorage.setItem(draftKey,JSON.stringify(repairedDraft)),{draftKey,repairedDraft});
  const cancelledPrompt=corrupt.waitForEvent('dialog');
  const cancelledRetry=corrupt.getByRole('button',{name:'Retry saved drafts',exact:true}).click();
  const firstPrompt=await cancelledPrompt;assert.equal(firstPrompt.type(),'confirm');await firstPrompt.dismiss();await cancelledRetry;
  await expect(corrupt.getByLabel('Title overlay',{exact:true})).toHaveValue('Do not overwrite unreadable stored data');
  await expect(corrupt.locator('.rp-editor-clips li')).toHaveCount(0);
  const acceptedPrompt=corrupt.waitForEvent('dialog');
  const acceptedRetry=corrupt.getByRole('button',{name:'Retry saved drafts',exact:true}).click();
  const secondPrompt=await acceptedPrompt;assert.equal(secondPrompt.type(),'confirm');await secondPrompt.accept();await acceptedRetry;
  await expect(corrupt.getByLabel('Title overlay',{exact:true})).toHaveValue(repairedDraft.title);
  await expect(corrupt.locator('.rp-editor-clips li')).toHaveCount(2);
  await corrupt.getByLabel('Title overlay',{exact:true}).fill('Repaired edit retains its identity');
  await expect.poll(()=>corrupt.evaluate(key=>JSON.parse(localStorage.getItem(key)).title,draftKey)).toBe('Repaired edit retains its identity');
  const afterRepair=JSON.parse(await corrupt.evaluate(key=>localStorage.getItem(key),draftKey));
  assert.equal(afterRepair.id,repairedDraft.id);assert.equal(afterRepair.clips.length,2);assert.ok(afterRepair.revision>repairedDraft.revision);
  check('cancelled retry preserves temporary edits; accepted retry remounts the repaired draft and preserves its identity on the next save');
  await navigate(corrupt,'Content planner','Content planner');
  await expect(corrupt.getByRole('heading',{name:originalPlan.title,exact:true})).toBeVisible();
  await malformedEditContext.close();
  check('malformed editor data is write-locked while a valid planner restores independently');

  const blockedReadContext=await isolatedContext({viewport:{width:1440,height:1000}});
  await blockedReadContext.addInitScript(({draftKey,savedDraft,origin})=>{
    if(location.origin!==origin)return;
    localStorage.setItem(draftKey,JSON.stringify(savedDraft));
    const read=Storage.prototype.getItem,write=Storage.prototype.setItem;
    window.__workspaceFixtureWrites=[];
    window.__readWorkspaceFixture=()=>read.call(localStorage,draftKey);
    Storage.prototype.getItem=function(key){if(key===draftKey)throw new Error('Simulated browser-storage read failure');return read.call(this,key);};
    Storage.prototype.setItem=function(key,value){if(key===draftKey)window.__workspaceFixtureWrites.push(value);return write.call(this,key,value);};
  },{draftKey,savedDraft,origin:base.origin});
  const blocked=await blockedReadContext.newPage();activePage=blocked;await blocked.goto(base.href,{waitUntil:'networkidle'});
  await navigate(blocked,'Video editor','Video editor');
  await expect(blocked.getByLabel('Title overlay',{exact:true})).toBeVisible();
  await blocked.getByLabel('Title overlay',{exact:true}).fill('Do not save over a failed read');
  await blocked.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  assert.deepEqual(await blocked.evaluate(()=>window.__workspaceFixtureWrites),[],'A failed storage read must not become an empty or edited autosave.');
  assert.deepEqual(JSON.parse(await blocked.evaluate(()=>window.__readWorkspaceFixture())),savedDraft);
  await blockedReadContext.close();
  check('throwing getItem does not trigger empty-draft autosave or overwrite unread stored content');

  const mobileContext = await isolatedContext({
    viewport: { width: 375, height: 812 },
    deviceScaleFactor: 1,
    isMobile: true,
    hasTouch: true,
  });
  const mobile = await mobileContext.newPage();
  activePage = mobile;
  await mobile.goto(base.href, { waitUntil: "networkidle" });
  for (const [label, heading] of routes) {
    const button = navButton(mobile, label);
    await expect(button).toBeVisible();
    await expect(button).toHaveAccessibleName(
      new RegExp(`^${label}(?:\\s*NEW)?$`),
    );
    assert.ok(
      await button.evaluate(
        (element) => Number.parseFloat(getComputedStyle(element).fontSize) > 0,
      ),
      `${label} mobile navigation hides its visible text label.`,
    );
    const bounds = await button.boundingBox();
    assert.ok(
      bounds && bounds.width >= 44 && bounds.height >= 44,
      `${label} mobile navigation target is smaller than 44px.`,
    );
    await navigate(mobile, label, heading);
    await assertNoOverflow(mobile, `375px ${label}`);
    receipt.pages.push(`375px:${label}`);
  }
  await navigate(mobile, "Overview", "Make your next impression.");
  await mobile.screenshot({
    path: join(artifacts, "mobile-overview.png"),
    fullPage: true,
  });
  check(
    "375px viewport: all five pages fit and every navigation target has an accessible name and 44px target",
  );
  assert.deepEqual(
    receipt.externalRequests,
    [],
    "No external account or provider requests should run in local browser checks.",
  );
  assert.deepEqual(
    receipt.consoleErrors,
    [],
    "Browser console and uncaught runtime errors must remain clear.",
  );
  assert.deepEqual(receipt.disallowedRequests, [], "No write, redirect or WebSocket request is permitted.");
  check("no uncaught browser errors and no external network requests");
  receipt.status = "passed";
  await context.close();
  await mobileContext.close();
} catch (error) {
  receipt.status = "failed";
  receipt.error = error instanceof Error ? error.message : String(error);
  if (activePage && !activePage.isClosed())
    await activePage
      .screenshot({ path: join(artifacts, "failure.png"), fullPage: true })
      .catch(() => {});
  process.exitCode = 1;
} finally {
  receipt.finishedAt = new Date().toISOString();
  await writeFile(
    join(artifacts, "receipt.json"),
    JSON.stringify(receipt, null, 2),
  );
  await browser?.close();
  previewProcess?.kill("SIGTERM");
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
}
