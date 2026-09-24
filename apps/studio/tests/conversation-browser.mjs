import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";

const root = fileURLToPath(new URL("../", import.meta.url)), artifacts = await mkdtemp(join(tmpdir(), "rendprop-conversation-")), dist = join(artifacts, "dist");
const receipt = { proof: "Actual VideoEditor conversation UI, original synthetic media, real canvas preview and MP4 encoding. Only injected deferred text-plan and prompt-enhancement fixtures; no live account, model, generation or external requests.", checks: [], externalRequests: [], errors: [], status: "running" };
let browser, server, page;
try {
  await build({ configFile: false, root, publicDir: false, logLevel: "error", build: { outDir: dist, rollupOptions: { input: join(root, "tests/conversation-fixture.html") } } });
  server = createServer(async (request, response) => {
    const path = resolve(dist, `.${new URL(request.url, "http://localhost").pathname}`);
    if (!path.startsWith(`${dist}/`)) return response.writeHead(400).end();
    try { response.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css" })[extname(path)] ?? "application/octet-stream"); response.end(await readFile(path)); }
    catch { response.writeHead(404).end(); }
  });
  await new Promise(done => server.listen(0, "127.0.0.1", done));
  const origin = `http://127.0.0.1:${server.address().port}`, sourceVideo = join(artifacts, "original-blue.mp4");
  execFileSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=640x360:r=30:d=4", "-f", "lavfi", "-i", "sine=frequency=660:duration=4", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", sourceVideo]);
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 }, serviceWorkers: "block", acceptDownloads: true });
  await context.route("**/*", route => {
    const url = new URL(route.request().url());
    if (url.origin === origin && route.request().method() === "GET" || url.protocol === "blob:") return route.continue();
    receipt.externalRequests.push(url.href); return route.abort();
  });
  page = await context.newPage(); page.on("pageerror", error => receipt.errors.push(error.message)); page.setDefaultTimeout(12000);
  await page.goto(`${origin}/tests/conversation-fixture.html`);
  const snapshot = () => page.evaluate(() => window.conversationFixture.snapshot());
  const length = state => state.draft.clips.reduce((total, clip) => total + (clip.end - clip.start) / (clip.source.kind === "video" ? clip.speed ?? 1 : 1), 0);
  async function send(message) {
    const input = page.getByRole("textbox", { name: "Describe your video or edit", exact: true });
    await input.fill(message); await input.press("Enter");
  }
  async function settled() { await expect(page.getByRole("textbox", { name: "Describe your video or edit", exact: true })).toBeEnabled(); }
  const pngs = await page.evaluate(() => ["#ff0000", "#00ff00", "#0000ff"].map(color => {
    const canvas = document.createElement("canvas"); canvas.width = 720; canvas.height = 1280;
    const ctx = canvas.getContext("2d"); ctx.fillStyle = color; ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = "white"; ctx.fillRect(60, 30, 80, 80);
    return canvas.toDataURL().split(",")[1];
  }));
  const photos = pngs.map((bytes, index) => ({ name: `photo-${index + 1}.png`, mimeType: "image/png", buffer: Buffer.from(bytes, "base64") }));

  await send("Make a 15-second reel");
  await expect(page.getByText("Add media to continue your request.", { exact: false })).toBeVisible();
  await page.getByLabel("Add photos or videos", { exact: true }).setInputFiles(photos);
  await expect.poll(async () => length(await snapshot())).toBe(15);
  await expect(page.getByText("Add media to continue your request.", { exact: false })).toHaveCount(0);
  let state = await snapshot();
  assert.equal(state.draft.clips.length, 3); assert(state.draft.clips.every(clip => clip.motion === "push_in"));
  assert.deepEqual(state.draft.clips.map(clip => clip.transition), ["cut", "dissolve", "dissolve"]);
  assert.equal(state.conversation.messages.filter(message => message.role === "user").length, 1); assert.equal(state.requests.length, 0);
  await expect(page.getByRole("button", { name: "Play", exact: true })).toBeEnabled();
  await expect.poll(() => page.locator("canvas").evaluate(canvas => [...canvas.getContext("2d").getImageData(360, 600, 1, 1).data].slice(0, 3))).toEqual([255, 0, 0]);
  receipt.checks.push("A brief before media resumes once after three real photos decode, creates an actual 15-second vertical sequence with motion/dissolves, and displays decoded pixels without a model call");

  const beforeFailure = state.draft;
  await page.getByLabel("Add photos or videos", { exact: true }).setInputFiles([photos[0], { name: "broken.png", mimeType: "image/png", buffer: Buffer.from("not a real image") }]);
  await expect(page.locator(".rp-editor-notice")).toContainText(/decode|image|media|load/i);
  await settled(); assert.deepEqual((await snapshot()).draft, beforeFailure);
  receipt.checks.push("A mixed valid-plus-undecodable media batch leaves the existing draft and its media associations intact");

  await send("Make it shorter"); await expect.poll(async () => Number(length(await snapshot()).toFixed(5))).toBe(12);
  await send("Undo that"); await expect.poll(async () => Number(length(await snapshot()).toFixed(5))).toBe(15);
  const beforeMode = (await snapshot()).draft;
  await page.getByRole("button", { name: "Pro view", exact: true }).click();
  await expect(page.getByLabel("Photo motion", { exact: true })).toHaveValue("push_in");
  await page.getByRole("button", { name: /Select clip 2:/ }).click();
  await expect(page.getByLabel("Transition into this clip", { exact: true })).toHaveValue("dissolve");
  await page.getByRole("button", { name: "Chat", exact: true }).click();
  assert.deepEqual((await snapshot()).draft, beforeMode);
  receipt.checks.push("Conversation pacing is undoable in one step; Chat and Pro expose the same live editor and exact source bindings");

  for (const prompt of ["Generate a different kitchen and clone the agent", "Don't make it shorter", "Make it shorter; add a dragon"]) {
    const before = (await snapshot()).draft; await send(prompt); await settled(); assert.deepEqual((await snapshot()).draft, before);
  }
  assert.equal((await snapshot()).requests.length, 0);
  await expect(page.getByRole("log", { name: "Editing conversation" })).toContainText(/unchanged|haven’t changed|not enabled/);
  receipt.checks.push("Negated, partly unsupported and generative prompts perform no partial edit and dispatch no assistant call while disabled");

  await send("Make it 3 seconds"); await expect.poll(async () => Number(length(await snapshot()).toFixed(5))).toBe(3);
  await page.getByRole("button", { name: "Export MP4", exact: true }).click();
  await expect(page.getByRole("link", { name: /Download MP4/ })).toBeVisible({ timeout: 20000 });
  let downloading = page.waitForEvent("download"); await page.getByRole("link", { name: /Download MP4/ }).click();
  const photosOutput = join(artifacts, "conversation-photos.mp4"); await (await downloading).saveAs(photosOutput);
  let probe = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_entries", "stream=codec_name,codec_type,width,height:format=duration", "-of", "json", photosOutput], { encoding: "utf8" }));
  assert(probe.streams.some(stream => stream.codec_name === "h264" && stream.width === 720 && stream.height === 1280));
  assert(Math.abs(Number(probe.format.duration) - 3) < .4);
  const pixel = time => [...execFileSync("ffmpeg", ["-v", "error", "-ss", String(time), "-i", photosOutput, "-frames:v", "1", "-vf", "format=rgb24,crop=1:1:360:600", "-f", "rawvideo", "pipe:1"])];
  const red = pixel(.4), green = pixel(1.5), blue = pixel(2.5), dissolve = pixel(1.12);
  assert(red[0] > 230 && red[1] < 20 && red[2] < 20); assert(green[1] > 230 && green[0] < 20); assert(blue[2] > 230 && blue[0] < 20);
  assert(dissolve[0] > 30 && dissolve[1] > 30, `Expected real red/green dissolve, got ${dissolve}`);
  receipt.checks.push(`The chat-created photo sequence exports real 720×1280 H.264 MP4 (${Number(probe.format.duration).toFixed(2)}s); decoded frames prove red/green/blue source order and an actual dissolve`);

  await page.setViewportSize({ width: 1440, height: 1100 }); await page.screenshot({ path: join(artifacts, "conversation-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "Conversation should not overflow a phone-width viewport");
  await page.screenshot({ path: join(artifacts, "conversation-mobile.png"), fullPage: true });
  await page.setViewportSize({ width: 1440, height: 1100 });
  receipt.checks.push("Chat and real preview/export remain usable without horizontal overflow at desktop and phone widths");

  await page.evaluate(() => window.conversationFixture.enableAssistant());
  await send("Give this a distinctive opening"); await expect.poll(async () => (await snapshot()).requests.length).toBe(1);
  await page.getByRole("button", { name: "Pro view", exact: true }).click();
  await page.getByLabel("Title overlay", { exact: true }).fill("Manual title wins");
  await expect.poll(async () => (await snapshot()).draft.title).toBe("Manual title wins");
  const manuallyEdited = (await snapshot()).draft;
  await page.evaluate(() => window.conversationFixture.resolve(0, [{ type: "title", text: "Late assistant title" }]));
  await page.getByRole("button", { name: "Chat", exact: true }).click(); await settled();
  assert.deepEqual((await snapshot()).draft, manuallyEdited);
  await expect(page.getByRole("log", { name: "Editing conversation" })).toContainText(/edit changed|preserved/);
  receipt.checks.push("A deferred assistant plan cannot overwrite a newer manual edit; the exact current draft survives the stale response");

  await send("Give this a distinctive ending"); await expect.poll(async () => (await snapshot()).requests.length).toBe(2);
  const formerDraftId = (await snapshot()).draft.id;
  await page.evaluate(() => window.conversationFixture.resetAccount());
  await expect.poll(async () => (await snapshot()).draft?.id).not.toBe(formerDraftId);
  await expect.poll(async () => (await snapshot()).requests[1].aborted).toBe(true);
  const newAccount = await snapshot();
  await page.evaluate(() => window.conversationFixture.resolve(1, [{ type: "title", text: "Previous account leaked" }]));
  // Flush queued promise continuations and React effects without using an arbitrary sleep.
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  state = await snapshot(); assert.deepEqual(state.draft, newAccount.draft); assert.equal(state.draft.clips.length, 0); assert.equal(state.conversation.messages.length, 0);
  await expect(page.getByText("Previous account leaked", { exact: false })).toHaveCount(0);
  receipt.checks.push("Unmount/account replacement aborts the pending plan and fences an intentionally late response from the fresh account’s draft and conversation");

  await page.getByLabel("Add photos or videos", { exact: true }).setInputFiles(sourceVideo);
  await expect.poll(async () => (await snapshot()).draft.clips.length).toBe(1);
  await send("Make it 2 seconds"); await expect.poll(async () => Number(length(await snapshot()).toFixed(5))).toBe(2);
  state = await snapshot(); assert.equal(state.draft.audio, "original"); assert.equal(state.draft.clips[0].speed ?? 1, 1);
  await page.getByRole("button", { name: "Export MP4", exact: true }).click();
  await expect(page.getByRole("link", { name: /Download MP4/ })).toBeVisible({ timeout: 20000 });
  downloading = page.waitForEvent("download"); await page.getByRole("link", { name: /Download MP4/ }).click();
  const videoOutput = join(artifacts, "conversation-original-audio.mp4"); await (await downloading).saveAs(videoOutput);
  probe = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_entries", "stream=codec_name,codec_type:format=duration", "-of", "json", videoOutput], { encoding: "utf8" }));
  assert(probe.streams.some(stream => stream.codec_name === "h264")); assert(probe.streams.some(stream => stream.codec_name === "aac")); assert(Math.abs(Number(probe.format.duration) - 2) < .4);
  const pcm = execFileSync("ffmpeg", ["-v", "error", "-i", videoOutput, "-ss", "0.3", "-t", "1", "-vn", "-ac", "1", "-ar", "48000", "-f", "s16le", "pipe:1"]);
  let power = 0, crossings = 0; for (let index = 0; index < pcm.length; index += 2) { const value = pcm.readInt16LE(index) / 32768; power += value * value; if (index && pcm.readInt16LE(index - 2) < 0 && value >= 0) crossings++; }
  const rms = Math.sqrt(power / (pcm.length / 2)); assert(rms > .02); assert(crossings > 610 && crossings < 710, `Expected original 660Hz audio, got ${crossings} crossings`);
  receipt.checks.push(`A conversational trim exports real H.264/AAC with unchanged original 660Hz audio (${crossings} crossings, RMS ${rms.toFixed(3)}), not simulated media or changed voice speed`);
  const composer=()=>page.getByRole("textbox",{name:"Describe your video or edit",exact:true});
  const suggestion=()=>page.getByRole("region",{name:"Prompt suggestion",exact:true});
  const improve=()=>page.getByRole("button",{name:"✦ Improve prompt",exact:true}).click();
  const flush=()=>page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  const guidedOriginal='Change title "Bright new listing"';
  await composer().fill(guidedOriginal);
  const beforeGuided=await snapshot();
  await improve();await expect(suggestion()).toBeVisible();
  await expect(suggestion()).toContainText("Guided prompt suggestion");
  await expect(composer()).toHaveValue(guidedOriginal);
  assert.deepEqual((await snapshot()).draft,beforeGuided.draft);assert.deepEqual((await snapshot()).conversation,beforeGuided.conversation);
  const guidedText=await suggestion().locator(".creation-enhanced-text").textContent();assert.notEqual(guidedText,guidedOriginal);
  await suggestion().getByRole("button",{name:"Keep original",exact:true}).click();
  await expect(suggestion()).toHaveCount(0);await expect(composer()).toHaveValue(guidedOriginal);assert.deepEqual((await snapshot()).draft,beforeGuided.draft);
  await improve();await suggestion().getByRole("button",{name:"Use this prompt",exact:true}).click();
  await expect(composer()).toHaveValue(guidedText);assert.deepEqual((await snapshot()).draft,beforeGuided.draft);assert.deepEqual((await snapshot()).conversation,beforeGuided.conversation);
  await composer().press("Enter");await expect.poll(async()=>(await snapshot()).draft.title).toBe("Bright new listing");
  assert.equal((await snapshot()).enhancementRequests.length,0);
  receipt.checks.push("Guided improvement previews equivalent wording without touching the composer, conversation or actual draft; Keep original preserves it, Use only fills the composer, and a separate Send applies the exact title");

  const unknown='Make this cinematic like the sunset in that other video';
  await composer().fill(unknown);const beforeUnknown=await snapshot();await improve();
  await expect(suggestion().locator(".creation-enhanced-text")).toHaveText(unknown);
  await expect(suggestion()).toContainText(/wording is kept intact|cannot be safely translated/);
  assert.deepEqual((await snapshot()).draft,beforeUnknown.draft);await expect(composer()).toHaveValue(unknown);
  await suggestion().getByRole("button",{name:"Keep original",exact:true}).click();
  receipt.checks.push("An unsupported offline prompt remains verbatim with useful limitations, without invented effects, a model request or an edit");

  await page.evaluate(()=>window.conversationFixture.enableEnhancer());
  const aiOriginal="Help turn this into a punchy opening",aiEnhanced='Set title "A fresh start"';
  await composer().fill(aiOriginal);const beforeAI=await snapshot();await improve();
  await expect.poll(async()=>(await snapshot()).enhancementRequests.length).toBe(1);
  await page.evaluate(({original,enhanced})=>window.conversationFixture.resolveEnhancement(0,{original,enhanced,notes:["Keeps the original footage and changes only the title."],method:"ai"}),{original:aiOriginal,enhanced:aiEnhanced});
  await expect(suggestion()).toContainText("AI prompt suggestion");await expect(composer()).toHaveValue(aiOriginal);assert.deepEqual((await snapshot()).draft,beforeAI.draft);
  await suggestion().locator("summary").click();
  for(const width of [1440,390]) {await page.setViewportSize({width,height:width===390?844:1100});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),"Prompt review must fit the viewport");await page.screenshot({path:join(artifacts,`prompt-review-${width}.png`),fullPage:true});}
  await page.setViewportSize({width:1440,height:1100});
  await suggestion().getByRole("button",{name:"Use this prompt",exact:true}).click();
  await expect(composer()).toHaveValue(aiEnhanced);await expect(suggestion()).toHaveCount(0);await flush();
  const afterAI=await snapshot();assert.deepEqual(afterAI.draft,beforeAI.draft);assert.deepEqual(afterAI.conversation,beforeAI.conversation);assert.equal(afterAI.requests.length,beforeAI.requests.length);
  receipt.checks.push("A mocked AI suggestion shows the original and proposed prompt at desktop/mobile widths; Use fills the composer without editing, appending chat messages or sending a request");

  const canceledOriginal="Keep this wording if I stop improving it";
  await composer().fill(canceledOriginal);const beforeCancel=await snapshot();await improve();
  await expect.poll(async()=>(await snapshot()).enhancementRequests.length).toBe(2);
  await page.getByRole("button",{name:"Stop",exact:true}).click();
  await expect.poll(async()=>(await snapshot()).enhancementRequests[1].aborted).toBe(true);await expect(composer()).toHaveValue(canceledOriginal);
  await page.evaluate(original=>window.conversationFixture.resolveEnhancement(1,{original,enhanced:'Set title "Canceled suggestion"',notes:[],method:"ai"}),canceledOriginal);
  await settled();await expect(suggestion()).toHaveCount(0);await expect(composer()).toHaveValue(canceledOriginal);assert.deepEqual((await snapshot()).draft,beforeCancel.draft);assert.deepEqual((await snapshot()).conversation,beforeCancel.conversation);
  receipt.checks.push("Stop aborts improvement and preserves the original wording and video even when the canceled request deliberately returns later");

  const malformedOriginal="Keep this original when the suggestion is malformed";
  await composer().fill(malformedOriginal);const beforeMalformed=await snapshot();await improve();
  await expect.poll(async()=>(await snapshot()).enhancementRequests.length).toBe(3);
  await page.evaluate(original=>window.conversationFixture.resolveEnhancement(2,{original,enhanced:17,notes:[],method:"ai"}),malformedOriginal);
  await settled();await expect(suggestion()).toHaveCount(0);await expect(composer()).toHaveValue(malformedOriginal);await expect(page.locator(".rp-editor-notice")).toContainText("Your original wording is kept.");
  assert.deepEqual((await snapshot()).draft,beforeMalformed.draft);assert.deepEqual((await snapshot()).conversation,beforeMalformed.conversation);
  receipt.checks.push("An invalid enhancement response cannot populate a suggestion or alter the original prompt, conversation or video");

  const staleOriginal="Improve this while I change the title manually";
  await composer().fill(staleOriginal);await improve();await expect.poll(async()=>(await snapshot()).enhancementRequests.length).toBe(4);
  await page.getByRole("button",{name:"Pro view",exact:true}).click();await page.getByLabel("Title overlay",{exact:true}).fill("Newer manual title stays");
  await expect.poll(async()=>(await snapshot()).draft.title).toBe("Newer manual title stays");const beforeLateEnhancement=await snapshot();
  await page.evaluate(original=>window.conversationFixture.resolveEnhancement(3,{original,enhanced:'Set title "Stale AI suggestion"',notes:[],method:"ai"}),staleOriginal);
  await page.getByRole("button",{name:"Chat",exact:true}).click();await settled();await expect(suggestion()).toHaveCount(0);await expect(composer()).toHaveValue(staleOriginal);
  assert.deepEqual((await snapshot()).draft,beforeLateEnhancement.draft);await expect(page.locator(".rp-editor-notice")).toContainText(/edit changed|original wording/);
  receipt.checks.push("A prompt improvement tied to an older draft revision is rejected after a manual edit; the newer title and original prompt remain intact");

  const oldAccountPrompt="A suggestion belonging only to the previous account";
  await composer().fill(oldAccountPrompt);await improve();await expect.poll(async()=>(await snapshot()).enhancementRequests.length).toBe(5);
  const beforeEnhanceAccount=(await snapshot()).draft.id;await page.evaluate(()=>window.conversationFixture.resetAccount());
  await expect.poll(async()=>(await snapshot()).draft?.id).not.toBe(beforeEnhanceAccount);
  await expect.poll(async()=>(await snapshot()).enhancementRequests[4].aborted).toBe(true);const freshEnhanceAccount=await snapshot();
  await page.evaluate(original=>window.conversationFixture.resolveEnhancement(4,{original,enhanced:'Set title "Former account secret"',notes:[],method:"ai"}),oldAccountPrompt);
  await flush();state=await snapshot();assert.deepEqual(state.draft,freshEnhanceAccount.draft);assert.deepEqual(state.conversation,freshEnhanceAccount.conversation);await expect(composer()).toHaveValue("");await expect(suggestion()).toHaveCount(0);await expect(page.getByText("Former account secret",{exact:false})).toHaveCount(0);
  receipt.checks.push("Account unmount aborts enhancement and fences a deliberately late suggestion from the new account's composer, conversation and draft");
  assert.deepEqual(receipt.externalRequests, []); assert.deepEqual(receipt.errors, []); receipt.status = "passed";
} catch (error) {
  receipt.status = "failed"; receipt.failure = error.stack ?? String(error);
  if (page) await page.screenshot({ path: join(artifacts, "failure.png"), fullPage: true }).catch(() => {});
  throw error;
} finally {
  await writeFile(join(artifacts, "receipt.json"), JSON.stringify(receipt, null, 2) + "\n");
  await browser?.close(); await new Promise(done => server ? server.close(done) : done());
  console.log(JSON.stringify({ ...receipt, artifacts }, null, 2));
}
