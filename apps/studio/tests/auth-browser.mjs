import assert from "node:assert/strict";
import {mkdtemp,readFile,writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join,resolve,extname} from "node:path";
import {createServer} from "node:http";
import {build} from "vite";
import {chromium,expect} from "@playwright/test";
const root=resolve(import.meta.dirname,".."),artifacts=await mkdtemp(join(tmpdir(),"rendprop-auth-sdk-")),dist=join(artifacts,"dist");
const receipt={checks:[],errors:[],unexpectedRequests:[],proof:"Official Auth SDK and browser storage; all identity API responses synthetic. No Apple or live Supabase call."};
const actor="11111111-1111-4111-8111-111111111111",storageKey="rendprop-studio-auth:auth-fixture.supabase.co",authOrigin="https://auth-fixture.supabase.co";
let server,browser,page;
try{
  await build({configFile:false,root,publicDir:false,logLevel:"error",build:{outDir:dist,rollupOptions:{input:join(root,"tests/auth-fixture.html")}}});
  server=createServer(async(req,res)=>{const path=resolve(dist,"."+new URL(req.url,"http://localhost").pathname);if(!path.startsWith(dist+"/")||req.method!=="GET")return res.writeHead(400).end();try{res.setHeader("Content-Type",({".html":"text/html",".js":"application/javascript"})[extname(path)]??"application/octet-stream");res.end(await readFile(path));}catch{res.writeHead(404).end();}});
  await new Promise(done=>server.listen(0,"127.0.0.1",done));const origin=`http://127.0.0.1:${server.address().port}`;
  browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
  const context=await browser.newContext({serviceWorkers:"block"});const calls=[];
  const expires_at=Math.floor(Date.now()/1000)+3600,part=data=>Buffer.from(JSON.stringify(data)).toString("base64url");
  const session={access_token:`${part({alg:"HS256",typ:"JWT"})}.${part({sub:actor,exp:expires_at})}.fixture`,refresh_token:"fixture-refresh",expires_at,expires_in:3600,token_type:"bearer",user:{id:actor,aud:"authenticated",email:"fixture@example.invalid",app_metadata:{},user_metadata:{},created_at:"2026-09-24T00:00:00Z"}};
  await context.route("**/*",async route=>{
    const request=route.request(),url=new URL(request.url());if(url.origin===origin&&request.method()==="GET")return route.continue();
    if(url.origin===authOrigin){calls.push({path:url.pathname,query:url.search,method:request.method()});
      if(url.pathname==="/auth/v1/token"&&request.method()==="POST"&&url.searchParams.get("grant_type")==="pkce"){
        assert.deepEqual(request.postDataJSON(),{auth_code:"fixture-code",code_verifier:"a".repeat(64)});
        return route.fulfill({status:200,contentType:"application/json",body:JSON.stringify(session)});
      }
      if(url.pathname==="/auth/v1/logout"&&request.method()==="POST"&&url.searchParams.get("scope")==="local")return route.fulfill({status:204,body:""});
    }
    receipt.unexpectedRequests.push(request.url());return route.abort();
  });
  page=await context.newPage();page.on("pageerror",e=>receipt.errors.push(e.message));
  await page.goto(`${origin}/tests/auth-fixture.html`);await expect(page.locator("#state")).toHaveText("Signed out");
  await page.evaluate(({key})=>localStorage.setItem(`${key}-code-verifier`,JSON.stringify("a".repeat(64))),{key:storageKey});
  await page.goto(`${origin}/tests/auth-fixture.html?code=fixture-code`);await expect(page.locator("#state")).toHaveText(actor);
  assert.equal(new URL(page.url()).searchParams.has("code"),false);
  assert.equal(await page.evaluate(key=>localStorage.getItem(`${key}-code-verifier`),storageKey),null);
  receipt.checks.push("Browser callback automatically exchanges PKCE code and removes callback/verifier without contacting Apple");
  const second=await context.newPage();second.on("pageerror",e=>receipt.errors.push(e.message));await second.goto(`${origin}/tests/auth-fixture.html`);
  await expect(second.locator("#state")).toHaveText(actor);await page.reload();await expect(page.locator("#state")).toHaveText(actor);
  assert.equal(calls.filter(c=>c.path.endsWith("/token")).length,1);receipt.checks.push("Existing Studio session persists across reload and a second tab with no second token exchange");
  await page.getByRole("button",{name:"Sign out this browser"}).click();await expect(page.locator("#state")).toHaveText("Signed out");await expect(second.locator("#state")).toHaveText("Signed out");
  assert.equal(calls.filter(c=>c.path.endsWith("/logout")&&c.query==="?scope=local").length,1);receipt.checks.push("Local logout clears both browser tabs and requests local scope, preserving other device sessions");
  assert.deepEqual(receipt.errors,[]);assert.deepEqual(receipt.unexpectedRequests,[]);receipt.status="passed";
}catch(error){receipt.status="failed";receipt.failure=String(error.stack??error);process.exitCode=1;await page?.screenshot({path:join(artifacts,"failure.png"),fullPage:true}).catch(()=>{});}
finally{await browser?.close();if(server)await new Promise(done=>server.close(done));await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2));console.log(JSON.stringify({...receipt,artifacts},null,2));}
