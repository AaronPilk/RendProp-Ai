import assert from "node:assert/strict";
import {mkdtemp,readFile,writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join,resolve,extname} from "node:path";
import {createServer} from "node:http";
import {build} from "vite";
import {chromium} from "@playwright/test";
const root=resolve(import.meta.dirname,".."),artifacts=await mkdtemp(join(tmpdir(),"rendprop-photo-prep-")),dist=join(artifacts,"dist");
const receipt={proof:"Actual browser decoder/canvas; deterministic synthetic photo; original immutable; no API/provider/account calls",checks:[],externalRequests:[]};
let server,browser;
try{
 await writeFile(join(artifacts,"index.html"),'<html><body><script type="module" src="/fixture.ts"></script></body></html>');
 await writeFile(join(artifacts,"fixture.ts"),'import {prepareImage,AI_PHOTO_PREPARED_BYTES} from '+JSON.stringify(join(root,"src/features/creative/media.ts"))+'; window.mediaPrep={prepareImage,AI_PHOTO_PREPARED_BYTES};');
 await build({configFile:false,root:artifacts,publicDir:false,logLevel:"error",build:{outDir:dist}});
 server=createServer(async(req,res)=>{const path=resolve(dist,"."+new URL(req.url,"http://localhost").pathname);if(!path.startsWith(dist+"/"))return res.writeHead(400).end();try{res.setHeader("content-type",({".html":"text/html",".js":"application/javascript"})[extname(path)]??"application/octet-stream");res.end(await readFile(path));}catch{res.writeHead(404).end();}});
 await new Promise(done=>server.listen(0,"127.0.0.1",done));const origin="http://127.0.0.1:"+server.address().port;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
 const context=await browser.newContext({serviceWorkers:"block"});
 await context.route("**/*",route=>{if(new URL(route.request().url()).origin===origin)return route.continue();receipt.externalRequests.push(route.request().url());return route.abort();});
 const page=await context.newPage();await page.goto(origin+"/index.html");await page.waitForFunction(()=>!!window.mediaPrep);
 const result=await page.evaluate(async()=>{
  const {prepareImage,AI_PHOTO_PREPARED_BYTES}=window.mediaPrep;
  const hash=async(blob)=>[...new Uint8Array(await crypto.subtle.digest("SHA-256",await blob.arrayBuffer()))].map(x=>x.toString(16).padStart(2,"0")).join("");
  const canvas=document.createElement("canvas");canvas.width=3200;canvas.height=2400;const ctx=canvas.getContext("2d"),pixels=ctx.createImageData(canvas.width,canvas.height);let seed=123456789;
  for(let n=0;n<pixels.data.length;n+=4){seed=(Math.imul(seed,1664525)+1013904223)>>>0;pixels.data[n]=seed&255;pixels.data[n+1]=(seed>>>8)&255;pixels.data[n+2]=(seed>>>16)&255;pixels.data[n+3]=255;}
  ctx.putImageData(pixels,0,0);const blob=await new Promise(done=>canvas.toBlob(done,"image/png"));const file=new File([blob],"untouched-master.png",{type:"image/png",lastModified:1234}),before=await hash(file);
  const decode=async(source)=>{const raw=atob(source.base64),bytes=Uint8Array.from(raw,c=>c.charCodeAt(0)),bitmap=await createImageBitmap(new Blob([bytes],{type:source.mime}));const facts={bytes:bytes.length,width:bitmap.width,height:bitmap.height};bitmap.close();return facts;};
  const first=await prepareImage(file),again=await prepareImage(file),paired=await prepareImage(file,undefined,500000);
  const facts=await decode(first),pairedFacts=await decode(paired);
  let aborted=false,corrupt=false,unsupported=false,budget=false;
  const controller=new AbortController();controller.abort();try{await prepareImage(file,controller.signal);}catch(error){aborted=error.name==="AbortError";}
  try{await prepareImage(new File(["invalid-image"],"broken.png",{type:"image/png"}));}catch{corrupt=true;}
  try{await prepareImage(new File(["pdf"],"wrong.pdf",{type:"application/pdf"}));}catch{unsupported=true;}
  try{await prepareImage(file,undefined,1000001);}catch{budget=true;}
  const alpha=document.createElement("canvas");alpha.width=10;alpha.height=10;
  const transparent=new File([await new Promise(done=>alpha.toBlob(done,"image/png"))],"transparent.png",{type:"image/png"});
  const white=await prepareImage(transparent),raw=atob(white.base64),image=await createImageBitmap(new Blob([Uint8Array.from(raw,c=>c.charCodeAt(0))],{type:"image/jpeg"}));
  const check=document.createElement("canvas");check.width=10;check.height=10;check.getContext("2d").drawImage(image,0,0);const pixel=[...check.getContext("2d").getImageData(5,5,1,1).data];image.close();
  return{budget:AI_PHOTO_PREPARED_BYTES,originalBytes:file.size,originalSHA256:before,originalAfterSHA256:await hash(file),sameOriginalObject:first.file===file&&again.file===file&&paired.file===file,originalName:file.name,originalLastModified:file.lastModified,deterministic:first.base64===again.base64,first:facts,paired:pairedFacts,aborted,corrupt,unsupported,invalidBudget:budget,whitePixel:pixel};
 });
 assert.equal(result.budget,1000000);assert(result.originalBytes>1000000);assert.equal(result.originalSHA256,result.originalAfterSHA256);assert(result.sameOriginalObject);assert.equal(result.originalName,"untouched-master.png");assert.equal(result.originalLastModified,1234);
 assert(result.first.bytes<=1000000);assert(result.paired.bytes<=500000&&result.paired.bytes*2<=1000000);assert(result.first.width<=2048&&result.first.height<=2048);assert(result.first.width<2048,"Noisy photo should exercise real resizing to fit, not just the first encoder call");assert(Math.abs(result.first.width/result.first.height-4/3)<.01);assert(result.deterministic);
 assert(result.aborted&&result.corrupt&&result.unsupported&&result.invalidBudget);assert(result.whitePixel.slice(0,3).every(x=>x>=250));assert.equal(receipt.externalRequests.length,0);
 receipt.result=result;receipt.passed=true;receipt.checks.push("Real decoder and JPEG encoder fit a noisy7.68MP PNG under1MB while retaining exact original File bytes/name/date and full-frame aspect", "Repeated preparation produces identical JPEG bytes; explicit500KB budget supports two-image combined1MB", "Aborted/corrupt/unsupported/over-budget requests fail; transparency flattens white");
}finally{
 await browser?.close();await new Promise(done=>server?server.close(done):done());await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2));console.log(JSON.stringify({artifacts,passed:receipt.passed??false,...(receipt.result?{result:receipt.result}:{})}));
}
