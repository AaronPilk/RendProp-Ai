import assert from "node:assert/strict";
import {mkdtemp,readFile,writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";import {join,resolve,extname} from "node:path";import {createServer} from "node:http";
import {build} from "vite";import {chromium,expect} from "@playwright/test";
// Regression: saved photo versions past the first 50-row media page must still appear in the
// AI Photo Studio Original / Decluttered / Staged tabs (photo-first parity, no hidden history).
const root=resolve(import.meta.dirname,".."),artifacts=await mkdtemp(join(tmpdir(),"rendprop-creative-pages-")),dist=join(artifacts,"dist");
const receipt={proof:"Real Creative Studio photo tabs over isolated server-shaped media pages; no paid AI, upload or publication",checks:[],externalRequests:[],errors:[]};
const png=Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=","base64");
let browser,server,page;
try{
 await build({configFile:false,root,publicDir:false,logLevel:"error",build:{outDir:dist,rollupOptions:{input:join(root,"tests/creative-fixture.html")}}});
 server=createServer(async(req,res)=>{const path=resolve(dist,`.${new URL(req.url,"http://localhost").pathname}`);if(!path.startsWith(`${dist}/`))return res.writeHead(400).end();try{res.setHeader("Content-Type",({".html":"text/html",".js":"application/javascript",".css":"text/css"})[extname(path)]??"application/octet-stream");res.end(await readFile(path));}catch{res.writeHead(404).end();}});
 await new Promise(done=>server.listen(0,"127.0.0.1",done));const origin=`http://127.0.0.1:${server.address().port}`;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});const context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:"block"});
 await context.addInitScript(()=>localStorage.setItem("fixture-photo-pages","true"));
 await context.route("**/*",route=>{const url=new URL(route.request().url());if(url.origin===origin&&route.request().method()==="GET")return route.continue();if(url.hostname==="012345678901234567890123456789ab.r2.cloudflarestorage.com")return route.fulfill({status:200,contentType:"image/png",headers:{"Access-Control-Allow-Origin":"*"},body:png});receipt.externalRequests.push(url.origin);return route.abort();});
 page=await context.newPage();page.on("pageerror",error=>receipt.errors.push(error.message));page.setDefaultTimeout(10000);
 await page.goto(`${origin}/tests/creative-fixture.html`);await expect(page.getByText("Your saved draft is ready",{exact:true})).toBeVisible();
 const versions=page.getByRole("navigation",{name:"Photo versions"}),picker=page.getByRole("combobox",{name:"Source property photo",exact:true});
 await expect(picker.locator("option")).toHaveCount(57);
 await expect(picker.locator("option",{hasText:"Room 55"})).toHaveCount(1);
 await expect(picker.locator("option",{hasText:"Staged primary bedroom · paired original"})).toHaveCount(1);
 receipt.checks.push("Original tab lists all 56 gallery rows from both media pages, including the paired original of a page-two staged version");
 await versions.getByRole("button",{name:"Staged",exact:true}).click();
 await expect(page.getByText("No saved results in this category yet.",{exact:true})).toHaveCount(0);
 await expect(picker.locator("option",{hasText:"Staged primary bedroom · saved edit"})).toHaveCount(1);
 await picker.selectOption({label:"Staged primary bedroom · saved edit"});
 await expect(page.getByAltText("Selected source property")).toBeVisible();await expect(page.getByRole("button",{name:"Edit original with AI",exact:true})).toBeVisible();
 await expect(page.getByRole("button",{name:"Generate preview",exact:true})).toHaveCount(0);
 receipt.checks.push("Staged tab shows the saved page-two version for review/select/share; new edits still start from Original");
 await versions.getByRole("button",{name:"Saved edits",exact:true}).click();await expect(page.getByText("No saved results in this category yet.",{exact:true})).toBeVisible();
 receipt.checks.push("Video-only processing copies and video poster frames are not offered as originals or saved photo versions");
 const batch=page.getByRole("region",{name:"Edit several photos",exact:true});await versions.getByRole("button",{name:"Original",exact:true}).click();
 await expect(batch.getByRole("checkbox",{name:"Room 55",exact:true})).toBeVisible();
 const offsets=(await page.evaluate(()=>window.creativeFixture.mediaCalls())).map(call=>call.offset);
 assert.ok(offsets.includes(0)&&offsets.includes(50),`media pages requested: ${offsets}`);
 const aiCalls=(await page.evaluate(()=>window.creativeFixture.calls())).filter(call=>/ai-photo|studio\/photos|\/uploads/.test(call.path));assert.deepEqual(aiCalls,[]);
 receipt.checks.push("Batch photo choices include page-two originals; loading pages makes no AI, upload or gallery mutation");
 assert.deepEqual(receipt.errors,[]);assert.deepEqual(receipt.externalRequests,[]);receipt.status="passed";
}catch(error){receipt.status="failed";receipt.failure=error.stack;process.exitCode=1;await page?.screenshot({path:join(artifacts,"failure.png"),fullPage:true}).catch(()=>{});}
finally{await browser?.close();if(server)await new Promise(done=>server.close(done));await writeFile(join(artifacts,"receipt.json"),JSON.stringify({...receipt,artifacts},null,2));console.log(JSON.stringify({...receipt,artifacts},null,2));}
