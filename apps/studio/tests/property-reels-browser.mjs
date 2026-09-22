import assert from "node:assert/strict";
import {mkdtemp,readFile,writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join,resolve,extname} from "node:path";
import {createServer} from "node:http";
import {build} from "vite";
import {chromium,expect} from "@playwright/test";
const root=resolve(import.meta.dirname,".."),artifacts=await mkdtemp(join(tmpdir(),"rendprop-property-reels-")),dist=join(artifacts,"dist");
const a="20000000-0000-4000-8000-000000000002",b="20000000-0000-4000-8000-000000000003",org="10000000-0000-4000-8000-000000000001",user="40000000-0000-4000-8000-000000000004";
const receipt={proof:"Real property reel sessions, editor, source uploader and document writer; synthetic isolated cloud, no camera or provider requests",checks:[],errors:[],externalRequests:[]};
let server,browser,page;
try{
  await build({configFile:false,root,publicDir:false,logLevel:"error",build:{outDir:dist,rollupOptions:{input:join(root,"tests/cloud-editor-fixture.html")}}});
  server=createServer(async(req,res)=>{const path=resolve(dist,`.${new URL(req.url,"http://localhost").pathname}`);if(!path.startsWith(`${dist}/`))return res.writeHead(400).end();try{res.setHeader("Content-Type",({".html":"text/html",".js":"application/javascript",".css":"text/css"})[extname(path)]??"application/octet-stream");res.end(await readFile(path));}catch{res.writeHead(404).end();}});
  await new Promise(done=>server.listen(0,"127.0.0.1",done));const origin=`http://127.0.0.1:${server.address().port}`;
  browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
  async function device(seed,storage={}){
    const context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:"block"});
    await context.addInitScript(({seed,storage})=>{if(seed)localStorage.setItem("fixture-cloud",JSON.stringify(seed));for(const [key,value] of Object.entries(storage))localStorage.setItem(key,value);},{seed,storage});
    await context.route("**/*",route=>{const url=new URL(route.request().url());if(url.origin===origin&&route.request().method()==="GET"||url.protocol==="blob:")return route.continue();receipt.externalRequests.push(url.href);return route.abort();});
    const tab=await context.newPage();tab.setDefaultTimeout(12000);tab.on("pageerror",error=>receipt.errors.push(error.message));await tab.goto(`${origin}/tests/cloud-editor-fixture.html`);return tab;
  }
  const snapshot=tab=>tab.evaluate(()=>window.cloudFixture.snapshot());
  const title=tab=>tab.getByLabel("Title overlay",{exact:true});
  const savedTitle=async(tab,id,text)=>expect.poll(async()=>(await snapshot(tab)).documents[`edit:${id}`]?.payload.draft.title).toBe(text);
  page=await device();await expect(title(page)).toBeVisible();
  const png=await page.evaluate(()=>{const c=document.createElement("canvas");c.width=800;c.height=450;const g=c.getContext("2d");g.fillStyle="#77509c";g.fillRect(0,0,800,450);return c.toDataURL().split(",")[1];});
  await page.getByLabel("Add photos or videos",{exact:true}).setInputFiles({name:"first-room.png",mimeType:"image/png",buffer:Buffer.from(png,"base64")});await title(page).fill("Oak property story");
  await expect.poll(async()=>(await snapshot(page)).documents[`edit:${a}`]?.payload.sources.length).toBe(1);await savedTitle(page,a,"Oak property story");
  const original=structuredClone((await snapshot(page)).documents[`edit:${a}`]);
  await page.getByLabel("Property reel",{exact:true}).selectOption(b);await expect(title(page)).toHaveValue("");await expect(page.getByRole("button",{name:/Select clip /})).toHaveCount(0);
  await title(page).fill("Pine property story");await savedTitle(page,b,"Pine property story");
  assert.equal((await snapshot(page)).tickets,1);assert.deepEqual((await snapshot(page)).documents[`edit:${a}`],original);
  await page.getByLabel("Property reel",{exact:true}).selectOption(a);await expect(title(page)).toHaveValue("Oak property story");await expect(page.getByRole("button",{name:/Select clip 1:/})).not.toHaveAccessibleName(/original file missing/);
  assert.equal((await snapshot(page)).tickets,1);assert.equal((await snapshot(page)).documents[`edit:${b}`].payload.draft.title,"Pine property story");
  receipt.checks.push("A→B creates a separate empty reel; returning A restores exact source bytes, title and timeline with no reassignment or upload");
  await page.evaluate(()=>window.cloudFixture.requestReelEntry("open-b","20000000-0000-4000-8000-000000000003"));await expect(title(page)).toHaveValue("Pine property story");
  const picker=page.getByRole("region",{name:"Choose property photos and video",exact:true});await expect(picker).toBeVisible();await picker.getByRole("button",{name:"Close media picker",exact:true}).click();
  await page.evaluate(()=>window.cloudFixture.requestReelEntry("open-b","20000000-0000-4000-8000-000000000003"));await expect(picker).toHaveCount(0);
  receipt.checks.push("Feature-card routing opens the requested property's saved reel once, without moving the previous story");
  await page.evaluate(()=>window.cloudFixture.failUpload(true));await page.getByLabel("Add photos or videos",{exact:true}).setInputFiles({name:"pending-room.png",mimeType:"image/png",buffer:Buffer.from(png,"base64")});
  await expect(page.getByText("Fixture upload paused",{exact:true})).toBeVisible();await page.getByLabel("Property reel",{exact:true}).selectOption(a);
  await expect(page.getByLabel("Property reel",{exact:true})).toHaveValue(b);await expect(page.getByText(/Finish opening or saving this reel's files/)).toBeVisible();await expect(title(page)).toHaveValue("Pine property story");
  await page.evaluate(()=>window.cloudFixture.failUpload(false));await page.getByRole("button",{name:"Resume source upload",exact:true}).click();await expect.poll(async()=>(await snapshot(page)).documents[`edit:${b}`]?.payload.sources.length).toBe(1);
  await page.getByRole("button",{name:"Try opening 10 Oak Street again",exact:true}).click();await expect(title(page)).toHaveValue("Oak property story");
  receipt.checks.push("A paused source upload blocks switching and retains local files; Resume then safe switch preserves both property edits");
  const seed=await snapshot(page);const second=await device(seed);await expect(title(second)).toHaveValue("Oak property story");await expect(second.getByRole("button",{name:/Select clip 1:/})).not.toHaveAccessibleName(/original file missing/);await second.close();await page.bringToFront();
  receipt.checks.push("A fresh browser restores the correct property document and original media without another upload");
  const legacy=structuredClone(seed);legacy.documents={edit:{...original,key:"edit",listing_id:null}};
  const backup={...original.payload,draft:{...original.payload.draft,title:"Unsaved browser correction"}};
  const legacyKey=`rendprop-studio:account:${user}:org:${org}:edit`;
  // Use the production key helper's actual format, rather than a guessed alias.
  const key=await page.evaluate(({user,org})=>Object.keys(localStorage).find(key=>key.includes(user)&&key.includes(org)&&key.endsWith(":edit:20000000-0000-4000-8000-000000000002")),{user,org});
  assert.ok(key,"Exact current-account editor backup key must exist");const oldKey=key.slice(0,-37),backupText=JSON.stringify(backup);
  const recovered=await device(legacy,{[`${oldKey}:cloud-backup`]:backupText});page=recovered;
  await expect(recovered.getByRole("region",{name:"Earlier reel recovery",exact:true})).toBeVisible();assert.equal((await snapshot(recovered)).documents[`edit:${a}`],undefined);
  await recovered.getByRole("button",{name:"Use earlier browser backup",exact:true}).click();await expect(title(recovered)).toHaveValue("Unsaved browser correction");await savedTitle(recovered,a,"Unsaved browser correction");
  assert.deepEqual((await snapshot(recovered)).documents.edit,legacy.documents.edit);assert.equal(await recovered.evaluate(key=>localStorage.getItem(key),`${oldKey}:cloud-backup`),backupText);
  assert.equal((await snapshot(recovered)).tickets,seed.tickets);
  receipt.checks.push("Legacy account and unsaved browser edits require an explicit recovery choice; new property save preserves all original copies byte-for-byte");
  await recovered.evaluate(()=>window.cloudFixture.holdNextRead());await recovered.getByLabel("Property reel",{exact:true}).selectOption(b);await expect.poll(()=>recovered.evaluate(()=>window.cloudFixture.pendingReads())).toBe(1);
  await recovered.evaluate(()=>window.cloudFixture.switchAccount());await expect(title(recovered)).toHaveValue("");await recovered.evaluate(()=>window.cloudFixture.releaseReads());await expect(title(recovered)).toHaveValue("");
  assert.equal((await snapshot(recovered)).documents[`edit:${a}`].payload.draft.title,"Unsaved browser correction");
  receipt.checks.push("Late document response after account switch is ignored; prior actor's title and source references cannot hydrate the new editor");
  await recovered.setViewportSize({width:390,height:844});assert.ok(await recovered.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+2));await recovered.screenshot({path:join(artifacts,"property-reels-mobile.png"),fullPage:true});
  receipt.checks.push("390px property selection and separate reel workflow fit without horizontal overflow");
  assert.deepEqual(receipt.errors,[]);assert.deepEqual(receipt.externalRequests,[]);receipt.status="passed";
}catch(error){receipt.status="failed";receipt.failure=error.stack;receipt.visibleText=await page?.locator("body").innerText().catch(()=>"");process.exitCode=1;await page?.screenshot({path:join(artifacts,"failure.png"),fullPage:true}).catch(()=>{});}
finally{await browser?.close();if(server)await new Promise(done=>server.close(done));await writeFile(join(artifacts,"receipt.json"),JSON.stringify({...receipt,artifacts},null,2));console.log(JSON.stringify({...receipt,artifacts},null,2));}
