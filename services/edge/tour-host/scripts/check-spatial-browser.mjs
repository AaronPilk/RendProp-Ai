// Test-controlled, isolated headless browser. Not the owner's phone or real room.
import assert from 'node:assert/strict';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { checkSpatialBrowser } from './build-spatial-browser.mjs';
import { sha, sourceSnapshot, deadline } from './spatial-built-fixture.mjs';
assert(process.argv.length===3||(process.argv.length===4&&process.argv[3]==='--negative-control'),'Provide Playwright module path and optional --negative-control');
const ROOT=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const inputs=sourceSnapshot(ROOT),canonical=await checkSpatialBrowser({root:ROOT});
const evidence=mkdtempSync(join(tmpdir(),'rendprop-spatial-browser-'));
const receipt={status:'running',evidence,inputs,browser_sha256:canonical.metadata.browser_sha256,
  scope:'Actual emitted Worker/browser, synthetic converted SOG and test-pattern MP4 in Chromium. No phone, captured-room quality or live backend proof.'};
let artifactAssertions=0;
const artifactCheck=(value,message)=>{artifactAssertions++;assert.ok(value,message);};
const proofResponse=await fetch('http://127.0.0.1:8794/__spatial-proof',{signal:AbortSignal.timeout(15000)});
const proof=await proofResponse.json();
artifactCheck(proofResponse.ok&&proof.synthetic===true&&proof.kind==='actual-emitted-worker-synthetic-preview','Actual emitted synthetic preview required');
artifactCheck(proof.browser_sha256===canonical.metadata.browser_sha256,'Preview is bound to current canonical browser bytes');
artifactCheck(JSON.stringify(proof.inputs)===JSON.stringify(inputs),'Preview source inventory matches current source');
receipt.preview=proof;
const engineResponse=await fetch('http://127.0.0.1:8794/vendor/playcanvas.min.js',{signal:AbortSignal.timeout(15000)});
const engine=Buffer.from(await engineResponse.arrayBuffer());
artifactCheck(engineResponse.ok&&engine.length<8*1024*1024&&createHash('sha384').update(engine).digest('base64')==='2sYsYZfrbYhDV41s7X2ecMMRNZ8xTYBbSZcu3t9x0fpAFoqDtCQVeQtiq+mx0Fwz','Engine fixture has exact pinned SRI bytes');
const { chromium } = await import(pathToFileURL(process.argv[2]).href);
const browser = await chromium.launch({headless:true});
const base='http://127.0.0.1:8794', scene=base+'/s/11111111-1111-4111-8111-111111111111';
let assertions=0;
const check=(value,message)=>{assertions++;assert.ok(value,message);};
const page=await browser.newPage({viewport:{width:390,height:844}});
page.setDefaultTimeout(15000);
const errors=[];page.on('pageerror',error=>errors.push(error.message));
const unexpectedNetwork=[],moduleHashes=[],mutantHashes=[];
let syntheticBeacons=0;
await page.route('**/*',async route=>{
  const url=new URL(route.request().url());
  if(url.href==='https://cdn.jsdelivr.net/npm/playcanvas@2.22.1/build/playcanvas.min.js'){
    assert.equal(route.request().headers().authorization,undefined,'Renderer request must not carry private viewer authorization');
    await route.fulfill({status:200,body:engine,headers:{'Content-Type':'text/javascript','Access-Control-Allow-Origin':'*'}});return;
  }
  // The actual tour player meters decoded video. Fulfill only this explicit
  // synthetic endpoint, not an entire origin that could hide other requests.
  if(url.href==='https://spatial-preview.invalid/functions/v1/beacon/synthetic-tour'){
    assert.equal(route.request().method(),'POST','Synthetic beacon method');
    assert.equal(route.request().headers().authorization,undefined,'No viewer capability in a video beacon');
    const body=route.request().postData()||'';
    assert(Buffer.byteLength(body)<=1024,'Synthetic beacon body bound');
    const meter=JSON.parse(body);
    assert(Object.keys(meter).every(key=>['watch_ms','scroll_depth','streamed_minutes','unbranded','view_start'].includes(key)),'Only expected synthetic metering fields');
    assert(Number.isFinite(meter.watch_ms)&&meter.watch_ms>=0&&Number.isFinite(meter.scroll_depth)&&meter.scroll_depth>=0&&meter.scroll_depth<=1&&Number.isFinite(meter.streamed_minutes)&&meter.streamed_minutes>=0&&meter.streamed_minutes<=1&&meter.unbranded===true,'Synthetic metering values');
    syntheticBeacons++;
    await route.fulfill({status:204,headers:{'Access-Control-Allow-Origin':base,'Access-Control-Allow-Credentials':'true'}});return;
  }
  if(url.origin===base||url.protocol==='blob:'||url.protocol==='data:'){await route.continue();return;}
  unexpectedNetwork.push(url.origin);await route.abort('blockedbyclient');
});
await page.route('**/spatial-viewer.js',async route=>{
  const response=await route.fetch(),bytes=await response.body();
  assert.equal(sha(bytes),canonical.metadata.browser_sha256,'Only current emitted module bytes may execute');
  moduleHashes.push(sha(bytes));
  let body=bytes;
  if(process.argv.includes('--negative-control')){
    // Mutation is explicitly source-bound, but independent of minified local
    // variable names. A native-ready claim at module import must always fail.
    body=Buffer.concat([Buffer.from("window.webkit.messageHandlers.spatialViewer.postMessage({type:'spatial-ready',scene_id:'11111111-1111-4111-8111-111111111111',artifact_revision:'premature'});\n"),bytes]);
    mutantHashes.push(sha(body));
  }
  await route.fulfill({response,body});
});
await page.addInitScript(()=>{
  window.__spatialDraws=0;
  window.__nativeSpatial=[];
  window.webkit={messageHandlers:{spatialViewer:{postMessage(message){window.__nativeSpatial.push({message,draws:window.__spatialDraws});}}}};
  for(const name of ['drawArraysInstanced','drawElementsInstanced']) {
    const original=WebGL2RenderingContext.prototype[name];
    WebGL2RenderingContext.prototype[name]=function(...args){
      const count=name==='drawArraysInstanced'?args[2]:args[1];
      const instances=name==='drawArraysInstanced'?args[3]:args[4];
      const canvasDraw=this.getParameter(this.DRAW_FRAMEBUFFER_BINDING)===null;
      const result=original.apply(this,args);
      if(canvasDraw&&count>0&&instances>0&&!this.isContextLost())window.__spatialDraws++;
      return result;
    };
  }
});
const position=()=>page.evaluate(()=>window.pc.Application.getApplication().root.findByName('spatial-camera').getPosition().toArray());
const enter=async()=>{await page.goto(scene);await page.getByRole('status').filter({hasText:'Reviewed room.'}).waitFor();};
let releaseModel=()=>{};
try {
  let sawModel;
  const holdModel=new Promise(resolve=>{releaseModel=resolve}), requestedModel=new Promise(resolve=>{sawModel=resolve});
  await page.route('**/model?*',async(route)=>{sawModel();await holdModel;await route.continue();});
  await page.goto(scene);await deadline(requestedModel,10000);
  check(await page.evaluate(()=>window.__nativeSpatial.length===0),'no native ready message before model transfer');
  releaseModel();await page.getByRole('status').filter({hasText:'Reviewed room.'}).waitFor();
  await page.unroute('**/model?*');await page.waitForFunction(()=>window.__spatialDraws>0);
  const native=await page.evaluate(()=>window.__nativeSpatial);
  check(native.length===1 && native[0].draws>0,'native ready emitted once after actual nonempty frame');
  check(native[0].message.type==='spatial-ready' && native[0].message.scene_id==='11111111-1111-4111-8111-111111111111' && native[0].message.artifact_revision==='22222222-2222-4222-8222-222222222222','native ready binds exact rendered identity');
  check((await page.getByRole('status').innerText()).includes('SYNTHETIC TEST'), 'synthetic fixture labelled');
  check(await page.evaluate(()=>window.__spatialDraws>0), 'nonempty instanced draw to actual framebuffer');
  check(await page.getByRole('dialog',{name:'3D room viewer'}).count()===1,'viewer exposes modal semantics');
  check(await page.evaluate(()=>document.activeElement?.textContent==='Close 3D'),'initial focus is a working exit');
  for(const width of [320,390,768,1440]) {
    await page.setViewportSize({width,height:844});
    check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'no horizontal overflow at '+width);
    for(const label of ['Close 3D','Starting view','Top-down','Forward','Back','Left','Right']) {
      const box=await page.getByRole('button',{name:label,exact:true}).boundingBox();
      check(box && box.width>=44 && box.height>=44 && box.x>=0 && box.x+box.width<=width,'visible44px '+label+' at '+width);
    }
  }
  await page.setViewportSize({width:390,height:844});
  const start=await position();await page.keyboard.down('w');await page.waitForTimeout(250);await page.keyboard.up('w');
  const walked=await position();check(walked[2]<start[2]-.05 && walked[1]===start[1], 'keyboard walks while floor height stays fixed');
  const pad=await page.locator('.spatial-pad').boundingBox();
  await page.mouse.move(pad.x+pad.width/2,pad.y+pad.height/2);await page.mouse.down();await page.mouse.move(pad.x+pad.width-3,pad.y+pad.height/2);await page.waitForTimeout(250);await page.mouse.up();
  const joystick=await position();check(joystick[0]>walked[0]+.05 && joystick[1]===start[1], 'joystick walks and stays floor locked');
  await page.waitForTimeout(160);const released=await position();check(Math.abs(released[0]-joystick[0])<.001,'joystick stops after release');
  await page.getByRole('button',{name:'Synthetic test',exact:true}).click();const anchored=await position();
  check(Math.abs(anchored[0]-1)<.00001 && Math.abs(anchored[2]-3)<.00001,'room anchor positions camera');
  await page.getByRole('button',{name:'Top-down',exact:true}).click();check((await position())[1]>4,'top-down uses overhead camera');
  check(await page.getByRole('button',{name:'Top-down',exact:true}).getAttribute('aria-pressed')==='true','topdown pressed state');
  check(await page.evaluate(()=>window.pc.Application.getApplication().root.findByName('spatial-camera').camera.orthoHeight>=10/(390/844)/2),'portrait topdown contains horizontal bounds');
  await page.getByRole('button',{name:'Starting view',exact:true}).click();check((await position())[1]===0,'reset returns to floor height');
  const screenshotPath=join(evidence,'spatial-product-mobile.png');
  const screenshot=await page.screenshot({path:screenshotPath});
  receipt.screenshot={path:screenshotPath,sha256:sha(screenshot)};
  await page.getByRole('button',{name:'Close 3D',exact:true}).click();
  check(await page.locator('canvas').count()===0,'close removes canvas');
  check(await page.evaluate(()=>!window.pc.Application.getApplication()),'close destroys actual PlayCanvas application');

  // Real HTML video, generated test-pattern MP4. No synthetic seek override.
  await page.goto(base+'/synthetic-tour');
  await page.waitForFunction(()=>document.querySelector('#scrub')?.readyState>=2);
  await page.evaluate(()=>scrollTo(0,650));await page.waitForTimeout(500);
  const before=await page.evaluate(()=>({y:scrollY,time:document.querySelector('#scrub').currentTime}));
  await page.locator('#roomstrip [data-spatial-scene]').click();
  await page.getByRole('status').filter({hasText:'Reviewed room.'}).waitFor();
  check(await page.evaluate(()=>!document.querySelector('#scrub').getAttribute('src')),'actual video src detached in 3D');
  check(await page.evaluate(()=>document.body.style.overflow==='hidden'),'tour scroll locked while in 3D');
  await page.getByRole('button',{name:'Close 3D',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('#scrub')?.readyState>=2);await page.waitForTimeout(250);
  const after=await page.evaluate(()=>({y:scrollY,time:document.querySelector('#scrub').currentTime,src:document.querySelector('#scrub').getAttribute('src')}));
  check(after.src==='/synthetic-video.mp4','video source restored');
  check(Math.abs(before.y-after.y)<=1,'actual tour scroll position restored');
  check(Math.abs(before.time-after.time)<.15,'actual video playback position restored');
  check(await page.locator('.spatial-view').count()===0,'3D removed on tour exit');
  await page.locator('#roomstrip [data-spatial-scene]').click();
  await page.getByRole('status').filter({hasText:'Reviewed room.'}).waitFor();
  await page.keyboard.press('Escape');
  check(await page.locator('.spatial-view').count()===0,'Escape returns to tour');
  check(await page.evaluate(()=>document.activeElement?.hasAttribute('data-spatial-scene')),'tour entry regains focus');

  // Exercise real browser admission failures, not a fake engine success.
  await page.route('**/manifest', async(route)=>{const result=await route.fetch();const m=await result.json();m.privacy_reviewed=false;await route.fulfill({json:m});});
  await page.goto(scene);await page.getByRole('status').filter({hasText:'not published'}).waitFor();
  check(await page.evaluate(()=>!window.pc?.Application.getApplication()),'public unreviewed scene never mounts');
  check(await page.evaluate(()=>window.__nativeSpatial.length===0),'unpublished scene cannot unlock native review');
  await page.unroute('**/manifest');
  await page.route('**/model?*',route=>route.fulfill({status:200,body:'invalid model',headers:{'Content-Type':'application/octet-stream'}}));
  await page.goto(scene);await page.getByRole('status').filter({hasText:'incomplete'}).waitFor();
  check(await page.evaluate(()=>!window.pc?.Application.getApplication()),'short artifact rejected before decode');
  check(await page.evaluate(()=>window.__nativeSpatial.length===0),'short model cannot unlock native review');
  await page.unroute('**/model?*');
  await page.route('**/manifest',async(route)=>{const result=await route.fetch();const m=await result.json();m.sha256='0'.repeat(64);await route.fulfill({json:m});});
  await page.goto(scene);await page.getByRole('status').filter({hasText:'integrity check failed'}).waitFor();
  check(await page.evaluate(()=>!window.pc?.Application.getApplication()),'hash mismatch never mounts');
  check(await page.evaluate(()=>window.__nativeSpatial.length===0),'failed integrity cannot unlock native review');
  await page.unroute('**/manifest');
  await page.route('**/manifest',async(route)=>{const result=await route.fetch();const m=await result.json();m.gaussian_count=2049;await route.fulfill({json:m});});
  await page.goto(scene);await page.getByRole('status').filter({hasText:'bounded SOG'}).waitFor();
  check(await page.evaluate(()=>!window.pc?.Application.getApplication()),'SOG count mismatch rejected before graphics');
  check(await page.evaluate(()=>window.__nativeSpatial.length===0),'failed SOG admission cannot unlock native review');
  await page.unroute('**/manifest');
  await page.route('**/manifest', async(route)=>{const result=await route.fetch();const m=await result.json();m.privacy_reviewed=false;await route.fulfill({json:m});});
  await page.goto('about:blank');await page.goto(scene+'#access=synthetic.capability');
  await page.getByRole('status').filter({hasText:'Private preview'}).waitFor();
  check(!page.url().includes('access'), 'private fragment removed before engine load');
  check(await page.locator('canvas').count()===1, 'private unreviewed room available for owner review');
  await page.unroute('**/manifest');
  await page.evaluate(()=>window.pc.Application.getApplication().graphicsDevice.gl.getExtension('WEBGL_lose_context').loseContext());
  await page.getByRole('status').filter({hasText:'graphics were interrupted'}).waitFor();
  check(await page.evaluate(()=>!window.pc.Application.getApplication()), 'context loss tears down app and offers recovery');
  check(errors.length===0, 'no uncaught browser errors: '+errors.join(';'));
  assert.equal(assertions,69,'All 69 browser behavior assertions must execute');
  artifactCheck(moduleHashes.length>0&&moduleHashes.every(hash=>hash===canonical.metadata.browser_sha256),'Every executed normal viewer response has current emitted identity');
  artifactCheck(unexpectedNetwork.length===0&&syntheticBeacons>0,'Only the exact synthetic beacon was handled; unexpected origins: '+unexpectedNetwork.join(','));
  artifactCheck(JSON.stringify(sourceSnapshot(ROOT))===JSON.stringify(inputs),'Source stayed unchanged during browser proof');
  assert.equal(artifactAssertions,7,'All seven emitted-byte/fixture assertions must execute');
  receipt.status='passed';
} catch(error){receipt.status='failed';receipt.failure={name:error.name,message:error.message};throw error;
} finally {
  releaseModel();await browser.close();
  Object.assign(receipt,{ui_assertions:assertions,artifact_assertions:artifactAssertions,moduleHashes,mutantHashes,synthetic_beacons:syntheticBeacons});
  writeFileSync(join(evidence,'receipt.json'),JSON.stringify(receipt,null,2)+'\n');
  console.log(JSON.stringify({status:receipt.status,evidence,ui_assertions:assertions,artifact_assertions:artifactAssertions,failure:receipt.failure}));
}
