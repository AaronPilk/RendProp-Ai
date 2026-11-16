// LOCAL EXPERIMENT ONLY (never in the tree): does the measured-loss detector fire only when the
// recording really lost original audio? Instrumented copy of export.ts: trace the measurement and
// mark "wouldRefuse" instead of aborting, so the exported audio can be analysed for real gaps.
import assert from "node:assert/strict";
import {mkdtemp,readFile,writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join,resolve,extname} from "node:path";
import {createServer} from "node:http";
import {execFileSync,spawn} from "node:child_process";
import {build} from "vite";
import {chromium,expect} from "@playwright/test";
const root=resolve(import.meta.dirname,".."), artifacts=await mkdtemp(join(tmpdir(),"rendprop-loss-experiment-")),dist=join(artifacts,"dist");
const patterns=JSON.parse(process.argv[2]??'[[0,0],[80,300],[150,400],[250,500]]'); const reps=Number(process.argv[3]??3);
let instrumented=false;
await build({configFile:false,root,publicDir:false,logLevel:"error",plugins:[{name:"loss-instrument",enforce:"pre",transform(code,id){
  if(!id.endsWith("/src/editor/export.ts"))return;
  const cond='        if (video && audio && mediaClockStart !== undefined && elapsed < duration && !video.ended &&';
  const refuse='            refuseStall();\n            throwIfAborted(renderSignal);';
  assert(code.includes(cond)&&code.includes(refuse),"instrument sentinels missing");instrumented=true;
  return code.replace(cond,'        if (video && audio && mediaClockStart !== undefined) { const __m = audio.currentTime - mediaClockStart - Math.max(0, video.currentTime - mediaTimeStart) / (clip.speed ?? 1); (window.__lossTrace ||= []).push([Number(elapsed.toFixed(3)), Number(__m.toFixed(4))]); }\n'+cond)
             .replace(refuse,'            (window.__wouldRefuse = true);');
}}],build:{outDir:dist,rollupOptions:{input:join(root,"tests/export-audio-fixture.html")}}});
assert(instrumented);
const server=createServer(async(req,res)=>{const path=resolve(dist,`.${new URL(req.url,"http://localhost").pathname}`);if(!path.startsWith(`${dist}/`)||req.method!=="GET")return res.writeHead(400).end();try{res.setHeader("Content-Type",({".html":"text/html",".js":"text/javascript",".css":"text/css"})[extname(path)]??"application/octet-stream");res.end(await readFile(path));}catch{res.writeHead(404).end();}});
await new Promise(done=>server.listen(0,"127.0.0.1",done));const origin=`http://127.0.0.1:${server.address().port}`;
const tone=join(artifacts,"original-tone.mp4");
execFileSync("ffmpeg",["-v","error","-f","lavfi","-i","color=c=green:s=640x360:r=30:d=3","-f","lavfi","-i","sine=frequency=880:duration=3","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac","-shortest",tone]);
const browser=await chromium.launch({headless:true});const context=await browser.newContext({viewport:{width:1000,height:800},serviceWorkers:"block"});
const page=await context.newPage();page.setDefaultTimeout(30000);
const rows=[];
for(const [stop,period] of patterns){
  let fz=null; if(stop>0){fz=spawn("bash",["/tmp/s1/freeze.sh",String(stop),String(period)],{stdio:"ignore"});}
  for(let r=0;r<reps;r++){
    await page.goto(`${origin}/tests/export-audio-fixture.html`);await page.getByLabel("Synthetic source").setInputFiles(tone);
    await page.evaluate(()=>{window.__lossTrace=[];window.__wouldRefuse=false;window.audioExportFixture.config={speed:2,stall:false,hiccup:true,decodeFailure:false,split:false,cancelAfterBuffer:false};});
    await page.getByRole("button",{name:"Export fixture",exact:true}).click();await expect.poll(()=>page.evaluate(()=>window.audioExportFixture.result),{timeout:60000}).not.toBeNull();
    const result=await page.evaluate(()=>({ok:window.audioExportFixture.result.ok,error:window.audioExportFixture.result.error,base64:window.audioExportFixture.result.base64,trace:window.__lossTrace,wouldRefuse:window.__wouldRefuse}));
    const row={stop,period,rep:r,ok:result.ok,error:result.error,wouldRefuse:result.wouldRefuse,maxLoss:Math.max(0,...result.trace.map(t=>t[1])),readings:result.trace.length,hits:result.trace.filter(t=>t[1]>2/30).length};
    if(result.ok){
      const path=join(artifacts,`run-${stop}-${period}-${r}.mp4`);await writeFile(path,Buffer.from(result.base64,"base64"));
      const probe=JSON.parse(execFileSync("ffprobe",["-v","error","-show_format","-of","json",path],{encoding:"utf8"}));row.duration=Number(probe.format.duration);
      const pcm=execFileSync("ffmpeg",["-v","error","-i",path,"-ss","0.2","-t","0.6","-vn","-ac","1","-ar","48000","-f","s16le","pipe:1"]);
      let weakest=1,weak=0,crossings=0,power=0; for(let offset=0;offset+3840<=pcm.length;offset+=3840){let p=0;for(let i=offset;i<offset+3840;i+=2)p+=(pcm.readInt16LE(i)/32768)**2;const rms=Math.sqrt(p/1920);weakest=Math.min(weakest,rms);if(rms<.03)weak++;}
      for(let i=0;i<pcm.length;i+=2){const v=pcm.readInt16LE(i)/32768;power+=v*v;if(i&&v>=0&&pcm.readInt16LE(i-2)<0)crossings++;}
      row.weakest40msRMS=Number(weakest.toFixed(4));row.weakWindows=weak;row.frequency=Number((crossings/(pcm.length/2/48000)).toFixed(1));
    }
    rows.push(row);console.log(JSON.stringify(row));
  }
  if(fz){fz.kill("SIGTERM");execFileSync("bash",["-c","pkill -CONT -f -- --type=renderer || true"]);}
}
await browser.close();server.close();
await writeFile(join(artifacts,"rows.json"),JSON.stringify(rows,null,2));
console.log("artifacts",artifacts);
