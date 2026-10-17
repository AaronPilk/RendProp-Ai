#!/usr/bin/env node
import assert from "node:assert/strict";
import {mkdtemp,readFile,writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join,extname,resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {createServer} from "node:http";
import {createHash} from "node:crypto";
import {build} from "vite";
import {chromium,expect} from "@playwright/test";
const root=fileURLToPath(new URL("../",import.meta.url));
const beforeArg=process.argv.find(x=>x.startsWith("--baseline-app="));
const faultArg=process.argv.find(x=>x.startsWith("--fault="));
const fault=faultArg?.split("=")[1]??null;
assert(process.argv.slice(2).every(x=>x===beforeArg||x===faultArg));
const FAULTS={
 "clear-same-scope":["    const depth = mediaDepth.current.pages;","    setMedia(null);\n    const depth = mediaDepth.current.pages;"],
 "forget-pending-depth":["    mediaDepth.current.pages++;","    // omitted pending page depth"],
 "retain-unverified":[
  ["          setMediaWorkspaceVerified(false);\n          if (!canRetainWorkspace(error)) {","          if (!canRetainWorkspace(error)) {"],
  ["      if (current()) {\n        setMedia(null);\n        setMediaLoadedScope(\"\");\n        setMediaError(errorMessage(error));","      if (current()) {\n        setMediaError(errorMessage(error));"],
 ],
};
assert(!fault||Object.hasOwn(FAULTS,fault));assert(!(beforeArg&&fault));
const artifacts=await mkdtemp(join(tmpdir(),"rendprop-library-pagination-")),dist=join(artifacts,"dist");
const sha=bytes=>createHash("sha256").update(bytes).digest("hex");
const files=["src/App.tsx","src/data/services.ts","src/data/contracts.ts","tests/fixtures/library-pagination.tsx","tests/fixtures/library-pagination.html","tests/library-pagination-browser.mjs"];
const sourceHashes=Object.fromEntries(await Promise.all(files.map(async n=>[n,sha(await readFile(join(root,n)))])));
const receipt={status:"running",fault,baseline:!!beforeArg,artifacts,sourceHashes,checks:[],errors:[],externalRequests:[],proof:"Actual App + createStudioServices; closed Auth/fetch and existing synthetic thumbnails; no provider, writes, media export or deployed claim."};
let browser,server,page,context,changed=false;
const cards=()=>page.getByRole("button",{name:"Use in editor",exact:true});
const more=()=>page.getByRole("button",{name:"Load more media",exact:true});
const check=name=>receipt.checks.push(name);
const control=(name,...args)=>page.evaluate(({name,args})=>window.libraryFixture[name](...args),{name,args});
const calls=()=>control("calls");
const mediaCalls=async()=> (await calls()).filter(x=>x.path==="/functions/v1/studio/media");
const focus=()=>page.evaluate(()=>window.dispatchEvent(new Event("focus")));
const settled=()=>expect(page.getByText(/^Updated /)).toBeVisible();
async function open(){
 await context?.close();context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:"block"});
 await context.route("**/*",route=>{
  const u=new URL(route.request().url());
  if(u.origin===origin&&route.request().method()==="GET")return route.continue();
  if(u.origin==="https://rendprop.com"&&u.pathname.startsWith("/private-media/")&&route.request().method()==="GET")return route.fulfill({status:200,contentType:"image/svg+xml",body:'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="9"><rect width="16" height="9" fill="#d9c9ed"/></svg>'});
  receipt.externalRequests.push(u.href);return route.abort();
 });
 page=await context.newPage();page.setDefaultTimeout(7000);page.on("pageerror",e=>receipt.errors.push(e.message));
 await page.goto(`${origin}/tests/fixtures/library-pagination.html?view=library&listing=55555555-5555-4555-8555-555555555555`);
 await expect(cards()).toHaveCount(50);await settled();
}
let origin;
try{
 const before=beforeArg?await readFile(beforeArg.slice("--baseline-app=".length),"utf8"):null;
 if(before)receipt.baselineAppSHA256=sha(before);
 await build({configFile:false,root,publicDir:"public",logLevel:"error",plugins:[{name:"closed-library-pagination-control",enforce:"pre",transform(code,id){
  if(!id.endsWith("/src/App.tsx"))return;
  if(before){changed=true;return before;}
  if(fault){const specs=Array.isArray(FAULTS[fault][0])?FAULTS[fault]:[FAULTS[fault]];for(const[a,b]of specs){assert.equal(code.split(a).length-1,1,"Exact pagination omission anchor");code=code.replace(a,b);}changed=true;return code;}
 }}],build:{outDir:dist,rollupOptions:{input:join(root,"tests/fixtures/library-pagination.html")}}});
 if(before||fault)assert(changed);
 server=createServer(async(req,res)=>{const p=resolve(dist,`.${new URL(req.url,"http://localhost").pathname}`);if(!p.startsWith(dist+"/")||req.method!=="GET")return res.writeHead(400).end();try{res.setHeader("Content-Type",({".html":"text/html",".js":"text/javascript",".css":"text/css",".svg":"image/svg+xml"})[extname(p)]??"application/octet-stream");res.end(await readFile(p));}catch{res.writeHead(404).end();}});
 await new Promise(done=>server.listen(0,"127.0.0.1",done));origin=`http://127.0.0.1:${server.address().port}`;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
 await open();check("Actual App starts with50 scoped Library photos and a next page");
 await control("holdPages");await control("holdDirectory");await more().click();
 await expect.poll(async()=> (await mediaCalls()).filter(x=>x.offset===50).length).toBe(1);
 const directories=(await calls()).filter(x=>x.path==="/functions/v1/me/workspaces").length;await focus();
 await expect.poll(async()=> (await calls()).filter(x=>x.path==="/functions/v1/me/workspaces").length).toBeGreaterThan(directories);
 await expect(page.getByText("Connecting…",{exact:true})).toBeVisible();
 await expect(cards(),"Same-scope refresh keeps the first50 cards while page2 and directory are pending").toHaveCount(50);
 await control("releaseDirectory");await settled();
 await expect.poll(async()=> (await mediaCalls()).filter(x=>x.offset===50).length,{message:"Fresh mapping replays the pending page2"}).toBeGreaterThan(1);
 const page2=(await mediaCalls()).filter(x=>x.offset===50);assert(page2.at(-1).mapping>page2[0].mapping,"New page2 joins a newer complete listing map");
 await expect(cards(),"Fresh page0 is not committed over the desired pending page depth").toHaveCount(50);
 await control("releasePages");await expect(cards(),"Pending page2 survives same-authority refresh").toHaveCount(100);
 assert((await mediaCalls()).some(x=>x.offset===50&&x.aborted));
 check("Held page2/focus/directory refresh preserves50 visible cards and completes100 under fresh mapping");
 await more().click();await expect(cards()).toHaveCount(101);await expect(more()).toHaveCount(0);
 await expect(page.locator(".media-card strong").last()).toHaveText("A Own House photo101");
 check("User can open the third page beyond100 without a permanent page-size cap or reordering");
 const initialSrc=await page.locator(".media-card img").first().getAttribute("src");
 await control("renew");await control("holdDirectory");await focus();await expect(page.getByText("Connecting…",{exact:true})).toBeVisible();await expect(cards()).toHaveCount(101);await control("releaseDirectory");await settled();await expect(page.getByText("Loading media…",{exact:true})).toHaveCount(0);await expect(cards()).toHaveCount(101);
 await expect.poll(()=>page.locator(".media-card img").first().getAttribute("src")).not.toBe(initialSrc);
 check("Completed depth and ordered rows survive passive refresh while private URLs renew atomically");
 const beforeExplicit=(await mediaCalls()).length;await page.getByRole("button",{name:"Refresh library",exact:true}).click();await expect.poll(async()=> (await mediaCalls()).length).toBeGreaterThanOrEqual(beforeExplicit+3);await settled();await expect(page.getByText("Loading media…",{exact:true})).toHaveCount(0);await expect(cards()).toHaveCount(101);
 check("Explicit Refresh library also renews all previously loaded pages");
 await page.screenshot({path:join(artifacts,"library-desktop.png")});
 for(const mode of["503","malformed","403"]){
  await control("setDirectoryMode",mode);await focus();await expect(page.getByRole("alert").first()).toBeVisible();await expect(cards(),`Directory${mode} hides private Library rows`).toHaveCount(0);await expect(more()).toHaveCount(0);
  await control("setDirectoryMode","ok");await page.getByRole("button",{name:"Retry connection",exact:true}).click();await settled();
  const select=page.locator(".space-list .space-row").filter({hasText:"A Own House"});if(await cards().count()===0)await select.click();await expect(cards()).not.toHaveCount(0);
 }
 check("Directory503, malformed data and lost membership hide private rows until fresh scoped recovery");
 await control("setRemoved",true);await focus();await settled();await expect(cards()).toHaveCount(0);await control("setRemoved",false);await focus();await settled();await page.locator(".space-list .space-row").filter({hasText:"A Own House"}).click();await expect(cards()).toHaveCount(50);
 check("Removal from the fresh listing map clears prior media; reselecting resets page depth");
 const physicalPage2=(await mediaCalls()).filter(x=>x.offset===50).length;
 await control("holdPages");await more().click();await expect(page.getByRole("button",{name:"Loading more media…",exact:true})).toBeVisible();
 await expect.poll(async()=> (await mediaCalls()).filter(x=>x.offset===50).length).toBeGreaterThan(physicalPage2);
 await control("holdPages",0);await control("movePhysical");await focus();
 await expect.poll(async()=> (await mediaCalls()).filter(x=>x.offset===0&&x.org==="99999999-9999-4999-8999-999999999999").length).toBeGreaterThan(0);
 await expect(cards(),"Same actor/library/listing with a different physical org immediately masks old rows").toHaveCount(0);
 await control("releasePages");await settled();await expect(cards()).toHaveCount(50);
 const movedSource=await page.locator(".media-card img").first().getAttribute("src"),movedPayload=JSON.parse(Buffer.from(new URL(movedSource).pathname.split("/").at(-1).split(".")[0],"base64url").toString());
 assert.equal(movedPayload.org,"99999999-9999-4999-8999-999999999999");await expect(page.locator(".media-card strong").first()).toHaveText("A Own House photo1");
 check("Same logical library/listing physical-org switch masks old rows and resets depth before late page2 completion");
 await control("holdPages");await more().click();await expect(page.getByRole("button",{name:"Loading more media…",exact:true})).toBeVisible();
 await page.locator(".space-list .space-row").filter({hasText:"A Own Second"}).click();await expect(page.locator(".media-card strong").filter({hasText:"A Own House"})).toHaveCount(0);await expect(cards()).toHaveCount(50);await control("releasePages");await expect(page.locator(".media-card strong").first()).toHaveText("A Own Second photo1");await expect(cards()).toHaveCount(50);
 check("Listing switch aborts and masks the old listing before late page2 bytes can arrive");
 await control("holdPages");await more().click();await page.getByLabel("Switch agent",{exact:true}).selectOption("44444444-4444-4444-8444-444444444444");await settled();await expect(cards()).toHaveCount(0);await page.locator(".space-list .space-row").filter({hasText:"A Other House"}).click();await expect(cards()).toHaveCount(50);await control("releasePages");await expect(page.locator(".media-card strong").first()).toHaveText("A Other House photo1");await expect(cards()).toHaveCount(50);
 check("Logical-library switch fences old rows even when physical org/listing IDs can be reused");
 await control("holdPages");await more().click();await control("switchActor");await settled();await expect(cards()).toHaveCount(0);await page.locator(".space-list .space-row").filter({hasText:"B Other House"}).click();await expect(cards()).toHaveCount(50);await control("releasePages");await expect(page.locator(".media-card strong").first()).toHaveText("B Other House photo1");await expect(cards()).toHaveCount(50);
 check("Actor/session switch clears and ignores the previous actor's late page2 response");
 for(const mode of["503","malformed","403"]){
  await control("setMediaMode",mode);await page.getByRole("button",{name:"Refresh library",exact:true}).click();await expect(page.getByRole("alert").first()).toBeVisible();await expect(cards()).toHaveCount(0);await control("setMediaMode","ok");await page.locator(".media-panel").getByRole("button",{name:"Retry",exact:true}).click();await expect(cards()).toHaveCount(50);
 }
 check("Current media503/malformed/403 responses do not leave stale private cards");
 receipt.calls=await calls();assert(receipt.calls.every(x=>x.method==="GET"));assert.deepEqual(receipt.errors,[]);assert.deepEqual(receipt.externalRequests,[]);
 await control("signOut");await expect(cards()).toHaveCount(0);await expect(more()).toHaveCount(0);check("Sign-out removes private media; whole test issued only reads and no paid requests");
 receipt.status="passed";
}catch(error){receipt.status="failed";receipt.failure=String(error.stack??error);if(page)await page.screenshot({path:join(artifacts,"failure.png")}).catch(()=>{});process.exitCode=1;}
finally{await context?.close();await browser?.close();if(server)await new Promise(done=>server.close(done));receipt.sourceStable=(await Promise.all(files.map(async n=>sourceHashes[n]===sha(await readFile(join(root,n)))))).every(Boolean);await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2)+"\n");console.log(JSON.stringify(receipt));}
