import assert from "node:assert/strict";
import {readFile,writeFile,mkdtemp} from "node:fs/promises";
import {tmpdir} from "node:os";
import {resolve,join,extname} from "node:path";
import {createServer} from "node:http";
import {build} from "vite";
import {chromium,expect} from "@playwright/test";
import {exportSourceHashes} from "./export-source-binding.mjs";
const directory=import.meta.dirname,root=resolve(directory,"..");
const paths=["tests/export-format-lifecycle-browser.mjs","tests/export-format-lifecycle-fixture.tsx","tests/export-format-lifecycle-fixture.html"];
const hashes=()=>exportSourceHashes(root,paths);
const artifacts=await mkdtemp(join(tmpdir(),"rendprop-codec-lifecycle-")),dist=join(artifacts,"dist");
const receipt={status:"running",scope:"Actual React VideoEditor lifecycle with probe-only FakeWorker; no real worker/native codec/media/export evidence",sourceHashesBefore:await hashes(),sourceHashesAfter:null,actualProductModule:true,candidateOverlayUsed:false,checks:[],errors:[],externalRequests:[],downloads:0,requests:[],rows:[],sourceBoundAtEnd:false};
let browser,server;
const permanentServerError=error=>{receipt.errors.push("Owned HTTP server: "+String(error).slice(0,1024));receipt.status="failed";process.exitCode=1;};
try{
 await build({configFile:false,root,publicDir:false,logLevel:"error",build:{outDir:dist,rollupOptions:{input:join(directory,"export-format-lifecycle-fixture.html")}}});
 server=createServer(async(request,response)=>{const url=new URL(request.url,"http://localhost");if(receipt.requests.length<128)receipt.requests.push(url.pathname);const path=resolve(dist,"."+url.pathname);if(!path.startsWith(dist+"/")||request.method!=="GET")return response.writeHead(400).end();try{response.setHeader("Content-Type",({".html":"text/html",".js":"application/javascript",".css":"text/css"})[extname(path)]??"application/octet-stream");response.end(await readFile(path));}catch{response.writeHead(404).end();}});
 server.on("error",permanentServerError);
 await new Promise((done,reject)=>{const failed=error=>{server.removeListener("listening",ready);reject(error);};const ready=()=>{server.removeListener("error",failed);done();};server.once("error",failed);server.once("listening",ready);server.listen(0,"127.0.0.1");});
 const origin="http://127.0.0.1:"+server.address().port;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
 receipt.browserVersion=browser.version();
 const context=await browser.newContext({viewport:{width:1100,height:900},serviceWorkers:"block",acceptDownloads:true});
 await context.route("**/*",route=>{const url=new URL(route.request().url());if(url.origin===origin&&route.request().method()==="GET"||["blob:","data:"].includes(url.protocol))return route.continue();receipt.externalRequests.push(url.href);return route.abort();});
 const page=await context.newPage();page.setDefaultTimeout(10_000);
 page.on("pageerror",error=>{if(receipt.errors.length<32)receipt.errors.push(error.message);});page.on("download",()=>receipt.downloads++);
 await page.goto(origin+"/tests/export-format-lifecycle-fixture.html");await page.waitForFunction(()=>Boolean(window.codecLifecycleFixture));
 assert(await page.evaluate(()=>typeof VideoEncoder==="function"&&typeof VideoFrame==="function"),"Fixture needs actual API presence but never executes native codecs");
 const flush=async()=>{await page.evaluate(()=>new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done))));};
 const rows=()=>page.evaluate(()=>window.codecLifecycleFixture.snapshot());
 const configure=async(props,reset=false)=>{const serial=await page.evaluate(({props,reset})=>{window.codecLifecycleFixture.configure(props,reset);return window.codecLifecycleFixture.serial;},{props,reset});await expect.poll(()=>page.evaluate(()=>window.codecLifecycleFixture.committed),{timeout:10_000}).toBe(serial);await flush();};
 await expect.poll(()=>page.evaluate(()=>window.codecLifecycleFixture.committed),{timeout:10_000}).toBe(0);await flush();assert.equal((await rows()).length,0);await expect(page.getByText("Add photos or videos to check available video formats.",{exact:true})).toHaveCount(1);await expect(page.getByText("Checking available video formats…",{exact:true})).toHaveCount(0);receipt.checks.push("Actual empty editable editor constructs zero workers and shows neutral idle copy");
 await configure({active:false,readOnly:false,populated:true},true);assert.equal((await rows()).length,0);receipt.checks.push("Actual inactive populated editor constructs zero workers");
 await configure({active:true,readOnly:true,populated:true},true);assert.equal((await rows()).length,0);await expect(page.getByRole("group",{name:"Export format",exact:true})).toHaveCount(0);receipt.checks.push("Actual read-only populated editor constructs zero workers");
 await configure({active:true,readOnly:false,populated:true},true);await expect.poll(async()=>(await rows()).length,{timeout:10_000}).toBe(1);let observed=await rows();assert.equal(observed[0].terminated,0);assert.equal(observed[0].init.revision,"format-probe");assert.equal(observed[0].init.config.frames,1);assert.equal(observed[0].init.config.withAudio,false);assert.equal(observed[0].init.config.audioFrames,0);receipt.checks.push("Actual active populated editor submits capability-only init and waits for readiness");
 await configure({active:false,readOnly:false,populated:true});observed=await rows();assert.equal(observed[0].terminated,1);await page.evaluate(()=>window.codecLifecycleFixture.reply(0));await flush();receipt.checks.push("Hiding actual editor aborts and terminates pending worker; a stale readiness reply cannot revive it");
 await configure({active:true,readOnly:false,populated:true});await expect.poll(async()=>(await rows()).length,{timeout:10_000}).toBe(2);observed=await rows();assert.equal(observed[1].terminated,0);await page.evaluate(()=>window.codecLifecycleFixture.reply(1));await expect.poll(async()=>(await rows())[1].terminated,{timeout:10_000}).toBe(1);await expect(page.getByRole("radio",{name:"MP4",exact:true})).toHaveCount(1);receipt.checks.push("Reactivation retries aborted probe and actual readiness reveals MP4");
 await configure({active:false,readOnly:false,populated:true});await configure({active:true,readOnly:false,populated:true});assert.equal((await rows()).length,2);receipt.checks.push("Completed supported result is reused across hide/reactivate without another worker");
 await configure({active:true,readOnly:false,populated:true},true);await expect.poll(async()=>(await rows()).length,{timeout:10_000}).toBe(3);assert.equal((await rows())[2].terminated,0);
 await page.getByRole("button",{name:"Remove from edit",exact:true}).click();await expect.poll(async()=>(await rows())[2].terminated,{timeout:10_000}).toBe(1);await flush();assert.equal((await rows()).length,3);await expect(page.getByText("Add photos or videos to check available video formats.",{exact:true})).toHaveCount(1);await expect(page.getByText("Checking available video formats…",{exact:true})).toHaveCount(0);
 await page.getByRole("button",{name:"Undo",exact:true}).click();await expect.poll(async()=>(await rows()).length,{timeout:10_000}).toBe(4);assert.equal((await rows())[3].terminated,0);await page.evaluate(()=>window.codecLifecycleFixture.reply(3));await expect.poll(async()=>(await rows())[3].terminated,{timeout:10_000}).toBe(1);receipt.checks.push("Removing the final actual clip aborts pending probe; actual Undo restores media metadata and retries the uncached abort");
 receipt.rows=await rows();assert(receipt.rows.every(row=>row.terminated===1));assert.equal(receipt.downloads,0);assert.deepEqual(receipt.externalRequests,[]);assert.deepEqual(receipt.errors,[]);assert(!receipt.requests.some(path=>/encoder-worker-.*\.js$/.test(path)),"Fake capability fixture must not fetch or execute native worker");receipt.status="passed";
}catch(error){receipt.status="failed";receipt.failure=String(error.stack??error);process.exitCode=1;}
finally{
 try{await browser?.close();receipt.browserClosed=true;}catch(error){receipt.status="failed";receipt.browserCloseError=String(error);process.exitCode=1;}
 if(server){server.closeAllConnections();await new Promise(done=>server.close(done));receipt.serverClosed=true;}
 try{receipt.sourceHashesAfter=await hashes();receipt.sourceBoundAtEnd=JSON.stringify(receipt.sourceHashesBefore)===JSON.stringify(receipt.sourceHashesAfter);assert(receipt.sourceBoundAtEnd);}catch(error){receipt.status="failed";receipt.bindingFailure=String(error);process.exitCode=1;}
 if(receipt.errors.length){receipt.status="failed";process.exitCode=1;}
 await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2)+"\n");console.log(JSON.stringify({status:receipt.status,artifacts,receipt:join(artifacts,"receipt.json")}));
}
