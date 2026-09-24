import assert from "node:assert/strict";
import {mkdtemp,readFile,writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join,resolve,extname} from "node:path";
import {createServer} from "node:http";
import {build} from "vite";
import {chromium,expect} from "@playwright/test";

const root=resolve(import.meta.dirname,".."),artifacts=await mkdtemp(join(tmpdir(),"rendprop-creation-shell-")),dist=join(artifacts,"dist");
const receipt={proof:"Real App, local editor and account scope transitions using synthetic media and isolated Auth/API. No provider, camera or production calls.",checks:[],errors:[],externalRequests:[]};
const first="55555555-5555-4555-8555-555555555500",org="33333333-3333-4333-8333-333333333333",other="44444444-4444-4444-8444-444444444444";
let browser,server,page;
try {
  await build({configFile:false,root,publicDir:"public",logLevel:"error",build:{outDir:dist,rollupOptions:{input:join(root,"tests/fixtures/connected.html")}}});
  server=createServer(async(req,res)=>{const path=resolve(dist,"."+new URL(req.url,"http://localhost").pathname);if(!path.startsWith(dist+"/")||req.method!=="GET")return res.writeHead(400).end();try{res.setHeader("Content-Type",({".html":"text/html",".js":"application/javascript",".css":"text/css",".svg":"image/svg+xml"})[extname(path)]??"application/octet-stream");res.end(await readFile(path));}catch{res.writeHead(404).end();}});
  await new Promise(done=>server.listen(0,"127.0.0.1",done));const origin=`http://127.0.0.1:${server.address().port}`;
  browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
  const context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:"block"});
  await context.route("**/*",route=>{if(new URL(route.request().url()).origin===origin&&route.request().method()==="GET")return route.continue();receipt.externalRequests.push(route.request().url());return route.abort();});
  page=await context.newPage();page.setDefaultTimeout(12000);page.on("pageerror",e=>receipt.errors.push(e.message));
  const nav=name=>page.getByRole("navigation",{name:"Studio navigation"}).getByRole("button",{name,exact:true});
  const local=()=>page.getByRole("region",{name:"Local video workspace",exact:true});
  const prompt=()=>local().getByLabel("Describe your video or edit",{exact:true});
  const clip=()=>local().getByRole("button",{name:/Select clip 1:/});
  await page.goto(`${origin}/tests/fixtures/connected.html?noProperties`);
  await expect(page.getByText(/^Updated \d/)).toBeVisible();
  await expect(nav("Create")).toHaveAttribute("aria-current","page");
  await expect(page.getByLabel("Property reel",{exact:true})).toHaveValue("");
  await expect(prompt()).toBeVisible();
  assert.deepEqual(await page.getByRole("navigation",{name:"Studio navigation"}).getByRole("button").allTextContents(),["CreateCreate","My homeshomes","MediaMedia","BusinessBusiness"]);
  receipt.checks.push("Create is the default with four primary destinations; an account with no properties reaches the real local editor immediately");

  await page.goto(`${origin}/tests/fixtures/connected.html`);
  await expect(prompt()).toBeVisible();
  await expect(page.getByLabel("Property reel",{exact:true})).toHaveValue("");
  const png=await page.evaluate(()=>{const c=document.createElement("canvas");c.width=800;c.height=450;const g=c.getContext("2d");g.fillStyle="#7d39ec";g.fillRect(0,0,800,450);return c.toDataURL().split(",")[1];});
  await local().getByLabel("Add photos or videos",{exact:true}).setInputFiles({name:"local-only.png",mimeType:"image/png",buffer:Buffer.from(png,"base64")});
  await expect(clip()).not.toHaveAccessibleName(/original file missing/);
  await prompt().fill("A local request that must survive navigation");
  await nav("Media").click();await nav("Create").click();
  await expect(prompt()).toHaveValue("A local request that must survive navigation");
  await expect(clip()).not.toHaveAccessibleName(/original file missing/);
  await nav("Media").click();await page.evaluate(()=>window.studioFixture.setMode("hold"));
  await page.getByRole("button",{name:"Refresh library",exact:true}).click();
  await expect(page.getByText("Connecting…",{exact:true})).toBeVisible();await nav("Create").click();
  await expect(prompt()).toHaveValue("A local request that must survive navigation");
  await expect(clip()).not.toHaveAccessibleName(/original file missing/);
  await page.evaluate(()=>window.studioFixture.release());await expect(page.getByText(/^Updated \d/)).toBeVisible();
  receipt.checks.push("Ordinary navigation and an in-flight account refresh preserve the local conversation and decoded source files");

  await prompt().fill("");let dialogs=0;
  page.on("dialog",async dialog=>{dialogs++;await dialog.dismiss();});
  await page.getByLabel("Property reel",{exact:true}).selectOption(first);
  await expect(page.getByLabel("Property reel",{exact:true})).toHaveValue("");assert.equal(dialogs,1);
  await expect(clip()).not.toHaveAccessibleName(/original file missing/);
  page.removeAllListeners("dialog");page.on("dialog",dialog=>dialog.accept());
  await page.getByLabel("Property reel",{exact:true}).selectOption(first);
  await expect(page.getByRole("region",{name:"Saved property video workspace",exact:true})).toBeVisible();
  await expect.poll(()=>new URL(page.url()).searchParams.get("listing")).toBe(first);
  await page.getByLabel("Property reel",{exact:true}).selectOption("");
  await expect(prompt()).toBeVisible();await expect(clip()).not.toHaveAccessibleName(/original file missing/);
  await expect.poll(()=>new URL(page.url()).searchParams.get("listing")).toBe(null);
  assert.equal((await page.evaluate(()=>window.studioFixture.calls())).filter(call=>call.method!=="GET").length,0);
  receipt.checks.push("Opening a property is an explicit separate-edit decision; cancel preserves local work, return retains bytes, URLs follow selection, and local media never uploads or cloud-saves");

  page.removeAllListeners("dialog");page.on("dialog",dialog=>dialog.dismiss());
  await page.getByLabel("Switch workspace",{exact:true}).selectOption(other);
  await expect(page.getByLabel("Switch workspace",{exact:true})).toHaveValue(org);
  await expect(clip()).not.toHaveAccessibleName(/original file missing/);
  page.removeAllListeners("dialog");page.on("dialog",dialog=>dialog.accept());
  await page.getByLabel("Switch workspace",{exact:true}).selectOption(other);
  await expect(page.getByLabel("Switch workspace",{exact:true})).toHaveValue(other);
  await expect(local().getByRole("button",{name:/Select clip 1:/})).toHaveCount(0);
  await prompt().fill("Second workspace private text");
  await page.evaluate(()=>window.studioFixture.switchUser("B"));
  await expect(page.getByRole("button",{name:"Manage Fixture B",exact:true})).toBeVisible();
  await expect(prompt()).not.toHaveValue("Second workspace private text");
  receipt.checks.push("Workspace cancellation retains source bytes; confirmed workspace changes and external account changes fence local files and unsent text");

  await page.goto(`${origin}/tests/fixtures/connected.html?view=editor&listing=${first}`);
  await expect(page.getByLabel("Property reel",{exact:true})).toHaveValue(first);
  await expect(page.getByRole("region",{name:"Saved property video workspace",exact:true})).toBeVisible();
  await page.goto(`${origin}/tests/fixtures/connected.html?view=overview`);
  await expect(nav("Home")).toHaveAttribute("aria-current","page");
  await expect(page.getByRole("button",{name:"Create a video",exact:true})).toBeVisible();
  await expect(page.getByRole("region",{name:"Make something",exact:true})).toBeHidden();
  await page.locator(".app-all-tools>summary").click();
  await expect(page.getByRole("region",{name:"Make something",exact:true})).toBeVisible();
  await nav("AI tools").click();await expect(page.getByRole("region",{name:"Creative Studio",exact:true})).toBeVisible();
  receipt.checks.push("Legacy editor/property and Home URLs remain valid, and secondary AI tools plus the complete tool catalog remain accessible");

  await page.goto(`${origin}/tests/fixtures/connected.html?noProperties`);
  await expect(prompt()).toBeVisible();
  await page.evaluate(()=>localStorage.clear());await page.reload();await expect(prompt()).toBeVisible();
  for(const width of [1440,390]) {await page.setViewportSize({width,height:1000});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);await page.screenshot({path:join(artifacts,`create-${width}.png`),fullPage:true});}
  await page.locator(".secondary-navigation>summary").click();
  await expect(nav("Home")).toBeVisible();
  const menu=await page.locator(".secondary-navigation-menu").boundingBox(),bar=await page.locator(".sidebar").boundingBox();assert.ok(menu&&bar&&menu.y+menu.height<=bar.y+5);
  await nav("AI tools").click();await expect(page.getByRole("region",{name:"Creative Studio",exact:true})).toBeVisible();
  receipt.checks.push("The creation shell has no horizontal overflow at desktop and phone widths; the mobile More tools menu opens above its navigation bar");
  assert.deepEqual(receipt.errors,[]);assert.deepEqual(receipt.externalRequests,[]);receipt.status="passed";
}catch(error){receipt.status="failed";receipt.failure=String(error.stack??error);process.exitCode=1;await page?.screenshot({path:join(artifacts,"failure.png"),fullPage:true}).catch(()=>{});if(page)await writeFile(join(artifacts,"failure.txt"),await page.locator("body").innerText().catch(()=>""));}
finally{await browser?.close();if(server)await new Promise(done=>server.close(done));await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2));console.log(JSON.stringify({...receipt,artifacts},null,2));}
