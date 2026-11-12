import assert from "node:assert/strict";
import {mkdir,readFile,writeFile} from "node:fs/promises";
import {join,resolve,extname} from "node:path";
import {createServer} from "node:http";
import {execFileSync} from "node:child_process";
import {build} from "vite";
import {chromium} from "@playwright/test";
const png=Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==","base64");
/** Native HTTP cache is essential here: Playwright routing disables that cache.
 * Only the existing buildKit fetcher seam maps a synthetic admitted URL to the
 * same loopback URL the no-CORS image displays. No production URL is fetched. */
export async function verifyPrivateKitCache({root,artifacts,executablePath}){
 await mkdir(artifacts,{recursive:true});const dist=join(artifacts,"dist"),hits=[],receipt={proof:"Actual buildKit with native browser cache, two loopback origins and synthetic saved photo; no request routing, remote media or source overrides",cases:[],externalRequests:[],errors:[],passed:false};let app,media,browser,appOrigin,mediaOrigin;
 const cases=[{name:"fresh",prime:false},{name:"public-cache",prime:true},{name:"heuristic-cache",prime:true,heuristic:true}];
 try{
  await build({root,configFile:false,publicDir:false,logLevel:"error",build:{outDir:dist,rollupOptions:{input:join(root,"tests/listing-kit-cache-fixture.ts"),output:{entryFileNames:"cache-entry.js"}}}});
  app=createServer(async(req,res)=>{if(req.url==="/"){res.setHeader("content-type","text/html");res.setHeader("cache-control","no-store");return res.end('<!doctype html><html><body><script type="module" src="/cache-entry.js"></script></body></html>');}const pathname=new URL(req.url,"http://localhost").pathname,target=resolve(dist,pathname.slice(1));if(!target.startsWith(dist+"/"))return res.writeHead(400).end();try{res.setHeader("content-type",extname(target)===".js"?"application/javascript":"application/octet-stream");res.end(await readFile(target));}catch{res.writeHead(404).end();}});
  await new Promise(r=>app.listen(0,"127.0.0.1",r));appOrigin=`http://127.0.0.1:${app.address().port}`;
  media=createServer((req,res)=>{const name=/^\/image\/([a-z-]+)\.png$/.exec(new URL(req.url,"http://localhost").pathname)?.[1],item=cases.find(x=>x.name===name);if(req.method!=="GET"||!item)return res.writeHead(404).end();const origin=req.headers.origin;hits.push({case:name,originPresent:Boolean(origin),originMatchesApp:origin===appOrigin});res.setHeader("content-type","image/png");res.setHeader("content-length",png.length);res.setHeader("last-modified",new Date(Date.now()-7*86400000).toUTCString());res.setHeader("etag",'"private-cache-synthetic"');if(!item.heuristic)res.setHeader("cache-control","public, max-age=3600");if(origin===appOrigin)res.setHeader("access-control-allow-origin",origin);res.end(png);});
  await new Promise(r=>media.listen(0,"127.0.0.1",r));mediaOrigin=`http://127.0.0.1:${media.address().port}`;
  browser=await chromium.launch({headless:true,executablePath,args:["--disable-background-networking","--disable-component-update","--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1"]});
  for(const item of cases){const context=await browser.newContext({serviceWorkers:"block"}),page=await context.newPage();page.setDefaultTimeout(10000);page.on("request",r=>{if(![appOrigin,mediaOrigin].includes(new URL(r.url()).origin))receipt.externalRequests.push({method:r.method(),protocol:new URL(r.url()).protocol});});page.on("pageerror",e=>receipt.errors.push(e.name));await page.goto(appOrigin);await page.waitForFunction(()=>typeof window.runKitCache==="function");const result=await page.evaluate(p=>window.runKitCache(p),{...item,mediaOrigin}),requests=hits.filter(x=>x.case===item.name);const {bytes,...metadata}=result;receipt.cases.push({...item,...metadata,networkRequests:requests});
   assert.equal(result.outcome,"zip",`${item.name}: actual Kit must produce a ZIP after displaying the image; observed ${result.errorName??""} ${result.errorMessage??""}, network=${JSON.stringify(requests)}`);
   assert.equal(requests.length,item.prime?2:1);if(item.prime)assert.equal(requests[0].originPresent,false);assert.equal(requests.at(-1).originMatchesApp,true);assert.equal(result.fixtureMutationCount,0);assert.equal(result.mediaCount,1);
   const zip=join(artifacts,item.name+".zip");await writeFile(zip,Buffer.from(bytes));assert.match(execFileSync("unzip",["-t",zip],{encoding:"utf8",timeout:10000}),/No errors detected/);const manifest=JSON.parse(execFileSync("unzip",["-p",zip,"manifest.json"],{encoding:"utf8",timeout:10000}));assert.equal(manifest.files.length,1);assert.deepEqual(execFileSync("unzip",["-p",zip,manifest.files[0].path],{timeout:10000}),png);await context.close();
  }
  for(const row of receipt.cases)assert.deepEqual(row.requestOptions,[{cache:"no-store",credentials:"omit",referrerPolicy:"no-referrer",redirect:"error"}]);
  assert.deepEqual(receipt.externalRequests,[]);assert.deepEqual(receipt.errors,[]);receipt.passed=true;return receipt;
 }catch(error){receipt.error=error.stack??String(error);throw error;}
 finally{await browser?.close();if(app)await new Promise(r=>app.close(r));if(media)await new Promise(r=>media.close(r));await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2)+"\n");}
}
