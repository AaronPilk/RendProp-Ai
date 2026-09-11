// Test-controlled, isolated headless browser. Not the owner's phone or real room.
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { chromium } = await import(pathToFileURL(process.argv[2]).href);
const browser = await chromium.launch({headless:true});
const base='http://127.0.0.1:8794', scene=base+'/s/11111111-1111-4111-8111-111111111111';
let assertions=0;
const check=(value,message)=>{assertions++;assert.ok(value,message);};
const page=await browser.newPage({viewport:{width:390,height:844}});
const errors=[];page.on('pageerror',error=>errors.push(error.message));
await page.addInitScript(()=>{
  window.__spatialDraws=0;
  window.__nativeSpatial=[];
  window.webkit={messageHandlers:{spatialViewer:{postMessage(message){window.__nativeSpatial.push({message,draws:window.__spatialDraws});}}}};
  for(const name of ['drawArraysInstanced','drawElementsInstanced']) {
    const original=WebGL2RenderingContext.prototype[name];
    WebGL2RenderingContext.prototype[name]=function(...args){
      if(this.getParameter(this.DRAW_FRAMEBUFFER_BINDING)===null && args[1]>0 && args.at(-1)>0) window.__spatialDraws++;
      return original.apply(this,args);
    };
  }
});
const position=()=>page.evaluate(()=>window.pc.Application.getApplication().root.findByName('spatial-camera').getPosition().toArray());
const enter=async()=>{await page.goto(scene);await page.getByRole('status').filter({hasText:'Reviewed room.'}).waitFor();};
try {
  if(process.argv.includes('--negative-control')) {
    await page.route('**/spatial-viewer.js',async(route)=>{
      const response=await route.fetch(), source=await response.text(), marker='const boot = async () => {';
      assert.ok(source.includes(marker),'negative control must mutate actual runtime');
      await route.fulfill({response,body:source.replace(marker,marker+" window.webkit.messageHandlers.spatialViewer.postMessage({type:'spatial-ready',scene_id:options.sceneId,artifact_revision:'premature'});")});
    });
  }
  let releaseModel, sawModel;
  const holdModel=new Promise(resolve=>{releaseModel=resolve}), requestedModel=new Promise(resolve=>{sawModel=resolve});
  await page.route('**/model?*',async(route)=>{sawModel();await holdModel;await route.continue();});
  await page.goto(scene);await requestedModel;
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
  await page.screenshot({path:'/tmp/rendprop-spatial-product-mobile.png'});
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
  console.log('Spatial browser: '+assertions+' assertions passed; actual headless Chromium/SOG/test-pattern video. No phone, real room, HLS stream, measured floor or collision proof.');
} finally {await browser.close();}
