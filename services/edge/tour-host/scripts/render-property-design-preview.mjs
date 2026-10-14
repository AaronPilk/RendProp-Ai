#!/usr/bin/env node
// Separate visual QA, never a substitute for provider/functional acceptance.
// Uses owner-authorized existing app promotional photos, no customer identity,
// no remote media, no purchase and no live API. The video is local test motion.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync,readFileSync,writeFileSync,readdirSync } from 'node:fs';
import { join,resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { buildSrc,ROOT } from './build-src.mjs';
const argument=name=>process.argv.slice(2).find(x=>x.startsWith(name+'='))?.slice(name.length+1);
assert.ok(argument('--evidence'),'An explicit private evidence directory is required');
const evidence=resolve(argument('--evidence'));mkdirSync(evidence,{recursive:true});
const assetRoot=resolve(ROOT,'../../../apps/ios/Rendprop/Resources/Assets.xcassets');
const paths={hero:join(assetRoot,'BrandHomeHero.imageset/BrandHomeHero.jpg'),interior:join(assetRoot,'BrandPhotoTools.imageset/BrandPhotoTools.jpg'),exterior:join(assetRoot,'BrandVideoTools.imageset/BrandVideoTools.jpg')};
const photos=Object.fromEntries(Object.entries(paths).map(([name,path])=>[name,readFileSync(path)]));
const moviePath=join(evidence,'LOCAL-QA-PHOTO-MOTION-NOT-A-PROVIDER-RESULT.mp4');
execFileSync('ffmpeg',['-hide_banner','-loglevel','error','-y','-loop','1','-i',paths.hero,'-t','5','-vf',"scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,zoompan=z='1+0.00015*on':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=1920x1080:fps=24",'-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart','-an',moviePath],{timeout:90000});
const movie=readFileSync(moviePath),metadata=JSON.parse(execFileSync('ffprobe',['-v','quiet','-show_streams','-of','json',moviePath],{encoding:'utf8'}));
const video=metadata.streams.find(x=>x.codec_type==='video');assert.equal(video.width,1920);assert.equal(video.height,1080);
const sourceHashes=Object.fromEntries(readdirSync(join(ROOT,'src')).filter(x=>x.endsWith('.ts')).map(name=>['src/'+name,createHash('sha256').update(readFileSync(join(ROOT,'src',name))).digest('hex')]));
const load=buildSrc('real-property-design-preview-'+process.pid),{renderTourPage}=await load('player'),{buildDemoTour}=await load('demo'),{propertyPage}=await load('property-site');
const { chromium }=await import(pathToFileURL(resolve(ROOT,'../../../apps/studio/node_modules/@playwright/test/index.mjs')).href);
const failures=[],network=[],screenshots=[],metrics=[];
function fixture(){const t=buildDemoTour();t.slug='visual-design';t.website_theme='basic';
 t.listing={address:'A home worth discovering',tagline:'A considered presentation of your property.',details:{story:'Your listing description appears here, with its own facts and the photos you select. This private design fixture uses authorized promotional assets; it does not represent one real property.',show_app_cta:false,show_partners:false},beds:null,baths:null,sqft:null,price_cents:null,price:null,lat:null,lng:null};
 t.cover_url='/visual/hero.jpg';t.gallery=[{url:'/visual/hero.jpg',label:'Exterior presentation'},{url:'/visual/interior.jpg',label:'Interior presentation'},{url:'/visual/exterior.jpg',label:'Outdoor presentation'}];t.poster='/visual/interior.jpg';
 t.listing_video={url:'/visual/property-video.mp4',poster_url:'/visual/hero.jpg',width:1920,height:1080,duration_s:5,disclosure:'Photo-based design test. The sample motion is made locally, not by the production AI service.',branding_policy:'unbranded'};
 t.video_url=t.scrub_url='/visual/recorded.mp4';t.hls_url=null;t.duration_s=5;t.chapters=[];t.staged=false;t.altered_media=[];t.floorplan_url=null;
 t.agent_card={name:'Sample listing contact'};t.cta={mode:'lead_form',label:'Request a showing',url:null,secondary:[],lead_fields:['name','email','message']};return t;}
let server,browser,origin;
try{
 server=createServer((req,res)=>{const url=new URL(req.url,'http://127.0.0.1');network.push(url.pathname);
  const image=url.pathname.match(/^\/visual\/(hero|interior|exterior)\.jpg$/);
  if(image){res.writeHead(200,{'Content-Type':'image/jpeg','Cache-Control':'no-store'});res.end(photos[image[1]]);return;}
  if(['/visual/property-video.mp4','/visual/recorded.mp4'].includes(url.pathname)){const range=/bytes=(\d+)-(\d*)/.exec(req.headers.range||'');const start=range?Number(range[1]):0,end=range&&range[2]?Math.min(movie.length-1,Number(range[2])):movie.length-1;
   res.writeHead(range?206:200,{'Content-Type':'video/mp4','Content-Length':end-start+1,'Accept-Ranges':'bytes',...(range?{'Content-Range':`bytes ${start}-${end}/${movie.length}`}:{})});res.end(movie.subarray(start,end+1));return;}
  if(url.pathname==='/property/visual-design'){
   const theme=url.searchParams.get('preview_theme')==='coastal-luxe'?'coastal-luxe':'signature-estate',page=propertyPage(url.searchParams.get('page'));
   const published=url.searchParams.get('published')==='1',tour=fixture();if(published)tour.website_theme=theme;
   const html=renderTourPage(tour,origin+'/closed-api','','',{origin,page,publicBase:'/property',previewTheme:published?null:theme});
   writeFileSync(join(evidence,theme+'-'+(published?'published-':'')+page+'.html'),html);res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store'});res.end(html);return;
  }res.writeHead(404);res.end('Private visual fixture route unavailable');
 });await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
 const context=await browser.newContext({reducedMotion:'reduce'});await context.route('**/*',route=>{const url=new URL(route.request().url());if(url.origin===origin||url.protocol==='data:')return route.continue();failures.push('External request '+url.origin+url.pathname);return route.abort();});
 const page=await context.newPage();page.on('pageerror',error=>failures.push(String(error)));page.setDefaultTimeout(5000);
 for(const theme of ['signature-estate','coastal-luxe'])for(const screen of ['mobile','desktop'])for(const section of ['home','gallery','location','contact']){
  const size=screen==='mobile'?{width:390,height:844}:{width:1440,height:1000};await page.setViewportSize(size);
  await page.goto(origin+'/property/visual-design?preview_theme='+theme+(section==='home'?'':'&page='+section),{waitUntil:'networkidle'});
  // Visit the actual lazy-photo viewport before a full-page capture. Changing
  // image loading flags would conceal a production lazy-loading regression.
  for(const photo of await page.locator('img.property-thumb').all()){
   await photo.scrollIntoViewIfNeeded();
   await photo.evaluate(image=>new Promise((resolve,reject)=>{
    const limit=setTimeout(()=>reject(new Error('Visible property photo did not load')),5000);
    const check=()=>{if(!image.hasAttribute('data-property-src')&&image.complete&&image.naturalWidth>1){clearTimeout(limit);resolve();}else requestAnimationFrame(check);};check();
   }));
  }
  await page.evaluate(()=>scrollTo(0,0));
  const layout=await page.evaluate(()=>({overflow:document.documentElement.scrollWidth>innerWidth,blur:getComputedStyle(document.getElementById('listing-nav')).backdropFilter,body:document.body.className,forms:document.querySelectorAll('form').length,images:Array.from(document.images).filter(x=>x.getAttribute('data-property-src')===null).map(x=>({src:x.getAttribute('src'),width:x.naturalWidth,height:x.naturalHeight})),headlineCount:document.querySelectorAll('h1').length}));
  assert.equal(layout.overflow,false,theme+' '+screen+' '+section+' horizontal overflow');assert.equal(layout.forms,0,'Preview cannot submit buyer enquiries');assert.equal(layout.headlineCount,1,'One clear page headline');assert.notEqual(layout.blur,'none','Luxury preview uses its floating glass navigation');
  const name=theme+'-'+screen+'-'+section+'.png';await page.screenshot({path:join(evidence,name),fullPage:true});screenshots.push(name);metrics.push({theme,screen,section,...layout});
  if(section==='home'){assert.equal(await page.locator('#property-video-nav-play').isVisible(),true);await page.locator('#property-video-nav-play').click();await page.waitForFunction(()=>document.getElementById('property-video').currentTime>.1);assert.equal(await page.locator('#property-video').evaluate(v=>v.videoWidth),1920);await page.screenshot({path:join(evidence,theme+'-'+screen+'-playing.png'),fullPage:false});}
 }
 // The same closed fixture also shows the actual published layout without its
 // preview banner and with the real enquiry UI. No form is submitted and this
 // renderer fixture does not prove a purchase or grant a server entitlement.
 for(const theme of ['signature-estate','coastal-luxe'])for(const screen of ['mobile','desktop'])for(const section of ['home','contact']){
  await page.setViewportSize(screen==='mobile'?{width:390,height:844}:{width:1440,height:1000});
  await page.goto(origin+'/property/visual-design?preview_theme='+theme+'&published=1'+(section==='home'?'':'&page='+section),{waitUntil:'networkidle'});
  for(const photo of await page.locator('img.property-thumb').all()){
   await photo.scrollIntoViewIfNeeded();await photo.evaluate(image=>new Promise((resolve,reject)=>{const limit=setTimeout(()=>reject(new Error('Visible published-fixture photo did not load')),5000);const check=()=>{if(!image.hasAttribute('data-property-src')&&image.complete&&image.naturalWidth>1){clearTimeout(limit);resolve();}else requestAnimationFrame(check);};check();}));
  }
  await page.evaluate(()=>scrollTo(0,0));
  assert.equal(await page.locator('.property-preview-banner').count(),0,'Published fixture has no preview label');
  assert.equal(await page.locator('#leadform').count(),1,'Published fixture shows the actual enquiry fields');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,'Published fixture has no horizontal overflow');
  const name=theme+'-'+screen+'-published-'+section+'.png';await page.screenshot({path:join(evidence,name),fullPage:true});screenshots.push(name);
 }
 assert.deepEqual(failures,[]);
 writeFileSync(join(evidence,'receipt.json'),JSON.stringify({passed:true,scope:'Visual QA with authorized app promotional assets and local 1080p photo motion. Not one real listing, not a paid AI model result, not a customer/phone/purchase test.',sourceHashes,authorizedAssets:Object.fromEntries(Object.entries(paths).map(([name,path])=>[name,{path,sha256:createHash('sha256').update(photos[name]).digest('hex')}])),movie:{sha256:createHash('sha256').update(movie).digest('hex'),width:video.width,height:video.height,codec:video.codec_name,duration:video.duration},screenshots,metrics,failures,network,pilkReferences:['signature-estate/residence.html','coastal-luxe/home.html'],latestDesignDirection:'Modern floating Apple-style glass using the original cream/bronze and white/teal palettes; shared actual-data components, no per-property site generation.'},null,2));
 console.log('Real-estate design preview: 24 mobile/desktop preview/published-layout captures plus normal 1080p playback; '+evidence);
}finally{if(browser)await browser.close();if(server)await new Promise(resolve=>server.close(resolve));}
