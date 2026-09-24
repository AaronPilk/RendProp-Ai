import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "node:http";
import { build } from "vite";
import { execFileSync } from "node:child_process";
import { chromium, expect } from "@playwright/test";
const root = fileURLToPath(new URL("../", import.meta.url)), artifacts = await mkdtemp(join(tmpdir(), "rendprop-cloud-editor-")), dist = join(artifacts, "dist");
const receipt = { proof: "Real CloudEditor, VideoEditor, DocumentSync and CloudPlanner with isolated cloud/asset fixtures. No live account or paid provider use.", checks: [], externalRequests: [], errors: [], mediaTiming: [], exportProbes: [] };
let browser, server, page;
const timingDevices=[];
// Test-only observation: every wrapper returns the original native result and
// preserves thrown errors. No export timing, callback scheduling or assertions change.
function installMediaTimingFixture() {
  const events=[], recorderIds=new WeakMap(), mediaIds=new WeakMap(), audioIds=new WeakMap();
  const mediaElements=[],audioContexts=[];
  let recorderSequence=0,mediaSequence=0,audioSequence=0;
  const milliseconds=value=>Math.round(value*1000)/1000;
  const now=()=>milliseconds(performance.now());
  const mediaState=media=>({id:mediaIds.get(media),tag:media.tagName,currentTime:media.currentTime,duration:Number.isFinite(media.duration)?media.duration:null,playbackRate:media.playbackRate,paused:media.paused,ended:media.ended,readyState:media.readyState,networkState:media.networkState});
  const audioState=context=>({id:audioIds.get(context),currentTime:context.currentTime,state:context.state,sampleRate:context.sampleRate});
  const record=(kind,detail={})=>{if(events.length<5000)events.push({atMs:now(),kind,visibility:document.visibilityState,...detail});};
  function trackMedia(media) {
    if(mediaIds.has(media))return mediaIds.get(media);
    const id=++mediaSequence;mediaIds.set(media,id);mediaElements.push(media);
    for(const name of ["playing","waiting","stalled","seeking","seeked","pause","ended"])media.addEventListener(name,event=>record(`media.event.${name}`,{eventTimeStamp:event.timeStamp,media:mediaState(media)}));
    return id;
  }
  function trackAudio(context) {
    if(!audioIds.has(context)){audioIds.set(context,++audioSequence);audioContexts.push(context);context.addEventListener("statechange",()=>record("audio.event.statechange",{audio:audioState(context)}));}
    return audioIds.get(context);
  }
  function recorderState(recorder) {return {id:recorderIds.get(recorder),state:recorder.state,mimeType:recorder.mimeType,media:mediaElements.map(mediaState),audio:audioContexts.map(audioState)};}
  function trackRecorder(recorder) {
    if(recorderIds.has(recorder))return;
    recorderIds.set(recorder,++recorderSequence);
    for(const name of ["start","resume","pause","stop","dataavailable","error"])recorder.addEventListener(name,event=>record(`recorder.event.${name}`,{eventTimeStamp:event.timeStamp,...recorderState(recorder),...(name==="dataavailable"?{bytes:event.data.size,timecode:event.timecode}:{}),...(name==="error"?{error:String(event.error)}:{})}));
  }
  if(typeof MediaRecorder!=="undefined")for(const method of ["start","resume","pause","stop"]){
    const original=MediaRecorder.prototype[method];
    MediaRecorder.prototype[method]=function(...args){trackRecorder(this);record(`recorder.call.${method}`,{args,...recorderState(this)});try{const result=Reflect.apply(original,this,args);record(`recorder.return.${method}`,recorderState(this));return result;}catch(error){record(`recorder.throw.${method}`,{...recorderState(this),error:String(error)});throw error;}};
  }
  const originalPlay=HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play=function(...args){
    trackMedia(this);const started=performance.now();record("media.call.play",{media:mediaState(this)});
    try{const result=Reflect.apply(originalPlay,this,args);result.then(()=>record("media.resolve.play",{latencyMs:milliseconds(performance.now()-started),media:mediaState(this)}),error=>record("media.reject.play",{latencyMs:milliseconds(performance.now()-started),media:mediaState(this),error:String(error)}));return result;}
    catch(error){record("media.throw.play",{latencyMs:milliseconds(performance.now()-started),media:mediaState(this),error:String(error)});throw error;}
  };
  const audioTypes=[...new Set([window.AudioContext,window.webkitAudioContext].filter(Boolean))];
  for(const AudioType of audioTypes){const originalResume=AudioType.prototype.resume;AudioType.prototype.resume=function(...args){trackAudio(this);const started=performance.now();record("audio.call.resume",{audio:audioState(this)});try{const result=Reflect.apply(originalResume,this,args);result.then(()=>record("audio.resolve.resume",{latencyMs:milliseconds(performance.now()-started),audio:audioState(this)}),error=>record("audio.reject.resume",{latencyMs:milliseconds(performance.now()-started),audio:audioState(this),error:String(error)}));return result;}catch(error){record("audio.throw.resume",{audio:audioState(this),error:String(error)});throw error;}};}
  document.addEventListener("visibilitychange",()=>record("document.visibilitychange"));
  window.mediaTimingFixture={snapshot:()=>({timeOrigin:performance.timeOrigin,capturedAtMs:now(),userAgent:navigator.userAgent,truncated:events.length>=5000,events:structuredClone(events)})};
}
async function captureMediaTiming() {
  for(const device of timingDevices){
    if(device.tab.isClosed())continue;
    try{device.trace=await device.tab.evaluate(()=>window.mediaTimingFixture.snapshot());}
    catch(error){device.captureError=String(error);}
  }
  receipt.mediaTiming=timingDevices.map(({id,listing,trace,captureError})=>({id,listing,trace,captureError}));
}
async function closeDevice(tab){await captureMediaTiming();await tab.close();}
async function saveExportDiagnostics(label,path,probe){await captureMediaTiming();receipt.exportProbes.push({label,path,ffprobe:probe});await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2));}

