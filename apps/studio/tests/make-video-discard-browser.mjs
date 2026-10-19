import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,extname} from 'node:path';
import {createServer} from 'node:http';
import {build} from 'vite';
import {chromium,expect} from '@playwright/test';
// C2: an agent discards a saved video request the server never accepted, then
// changes photos/options. Actual MakeVideo + property-video client; the closed
// fixture mirrors the server contract. Each --fault compiles a real defect into
// the runtime source and must make this scenario fail.
const FAULTS={
 'client-only-discard':['/src/features/sync/property-video.ts','const raw=object(await services.api(`/functions/v1/property-video-jobs/operations/${operation}/abandon`',"const raw=object(await Promise.resolve({operation_id:operation,listing_id:scope.listing,selected_library_org_id:scope.library,operation_closed:true,closed_reason:'abandoned',job:null})??services.api(`/functions/v1/property-video-jobs/operations/${operation}/abandon`"],
 'forget-after-lost-reply':['/src/features/sync/MakeVideo.tsx','const outcome=await abandonVideoOperation(services,scope,journal,control.current.signal);current();',"const outcome=await abandonVideoOperation(services,scope,journal,control.current.signal).catch(()=>({job:null,closed:true,reason:'abandoned' as const}));current();"],
 'discard-hides-accepted-job':['/src/features/sync/MakeVideo.tsx','if(outcome.job){updateJournal({...journal,job_id:outcome.job.job_id});','if(outcome.job&&false){updateJournal({...journal,job_id:outcome.job.job_id});'],
};
const fault=process.argv.find(value=>value.startsWith('--fault='))?.slice(8);
if(fault&&!FAULTS[fault])throw Error('Unknown closed discard control');
let faultApplied=false;
const root=resolve(import.meta.dirname,'..'),artifacts=await mkdtemp(join(tmpdir(),'rendprop-make-video-discard-')),dist=join(artifacts,'dist');
const receipt={fault:fault??null,proof:'Actual MakeVideo/property-video discard flow, scoped persistence and recovery; isolated API mirrors the C2 server contract; no paid generation, real account or provider call',checks:[],errors:[],externalRequests:[],dialogs:[]};let server,browser,page;
try{
 await build({configFile:false,root,publicDir:false,logLevel:'error',plugins:[{name:'closed-discard-control',enforce:'pre',transform(code,id){if(!fault)return;const[file,before,after]=FAULTS[fault];if(!id.endsWith(file))return;assert.equal(code.split(before).length-1,1,'Exact compiled control anchor');faultApplied=true;return code.replace(before,after);}}],build:{outDir:dist,rollupOptions:{input:join(root,'tests/make-video-discard-fixture.html')}}});
 if(fault)assert.equal(faultApplied,true,'Control must compile the actual runtime source');
 server=createServer(async(req,res)=>{const path=resolve(dist,`.${new URL(req.url,'http://localhost').pathname}`);if(!path.startsWith(`${dist}/`))return res.writeHead(400).end();try{res.setHeader('Content-Type',({'.html':'text/html','.js':'application/javascript','.css':'text/css'})[extname(path)]??'application/octet-stream');res.end(await readFile(path));}catch{res.writeHead(404).end();}});await new Promise(done=>server.listen(0,'127.0.0.1',done));const origin=`http://127.0.0.1:${server.address().port}`;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});const context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});
 await context.route('**/*',route=>{const url=new URL(route.request().url());if(url.origin===origin&&route.request().method()==='GET')return route.continue();if(url.origin==='https://rendprop.com'&&url.pathname.startsWith('/private-media/'))return route.fulfill({status:200,contentType:'image/svg+xml',body:'<svg xmlns="http://www.w3.org/2000/svg" width="400" height="225"><rect width="400" height="225" fill="#cab8e2"/></svg>'});receipt.externalRequests.push(url.href);return route.abort();});
 page=await context.newPage();page.setDefaultTimeout(15000);page.on('pageerror',error=>receipt.errors.push(error.message));page.on('dialog',dialog=>{receipt.dialogs.push(dialog.message());void dialog.accept();});
 await page.goto(`${origin}/tests/make-video-discard-fixture.html`);
 const snapshot=()=>page.evaluate(()=>window.videoFixture.snapshot());const button=name=>page.getByRole('button',{name,exact:true});
 const photo=n=>page.getByRole('checkbox',{name:`Choose photo ${n}`,exact:true});const consent=()=>page.getByRole('checkbox',{name:/I allow AI processing/});
 const posts=(state,op)=>state.calls.filter(c=>c.method==='POST'&&c.path.endsWith('/property-video-jobs')&&(!op||c.body.operation_id===op));
 const discards=(state,op)=>state.calls.filter(c=>c.method==='POST'&&c.path.endsWith(`/operations/${op}/abandon`));
 const mainJournal=()=>page.evaluate(()=>{const entry=Object.entries(localStorage).find(([key])=>key.startsWith('rendprop-video-v1:')&&key.split(':').length===4);return entry?JSON.parse(entry[1]):null;});
 const discarded=()=>page.getByText('This saved request is discarded.',{exact:false});

 // 0. A request stuck in photo preparation never reaches the video POST; discard is the way out.
 await expect(photo(101)).toBeVisible();await photo(1).check();await photo(2).check();await consent().check();
 await page.evaluate(()=>window.videoFixture.refusePreparation(true));await button('Create video').click();
 await expect(page.getByRole('alert')).toContainText('cannot be prepared for video');
 let state=await snapshot();const stuck=(await mainJournal()).input.operation_id;assert.equal(posts(state).length,0,'no video request is sent while preparation is stuck');
 await page.reload();await expect(button('Discard saved request')).toBeVisible();await consent().check();await button('Resume same saved request').click();
 await expect(page.getByRole('alert')).toContainText('cannot be prepared for video');assert.equal((await snapshot()).refusedPreparations,2,'resume retried the same stuck preparation');
 // Another account never sees or discards this account's saved request.
 await page.evaluate(()=>window.videoFixture.switchAccount());await expect(button('Discard saved request')).toHaveCount(0);await expect(button('Create video')).toBeVisible();
 await page.evaluate(()=>window.videoFixture.switchAccount());await expect(button('Discard saved request')).toBeVisible();
 await button('Discard saved request').click();await expect(discarded()).toBeVisible();await expect(photo(5)).toBeEnabled();
 state=await snapshot();assert.ok(state.abandoned[stuck],'the server recorded the discard');assert.equal(posts(state,stuck).length,0);
 await page.evaluate(()=>window.videoFixture.refusePreparation(false));await button('Clear selection').click();
 receipt.checks.push('Request stuck in photo preparation: resume retries the same preparation, another account cannot see it, discard closes it on the server with no video request ever sent');

 // 1. A request is saved (one photo prepared for video), then its POST fails before the server accepts it.
 await photo(4).check();await photo(2).check();await photo(1).check();await consent().check();
 await page.evaluate(()=>window.videoFixture.failNextSubmit());await button('Create video').click();
 // The prepared 3:2 copy trims for 16:9, so the saved request first asks for a framing review (no AI video yet).
 await expect(page.getByRole('region',{name:'Review final framing'})).toBeVisible();assert.equal(posts(await snapshot()).length,0);
 await page.getByRole('checkbox',{name:'Keep this framing'}).check();await button('Resume same saved request').click();
 await expect(page.getByRole('alert')).toContainText('network failure before the server accepted');
 state=await snapshot();assert.equal(state.jobs.length,0);assert.equal(posts(state).length,1);
 const op=posts(state)[0].body.operation_id;assert.deepEqual(posts(state)[0].body.sources.map(s=>s.photo_id),['photo-4','photo-2','photo-1'],'manual selection order is the request order');
 const prepared=JSON.stringify(state.preparations);assert.equal(Object.keys(state.preparations).length,1,'photo 1 was prepared for video');
 await page.reload();await expect(button('Resume same saved request')).toBeVisible();await expect(button('Discard saved request')).toBeVisible();
 await expect(page.getByText('Your saved request was not found on the server.',{exact:false})).toBeVisible();await expect(photo(5)).toBeDisabled();
 receipt.checks.push('Unaccepted saved request stays fenced after reload: same request can resume, recover or be discarded; photos are locked');

 // 2. The agent saves a new version of a selected photo: resume refuses, the request is stuck without C2.
 const edited='00000000-0000-4000-8000-000000000504';await page.evaluate(asset=>window.videoFixture.editPhoto('photo-4',asset),edited);await page.reload();
 await expect(button('Resume same saved request')).toBeVisible();await consent().check();await button('Resume same saved request').click();
 await expect(page.getByRole('alert')).toContainText('earlier photo versions');await expect(page.getByRole('alert')).toContainText('discard the request');
 assert.equal(posts(await snapshot(),op).length,1,'resume never re-sends a request whose photo versions changed');
 receipt.checks.push('Changed photo version: resume refuses locally and points to discard; no request is re-sent');

 // 3. Discard with a lost reply: the server tombstoned it, but Studio keeps the request pending until confirmed.
 await page.evaluate(()=>window.videoFixture.loseNextDiscard());await button('Discard saved request').click();
 await expect(page.getByRole('alert')).toContainText('lost discard response');
 state=await snapshot();assert.ok(state.abandoned[op],'server recorded the discard');assert.equal(discards(state,op).length,1);
 await expect(button('Discard saved request')).toBeVisible();await expect(photo(5)).toBeDisabled();assert.equal((await mainJournal()).input.operation_id,op);
 receipt.checks.push('Lost discard reply never forgets locally: request stays pending and photos stay locked');

 // 4. Retrying (with a duplicate tap) resolves the same operation once; only then is the recipe unlocked and archived.
 await button('Discard saved request').dblclick();await expect(discarded()).toBeVisible();
 await expect(button('Discard saved request')).toHaveCount(0);await expect(button('Create video')).toBeVisible();await expect(photo(5)).toBeEnabled();
 state=await snapshot();assert.equal(discards(state,op).length,2,'a duplicate tap sends one discard');assert.ok(discards(state,op).every(c=>c.key===`property-video-abandon:${op}`&&c.consent===undefined&&c.body.listing_id&&c.body.expected_org_id),'discard carries the saved identity, never AI consent');
 assert.equal(await page.evaluate(id=>Object.keys(localStorage).filter(key=>key.endsWith(`:abandoned:${id}`)).length,op),1,'discarded recipe archived');
 assert.equal(JSON.stringify(state.preparations),prepared,'discard never erases the prepared source photo');
 assert.ok(receipt.dialogs.length>=3);assert.match(receipt.dialogs[0],/If it was already accepted, that video is kept/);
 await page.reload();await expect(discarded()).toBeVisible();await expect(photo(5)).toBeEnabled();await expect(button('Discard saved request')).toHaveCount(0);
 receipt.checks.push('Retried discard replays the server closure; reload re-confirms it from the server and keeps photos/options unlocked');

 // 5. New photos, new order and new options start a new operation; the discarded one never starts.
 await button('Clear selection').click();await photo(5).check();await photo(4).check();
 await page.getByText('Voice and music (optional)',{exact:true}).click();await page.getByLabel('Music',{exact:true}).selectOption('calm');
 await consent().check();await button('Create video').click();await expect(page.getByRole('region',{name:'Current property video'})).toContainText('queued');
 state=await snapshot();assert.equal(state.jobs.length,1);const job=state.jobs[0];assert.notEqual(job.operation_id,op);
 assert.deepEqual(job.input.sources.map(s=>s.photo_id),['photo-5','photo-4']);assert.equal(job.input.sources[1].photo_version_id,`asset:${edited}`);assert.equal(job.input.music.track_id,'calm');
 assert.equal(posts(state,op).length,1,'discarded operation was never sent again');assert.equal(state.jobs.filter(item=>item.operation_id===op).length,0);
 receipt.checks.push('After discard: changed photos, chosen order, saved new version and new music create one new operation; discarded operation never re-sent');

 // 6. Discarded elsewhere: GET-first resume resolves the exact closure before another paid POST.
 await page.evaluate(()=>window.videoFixture.ready());await button('Refresh videos').click();await expect(page.getByRole('region',{name:'Current property video'})).toContainText('1920×1080');
 await button('Clear selection').click();await photo(6).check();await consent().check();
 await page.evaluate(()=>window.videoFixture.failNextSubmit());await button('Create video').click();await expect(page.getByRole('alert')).toContainText('network failure');
 state=await snapshot();const op2=posts(state).at(-1).body.operation_id;assert.notEqual(op2,op);
 await page.evaluate(id=>window.videoFixture.discardElsewhere(id),op2);await button('Resume same saved request').click();
 await expect(discarded()).toBeVisible();await expect(button('Create video')).toBeVisible();
 state=await snapshot();assert.equal(state.jobs.filter(item=>item.operation_id===op2).length,0);assert.equal(posts(state,op2).length,1,'GET-first recovery discovers the exact abandoned operation before a second paid POST');assert.ok(state.calls.some(c=>c.method==='GET'&&c.query.includes(`operation_id=${op2}`)));
 receipt.checks.push('Stale tab resume of a request discarded elsewhere: exact operation GET resolves the closure before another POST, no job, recipe unlocked');

 // 7. A delayed POST that the server accepted just before the discard: the job is kept, shown and cancellable normally.
 await button('Clear selection').click();await photo(7).check();await consent().check();
 await page.evaluate(()=>window.videoFixture.failNextSubmit());await button('Create video').click();await expect(page.getByRole('alert')).toContainText('network failure');
 state=await snapshot();const op3=posts(state).at(-1).body.operation_id;
 await page.evaluate(()=>window.videoFixture.acceptOnNextDiscard());await button('Discard saved request').click();
 await expect(page.getByText('already accepted this request, so its video was kept',{exact:false})).toBeVisible();
 await expect(page.getByRole('region',{name:'Current property video'})).toContainText('queued');await expect(button('Cancel video')).toBeVisible();
 state=await snapshot();const kept=state.jobs.find(item=>item.operation_id===op3);assert.ok(kept);assert.equal(kept.state,'queued');assert.equal(state.abandoned[op3],undefined);
 assert.equal((await mainJournal()).job_id,kept.job_id);
 await button('Cancel video').click();await expect(page.getByRole('region',{name:'Current property video'})).toContainText('cancelled');
 receipt.checks.push('Accepted-before-discard: existing job retained and adopted, never tombstoned; normal Cancel video still stops it');

 await page.setViewportSize({width:390,height:844});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+2));await page.screenshot({path:join(artifacts,'make-video-discard-mobile.png'),fullPage:true});
 assert.deepEqual(receipt.errors,[]);assert.deepEqual(receipt.externalRequests,[]);receipt.status='passed';
}catch(error){receipt.status='failed';receipt.failure=error.stack;receipt.visibleText=await page?.locator('body').innerText().catch(()=>'');process.exitCode=1;await page?.screenshot({path:join(artifacts,'failure.png'),fullPage:true}).catch(()=>{});}finally{await browser?.close();if(server)await new Promise(done=>server.close(done));await writeFile(join(artifacts,'receipt.json'),JSON.stringify({...receipt,artifacts},null,2));console.log(JSON.stringify({...receipt,artifacts},null,2));}
