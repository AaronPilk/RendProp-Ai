import assert from "node:assert/strict";
import {mkdtemp,readFile,writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join,resolve,extname} from "node:path";
import {createServer} from "node:http";
import {createHash} from "node:crypto";
import {build} from "vite";
import {chromium,expect} from "@playwright/test";
const root=resolve(import.meta.dirname,".."),artifacts=await mkdtemp(join(tmpdir(),"rendprop-projects-")),dist=join(artifacts,"dist");
const receipt={proof:"Real Projects and VideoEditor, separate browser storage, synthetic source bytes, isolated API/CAS/object store. No production, provider or camera calls.",checks:[],errors:[],externalRequests:[]};
const documents=new Map(),media=new Map(),calls=[];let browser,server,page,holdNext=null,release;
const digest=data=>createHash("sha256").update(data).digest("hex");
function manifest(row){const count=Math.ceil(row.bytes/8388608),complete=row.parts.size===count;return {...row,complete,parts:Array.from({length:count},(_,index)=>({index,bytes:Math.min(8388608,row.bytes-index*8388608),sha256:row.parts.has(index)?digest(row.parts.get(index)):null,complete:row.parts.has(index),...(complete?{url:`https://fixture.r2.cloudflarestorage.com/${row.actor}/${row.id}/${index}`}:{})}))};}
try{
 await build({configFile:false,root,publicDir:"public",logLevel:"error",build:{outDir:dist,rollupOptions:{input:join(root,"tests/projects-fixture.html")}}});
 server=createServer(async(req,res)=>{try{
  const url=new URL(req.url,"http://localhost"),actor=req.headers["x-fixture-actor"],org=req.headers["x-fixture-org"],prefix=`${actor}:${org}:`;
  const send=(body,status=200)=>{res.writeHead(status,{"Content-Type":"application/json"}).end(JSON.stringify(body));};
  if(url.pathname.startsWith("/fixture/")){
   calls.push({path:url.pathname,method:req.method,actor});let buffers=[];for await(const part of req)buffers.push(part);const bytes=Buffer.concat(buffers),body=req.method==="PUT"?null:bytes.length?JSON.parse(bytes.toString()):null;
   if(url.pathname==="/fixture/projects")return send({projects:[...documents].filter(([k])=>k.startsWith(prefix)).map(([,d])=>({key:d.key,name:d.payload.name,archived:d.payload.archived,listingId:d.listing_id,revision:d.revision,updatedAt:d.updated_at}))});
   if(url.pathname==="/fixture/documents"){
    const key=body?.key??url.searchParams.get("key"),id=prefix+key,prior=documents.get(id);
    if(body){if((prior?.revision??0)!==body.expected_revision)return send({error:"Project changed"},409);assert.equal(body.listing_id,null);documents.set(id,{...body,revision:(prior?.revision??0)+1,updated_at:new Date().toISOString()});}
    if(holdNext===req.method){holdNext=null;await new Promise(done=>{release=done;});}
    return send({document:documents.get(id)??null});
   }
   if(url.pathname==="/fixture/project-media"){
    let row=[...media.values()].find(m=>m.actor===actor&&m.org===org&&m.sha256===(body?.sha256??url.searchParams.get("sha256")));
    if(body&&!row){row={...body,actor,org,parts:new Map()};media.set(body.id,row);}
    return send({media:row?manifest(row):null});
   }
   const match=/^\/fixture\/project-media\/([^/]+)\/(\d+)$/.exec(url.pathname);
   if(match&&req.method==="PUT"){const row=media.get(match[1]);assert.equal(row.actor,actor);row.parts.set(Number(match[2]),bytes);return send({media:manifest(row)});}
   return send({error:"Unexpected fixture route"},404);
  }
  const path=resolve(dist,"."+url.pathname);if(!path.startsWith(dist+"/")||req.method!=="GET")return res.writeHead(400).end();
  res.setHeader("Content-Type",({".html":"text/html",".js":"application/javascript",".css":"text/css",".svg":"image/svg+xml"})[extname(path)]??"application/octet-stream");res.end(await readFile(path));
 }catch(error){receipt.errors.push(String(error));res.writeHead(500).end();}});
 await new Promise(done=>server.listen(0,"127.0.0.1",done));const origin=`http://127.0.0.1:${server.address().port}`;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
 async function newPage(query=""){
  const context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:"block"});
  await context.route("**/*",route=>{const url=new URL(route.request().url());if(url.origin===origin)return route.continue();
   if(url.hostname==="fixture.r2.cloudflarestorage.com"){const [,actor,id,index]=url.pathname.split("/"),row=media.get(id);assert.equal(row?.actor,actor);return route.fulfill({status:200,headers:{"Access-Control-Allow-Origin":origin,"Content-Type":"application/octet-stream"},body:row.parts.get(Number(index))});}
   receipt.externalRequests.push(url.href);return route.abort();});
  const p=await context.newPage();p.setDefaultTimeout(15000);p.on("pageerror",e=>receipt.errors.push(e.message));p.on("dialog",d=>d.accept());await p.goto(`${origin}/tests/projects-fixture.html${query}`);return p;
 }
 page=await newPage();const clip=p=>p.getByRole("button",{name:/Select clip 1:/});const status=p=>p.getByText("Project and originals saved to your account.",{exact:true});
 const png=await page.evaluate(()=>{const c=document.createElement("canvas");c.width=800;c.height=450;const g=c.getContext("2d");g.fillStyle="#731cc2";g.fillRect(0,0,800,450);return c.toDataURL().split(",")[1];});
 await page.getByLabel("Add photos or videos",{exact:true}).setInputFiles({name:"private-room.png",mimeType:"image/png",buffer:Buffer.from(png,"base64")});
 await expect(clip(page)).not.toHaveAccessibleName(/original file missing/);await expect(page.getByText(/^Local video: originals/)).toBeVisible();
 assert.equal(calls.filter(c=>c.method!=="GET").length,0);await page.reload();await expect(clip(page)).toBeVisible();await expect(clip(page)).not.toHaveAccessibleName(/original file missing/);
 receipt.checks.push("Local import backs original bytes in IndexedDB and restores after page reload without any cloud mutation");
 await page.getByLabel("Project name",{exact:true}).fill("Kitchen reel");await page.getByRole("button",{name:"Save project to account",exact:true}).click();await expect(status(page)).toBeVisible();
 const key=await page.getByLabel("Open video project",{exact:true}).inputValue();assert.ok(key.startsWith("project:"));assert.equal(documents.size,1);assert.equal(media.size,1);
 receipt.checks.push("Explicit account save creates one named CAS document and private chunked original with separate completion status");
 const second=await newPage();await second.getByLabel("Open video project",{exact:true}).selectOption(key);await expect(status(second)).toBeVisible();await expect(clip(second)).not.toHaveAccessibleName(/original file missing/);
 const foreign=await newPage("?actor=B");await expect(foreign.getByLabel("Open video project",{exact:true}).locator("option")).toHaveCount(1);await expect(clip(foreign)).toHaveCount(0);
 receipt.checks.push("A separate browser restores the named project and verifies private source bytes; a different account receives no project or originals");
 await second.getByLabel("Project name",{exact:true}).fill("Office revision");await second.getByLabel("Project name",{exact:true}).blur();await expect(status(second)).toBeVisible();
 await page.evaluate(()=>window.dispatchEvent(new Event("focus")));await expect(page.getByText(/A newer project was saved on another device/)).toBeVisible();
 await page.getByLabel("Project name",{exact:true}).fill("Browser work to preserve");await page.getByLabel("Project name",{exact:true}).blur();
 await page.getByRole("button",{name:"Open newer saved version",exact:true}).click();await expect(page.getByLabel("Project name",{exact:true})).toHaveValue("Office revision");
 await page.getByRole("button",{name:"Recover browser edit: Browser work to preserve",exact:true}).click();await expect(page.getByLabel("Project name",{exact:true})).toHaveValue("Browser work to preserve");await expect(page.getByLabel("Open video project",{exact:true})).toHaveValue("");await expect(clip(page)).not.toHaveAccessibleName(/original file missing/);
 assert.equal([...documents.values()][0].payload.name,"Office revision");
 receipt.checks.push("Concurrent revision conflict preserves an independently recoverable browser draft; recovery makes a local copy without overwriting remote work");
 await page.getByRole("button",{name:"Save project to account",exact:true}).click();await expect(status(page)).toBeVisible();assert.equal(documents.size,2);assert.equal(media.size,1);
 await page.getByRole("button",{name:"Archive",exact:true}).click();await expect(page.getByRole("button",{name:"Unarchive",exact:true})).toBeVisible();
 receipt.checks.push("Saving recovered work creates another project identity while reusing verified source storage; archive is reversible");
 await page.getByRole("button",{name:"Switch fixture account",exact:true}).click();await expect(page.getByText("Fixture account B",{exact:true})).toBeVisible();await expect(clip(page)).toHaveCount(0);await expect(page.getByRole("button",{name:/Recover browser edit:/})).toHaveCount(0);
  receipt.checks.push("External account changes remount project and recovery scopes without exposing the previous user's text or media");
  const before=calls.filter(c=>c.method==="POST"&&c.actor==="33333333-3333-4333-8333-333333333333").length;
  holdNext="GET";release=undefined;
  await page.getByLabel("Project name",{exact:true}).fill("Deferred private project");await page.getByRole("button",{name:"Save project to account",exact:true}).click();
  await expect.poll(()=>typeof release).toBe("function");await page.getByRole("button",{name:"Switch fixture account",exact:true}).click();await expect(page.getByText("Fixture account A",{exact:true})).toBeVisible();release();release=undefined;
  await page.evaluate(()=>new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done))));
  assert.equal(calls.filter(c=>c.method==="POST"&&c.actor==="33333333-3333-4333-8333-333333333333").length,before);await expect(page.getByText("Deferred private project",{exact:true})).toHaveCount(0);
  receipt.checks.push("An account switch while a tentative project writer is opening aborts it before any cloud document write");
  const viewer=await newPage("?role=marketing");await viewer.getByLabel("Open video project",{exact:true}).selectOption(key);await expect(clip(viewer)).not.toHaveAccessibleName(/original file missing/);await expect(viewer.getByLabel("Project name",{exact:true})).toBeDisabled();await expect(viewer.getByRole("button",{name:"Save a copy",exact:true})).toBeDisabled();await expect(viewer.getByRole("button",{name:"Archive",exact:true})).toBeDisabled();
  receipt.checks.push("A current read-only workspace role can restore its own saved project but receives no cloud editing controls");
 for(const width of [1440,390]){await page.setViewportSize({width,height:1000});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);await page.screenshot({path:join(artifacts,`projects-${width}.png`),fullPage:true});}
 assert.deepEqual(receipt.errors,[]);assert.deepEqual(receipt.externalRequests,[]);receipt.status="passed";
}catch(error){receipt.status="failed";receipt.failure=String(error.stack??error);process.exitCode=1;await page?.screenshot({path:join(artifacts,"failure.png"),fullPage:true}).catch(()=>{});if(page)await writeFile(join(artifacts,"failure.txt"),await page.locator("body").innerText().catch(()=>""));}
finally{release?.();await browser?.close();if(server)await new Promise(done=>server.close(done));await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2));console.log(JSON.stringify({...receipt,artifacts},null,2));}