const pro=async tab=>{await expect(tab.getByRole("button",{name:"Pro view",exact:true})).toBeVisible();await tab.getByRole("button",{name:"Pro view",exact:true}).click();};
const advancedTools=async tab=>{const details=tab.locator("details.creation-advanced").filter({has:tab.locator("summary",{hasText:"Capture plan & extra editing tools"})});if(!await details.evaluate(node=>node.open))await details.locator("summary").click();};
try {
  await build({ configFile: false, root, publicDir: false, logLevel: "error", build: { outDir: dist, rollupOptions: { input: join(root, "tests/cloud-editor-fixture.html") } } });
  server = createServer(async (request, response) => { const path = resolve(dist, `.${new URL(request.url, "http://localhost").pathname}`); if (!path.startsWith(`${dist}/`)) return response.writeHead(400).end(); try { response.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css" })[extname(path)] ?? "application/octet-stream"); response.end(await readFile(path)); } catch { response.writeHead(404).end(); } });
  await new Promise((done) => server.listen(0, "127.0.0.1", done)); const origin = `http://127.0.0.1:${server.address().port}`;
  const sourceVideo = join(artifacts, "source-blue.mp4"), agentVideo = join(artifacts, "agent-green.mp4"), voiceFile = join(artifacts, "narration.wav");
  execFileSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=640x360:r=30:d=4", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", sourceVideo]);
  execFileSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=660:duration=4", "-c:a", "pcm_s16le", voiceFile]);
  execFileSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=green:s=640x360:r=30:d=4", "-f", "lavfi", "-i", "sine=frequency=880:duration=4", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", agentVideo]);
  const voiceBytes = await readFile(voiceFile);
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  async function device(seed, listing = "20000000-0000-4000-8000-000000000002") {
    const context = await browser.newContext({ viewport: { width: 1440, height: 1100 }, serviceWorkers: "block" });
    await context.addInitScript(installMediaTimingFixture);
    if (seed) await context.addInitScript(value => localStorage.setItem("fixture-cloud", JSON.stringify(value)), seed);
    await context.route("**/*", route => { const url = new URL(route.request().url()); if(url.href === `https://${"a".repeat(32)}.r2.cloudflarestorage.com/fixture/narration.wav`) return route.fulfill({status:200,contentType:"audio/wav",body:voiceBytes}); if (url.origin === origin && route.request().method() === "GET" || url.protocol === "blob:") return route.continue(); receipt.externalRequests.push(url.href); return route.abort(); });
    const tab = await context.newPage(); timingDevices.push({id:timingDevices.length+1,listing,tab}); tab.on("pageerror", error => receipt.errors.push(error.message)); tab.setDefaultTimeout(10000);
    await tab.goto(`${origin}/tests/cloud-editor-fixture.html?listing=${listing}`); await pro(tab); return tab;
  }
  page = await device();
  await expect(page.getByLabel("Title overlay", { exact: true })).toBeVisible();
  const png = await page.evaluate(() => { const c = document.createElement("canvas"); c.width = 800; c.height = 450; const g = c.getContext("2d"); g.fillStyle = "#77509c"; g.fillRect(0, 0, 800, 450); return c.toDataURL().split(",")[1]; });
  await page.getByLabel("Add photos or videos", { exact: true }).setInputFiles({ name: "office-source.png", mimeType: "image/png", buffer: Buffer.from(png, "base64") });
  await expect.poll(async () => (await page.evaluate(() => window.cloudFixture.snapshot())).documents["edit:20000000-0000-4000-8000-000000000002"]?.payload.sources?.length).toBe(1);
  await expect(page.getByText("Syncing media…",{exact:true})).toHaveCount(0);
  await page.getByRole("button",{name:"Chat",exact:true}).click();
  const creationMessage='Set title "Chat-created listing reel"; Make it 1 second; Add slow zooms';
  await page.getByLabel("Describe your video or edit",{exact:true}).fill(creationMessage);
  await page.getByRole("button",{name:"Update video",exact:true}).click();
  const firstKey="edit:20000000-0000-4000-8000-000000000002";
  await expect.poll(async()=>(await page.evaluate(()=>window.cloudFixture.snapshot())).documents[firstKey]?.payload.conversation?.messages?.at(-1)?.role).toBe("assistant");
  const chatSaved=await page.evaluate(()=>window.cloudFixture.snapshot()),chatPayload=chatSaved.documents[firstKey].payload;
  assert.equal(chatPayload.draft.title,"Chat-created listing reel");assert.equal(chatPayload.draft.clips[0].end,1);assert.equal(chatPayload.draft.clips[0].motion,"push_in");
  assert.equal(chatPayload.conversation.draftId,chatPayload.draft.id);assert.equal(chatPayload.conversation.messages[0].text,creationMessage);assert.equal(chatPayload.conversation.messages.at(-1).revision,chatPayload.draft.revision);
  const pairedWrites=await page.evaluate(()=>window.cloudFixture.writeHistory());
  assert.ok(pairedWrites.some(write=>write.key===firstKey&&write.payload.draft.title==="Chat-created listing reel"&&write.payload.conversation?.messages.at(-1)?.revision===write.payload.draft.revision));
  assert.equal(chatSaved.tickets,1);
  receipt.checks.push("A real chat command changes the rendered draft's title, exact duration and photo motion; the same CAS write includes its matching conversation and creates no additional upload");
  await pro(page);
  await page.getByLabel("Title overlay", { exact: true }).fill("Office to phone edit");
  await page.getByLabel("Photo duration (seconds)", { exact: true }).fill("0.5");
  await expect.poll(async () => (await page.evaluate(() => window.cloudFixture.snapshot())).documents["edit:20000000-0000-4000-8000-000000000002"]?.payload.sources?.length).toBe(1);
  await expect.poll(async () => (await page.evaluate(() => window.cloudFixture.snapshot())).documents["edit:20000000-0000-4000-8000-000000000002"]?.payload.draft?.title).toBe("Office to phone edit");
  const first = await page.evaluate(() => window.cloudFixture.snapshot()); assert.equal(first.tickets, 1); assert.equal(first.assets[0].uploaded, true);
  receipt.checks.push("Import automatically uploads the exact source and CAS-saves edit plus source asset reference");
  const second = await device(first); page = second;
  await expect(second.getByLabel("Title overlay", { exact: true })).toHaveValue("Office to phone edit");
  await expect(second.getByRole("button", { name: /Select clip 1:/ })).toBeVisible();
  await expect(second.getByRole("button", { name: /Select clip 1:/ })).not.toHaveAccessibleName(/original file missing/);
  await expect(second.getByRole("button", { name: "Reselect original file", exact: true })).toHaveCount(0);
  await expect(second.getByRole("button", { name: "Export MP4", exact: true })).toBeEnabled();
  assert.equal((await second.evaluate(() => window.cloudFixture.snapshot())).tickets, 1);
  receipt.checks.push("Fresh browser device restores original bytes, verifies SHA-256 and relinks clips without another upload");
  await expect(second.getByLabel("Photo duration (seconds)",{exact:true})).toHaveValue("0.5");
  await expect(second.getByLabel("Photo motion",{exact:true})).toHaveValue("push_in");
  await second.getByRole("button",{name:"Chat",exact:true}).click();
  await expect(second.getByRole("log",{name:"Editing conversation",exact:true}).getByText(creationMessage,{exact:true})).toBeVisible();
  assert.deepEqual((await second.evaluate(()=>window.cloudFixture.snapshot())).documents[firstKey].payload.conversation,first.documents[firstKey].payload.conversation);
  await pro(second);
  receipt.checks.push("A second browser restores both the complete conversation and its actual edited draft, including later manual refinements, while reusing the same original media");

  await second.getByRole("combobox", { name: "Property reel", exact: true }).selectOption("20000000-0000-4000-8000-000000000003");
  await expect(second.getByRole("button",{name:"Pro view",exact:true})).toHaveAttribute("aria-pressed","false");await pro(second);
  await expect(second.getByLabel("Title overlay", {exact:true})).toHaveValue("");
  await expect(second.getByRole("button", {name:/Select clip /})).toHaveCount(0);
  assert.equal((await second.evaluate(() => window.cloudFixture.snapshot())).tickets, 1);
  await second.getByLabel("Add photos or videos", {exact:true}).setInputFiles({name:"separate-property-source.png",mimeType:"image/png",buffer:Buffer.from(png,"base64")});
  await second.getByLabel("Photo duration (seconds)", {exact:true}).fill("0.5");
  await expect.poll(async () => (await second.evaluate(() => window.cloudFixture.snapshot())).documents["edit:20000000-0000-4000-8000-000000000003"]?.payload.sources?.length).toBe(1);
  assert.equal((await second.evaluate(() => window.cloudFixture.snapshot())).tickets, 2);
  receipt.checks.push("Changing property opens a separate empty reel; new sources save only with that property and the original edit remains intact");
  await second.getByLabel("Add photos or videos", {exact:true}).setInputFiles(sourceVideo);
  await second.getByRole("button",{name:"Pro view",exact:true}).click();
  await expect(second.getByLabel("Playback speed", {exact:true})).toBeVisible();
  await second.getByLabel("Playback speed", {exact:true}).selectOption("2");
  await second.getByLabel("Transition into this clip", {exact:true}).selectOption("dissolve");
  await second.getByLabel("Caption style", {exact:true}).selectOption("center");
  await second.getByLabel("Clip caption", {exact:true}).fill("A room to make your own");
  const red = await second.evaluate(() => {const c=document.createElement("canvas");c.width=800;c.height=450;const g=c.getContext("2d");g.fillStyle="red";g.fillRect(0,0,800,450);return c.toDataURL().split(",")[1];});
  await second.getByLabel("Add photos or videos", {exact:true}).setInputFiles({name:"closing.png",mimeType:"image/png",buffer:Buffer.from(red,"base64")});
  await second.getByLabel("Photo duration (seconds)", {exact:true}).fill("0.5");
  await second.getByLabel("Transition into this clip", {exact:true}).selectOption("whip");
  await second.getByLabel("Caption style", {exact:true}).selectOption("highlight");
  await second.getByLabel("Clip caption", {exact:true}).fill("Book a showing");
  await second.getByLabel("Saved narration", {exact:true}).selectOption("50000000-0000-4000-8000-000000000005");
  await second.getByLabel("Narration starts at (seconds)", {exact:true}).fill("0.15");
  await expect(second.getByText(/Narration is ready/)).toBeVisible();
  await expect.poll(async () => (await second.evaluate(() => window.cloudFixture.snapshot())).documents["edit:20000000-0000-4000-8000-000000000003"]?.payload.sources?.length).toBe(3);
  await expect.poll(async () => (await second.evaluate(() => window.cloudFixture.snapshot())).documents["edit:20000000-0000-4000-8000-000000000003"]?.payload.draft?.narration?.offset).toBe(0.15);
  const advanced = await second.evaluate(() => window.cloudFixture.snapshot());
  const third = await device(advanced, "20000000-0000-4000-8000-000000000003");
  await expect(third.getByLabel("Saved narration", {exact:true})).toHaveValue("50000000-0000-4000-8000-000000000005");
  await expect(third.getByText(/Narration is ready/)).toBeVisible();
  await expect(third.getByRole("button", {name:/Select clip 2:/})).not.toHaveAccessibleName(/original file missing/);
  await third.getByRole("button", {name:/Select clip 2:/}).click();
  await third.getByRole("button",{name:"Pro view",exact:true}).click();
  await expect(third.getByLabel("Playback speed", {exact:true})).toHaveValue("2");
  await expect(third.getByLabel("Transition into this clip", {exact:true})).toHaveValue("dissolve");
  await expect(third.getByLabel("Caption style", {exact:true})).toHaveValue("center");
  await third.getByRole("button", {name:/Select clip 3:/}).click();
  await expect(third.getByLabel("Transition into this clip", {exact:true})).toHaveValue("whip");
  assert.equal((await third.evaluate(() => window.cloudFixture.snapshot())).tickets,advanced.tickets);
  await closeDevice(third); await second.bringToFront();
  receipt.checks.push("Fresh device restores narration by trusted result ID, exact video bytes, speed, styled captions and both transition choices");
  await second.getByRole("button", { name: "Export MP4", exact: true }).click();
  await expect(second.getByRole("button", { name: "Save video to listing", exact: true })).toBeVisible({ timeout: 20000 });
  const download = second.waitForEvent("download"); await second.getByRole("link",{name:/Download MP4/}).click(); const exported = join(artifacts,"narrated-studio.mp4"); await (await download).saveAs(exported);
  const probe=JSON.parse(execFileSync("ffprobe",["-v","error","-show_streams","-show_format","-of","json",exported],{encoding:"utf8"}));
  await saveExportDiagnostics("narrated-studio",exported,probe);
  assert(probe.streams.some(s=>s.codec_name==="h264")); assert(probe.streams.some(s=>s.codec_name==="aac")); assert(Math.abs(Number(probe.format.duration)-3)<0.4,`Speed-adjusted edit duration ${probe.format.duration}`);
  const pcm=execFileSync("ffmpeg",["-v","error","-i",exported,"-ss","0.4","-t","1","-vn","-ac","1","-ar","48000","-f","s16le","pipe:1"]); let power=0,crossings=0;
  for(let i=0;i<pcm.length;i+=2){const v=pcm.readInt16LE(i)/32768;power+=v*v;if(i>=2&&pcm.readInt16LE(i-2)<0&&v>=0)crossings++;}
  const rms=Math.sqrt(power/(pcm.length/2)); assert(rms>0.02); assert(crossings>600&&crossings<720,`Narration frequency ${crossings}`);
  const pixel=(time,x=100)=>[...execFileSync("ffmpeg",["-v","error","-ss",String(time),"-i",exported,"-frames:v","1","-vf",`format=rgb24,crop=1:1:${x}:400`,"-f","rawvideo","pipe:1"])];
  const dissolve=pixel(.64);assert(dissolve[0]>20&&dissolve[0]<100&&dissolve[2]>170&&dissolve[2]<245,`Dissolve mixed outgoing purple and incoming blue: ${dissolve}`);
  const whipLeft=pixel(2.6,100),whipRight=pixel(2.6,650);assert(whipLeft[2]>200&&whipLeft[0]<30&&whipRight[0]>200&&whipRight[2]<30,"Whip frame must contain outgoing blue and incoming red at different horizontal positions");
  receipt.checks.push("Decoded exported frames prove actual dissolve blending and horizontal whip movement");
  receipt.checks.push(`Actual exported MP4 is H264/AAC, 2x speed gives ${Number(probe.format.duration).toFixed(2)}s edit, and decoded narration has 660Hz tone (RMS ${rms.toFixed(3)})`);
  await second.evaluate(() => window.cloudFixture.loseComplete());
  await second.getByRole("button", { name: "Save video to listing", exact: true }).click();
  await expect(second.getByText(/Fixture lost completion response/)).toBeVisible();
  const lost = await second.evaluate(() => window.cloudFixture.snapshot());
  await second.getByRole("button", { name: "Save video to listing", exact: true }).click();
  await expect(second.getByText("Video saved to your listing. Open Properties to review and publish it.", { exact: true })).toBeVisible();
  const confirmed = await second.evaluate(() => window.cloudFixture.snapshot()); assert.equal(confirmed.tickets, lost.tickets); assert.equal(confirmed.puts, lost.puts);
  await second.getByRole("button", { name: "Save video to listing", exact: true }).click();
  await expect(second.getByRole("button", { name: "Save video to listing", exact: true })).toBeEnabled();
  assert.equal((await second.evaluate(() => window.cloudFixture.snapshot())).tickets, confirmed.tickets);
  receipt.checks.push("Real MP4 export saves to workspace and a lost completion/repeated Save reconciles without duplicate ticket or bytes");
  const beforeImport = await second.evaluate(() => window.cloudFixture.snapshot());
  await second.getByLabel("Property reel",{exact:true}).selectOption("20000000-0000-4000-8000-000000000002");
  await expect(second.getByRole("button",{name:"Pro view",exact:true})).toHaveAttribute("aria-pressed","false");await pro(second);
  await expect(second.getByLabel("Title overlay",{exact:true})).toHaveValue("Office to phone edit");
  await second.getByLabel("Property reel",{exact:true}).selectOption("20000000-0000-4000-8000-000000000003");
  await expect(second.getByRole("button",{name:"Pro view",exact:true})).toHaveAttribute("aria-pressed","false");await pro(second);
  await expect(second.getByRole("button",{name:/Select clip /})).toHaveCount(3);
  assert.equal((await second.evaluate(() => window.cloudFixture.snapshot())).tickets,beforeImport.tickets);
  receipt.checks.push("Returning to each property restores its own sequence without moving or uploading the other property's originals");
  await second.evaluate(() => window.cloudFixture.requestShotPlan(true));
  await second.getByRole("button", {name:"Replace edit with this shot plan",exact:true}).click();
  await expect(second.getByText(/A photo in this shot plan is missing/)).toBeVisible();
  assert.deepEqual((await second.evaluate(() => window.cloudFixture.snapshot())).documents["edit:20000000-0000-4000-8000-000000000003"].payload.draft.clips,beforeImport.documents["edit:20000000-0000-4000-8000-000000000003"].payload.draft.clips);
  await second.evaluate(() => window.cloudFixture.requestShotPlan());
  await second.getByRole("button", {name:"Replace edit with this shot plan",exact:true}).click();
  await expect(second.getByText(/Saved shot plan applied/)).toBeVisible();
  await expect(second.getByRole("button", {name:/Select clip /})).toHaveCount(2);
  await expect(second.getByLabel("Photo duration (seconds)", {exact:true})).toHaveValue("2");
  await expect(second.getByLabel("Clip caption", {exact:true})).toHaveValue("The closing view");
  await second.getByRole("button",{name:"Pro view",exact:true}).click();
  await expect(second.getByLabel("Photo motion", {exact:true})).toHaveValue("push_in");
  await expect.poll(async () => (await second.evaluate(() => window.cloudFixture.snapshot())).documents["edit:20000000-0000-4000-8000-000000000003"]?.payload.sources?.length).toBe(2);
  const applied=await second.evaluate(() => window.cloudFixture.snapshot());assert.equal(applied.tickets,beforeImport.tickets);
  assert.equal(applied.documents["edit:20000000-0000-4000-8000-000000000003"].payload.draft.clips[1].motion,"pan_left");
  receipt.checks.push("Shot-plan missing-photo failure preserves current edit; confirmed valid plan atomically restores photo order, timing, captions and motion without duplicate uploads");
  await second.evaluate(() => window.cloudFixture.installNativeRecipe());
  await advancedTools(second);
  await second.getByRole("button",{name:"Load phone reel setup",exact:true}).click();
  await expect(second.getByLabel("Phone script",{exact:true})).toHaveValue("Saved on the phone");
  await second.getByRole("button",{name:"Restore phone photos and settings",exact:true}).click();
  await expect(second.getByLabel("Aspect ratio",{exact:true})).toHaveValue("16:9");
  await expect(second.getByLabel("Photo duration (seconds)",{exact:true})).toHaveValue("3");
  await expect(second.getByLabel("Title overlay",{exact:true})).toHaveValue("20 Pine Avenue");
  await second.getByRole("button",{name:/Select clip 2:/}).click();
  await expect(second.getByLabel("Caption style",{exact:true})).toHaveValue("center");
  await expect(second.getByLabel("Transition into this clip",{exact:true})).toHaveValue("dissolve");
  assert.equal((await second.evaluate(() => window.cloudFixture.snapshot())).tickets,applied.tickets);
  receipt.checks.push("Saved native phone recipe restores every linked photo, aspect, title, caption style and transitions with explicit review and no generation");
  await second.getByLabel("Add photos or videos",{exact:true}).setInputFiles(agentVideo);
  await expect.poll(async () => (await second.evaluate(() => window.cloudFixture.snapshot())).documents["edit:20000000-0000-4000-8000-000000000003"]?.payload.sources?.length).toBe(3);
  await second.evaluate(() => window.cloudFixture.requestAgentPlan());
  await second.getByRole("button",{name:"Replace edit with agent plan",exact:true}).click();
  await expect(second.getByText(/Agent plan applied/)).toBeVisible();
  await expect(second.getByRole("button",{name:/Select clip /})).toHaveCount(1);
  await expect(second.getByLabel("Cutaway 1 starts (seconds)",{exact:true})).toHaveValue("1");
  await expect.poll(async () => (await second.evaluate(() => window.cloudFixture.snapshot())).documents["edit:20000000-0000-4000-8000-000000000003"]?.payload.sources?.length).toBe(2);
  await expect.poll(async () => (await second.evaluate(() => window.cloudFixture.snapshot())).documents["edit:20000000-0000-4000-8000-000000000003"]?.payload.draft?.overlays?.length).toBe(1);
  const agentSaved = await second.evaluate(() => window.cloudFixture.snapshot()), fourth = await device(agentSaved, "20000000-0000-4000-8000-000000000003");
  await expect(fourth.getByLabel("Cutaway 1 starts (seconds)",{exact:true})).toHaveValue("1");
  await expect(fourth.getByRole("button",{name:"Reselect cutaway photo",exact:true})).toHaveCount(0);
  await expect(fourth.getByRole("button",{name:"Export MP4",exact:true})).toBeEnabled();
  assert.equal((await fourth.evaluate(() => window.cloudFixture.snapshot())).tickets,agentSaved.tickets);
  await closeDevice(fourth);await second.bringToFront();
  await second.getByRole("button",{name:"Export MP4",exact:true}).click();
  await expect(second.getByRole("link",{name:/Download MP4/})).toBeVisible({timeout:20000});
  const agentDownload=second.waitForEvent("download");await second.getByRole("link",{name:/Download MP4/}).click();const agentExport=join(artifacts,"agent-continuous.mp4");await (await agentDownload).saveAs(agentExport);
  const agentProbe=JSON.parse(execFileSync("ffprobe",["-v","error","-show_streams","-show_format","-of","json",agentExport],{encoding:"utf8"}));await saveExportDiagnostics("agent-continuous",agentExport,agentProbe);assert(Math.abs(Number(agentProbe.format.duration)-4)<.4);
  const agentPixel=time=>[...execFileSync("ffmpeg",["-v","error","-ss",String(time),"-i",agentExport,"-frames:v","1","-vf","format=rgb24,crop=1:1:100:300","-f","rawvideo","pipe:1"])];
  const beforeOverlay=agentPixel(.5),duringOverlay=agentPixel(1.5),afterOverlay=agentPixel(2.5);assert(beforeOverlay[1]>90&&beforeOverlay[0]<30);assert(duringOverlay[0]>200&&duringOverlay[1]<30);assert(afterOverlay[1]>90&&afterOverlay[0]<30);
  const agentPCM=execFileSync("ffmpeg",["-v","error","-i",agentExport,"-ss","0.5","-t","2","-vn","-ac","1","-ar","48000","-f","s16le","pipe:1"]);let weakest=1;
  for(let offset=0;offset+3840<=agentPCM.length;offset+=3840){let power=0;for(let i=offset;i<offset+3840;i+=2)power+=(agentPCM.readInt16LE(i)/32768)**2;weakest=Math.min(weakest,Math.sqrt(power/1920));}
  assert(weakest>.03,`Continuous speech through cutaway boundaries: weakest40ms RMS${weakest}`);
  receipt.checks.push(`Agent export preserves original duration and uninterrupted audio across photo-overlay boundaries (weakest 40ms RMS ${weakest.toFixed(3)}); decoded picture returns to the agent and a fresh device restores both sources`);
  await second.screenshot({path:join(artifacts,"agent-editor.png"),fullPage:true});
  await second.evaluate(() => window.cloudFixture.requestAgentPlan(true));
  await second.getByRole("button",{name:"Replace edit with agent plan",exact:true}).click();
  await expect(second.getByText("Agent plan applied. Your original recording and audio are ready to edit.",{exact:true})).toBeVisible();
  await expect(second.getByRole("button",{name:/Select clip /})).toHaveCount(1);
  await expect(second.getByLabel("Cutaway 1 starts (seconds)",{exact:true})).toHaveCount(0);
  const originalKey="edit:20000000-0000-4000-8000-000000000003";
  await expect.poll(async () => (await second.evaluate(() => window.cloudFixture.snapshot())).documents[originalKey]?.payload.sources?.length).toBe(1);
  const originalOnly=await second.evaluate(() => window.cloudFixture.snapshot());
  assert.equal(originalOnly.tickets,agentSaved.tickets);
  assert.equal(originalOnly.documents[originalKey].payload.draft.audio,"original");
  assert.equal(originalOnly.documents[originalKey].payload.sources[0].assetId,agentSaved.documents[originalKey].payload.sources[0].assetId);
  const originalDevice=await device(originalOnly,"20000000-0000-4000-8000-000000000003");
  await expect(originalDevice.getByRole("button",{name:/Select clip 1:/})).not.toHaveAccessibleName(/original file missing/);
  await expect(originalDevice.getByRole("button",{name:"Export MP4",exact:true})).toBeEnabled();
  await expect(originalDevice.getByLabel("Cutaway 1 starts (seconds)",{exact:true})).toHaveCount(0);
  assert.equal((await originalDevice.evaluate(() => window.cloudFixture.snapshot())).tickets,originalOnly.tickets);
  await closeDevice(originalDevice); await second.bringToFront();
  receipt.checks.push("Presenter original-only handoff reuses the exact saved video and original audio, removes previous overlays, and restores on another browser without another upload");
  await second.getByRole("button",{name:"Chat",exact:true}).click();
  const conflictMessage='Set title "My local conflict title"';
  await second.getByLabel("Describe your video or edit",{exact:true}).fill(conflictMessage);
  await second.getByRole("button",{name:"Update video",exact:true}).click();
  await expect.poll(async()=>(await second.evaluate(()=>window.cloudFixture.snapshot())).documents[originalKey]?.payload.draft?.title).toBe("My local conflict title");
  await pro(second);
  for(let i=0;i<1;i++) await second.getByRole("button", { name: "Remove from edit", exact: true }).click();
  await expect.poll(async () => (await second.evaluate(() => window.cloudFixture.snapshot())).documents["edit:20000000-0000-4000-8000-000000000003"]?.payload.sources?.length).toBe(0);
  receipt.checks.push("Removing a clip prunes its cloud document source reference while retaining original property media");
  await second.getByRole("button",{name:"Chat",exact:true}).click();
  const beforeConflict=(await second.evaluate(()=>window.cloudFixture.snapshot())).documents[originalKey];
  await second.evaluate(() => window.cloudFixture.remoteEdit(undefined,"A remote-only conversation change"));
  await expect(second.getByRole("button", { name: "Reload saved version", exact: true })).toBeVisible();
  await expect(second.getByRole("log",{name:"Editing conversation",exact:true}).getByText(conflictMessage,{exact:true})).toBeVisible();
  await expect(second.getByText("A remote-only conversation change",{exact:true})).toHaveCount(0);
  const remoteConflict=(await second.evaluate(()=>window.cloudFixture.snapshot())).documents[originalKey];
  assert.equal(remoteConflict.revision,beforeConflict.revision+1);assert.equal(remoteConflict.payload.conversation.messages.at(-1).text,"A remote-only conversation change");
  await pro(second);await expect(second.getByLabel("Title overlay", { exact: true })).toHaveValue("My local conflict title");
  receipt.checks.push("A newer cloud revision surfaces a CAS conflict without overwriting either the open draft or its conversation with remote content");
  await second.screenshot({ path: join(artifacts, "cloud-editor.png"), fullPage: true });
  assert.deepEqual(receipt.errors, []); assert.deepEqual(receipt.externalRequests, []); receipt.status = "passed";
} catch (error) { receipt.status = "failed"; receipt.failure = error.stack ?? String(error); receipt.visibleText = await page?.locator("body").innerText().catch(()=>""); process.exitCode = 1; if (page) await page.screenshot({ path: join(artifacts, "failure.png"), fullPage: true }).catch(() => {}); }
finally { await captureMediaTiming(); await browser?.close(); if (server) await new Promise(done => server.close(done)); await writeFile(join(artifacts, "receipt.json"), JSON.stringify(receipt, null, 2)); console.log(JSON.stringify({ ...receipt, artifacts }, null, 2)); }
