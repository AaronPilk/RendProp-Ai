import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,extname} from 'node:path';
import {createServer} from 'node:http';
import {build} from 'vite';
import {chromium,expect} from '@playwright/test';
// Regression: a status reply for the previously shown job must not replace the saved video the
// agent explicitly opened (status, cancel and resume stay bound to the job on screen).
const root=resolve(import.meta.dirname,'..'),artifacts=await mkdtemp(join(tmpdir(),'rendprop-make-video-status-')),dist=join(artifacts,'dist');
const receipt={proof:'Actual MakeVideo component over isolated job API; held status reply for job B while job A is opened; no paid generation, provider or account calls',checks:[],errors:[],externalRequests:[]};let server,browser,page;
try{
 await build({configFile:false,root,publicDir:false,logLevel:'error',build:{outDir:dist,rollupOptions:{input:join(root,'tests/make-video-fixture.html')}}});
 server=createServer(async(req,res)=>{const path=resolve(dist,`.${new URL(req.url,'http://localhost').pathname}`);if(!path.startsWith(`${dist}/`))return res.writeHead(400).end();try{res.setHeader('Content-Type',({'.html':'text/html','.js':'application/javascript','.css':'text/css'})[extname(path)]??'application/octet-stream');res.end(await readFile(path));}catch{res.writeHead(404).end();}});await new Promise(done=>server.listen(0,'127.0.0.1',done));const origin=`http://127.0.0.1:${server.address().port}`;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});const context=await browser.newContext({viewport:{width:1280,height:1000},serviceWorkers:'block'});
 await context.route('**/*',route=>{const url=new URL(route.request().url());if(url.origin===origin&&route.request().method()==='GET')return route.continue();if(url.origin==='https://rendprop.com'&&url.pathname.startsWith('/private-media/'))return route.fulfill({status:200,contentType:'image/svg+xml',body:'<svg xmlns="http://www.w3.org/2000/svg" width="400" height="225"><rect width="400" height="225" fill="#cab8e2"/></svg>'});receipt.externalRequests.push(url.href);return route.abort();});
 page=await context.newPage();page.setDefaultTimeout(15000);page.on('pageerror',error=>receipt.errors.push(error.message));await page.goto(`${origin}/tests/make-video-fixture.html`);
 const snapshot=()=>page.evaluate(()=>window.videoFixture.snapshot()),region=()=>page.getByRole('region',{name:'Current property video'}),consent=()=>page.getByRole('checkbox',{name:/I allow AI processing/});
 const create=async photos=>{await page.getByRole('button',{name:'Clear selection',exact:true}).click();for(const n of photos)await page.getByRole('checkbox',{name:`Choose photo ${n}`,exact:true}).check();await consent().check();await page.getByRole('button',{name:'Create video',exact:true}).click();await expect(region()).toContainText('queued');};
 await create([2,4]);const first=(await snapshot()).jobs.at(-1);
 await page.evaluate(()=>window.videoFixture.ready());await page.getByRole('button',{name:'Refresh videos',exact:true}).click();await expect(region()).toContainText('1920×1080');
 await create([5,6]);const second=(await snapshot()).jobs.at(-1);assert.notEqual(second.job_id,first.job_id);
 receipt.checks.push('Job A is ready and job B is creating for the same property');
 await page.evaluate(()=>window.videoFixture.holdJobStatus());
 await page.evaluate(()=>document.dispatchEvent(new Event('visibilitychange')));
 await expect.poll(()=>page.evaluate(()=>window.videoFixture.held())).toBe(1);
 await page.getByText(/^Saved videos for this property/).click();
 await page.getByRole('listitem').filter({hasText:'ready · 2 photos'}).getByRole('button',{name:'Open video',exact:true}).click();
 await expect(region()).toContainText('1920×1080');await expect(page.getByRole('heading',{name:'Your finished video',exact:true})).toBeVisible();
 const statusCalls=async()=>(await snapshot()).calls.filter(call=>call.method==='GET'&&call.path.endsWith(`/property-video-jobs/${second.job_id}`)).length;const before=await statusCalls();
 await page.evaluate(()=>window.videoFixture.release());await expect.poll(()=>page.evaluate(()=>window.videoFixture.held())).toBe(0);
 await page.waitForTimeout(750);assert.ok(before>=1);
 await expect(region()).toContainText('1920×1080');await expect(page.getByRole('heading',{name:'Your finished video',exact:true})).toBeVisible();await expect(page.getByRole('button',{name:'Cancel video',exact:true})).toHaveCount(0);
 const state=await snapshot();assert.equal(state.jobs.find(job=>job.job_id===second.job_id).state,'queued');assert.equal(state.calls.filter(call=>call.method==='POST'&&call.path.endsWith('/property-video-jobs')).length,2);assert.equal(state.publications.length,0);
 receipt.checks.push('A late status reply for job B is ignored after job A is explicitly opened; B keeps creating on the server, no cancel/publish or duplicate dispatch');
 assert.deepEqual(receipt.errors,[]);assert.deepEqual(receipt.externalRequests,[]);receipt.status='passed';
}catch(error){receipt.status='failed';receipt.failure=error.stack;receipt.visibleText=await page?.locator('body').innerText().catch(()=>'');process.exitCode=1;await page?.screenshot({path:join(artifacts,'failure.png'),fullPage:true}).catch(()=>{});}finally{await browser?.close();if(server)await new Promise(done=>server.close(done));await writeFile(join(artifacts,'receipt.json'),JSON.stringify({...receipt,artifacts},null,2));console.log(JSON.stringify({...receipt,artifacts},null,2));}
