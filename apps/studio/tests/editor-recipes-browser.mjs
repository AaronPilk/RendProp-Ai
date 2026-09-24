import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";

const root = fileURLToPath(new URL("../", import.meta.url));
const artifacts = await mkdtemp(join(tmpdir(), "rendprop-guided-recipes-")), dist = join(artifacts, "dist");
const receipt = { proof: "Real VideoEditor + guided recipes, isolated synthetic local video/photos; no accounts, providers or external requests.", checks: [], externalRequests: [], errors: [], status: "running" };
let browser, server;
try {
  await build({configFile:false,root,publicDir:false,logLevel:"error",build:{outDir:dist,rollupOptions:{input:join(root,"tests/editor-recipes-fixture.html")}}});
  server = createServer(async (request,response) => {
    const path = resolve(dist, `.${new URL(request.url,"http://localhost").pathname}`);
    if (!path.startsWith(`${dist}/`)) return response.writeHead(400).end();
    try { response.setHeader("Content-Type",({".html":"text/html",".js":"application/javascript",".css":"text/css"})[extname(path)]??"application/octet-stream"); response.end(await readFile(path)); }
    catch { response.writeHead(404).end(); }
  });
  await new Promise(done => server.listen(0,"127.0.0.1",done));
  const origin=`http://127.0.0.1:${server.address().port}`, video=join(artifacts,"presenter.mp4");
  execFileSync("ffmpeg",["-v","error","-f","lavfi","-i","color=c=green:s=640x360:r=30:d=20","-f","lavfi","-i","sine=frequency=440:duration=20","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac","-shortest",video]);
  browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
  const context=await browser.newContext({viewport:{width:1440,height:1100},serviceWorkers:"block"});
  await context.route("**/*",route=>{const url=new URL(route.request().url());if(url.origin===origin&&route.request().method()==="GET"||url.protocol==="blob:")return route.continue();receipt.externalRequests.push(url.href);return route.abort();});
  const page=await context.newPage();page.on("pageerror",error=>receipt.errors.push(error.message));page.setDefaultTimeout(12000);
  await page.goto(`${origin}/tests/editor-recipes-fixture.html`);
  const png=await page.evaluate(()=>{const canvas=document.createElement("canvas");canvas.width=800;canvas.height=450;const ctx=canvas.getContext("2d");ctx.fillStyle="#bb66dd";ctx.fillRect(0,0,800,450);return canvas.toDataURL().split(",")[1];});
  await page.getByLabel("Add photos or videos",{exact:true}).setInputFiles([
    {name:"presenter.mp4",mimeType:"video/mp4",buffer:await readFile(video)},
    {name:"kitchen.png",mimeType:"image/png",buffer:Buffer.from(png,"base64")},
    {name:"exterior.png",mimeType:"image/png",buffer:Buffer.from(png,"base64")},
  ]);
  await expect(page.getByRole("button",{name:/Select clip /})).toHaveCount(3);
  await expect(page.getByLabel("Playback speed",{exact:true})).toHaveCount(0);
  const beforeMode=await page.evaluate(()=>window.recipeFixture.snapshot());
  await page.getByRole("button",{name:"Pro view",exact:true}).click();
  await expect(page.getByLabel("Playback speed",{exact:true})).toBeVisible();
  assert.deepEqual((await page.evaluate(()=>window.recipeFixture.snapshot())).draft,beforeMode.draft);
  receipt.checks.push("Simple and pro views expose the same unchanged draft, with advanced controls available in pro");
  await page.getByLabel("Clip caption",{exact:true}).fill("A user supplied introduction");
  await page.getByRole("button",{name:"Choose a guided draft",exact:true}).click();
  await page.getByLabel("Draft recipe",{exact:true}).selectOption("agent-tour");
  const primary=(await page.evaluate(()=>window.recipeFixture.snapshot())).draft.clips[0].id;
  await page.getByLabel("Presentation recording",{exact:true}).selectOption(primary);
  await page.getByRole("button",{name:"Use full recording",exact:true}).click();
  await expect(page.getByText(/0:20.0 · 1 sequence item · 2 photo cutaways/)).toBeVisible();
  await page.getByRole("button",{name:"Apply guided draft",exact:true}).click();
  await expect(page.getByRole("button",{name:/Select clip /})).toHaveCount(1);
  let snapshot=await page.evaluate(()=>window.recipeFixture.snapshot());
  assert.equal(snapshot.draft.clips[0].end,20);assert.equal(snapshot.draft.audio,"original");assert.equal(snapshot.draft.overlays.length,2);
  assert.equal(snapshot.draft.clips[0].caption,"A user supplied introduction");
  assert.equal(await page.getByText(/original files need reselection/).count(),0);
  await page.evaluate(time=>window.recipeFixture.seek(time),snapshot.draft.overlays[0].start+.5);
  await expect.poll(()=>page.locator("canvas").evaluate(canvas=>{const pixel=canvas.getContext("2d").getImageData(canvas.width/2,canvas.height/2,1,1).data;return pixel[0]>100&&pixel[2]>150;})).toBe(true);
  receipt.checks.push("Agent recipe expands only explicitly selected source range, retains speech/source IDs and renders real photo cutaways");
  await page.evaluate(()=>window.recipeFixture.seek(3));
  await expect.poll(()=>page.evaluate(()=>window.recipeFixture.snapshot().playhead)).toBe(3);
  await page.getByRole("button",{name:"Split video at playhead",exact:true}).click();
  await expect(page.getByRole("button",{name:/Select clip /})).toHaveCount(2);
  snapshot=await page.evaluate(()=>window.recipeFixture.snapshot());
  assert.equal(snapshot.draft.clips[0].end,3);assert.equal(snapshot.draft.clips[1].start,3);
  await page.getByRole("button",{name:"Undo",exact:true}).click();
  await expect(page.getByRole("button",{name:/Select clip /})).toHaveCount(1);
  await page.getByRole("button",{name:"Redo",exact:true}).click();
  await expect(page.getByRole("button",{name:/Select clip /})).toHaveCount(2);
  await expect(page.getByRole("button",{name:"Play",exact:true})).toBeEnabled();
  assert.equal(await page.getByText(/original files need reselection/).count(),0);
  receipt.checks.push("Split at playhead has continuous source boundaries; undo and redo retain live exact-source media");
  const reviewBefore=await page.evaluate(()=>window.recipeFixture.snapshot());
  await page.evaluate(()=>{
    const original=File.prototype.arrayBuffer;
    let release;
    const gate=new Promise(resolve=>{release=resolve;});
    window.relinkGate={entered:false,release:()=>{File.prototype.arrayBuffer=original;release();}};
    File.prototype.arrayBuffer=async function(){window.relinkGate.entered=true;await gate;return original.call(this);};
  });
  await page.evaluate(()=>window.recipeFixture.review());
  await expect(page.getByRole("region",{name:"Saved edit review",exact:true})).toBeVisible();
  await expect.poll(()=>page.evaluate(()=>window.relinkGate.entered)).toBe(true);
  await page.evaluate(()=>window.recipeFixture.request({id:"rerender-during-relink",recipe:"listing-highlight"}));
  await page.evaluate(()=>window.relinkGate.release());
  await expect(page.getByRole("button",{name:"Play",exact:true})).toBeEnabled();
  await expect(page.getByRole("button",{name:"Apply guided draft",exact:true})).toHaveCount(0);
  await expect(page.getByLabel("Edit controls",{exact:true})).toHaveCount(0);
  await expect(page.getByRole("button",{name:"Save edit plan",exact:true})).toHaveCount(0);
  await page.evaluate(()=>window.recipeFixture.request({id:"blocked-review-request",recipe:"listing-highlight"}));
  await page.evaluate(()=>window.recipeFixture.seek(7.25));
  await expect.poll(()=>page.evaluate(()=>window.recipeFixture.snapshot().playhead)).toBe(7.25);
  await page.keyboard.press("Control+z");
  const reviewAfter=await page.evaluate(()=>window.recipeFixture.snapshot());
  assert.deepEqual(reviewAfter.draft,reviewBefore.draft);assert.equal(reviewAfter.changes,reviewBefore.changes);assert.equal(reviewAfter.sourceChanges,reviewBefore.sourceChanges);
  await page.getByRole("button",{name:"Play",exact:true}).click();await expect(page.getByRole("button",{name:"Pause",exact:true})).toBeVisible();await page.getByRole("button",{name:"Pause",exact:true}).click();
  await expect.poll(()=>page.locator("canvas").evaluate(canvas=>{const pixel=canvas.getContext("2d").getImageData(canvas.width/2,canvas.height/2,1,1).data;return pixel[0]>100&&pixel[2]>150;})).toBe(true);
  receipt.checks.push("Read-only review survives a parent rerender during real file hashing, restores exact media, seeks comment timestamps and plays without mutation, source-save callbacks or export controls");
  await page.setViewportSize({width:390,height:844});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  await page.screenshot({path:join(artifacts,"review-mobile.png"),fullPage:true});
  assert.deepEqual(receipt.externalRequests,[]);assert.deepEqual(receipt.errors,[]);receipt.status="passed";
} catch(error) {receipt.status="failed";receipt.failure=error.stack??String(error);throw error;}
finally {await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2)+"\n");await browser?.close();await new Promise(done=>server?server.close(done):done());console.log(JSON.stringify({...receipt,artifacts},null,2));}
