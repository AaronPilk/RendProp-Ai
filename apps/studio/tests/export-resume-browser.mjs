import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve, extname } from "node:path";
import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";

const root = resolve(import.meta.dirname, ".."), artifacts = await mkdtemp(join(tmpdir(), "rendprop-export-resume-")), dist = join(artifacts, "dist");
// Two one-second notifications leave a clear regression beyond the unchanged
// 400 ms export tolerance, even when a cold encoder compresses its startup.
// The fixed exporter never registers this listener, so it receives no delay.
const resumeNotificationDelayMs = 1000;
const sourceHashes = Object.fromEntries(await Promise.all(["tests/export-resume-browser.mjs", ...["export", "media", "model", "music", "finishing", "overlay-renderer"].map(name => `src/editor/${name}.ts`)].map(async path => [path, createHash("sha256").update(await readFile(join(root, path))).digest("hex")])));
const receipt = { sourceHashes, cadenceFault: "Hold only nextExportFrame animation callbacks until cancellation in both cadence-baseline and late-frames; native timers and media playback are unchanged", proof: `Real exportLocalVideo, decoded synthetic originals and actual MP4/AAC. Resume notifications are delayed ${resumeNotificationDelayMs} ms, and export decoder readiness is delayed 600 ms. Independent negative controls restore the former resume await and per-boundary loading; fixed build uses the production exporter. Actual frame PTS, audio timing and preparation cleanup are verified. No external requests or provider use.`, checks: [], runs: [], preparationFailures: [], errors: [], externalRequests: [], status: "running" };
let browser, server;
const persist = () => writeFile(join(artifacts, "receipt.json"), JSON.stringify(receipt, null, 2) + "\n");
try {
  await writeFile(join(artifacts, "fixture.html"), '<!doctype html><html><head><meta charset="utf-8"></head><body><input id="sources" type="file" multiple><input id="voice" type="file"><button id="run">Export</button><a id="download" download="export.mp4" hidden>Download</a><script type="module" src="./fixture.ts"></script></body></html>');
  await writeFile(join(artifacts, "fixture.ts"), `
import {exportLocalVideo,exportFormats} from ${JSON.stringify(join(root, "src/editor/export.ts"))};
import {inspectFile} from ${JSON.stringify(join(root, "src/editor/media.ts"))};
import {validateDraft} from ${JSON.stringify(join(root, "src/editor/model.ts"))};
let sources=[],voice,narrated=false,url,exportController,decodeIndex=0;
const fixture=window.fixture={ready:false,error:null,result:null,trace:[],exporting:false,decodeDelays:[],revision:1,configure:value=>{narrated=value;},cancel:()=>exportController?.abort(new Error("Fixture export cancelled")),
  delayDecode:async(signal,kind)=>{
    const index=decodeIndex++,delay=fixture.decodeDelays[index]??0;
    log("decode.start",{index,kind,delay});
    if(delay)await new Promise((resolve,reject)=>{
      const abort=()=>{clearTimeout(timer);signal.removeEventListener("abort",abort);log("decode.aborted",{index});reject(signal.reason);};
      const timer=setTimeout(()=>{signal.removeEventListener("abort",abort);log("decode.ready",{index});resolve();},delay);
      signal.addEventListener("abort",abort,{once:true});
    });
    if(fixture.decodeErrorIndex===index)throw new Error("Fixture decoder failure");
  }};
const nativeRAF=window.requestAnimationFrame.bind(window),nativeCancel=window.cancelAnimationFrame.bind(window),frameHandles=new Map();let frameID=0;
window.requestAnimationFrame=callback=>{
  if(!fixture.exporting||!(fixture.delayPhotoFrames&&fixture.frameClipIsPhoto))return nativeRAF(callback);
  const id=++frameID+1000000,handles={};frameHandles.set(id,handles);
  handles.frame=nativeRAF(time=>{handles.timer=setTimeout(()=>{frameHandles.delete(id);callback(time);},120);});return id;
};
window.cancelAnimationFrame=id=>{const handles=frameHandles.get(id);if(handles){if(handles.frame!==undefined)nativeCancel(handles.frame);clearTimeout(handles.timer);frameHandles.delete(id);if(handles.held)log("export.frame.cancelled",{id,index:handles.index});}else nativeCancel(id);};
// Model a throttled export animation scheduler without retiming media, decoder
// events or the timer path. Both paired variants receive the identical fault.
fixture.requestExportFrame=callback=>{
  if(!fixture.holdExportFrames)return window.requestAnimationFrame(time=>{log("export.frame.delivered",{index:fixture.frameClipIndex,time});callback(time);});
  const id=++frameID+1000000,handles={held:true,index:fixture.frameClipIndex};frameHandles.set(id,handles);
  log("export.frame.held",{id,index:handles.index});return id;
};
const NativeRecorder=MediaRecorder;
function log(event,extra={}){fixture.trace.push({event,at:performance.now(),...extra});}
window.MediaRecorder=class extends NativeRecorder {
  constructor(...args){super(...args);fixture.tracks.push(...args[0].getTracks());for(const event of ["start","resume","pause","stop"])
    super.addEventListener(event,()=>log(event+".native",{state:this.state}));}
  start(...args){log("start.call",{state:this.state});const result=super.start(...args);log("start.return",{state:this.state});return result;}
  resume(...args){log("resume.call",{state:this.state});const result=super.resume(...args);log("resume.return",{state:this.state});return result;}
  pause(...args){log("pause.call",{state:this.state,sourceTime:fixture.playingMedia?.currentTime});return super.pause(...args);}
  stop(...args){log("stop.call",{state:this.state});return super.stop(...args);}
  addEventListener(event,callback,options){
    if(event==="resume"&&typeof callback==="function")return super.addEventListener(event,eventObject=>setTimeout(()=>{log("resume.delivered");callback.call(this,eventObject);},${resumeNotificationDelayMs}),options);
    return super.addEventListener(event,callback,options);
  }
};
const nativePlay=HTMLMediaElement.prototype.play;
HTMLMediaElement.prototype.play=function(...args){fixture.playingMedia=this;log("play.call",{time:this.currentTime,rate:this.playbackRate});return nativePlay.apply(this,args).then(result=>{log("play.resolved",{time:this.currentTime,rate:this.playbackRate});return result;});};
document.querySelector("#sources").onchange=async event=>{fixture.ready=false;try{sources=[];for(const file of event.target.files)sources.push(await inspectFile(file,new AbortController().signal));fixture.ready=true;}catch(error){fixture.error=error.message;}};
document.querySelector("#voice").onchange=event=>{voice=event.target.files[0];};
document.querySelector("#run").onclick=async()=>{
  fixture.error=null;fixture.result=null;fixture.trace=[];fixture.resources=[];fixture.tracks=[];fixture.exporting=true;fixture.revision=1;decodeIndex=0;exportController=new AbortController();document.querySelector("#download").hidden=true;
  if(url)URL.revokeObjectURL(url);
  try{
    const draft=validateDraft({schema:1,id:"resume-regression",revision:1,ratio:"9:16",title:"",audio:"original",clips:sources.map((local,index)=>({id:"clip-"+index,source:local.source,start:0,end:index===1?4:.5,speed:index===1?2:1,caption:"",focusX:.5,focusY:.5,transition:index===1?"dissolve":index===2?"whip":"cut"})),...(narrated?{narration:{resultId:"10000000-0000-4000-8000-000000000001",label:"Synthetic narration",offset:.15,volume:1,wordCaptions:false,words:[]}}:{})});
    const result=await exportLocalVideo({draft,media:new Map(sources.map((local,index)=>["clip-"+index,local])),narrationBlob:narrated?voice:undefined,format:exportFormats().find(format=>format.extension==="mp4"),signal:exportController.signal,currentDraft:()=>({...draft,revision:fixture.revision}),onProgress:()=>{}});
    url=URL.createObjectURL(result.blob);const download=document.querySelector("#download");download.href=url;download.hidden=false;fixture.result={duration:result.duration,bytes:result.blob.size};
  }catch(error){fixture.error=error.message;}finally{fixture.exporting=false;}
};
`);
  const oldAwaitPlugin = { name: "negative-control-original-resume-await", enforce: "pre", transform(code, id) {
    if (!id.endsWith("/src/editor/export.ts")) return;
    const seam = /        \/\/ resume\(\) changes state synchronously[\s\S]*?track\?\.requestFrame\?\.\(\);/;
    assert(seam.test(code), "Negative control must match the audited resume fix");
    return code.replace(seam, '        const resumed = waitForEvent(recorder, "resume", renderSignal);\n        recorder.resume();\n        await resumed;');
  } };
  // Delay only export-time decoder readiness, never file inspection or source
  // playback. The sequential negative control restores the former per-boundary
  // loading behavior while using exactly the same source media and assertions.
  const delayedDecodePlugin = { name: "forced-export-decoder-latency", enforce: "pre", transform(code, id) {
    if (!id.endsWith("/src/editor/media.ts")) return;
    const seam = /export async function decodeMedia\([\s\S]*?throwIfAborted\(signal\);/;
    assert(seam.test(code), "Decoder delay must match the real decode entry");
    return code.replace(seam, match => match + '\n  if ((window as any).fixture?.exporting) await (window as any).fixture.delayDecode(signal, kind);')
      .replace('return { element: image, dispose };', 'if ((window as any).fixture?.exporting) (window as any).fixture.resources.push(image); return { element: image, dispose };')
      .replace('return { element: video, dispose };', 'if ((window as any).fixture?.exporting) (window as any).fixture.resources.push(video); return { element: video, dispose };');
  } };
  const sequentialPreparationPlugin = { name: "negative-control-sequential-decode", enforce: "pre", transform(code, id) {
    if (!id.endsWith("/src/editor/export.ts")) return;
    const seam = /      const next = draft.clips\[index \+ 1\];[\s\S]*?if \("error" in preparedNext\) throw preparedNext.error;\n        }\n      }/;
    assert(seam.test(code), "Sequential control must remove only successor preloading");
    code = code.replace(seam, "");
    const handoff = "      if (!lookahead?.result)";
    assert(code.includes(handoff));
    return code.replace(handoff, "      if (index > 0) { lookahead = prepare(clip); await lookahead.settled; }\n" + handoff);
  } };
  const clockObservationPlugin = { name: "export-clock-observation", enforce: "pre", transform(code, id) {
    if (!id.endsWith("/src/editor/export.ts")) return;
    const seam = "const start = performance.now();";
    assert(code.includes(seam));
    const schedule = "const frame = requestAnimationFrame(done);";
    assert(code.includes(schedule), "Cadence fault must intercept only the actual export-frame animation branch");
    return code.replace(seam, seam + ' (window as any).fixture.frameClipIsPhoto = !video; (window as any).fixture.frameClipIndex = index; (window as any).fixture.trace.push({event:"clip.clock.start",at:start,index});')
      .replace(schedule, "const frame = (window as any).fixture.requestExportFrame(done);");
  } };
  const oldFrameClockPlugin = { name: "negative-control-animation-only-clock", enforce: "pre", transform(code, id) {
    if (!id.endsWith("/src/editor/export.ts")) return;
    const seam = /export function nextExportFrame\([\s\S]*?\n}\n\n\/\*\* A real-time/;
    assert(seam.test(code), "Frame-clock control must match the actual deadline helper");
    return code.replace(seam, `export function nextExportFrame(signal: AbortSignal, _remainingMs: number): Promise<number> {
      throwIfAborted(signal);
      return new Promise((resolve, reject) => {
        const aborted = () => {cancelAnimationFrame(frame); reject(signal.reason);};
        const frame = requestAnimationFrame(time => {signal.removeEventListener("abort", aborted); resolve(time);});
        signal.addEventListener("abort", aborted, {once:true});
      });
    }

/** A real-time`);
  } };
  const deadlineOnlyPlugin = { name: "negative-control-deadline-only-cadence", enforce: "pre", transform(code, id) {
    if (!id.endsWith("/src/editor/export.ts")) return;
    const seam = "Math.min(remainingMs, 1000 / 30)";
    assert(code.includes(seam), "Cadence control must remove only the frame interval ceiling");
    return code.replace(seam, "remainingMs");
  } };
  for (const variant of ["baseline", "sequential", "clock-baseline", "cadence-baseline", "fixed", "late-frames"]) await build({ root: artifacts, configFile: false, publicDir: false, base: "./", logLevel: "error", plugins: [clockObservationPlugin, delayedDecodePlugin, ...(variant === "baseline" ? [oldAwaitPlugin] : variant === "sequential" ? [sequentialPreparationPlugin] : variant === "clock-baseline" ? [oldFrameClockPlugin] : variant === "cadence-baseline" ? [deadlineOnlyPlugin] : [])], build: { outDir: join(dist, variant), rollupOptions: { input: join(artifacts, "fixture.html") } } });
  server = createServer(async (request, response) => {
    const path = resolve(dist, `.${new URL(request.url, "http://localhost").pathname}`);
    if (!path.startsWith(`${dist}/`)) return response.writeHead(400).end();
    try { response.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css" })[extname(path)] ?? "application/octet-stream"); response.end(await readFile(path)); }
    catch { response.writeHead(404).end(); }
  });
  await new Promise(done => server.listen(0, "127.0.0.1", done)); const origin = `http://127.0.0.1:${server.address().port}`;
  const source = join(artifacts, "opening-tone-video.mp4"), narration = join(artifacts, "narration.wav");
  // Distinct opening phoneme surrogate: 990 Hz for the first .30 source seconds,
  // then 440 Hz. At 2x playback the opening still has .15 timeline seconds.
  execFileSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=640x360:r=30:d=4", "-f", "lavfi", "-i", "aevalsrc=if(lt(t\\,0.3)\\,0.2*sin(2*PI*990*t)\\,0.2*sin(2*PI*440*t)):s=48000:d=4", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", source]);
  execFileSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=660:duration=4", "-c:a", "pcm_s16le", narration]);
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const sample = (path, start, duration) => {
    const pcm = execFileSync("ffmpeg", ["-v", "error", "-i", path, "-ss", String(start), "-t", String(duration), "-vn", "-ac", "1", "-ar", "48000", "-f", "s16le", "pipe:1"]);
    let power = 0, crossings = 0; const count = pcm.length / 2;
    for (let index = 0; index < pcm.length; index += 2) { const value = pcm.readInt16LE(index) / 32768; power += value * value; if (index && pcm.readInt16LE(index - 2) < 0 && value >= 0) crossings++; }
    // A short opening window includes encoder priming silence. Zero-crossings
    // divided by its whole duration understates pitch; measure spectral energy
    // independently so silence cannot masquerade as lost opening speech.
    let dominantHz = 0, peakPower = 0;
    for (let hz = 300; hz <= 1200; hz += 10) {
      const coefficient = 2 * Math.cos(2 * Math.PI * hz / 48000); let previous = 0, prior = 0;
      for (let index = 0; index < pcm.length; index += 2) { const next = pcm.readInt16LE(index) / 32768 + coefficient * previous - prior; prior = previous; previous = next; }
      const energy = previous * previous + prior * prior - coefficient * previous * prior;
      if (energy > peakPower) { peakPower = energy; dominantHz = hz; }
    }
    return { rms: Math.sqrt(power / count), hz: crossings / (count / 48000), dominantHz, samples: count };
  };
  const frameCache = new Map();
  const frames = (path, x) => {
    const key = `${path}:${x}`;
    if (!frameCache.has(key)) {
      const timestamps = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_frames", "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", path], { encoding: "utf8" })).frames;
      const rgb = execFileSync("ffmpeg", ["-v", "error", "-i", path, "-vf", `format=rgb24,crop=1:1:${x}:400`, "-fps_mode", "passthrough", "-f", "rawvideo", "pipe:1"]);
      assert.equal(rgb.length, timestamps.length * 3);
      frameCache.set(key, timestamps.map((frame, index) => ({ time: Number(frame.best_effort_timestamp_time), rgb: [...rgb.subarray(index * 3, index * 3 + 3)] })));
    }
    return frameCache.get(key);
  };
  // Input seeking selects the next future frame and can conceal an encoded
  // gap. Sample the last frame actually displayed at each requested timestamp.
  const pixel = (path, time, x = 100) => frames(path, x).findLast(frame => frame.time <= time)?.rgb ?? frames(path, x)[0].rgb;
  const isOpeningTone = value => value.rms > .04 && value.dominantHz > 900 && value.dominantHz < 1100;
  const isWhip = ({ left, right }) => left[2] > 200 && left[0] < 30 && right[0] > 200 && right[2] < 30;
  const whipPixels = (path, time) => ({ time, left: pixel(path, time, 100), right: pixel(path, time, 650) });
  for (const variant of ["baseline", "sequential", "clock-baseline", "cadence-baseline", "fixed", "late-frames"]) {
    const context = await browser.newContext({ serviceWorkers: "block", acceptDownloads: true });
    await context.route("**/*", route => { const url = new URL(route.request().url()); if (url.origin === origin || ["blob:", "data:"].includes(url.protocol)) return route.continue(); receipt.externalRequests.push(url.href); return route.abort(); });
    const page = await context.newPage(); page.on("pageerror", error => receipt.errors.push(error.message)); await page.goto(`${origin}/${variant}/fixture.html`);
    const png = await page.evaluate(() => ["#77509c", "red"].map(color => { const canvas = document.createElement("canvas"); canvas.width = 800; canvas.height = 450; const ctx = canvas.getContext("2d"); ctx.fillStyle = color; ctx.fillRect(0, 0, 800, 450); return canvas.toDataURL().split(",")[1]; }));
    await page.locator("#sources").setInputFiles([{ name: "opening.png", mimeType: "image/png", buffer: Buffer.from(png[0], "base64") }, { name: "original.mp4", mimeType: "video/mp4", buffer: await readFile(source) }, { name: "closing.png", mimeType: "image/png", buffer: Buffer.from(png[1], "base64") }]);
    await page.locator("#voice").setInputFiles(narration); await expect.poll(() => page.evaluate(() => window.fixture.ready)).toBe(true);
    for (const narrated of [true, false]) {
      await page.evaluate(({ narrated, variant }) => { window.fixture.configure(narrated); window.fixture.delayPhotoFrames = variant === "clock-baseline"; window.fixture.holdExportFrames = ["cadence-baseline", "late-frames"].includes(variant); window.fixture.decodeDelays = variant === "baseline" ? [] : [0, 600, 600]; }, { narrated, variant }); await page.locator("#run").click();
      await expect.poll(() => page.evaluate(() => window.fixture.error ?? (window.fixture.result ? "done" : "pending")), { timeout: 20000 }).toBe("done");
      const download = page.waitForEvent("download"); await page.locator("#download").click(); const output = join(artifacts, `${variant}-${narrated ? "narrated" : "original"}.mp4`); await (await download).saveAs(output);
      const probe = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", output], { encoding: "utf8" }));
      const trace = await page.evaluate(() => window.fixture.trace), duration = Number(probe.format.duration);
      // AAC startup can shift the .15s opening tone by a few encoded frames.
      // Require it in two adjacent 90ms samples between .53s and .74s, well
      // before the injected old-await delay. Amplitude, pitch, total duration,
      // leading silence and the independent playback trace remain enforced.
      const audio = { opening: [.53, .57, .61, .65].map(start => ({ start, ...sample(output, start, .09) })), middle: sample(output, 1, .7), leading: sample(output, .02, .08) };
      // MediaRecorder timestamps vary by a few encoded frames on busy macOS
      // runners. The 180 ms whip starts at timeline 2.5 s; look for its actual
      // spatial split in this bounded window, not one exact timestamp. A hard
      // cut cannot satisfy the split, and the delayed-resume control must miss
      // this window. Keep the independent duration and audio timing bounds.
      const pixels = {
        dissolve: { before: pixel(output, .4), samples: [.54, .58, .62, .66, .70, .74, .78, .82, .86].map(time => ({ time, rgb: pixel(output, time) })), after: pixel(output, 1.1) },
        beforeWhip: whipPixels(output, 2.4),
        whip: [2.54, 2.58, 2.62, 2.66, 2.70, 2.74].map(time => whipPixels(output, time)),
        afterWhip: whipPixels(output, 2.9),
      };
      receipt.runs.push({ variant, narrated, plannedSeconds: 3, duration, trace, audio, pixels, decodedFrames: frames(output, 100), output, probe }); await persist();
      assert(probe.streams.some(stream => stream.codec_name === "h264")); assert(probe.streams.some(stream => stream.codec_name === "aac"));
      assert.equal(trace.filter(event => event.event === "resume.return").length, 2);
      assert(trace.filter(event => event.event === "resume.return").every(event => event.state === "recording"));
      if (["cadence-baseline", "late-frames"].includes(variant)) {
        const held = trace.filter(event => event.event === "export.frame.held");
        const cancelled = trace.filter(event => event.event === "export.frame.cancelled");
        assert(held.some(event => event.index === 1), "Paired cadence fault must intercept the actual dissolving video segment");
        assert.equal(cancelled.length, held.length, "Every held export animation request must be cancelled by the actual timer path");
        assert(held.every(event => cancelled.some(value => value.id === event.id)), "Timer wakeups must cancel the exact held animation handles");
        assert.equal(trace.filter(event => event.event === "export.frame.delivered").length, 0, "Paired cadence fault must deliver no export animation callbacks");
      }
      if (variant === "baseline") {
        assert(duration > 3.4, `Negative control must reproduce drift with the old await: ${duration}`);
        const resumed = trace.filter(event => event.event === "resume.return");
        const delivered = trace.filter(event => event.event === "resume.delivered");
        assert.equal(delivered.length, 2);
        assert(delivered.every((event, index) => event.at - resumed[index].at >= resumeNotificationDelayMs - 1), "Both negative-control resumptions must include the injected notification delay");
        assert(trace.find(event => event.event === "play.call").at >= delivered[0].at, "The old await must stall original playback until the delayed notification arrives");
        assert(!pixels.whip.some(isWhip), "Delayed-resume negative control must put the whip outside the fixed timeline window");
        if (!narrated) assert(!audio.opening.some(isOpeningTone), "The old-await control must put the original opening tone outside the bounded audio window");
      } else if (variant === "sequential") {
        assert.equal(trace.filter(event => event.event === "resume.delivered").length, 0);
        const ready = trace.filter(event => event.event === "decode.ready");
        assert.equal(ready.length, 2);
        assert(ready.every(event => event.at > trace.find(event => event.event === "start.call").at), "Both sequential decoder delays must occur after recording starts");
        const pauses = trace.filter(event => event.event === "pause.call"), resumes = trace.filter(event => event.event === "resume.call");
        assert(ready.every((event, index) => event.at > pauses[index].at && event.at < resumes[index].at), "Sequential control must finish each decoder at its paused boundary, violating readiness before handoff");
      } else if (variant === "clock-baseline") {
        const clocks = trace.filter(event => event.event === "clip.clock.start");
        const firstPause = trace.find(event => event.event === "pause.call");
        assert(firstPause.at - clocks[0].at > 600, "Animation-only photo clock must overrun its 500 ms segment under late callback delivery");
        assert(!pixels.whip.some(isWhip), "Animation-only clock must miss the unchanged whip timing window");
      } else if (variant === "cadence-baseline") {
        assert(Math.abs(duration - 3) < .4, "Deadline-only control still corrects total segment duration");
        const blends = pixels.dissolve.samples.filter(({rgb}) => rgb[0] > 20 && rgb[0] < 100 && rgb[2] > 170 && rgb[2] < 245);
        assert(!blends.some((sample, index) => blends.slice(index + 1).some(later => sample.rgb[0] - later.rgb[0] >= 8 && later.rgb[2] - sample.rgb[2] >= 8)), "Deadline-only cadence control must miss the unchanged progressing-dissolve criterion when export animation callbacks are held");
      } else {
        const start = trace.find(event => event.event === "start.call");
        const ready = trace.filter(event => event.event === "decode.ready");
        assert.equal(ready.length, 2);
        assert(ready[0].at < start.at, "The second source must be decoded/seeked before recording starts");
        const pauses = trace.filter(event => event.event === "pause.call");
        assert(pauses[1].sourceTime >= 3.999, "Deadline wakeup must still consume the complete four-second source at its selected speed");
        const thirdPreparation = trace.find(event => event.event === "decode.start" && event.index === 2);
        assert(thirdPreparation.at >= pauses[0].at && ready[1].at < pauses[1].at, "The third source must be prepared after the first segment and ready before the second segment ends");
        assert(Math.abs(duration - 3) < .4, `Fixed real MP4 must retain the existing duration tolerance: ${duration}`);
        assert.equal(trace.filter(event => event.event === "resume.delivered").length, 0);
        // Match the fixed, bounded cloud-editor criterion: a real dissolve
        // progresses through multiple blends; a cut or frozen blend cannot pass.
        const dissolve = pixels.dissolve;
        const blends = dissolve.samples.filter(({ rgb }) => rgb[0] > 20 && rgb[0] < 100 && rgb[2] > 170 && rgb[2] < 245);
        assert(blends.some((sample, index) => blends.slice(index + 1).some(later => sample.rgb[0] - later.rgb[0] >= 8 && later.rgb[2] - sample.rgb[2] >= 8)), `Dissolve must progress within the bounded window: ${JSON.stringify(dissolve.samples)}`);
        assert(dissolve.before[0] > 100 && dissolve.before[0] < 135 && dissolve.before[1] > 65 && dissolve.before[1] < 95 && dissolve.before[2] > 135 && dissolve.before[2] < 175, "The preceding shot must still be purple before the dissolve");
        assert(dissolve.after[0] < 10 && dissolve.after[1] < 10 && dissolve.after[2] > 240, "The following shot must be fully blue after the dissolve");
        assert(pixels.whip.some(isWhip), `Actual whip must move blue and red across the frame within the bounded timeline window: ${JSON.stringify(pixels.whip)}`);
        assert(pixels.beforeWhip.left[2] > 200 && pixels.beforeWhip.right[2] > 200 && !isWhip(pixels.beforeWhip), "The preceding shot must still be blue before the whip");
        assert(pixels.afterWhip.left[0] > 200 && pixels.afterWhip.right[0] > 200 && !isWhip(pixels.afterWhip), "The closing shot must be fully red after the whip");
        if (narrated) assert(audio.middle.rms > .02 && audio.middle.hz > 610 && audio.middle.hz < 710, `Narration stays at 660 Hz: ${JSON.stringify(audio.middle)}`);
        else {
          assert(audio.leading.rms < .005, "Leading photo stays silent; video speech does not shift to time zero");
          assert(audio.opening.some((value, index) => index > 0 && isOpeningTone(value) && isOpeningTone(audio.opening[index - 1])), `The distinct first .15 seconds of original audio must survive resume in adjacent bounded samples: ${JSON.stringify(audio.opening)}`);
          assert(audio.middle.rms > .04 && audio.middle.hz > 400 && audio.middle.hz < 480, `The rest of the original recording stays continuous at 440 Hz: ${JSON.stringify(audio.middle)}`);
        }
      }
    }
    if (variant === "fixed") {
      for (const scenario of ["late-successor", "abort-initial-successor", "stale-during-lookahead", "failed-initial-successor"]) {
        await page.evaluate(scenario => {
          window.fixture.configure(false);
          window.fixture.decodeDelays = scenario === "abort-initial-successor" ? [0, 5000] : scenario === "failed-initial-successor" ? [] : [0, 0, 5000];
          window.fixture.decodeErrorIndex = scenario === "failed-initial-successor" ? 1 : undefined;
        }, scenario);
        await page.locator("#run").click();
        if (scenario === "abort-initial-successor" || scenario === "stale-during-lookahead") {
          const index = scenario === "abort-initial-successor" ? 1 : 2;
          await expect.poll(() => page.evaluate(index => window.fixture.trace.some(event => event.event === "decode.start" && event.index === index), index)).toBe(true);
          await page.evaluate(scenario => { if (scenario === "abort-initial-successor") window.fixture.cancel(); else window.fixture.revision++; }, scenario);
        }
        await expect.poll(() => page.evaluate(() => window.fixture.exporting), { timeout: 10000 }).toBe(false);
        const evidence = await page.evaluate(() => ({ error: window.fixture.error, result: window.fixture.result, trace: window.fixture.trace, resourceCount: window.fixture.resources.length, remainingSources: window.fixture.resources.filter(element => element.hasAttribute("src")).length, liveTracks: window.fixture.tracks.filter(track => track.readyState !== "ended").length }));
        receipt.preparationFailures.push({ scenario, ...evidence }); await persist();
        assert.equal(evidence.result, null, "Preparation failure must never offer an export blob");
        assert.equal(evidence.remainingSources, 0, "All current and prepared decoders must release their source");
        assert.equal(evidence.liveTracks, 0, "Failed exports must stop their recording tracks");
        assert(evidence.resourceCount > 0, "Cleanup assertion must inspect real decoded resources");
        if (scenario === "late-successor") assert.match(evidence.error, /could not prepare the next clip in time/);
        if (scenario === "abort-initial-successor") assert.match(evidence.error, /Fixture export cancelled/);
        if (scenario === "stale-during-lookahead") assert.match(evidence.error, /changed/i);
        if (scenario === "failed-initial-successor") {
          assert.match(evidence.error, /Fixture decoder failure/);
          assert(!evidence.trace.some(event => event.event === "start.call"), "Known initial preparation failure must precede recording");
        } else assert(evidence.trace.some(event => event.event === "decode.aborted"), "Pending preparation must be aborted and settled before returning");
      }
    }
    await context.close();
  }
  receipt.checks.push("Held export animation callbacks retain the same MP4 timing, held-frame transitions and opening speech; the animation-only clock misses whip timing and the deadline-only control misses progressing dissolve frames");
  receipt.checks.push("Late decoder readiness, cancellation during initial preparation, stale revision during lookahead and decoder failure reject without a blob, source handles or live tracks");
  receipt.checks.push("Negative control reproduces >400 ms accumulated timing error by delaying only two resume notifications; source playback and decoding are unchanged");
  receipt.checks.push("Sequential-decoder negative control violates readiness before handoff; fixed export prepares the second source before start and third during the second segment despite identical 600 ms decoder delays");
  receipt.checks.push("Fixed exports keep the existing 400 ms duration tolerance without cutting source spans or changing playback speed");
  receipt.checks.push("Decoded MP4 frames retain the real dissolve and whip at their intended timeline positions");
  receipt.checks.push("AAC retains 660 Hz narration, leading photo silence, the distinctive 990 Hz opening sound in adjacent bounded samples after resume, and continuous 440 Hz original audio; the old-await control misses that opening window");
  assert.deepEqual(receipt.errors, []); assert.deepEqual(receipt.externalRequests, []); receipt.status = "passed";
} catch (error) { receipt.status = "failed"; receipt.failure = error.stack ?? String(error); throw error; }
finally {
  await persist(); await browser?.close(); await new Promise(done => server ? server.close(done) : done());
  // Persist every decoded frame, pixel and trace in the receipt; keep CI output
  // compact enough that an intended-control failure remains visible.
  console.log(JSON.stringify({ artifacts, receipt: join(artifacts, "receipt.json"), status: receipt.status,
    checks: receipt.checks.length, preparationFailures: receipt.preparationFailures.length,
    runs: receipt.runs.map(({variant,narrated,duration,trace}) => ({variant,narrated,duration,
      heldFrames: trace.filter(value => value.event === "export.frame.held").length,
      cancelledFrames: trace.filter(value => value.event === "export.frame.cancelled").length,
      deliveredFrames: trace.filter(value => value.event === "export.frame.delivered").length})),
    failure: receipt.failure?.split("\n")[0], errors: receipt.errors, externalRequests: receipt.externalRequests }, null, 2));
}
