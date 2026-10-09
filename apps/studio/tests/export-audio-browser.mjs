import assert from "node:assert/strict";
import {mkdtemp,readFile,writeFile} from "node:fs/promises";
import {createHash} from "node:crypto";
import {tmpdir} from "node:os";
import {join,resolve,extname} from "node:path";
import {createServer} from "node:http";
import {execFileSync} from "node:child_process";
import {build} from "vite";
import {chromium,expect} from "@playwright/test";
const fault=process.argv[2]??null;assert(fault===null||fault==="--fault=live-original-audio");
const root=resolve(import.meta.dirname,".."), artifacts=await mkdtemp(join(tmpdir(),"rendprop-export-original-audio-")),dist=join(artifacts,"dist");
const paths=["src/editor/export.ts","src/editor/media.ts","src/editor/model.ts","tests/export-audio-fixture.ts","tests/export-audio-browser.mjs"];
const hashes=async()=>Object.fromEntries(await Promise.all(paths.map(async path=>[path,createHash("sha256").update(await readFile(join(root,path))).digest("hex")])));
const receipt={status:"running",fault,proof:"Actual browser exporter/MediaRecorder with generated H264/AAC source and real100ms video pause. No live accounts/providers. RMS>.03 retained.",sourceHashes:await hashes(),checks:[],cases:[],externalRequests:[],errors:[]};
let browser,server,page,mutated=false;
try{
 await build({configFile:false,root,publicDir:false,logLevel:"error",plugins:fault?[{name:"live-original-audio-regression",enforce:"pre",transform(code,id){
  if(!id.endsWith("/src/editor/export.ts"))return;
  const buffer='if (originalAudio && audio && clip.source.kind === "video" && (clip.speed ?? 1) === 1 &&';
  const stall='const refuseStall = () => controller.abort(new Error("Original audio playback stalled during export. No download was created. Try a shorter clip or export with audio explicitly muted."));';
  assert(code.includes(buffer)&&code.includes(stall),"Original-audio mutation sentinel missing");mutated=true;
  return code.replace(buffer,'if (false && originalAudio && audio && clip.source.kind === "video" && (clip.speed ?? 1) === 1 &&').replace(stall,'const refuseStall = () => {};');
 }}]:[],build:{outDir:dist,rollupOptions:{input:join(root,"tests/export-audio-fixture.html")}}});
 if(fault)assert(mutated,"Negative control did not compile the product mutation");
 server=createServer(async(req,res)=>{const path=resolve(dist,`.${new URL(req.url,"http://localhost").pathname}`);if(!path.startsWith(`${dist}/`)||req.method!=="GET")return res.writeHead(400).end();try{res.setHeader("Content-Type",({".html":"text/html",".js":"application/javascript"})[extname(path)]??"application/octet-stream");res.end(await readFile(path));}catch{res.writeHead(404).end();}});
 await new Promise(done=>server.listen(0,"127.0.0.1",done));const origin=`http://127.0.0.1:${server.address().port}`;
 const tone=join(artifacts,"original-tone.mp4"),silent=join(artifacts,"silent-video.mp4");
 execFileSync("ffmpeg",["-v","error","-f","lavfi","-i","color=c=green:s=640x360:r=30:d=3","-f","lavfi","-i","sine=frequency=880:duration=3","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac","-shortest",tone]);
 execFileSync("ffmpeg",["-v","error","-f","lavfi","-i","color=c=blue:s=640x360:r=30:d=3","-an","-c:v","libx264","-pix_fmt","yuv420p",silent]);
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});const context=await browser.newContext({viewport:{width:1000,height:800},serviceWorkers:"block"});
 await context.route("**/*",route=>{const u=new URL(route.request().url());if(u.origin===origin&&route.request().method()==="GET"||u.protocol==="blob:")return route.continue();receipt.externalRequests.push(u.href);return route.abort();});
 page=await context.newPage();page.on("pageerror",error=>receipt.errors.push(error.message));page.setDefaultTimeout(15000);
 const run=async(name,config,{refused=false,silentAudio=false,cancelled=false}={})=>{
  await page.goto(`${origin}/tests/export-audio-fixture.html`);await page.getByLabel("Synthetic source").setInputFiles(silentAudio?silent:tone);
  await page.evaluate(config=>window.audioExportFixture.config={speed:1,stall:false,decodeFailure:false,split:false,cancelAfterBuffer:false,...config},config);
  await page.getByRole("button",{name:"Export fixture",exact:true}).click();await expect.poll(()=>page.evaluate(()=>window.audioExportFixture.result)).not.toBeNull();
  const result=await page.evaluate(()=>window.audioExportFixture.result),record={name,...config,ok:result.ok,decodeCalls:result.decodeCalls,injected:result.injected,error:result.error};receipt.cases.push(record);
  if(config.stall)assert(result.injected,"Forced video stall not injected");
  if(cancelled){assert.equal(result.ok,false);assert.match(result.error,/Synthetic export cancelled/);assert.equal(result.base64,undefined);return;}
  if(refused){assert.equal(result.ok,false,"A media-audio stall must refuse an export");assert.match(result.error,/Original audio playback stalled/);assert.equal(result.base64,undefined);return;}
  assert.equal(result.ok,true,result.error);
  const path=join(artifacts,`${name}.mp4`);await writeFile(path,Buffer.from(result.base64,"base64"));
  const probe=JSON.parse(execFileSync("ffprobe",["-v","error","-show_streams","-show_format","-of","json",path],{encoding:"utf8"}));record.probe=probe;
  const expected=2/(config.speed??1);assert(Math.abs(Number(probe.format.duration)-expected)<.18,`Trim/speed duration ${probe.format.duration} expected${expected}`);
  const pcm=execFileSync("ffmpeg",["-v","error","-i",path,"-ss","0.2","-t",String(expected-.4),"-vn","-ac","1","-ar","48000","-f","s16le","pipe:1"]);let weakest=1,crossings=0,power=0;
  for(let offset=0;offset+3840<=pcm.length;offset+=3840){let chunkPower=0;for(let i=offset;i<offset+3840;i+=2)chunkPower+=(pcm.readInt16LE(i)/32768)**2;weakest=Math.min(weakest,Math.sqrt(chunkPower/1920));}
  for(let i=0;i<pcm.length;i+=2){const v=pcm.readInt16LE(i)/32768;power+=v*v;if(i&&v>=0&&pcm.readInt16LE(i-2)<0)crossings++;}
  const rms=Math.sqrt(power/(pcm.length/2)),frequency=crossings/(pcm.length/2/48000);record.weakest40msRMS=weakest;record.rms=rms;record.frequency=frequency;
  if(silentAudio)assert(rms<.001,"Silent source gained sound");
  else{assert(weakest>.03,`Continuous speech through cutaway boundaries: weakest40ms RMS${weakest}`);assert(Math.abs(frequency-880)<30,`Original speech pitch changed: ${frequency}`);}
 };
 await run("normal-speed-stall",{stall:true});receipt.checks.push("A real100ms video stall preserves uninterrupted normal-speed original audio with exact trim/duration");
 await run("split-segments",{split:true});receipt.checks.push("Adjacent trimmed source segments export once without overlapping sound or a cut gap");
 await run("double-speed-pitch",{speed:2});receipt.checks.push("Media fallback retains2x duration and original880Hz pitch");
 await run("double-speed-stall",{speed:2,stall:true},{refused:true});
 await run("decode-failure",{decodeFailure:true});
 await run("decode-failure-stall",{decodeFailure:true,stall:true},{refused:true});receipt.checks.push("Unsupported decoding preserves source audio; speed-adjusted and unsupported audio stalls refuse download");
 await run("cancel-before-audio-start",{cancelAfterBuffer:true},{cancelled:true});receipt.checks.push("Cancellation before scheduled audio start preserves its abort reason and produces no download");
 await run("silent-video",{},{silentAudio:true});receipt.checks.push("A genuinely silent video stays exportable without fabricating or dropping sound");
 assert.deepEqual(receipt.errors,[]);assert.deepEqual(receipt.externalRequests,[]);receipt.sourceBoundAtEnd=JSON.stringify(await hashes())===JSON.stringify(receipt.sourceHashes);assert(receipt.sourceBoundAtEnd);receipt.status="passed";
}catch(error){receipt.status="failed";receipt.failure=String(error.stack??error);process.exitCode=1;}
finally{await browser?.close();if(server)await new Promise(done=>server.close(done));await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2));console.log(JSON.stringify({...receipt,artifacts},null,2));}
