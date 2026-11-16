import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,extname} from 'node:path';
import {createServer} from 'node:http';
import {build} from 'vite';
import {chromium,expect} from '@playwright/test';

const root=resolve(import.meta.dirname,'..'),artifacts=await mkdtemp(join(tmpdir(),'rendprop-finished-video-download-')),dist=join(artifacts,'dist');
const mp4=await readFile(resolve(root,'../ios/tests/fixtures/clip-frames-known-good.mp4'));
const actor='11111111-1111-4111-8111-111111111111',org='22222222-2222-4222-8222-222222222222',listing='44444444-4444-4444-8444-444444444444';
const asset='00000000-0000-4000-8000-000000000700',photo='00000000-0000-4000-8000-000000000001';
const job={job_id:'00000000-0000-4000-8000-000000000900',operation_id:'00000000-0000-4000-8000-000000000901',listing_id:listing,org_id:org,selected_library_org_id:org,source_count:1,manifest_sha256:'a'.repeat(64),state:'ready',completed_sources:1,consent_revision:'property-video-jobs-v1',quality_profile:'legacy',processor_consent:null,owner:actor,input:{purpose:'listing',aspect:'16:9',music:null,sources:[{photo_id:'photo-1',photo_asset_id:photo,photo_version_id:`asset:${photo}`,photo_provenance_id:null,motion:'push_in'}]},result:{asset_id:asset,poster_asset_id:'00000000-0000-4000-8000-000000000701',download_url:'',width:1920,height:1080,duration_s:2,bytes:mp4.length,sha256:'b'.repeat(64),branding_policy:'unbranded',sources:[{photo_asset_id:photo,photo_version_id:`asset:${photo}`,photo_provenance_id:null,generation_request_id:'fixture-paid-id',generation_provenance_id:'00000000-0000-4000-8000-000000000702',motion_kind:'ai'}],original_photo_count:0,music:null}};
const receipt={source:'actual MakeVideo component and Chrome browser; intercepted private-media bytes',live:false,checks:[]};
let server,browser,page;
try{
 await build({configFile:false,root,publicDir:false,logLevel:'error',build:{outDir:dist,rollupOptions:{input:join(root,'tests/make-video-fixture.html')}}});
 server=createServer(async(req,res)=>{const path=resolve(dist,`.${new URL(req.url,'http://localhost').pathname}`);if(!path.startsWith(`${dist}/`))return res.writeHead(400).end();try{res.setHeader('Content-Type',({'.html':'text/html','.js':'application/javascript','.css':'text/css'})[extname(path)]??'application/octet-stream');res.end(await readFile(path));}catch{res.writeHead(404).end();}});
 await new Promise(done=>server.listen(0,'127.0.0.1',done));const origin=`http://127.0.0.1:${server.address().port}`;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});const context=await browser.newContext({acceptDownloads:true,serviceWorkers:'block'});
 await context.addInitScript(({job})=>{localStorage.setItem('video-fixture-cloud',JSON.stringify({jobs:[job],calls:[],publications:[],audio:null}));}, {job});
 const mediaRequests=[];
 await context.route('**/*',async route=>{
  const url=new URL(route.request().url());if(url.origin===origin&&route.request().method()==='GET')return route.continue();
  if(url.origin==='https://rendprop.com'&&(/^\/private-media\/|^\/private-media-download\//).test(url.pathname)){
   const cap=JSON.parse(Buffer.from(url.pathname.split('/').at(-1).split('.')[0],'base64url'));
   const attachment=url.pathname.startsWith('/private-media-download/');
   if(cap.bucket==='renders'&&cap.key.endsWith(`/${asset}.mp4`)){
    mediaRequests.push({attachment,method:route.request().method()});
    return route.fulfill({status:200,headers:{'Content-Type':'video/mp4','Access-Control-Allow-Origin':origin,...(attachment?{'Content-Disposition':'attachment; filename="Rendprop-listing-video.mp4"'}:{})},body:mp4});
   }
   if(!attachment)return route.fulfill({status:200,contentType:'image/svg+xml',headers:{'Access-Control-Allow-Origin':origin},body:'<svg xmlns="http://www.w3.org/2000/svg" width="400" height="250"/>'});
  }
  throw Error(`Unexpected external request: ${url.href}`);
 });
 page=await context.newPage();page.setDefaultTimeout(15000);await page.goto(`${origin}/tests/make-video-fixture.html`);
 await page.getByText('Saved videos for this property (1)',{exact:true}).click();
 await expect(page.getByRole('button',{name:'Open video',exact:true})).toBeVisible();await page.getByRole('button',{name:'Open video',exact:true}).click();
 const player=page.locator('video');await expect(player).toHaveAttribute('controls','');await expect(player).toHaveAttribute('preload','metadata');
 const inline=await player.getAttribute('src');assert.match(inline,/^https:\/\/rendprop\.com\/private-media\//);
 await expect.poll(()=>player.evaluate(v=>v.readyState)).toBeGreaterThanOrEqual(2);
 assert.equal(await player.evaluate(v=>v.videoWidth>0&&v.videoHeight>0),true,'Chrome decoded the inline MP4');
 await player.evaluate(async v=>{await v.play();await new Promise((resolve,reject)=>{const deadline=setTimeout(()=>reject(Error('Inline video did not advance')),4000);const timer=setInterval(()=>{if(v.currentTime>0.05){clearTimeout(deadline);clearInterval(timer);v.pause();resolve();}},25);});});
 receipt.checks.push('Inline signed URL still decodes and plays its MP4 in Chrome');
 const link=page.getByRole('link',{name:'Download finished video'}),attachment=await link.getAttribute('href');
 assert.equal(attachment,inline.replace('/private-media/','/private-media-download/'));
 const [download]=await Promise.all([page.waitForEvent('download'),link.click()]);
 assert.equal(download.suggestedFilename(),'Rendprop-listing-video.mp4');const saved=join(artifacts,'downloaded.mp4');await download.saveAs(saved);assert.deepEqual(await readFile(saved),mp4);
 assert.equal(page.url(),`${origin}/tests/make-video-fixture.html`);assert.equal(await player.getAttribute('src'),inline);
 assert(mediaRequests.some(row=>!row.attachment));assert(mediaRequests.some(row=>row.attachment));
 receipt.checks.push('Chrome download event saves exact MP4 bytes with an .mp4 filename; page and inline playback URL remain intact');
 receipt.status='passed';receipt.mediaRequests=mediaRequests;
}catch(error){receipt.status='failed';receipt.failure=error.stack;process.exitCode=1;await page?.screenshot({path:join(artifacts,'failure.png'),fullPage:true}).catch(()=>{});}finally{await browser?.close();if(server)await new Promise(done=>server.close(done));await writeFile(join(artifacts,'receipt.json'),JSON.stringify({...receipt,artifacts},null,2));console.log(JSON.stringify({...receipt,artifacts},null,2));}
