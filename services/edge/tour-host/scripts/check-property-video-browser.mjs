#!/usr/bin/env node
// Real rendered pages and real 1080p H.264/AAC, exclusively on loopback.
// No phone, customer content, purchase, live network or provider generation.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { buildSrc, ROOT } from './build-src.mjs';
const arg=name=>process.argv.slice(2).find(x=>x.startsWith(name+'='))?.slice(name.length+1);
const evidence=arg('--evidence')?resolve(arg('--evidence')):mkdtempSync(join(tmpdir(),'rendprop-property-video-'));
mkdirSync(evidence,{recursive:true});
const fault=arg('--fault')||null;
assert.ok(!fault||['eager-media','no-controls','crop-master','preview-beacon','retain-master'].includes(fault));
const { chromium } = await import(pathToFileURL(arg('--playwright')||resolve(ROOT,'../../../apps/studio/node_modules/@playwright/test/index.mjs')).href);
const sourceHashes=Object.fromEntries(readdirSync(join(ROOT,'src')).filter(x=>x.endsWith('.ts')).map(x=>['src/'+x,createHash('sha256').update(readFileSync(join(ROOT,'src',x))).digest('hex')]));
sourceHashes['scripts/check-property-video-browser.mjs']=createHash('sha256').update(readFileSync(new URL(import.meta.url))).digest('hex');
const moviePath=join(evidence,'SYNTHETIC-NOT-A-LISTING-1080P.mp4');
execFileSync('ffmpeg',['-hide_banner','-loglevel','error','-y','-f','lavfi','-i','testsrc2=size=1920x1080:rate=24:duration=4','-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=4','-c:v','libx264','-preset','ultrafast','-crf','30','-g','24','-pix_fmt','yuv420p','-c:a','aac','-b:a','96k','-movflags','+faststart','-shortest',moviePath],{timeout:60000});
const movie=readFileSync(moviePath),load=buildSrc('property-video-browser-'+process.pid);
const { renderTourPage,unbrandedSelfCheck }=await load('player');
const { buildDemoTour }=await load('demo');
const { propertyPage }=await load('property-site');
const { previewWebsiteTheme }=await load('property-design');
const requests=[],errors=[],external=[],checks=[],measurements=[];
const check=(condition,label)=>{assert.ok(condition,label);checks.push(label);};
const svg=label=>`<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080"><rect width="1920" height="1080" fill="#233c40"/><text x="100" y="400" font-size="80" fill="white">SYNTHETIC ${label}</text></svg>`;
function fixture(theme){
 const tour=buildDemoTour();tour.slug='synthetic-video';tour.website_theme=theme;
 tour.listing_video={url:'/synthetic-master.mp4',poster_url:'/synthetic-poster.svg',duration_s:4,width:1920,height:1080,branding_policy:'unbranded',disclosure:'AI motion from selected property photos. Synthetic fixture, not a listing.'};
 tour.listing={...tour.listing,address:'SYNTHETIC — 123 Property Avenue',details:{story:'Synthetic published description. No real customer data.',show_app_cta:false,show_partners:false},lat:null,lng:null};
 tour.gallery=Array.from({length:9},(_,n)=>({url:'/synthetic-photo-'+n+'.svg',label:'Synthetic photo '+n}));tour.cover_url='/synthetic-cover.svg';
 tour.video_url=tour.scrub_url='/synthetic-walkthrough.mp4';tour.hls_url=null;tour.poster='/synthetic-cover.svg';tour.duration_s=4;
 tour.chapters=[{label:'Synthetic entry',t_ms:0,sort:0}];tour.floorplan_url=null;tour.altered_media=[];tour.staged=false;
 tour.agent_card={name:'Synthetic Contact',email:'synthetic@example.invalid',phone:'555-010-1234'};
 tour.cta={mode:'lead_form',url:null,label:'Request information',secondary:[],lead_fields:['name','email','message']};
 return tour;
}
let server,browser,page,origin,retryBlocked=true;
try{
 server=createServer((req,res)=>{
  const url=new URL(req.url,'http://127.0.0.1');requests.push({path:url.pathname,method:req.method,range:req.headers.range||null});
  if(url.pathname.endsWith('.svg')){res.writeHead(200,{'Content-Type':'image/svg+xml','Cache-Control':'no-store'});res.end(svg(url.pathname));return;}
  if(['/synthetic-master.mp4','/synthetic-walkthrough.mp4','/synthetic-retry.mp4'].includes(url.pathname)){
   if(url.pathname==='/synthetic-retry.mp4'&&retryBlocked){res.writeHead(503,{'Cache-Control':'no-store'});res.end('Synthetic media failure');return;}
   const match=/bytes=(\d+)-(\d*)/.exec(req.headers.range||'');const start=match?Number(match[1]):0,end=match&&match[2]?Math.min(movie.length-1,Number(match[2])):movie.length-1;
   if(start>=movie.length){res.writeHead(416,{'Content-Range':'bytes */'+movie.length});res.end();return;}
   res.writeHead(match?206:200,{'Content-Type':'video/mp4','Content-Length':end-start+1,'Accept-Ranges':'bytes','Cache-Control':'no-store',...(match?{'Content-Range':`bytes ${start}-${end}/${movie.length}`}:{})});res.end(movie.subarray(start,end+1));return;
  }
  if(url.pathname==='/api/beacon/synthetic-video'&&req.method==='POST'){res.writeHead(200,{'Content-Type':'application/json'});res.end('{}');return;}
  if(url.pathname.startsWith('/f/synthetic-video')||url.pathname.startsWith('/property/synthetic-video')||url.pathname.startsWith('/u/synthetic-video')){
   const theme=['signature-estate','coastal-luxe'].includes(url.searchParams.get('published_theme'))?url.searchParams.get('published_theme'):'basic';
   const tour=fixture(theme),unbranded=url.pathname.startsWith('/u/');
   if(url.searchParams.has('retry'))tour.listing_video.url='/synthetic-retry.mp4';
   let html=renderTourPage(tour,origin+'/api','','',{origin,publicBase:url.pathname.startsWith('/property/')?'/property':'/f',page:propertyPage(url.searchParams.get('page')),previewTheme:previewWebsiteTheme(url.searchParams.get('preview_theme')),unbranded});
   if(unbranded)assert.equal(unbrandedSelfCheck(html,tour).length,0);
   if(fault==='eager-media')html=html.replace('id="property-video" preload="none"','id="property-video" src="/synthetic-master.mp4" preload="auto"');
   if(fault==='no-controls')html=html.replace('video.controls=true;video.preload','video.controls=false;video.preload');
   if(fault==='crop-master')html=html.replace('aspect-ratio:16/9; background:#111','aspect-ratio:1/1; background:#111').replace('.property-video-stage video { display:block; width:100%; height:100%; object-fit:contain; }','.property-video-stage video { display:block; width:100%; height:100%; object-fit:cover; }');
   if(fault==='preview-beacon')html=html.replace('if(CFG.preview || !viewed','if(!viewed');
   if(fault==='retain-master')html=html.replace("generation++;clearTimeout(deadline);video.pause();video.removeAttribute('src');video.preload='none'","generation++;clearTimeout(deadline);video.pause();video.preload='none'");
   res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store'});res.end(html);return;
  }
  res.writeHead(404);res.end('Synthetic route not available');
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
 const context=await browser.newContext();await context.route('**/*',route=>{const url=new URL(route.request().url());if(url.origin===origin||url.protocol==='data:')return route.continue();external.push(url.origin+url.pathname);return route.abort();});
 page=await context.newPage();page.on('pageerror',error=>errors.push(String(error)));page.setDefaultTimeout(6000);
 const mediaRequests=()=>requests.filter(x=>x.path.endsWith('.mp4'));
 for(const theme of ['basic','signature-estate','coastal-luxe']){
  await page.setViewportSize({width:390,height:844});const before=mediaRequests().length;
  await page.goto(origin+'/property/synthetic-video?published_theme='+theme,{waitUntil:'networkidle'});
  check(mediaRequests().length===before,'No initial video download for '+theme);
  check(await page.locator('#property-video-play').isVisible(),'Clear Play affordance for '+theme);
  const layout=await page.evaluate(()=>{const v=document.getElementById('property-video'),stage=v.parentElement,bounds=stage.getBoundingClientRect();return {width:bounds.width,height:bounds.height,fit:getComputedStyle(v).objectFit,overflow:document.documentElement.scrollWidth>innerWidth,poster:v.poster,body:document.body.className};});
  check(!layout.overflow,'No horizontal mobile overflow for '+theme);
  check(Math.abs(layout.width/layout.height-16/9)<.01&&layout.fit==='contain','Complete landscape master retained at mobile width for '+theme);
  check(layout.body.includes('site-theme-'+theme),'Actual server style rendered for '+theme);measurements.push({theme,...layout});
  await page.screenshot({path:join(evidence,theme+'-mobile.png'),fullPage:false});
  await page.locator(theme==='basic'?'#property-video-nav-play':'#property-video-play').click();
  await page.waitForFunction(()=>{const v=document.getElementById('property-video');return v.readyState>=2&&v.currentTime>0;});
  const playback=await page.locator('#property-video').evaluate(v=>({controls:v.controls,width:v.videoWidth,height:v.videoHeight,muted:v.muted,paused:v.paused,source:v.currentSrc}));
  check(playback.controls,'Native controls available for '+theme);
  check(playback.width===1920&&playback.height===1080,'Actual decoded 1080p master for '+theme);
  check(!playback.muted&&!playback.paused,'Explicit Play uses normal sound/playback for '+theme);
  await page.locator('#listing-nav .walkthrough-secondary').click();
  check(await page.locator('#property-video').evaluate(v=>v.paused),'Optional walkthrough pauses hero for '+theme);
  await page.locator('#flythrough-close').click();
  await page.evaluate(()=>dispatchEvent(new Event('pagehide')));
  check(await page.locator('#property-video').evaluate(v=>!v.getAttribute('src')&&v.preload==='none'),'Page lifecycle releases primary master for '+theme);
  check(await page.locator('#property-video-play').isVisible(),'Restored page can explicitly replay for '+theme);
 }
 await page.goto(origin+'/property/synthetic-video?retry=1',{waitUntil:'networkidle'});
 await page.locator('#property-video-play').click();await page.waitForFunction(()=>document.getElementById('property-video-play').textContent==='Retry property video');
 check(await page.locator('#property-video-play').isVisible(),'Real HTTP failure exposes usable Retry control');
 check(await page.locator('#property-video').evaluate(v=>!v.getAttribute('src')&&v.preload==='none'),'Failed playback releases background media downloads');
 check(await page.locator('.property-hero-link').first().isVisible(),'Real video failure leaves Gallery available');
 const failedRequests=requests.filter(x=>x.path==='/synthetic-retry.mp4').length;retryBlocked=false;
 await page.locator('#property-video-play').click();await page.waitForFunction(()=>document.getElementById('property-video').currentTime>0);
 check(requests.filter(x=>x.path==='/synthetic-retry.mp4').length>failedRequests,'Retry actually requests the released master again');
 check(await page.locator('#property-video').evaluate(v=>v.videoWidth===1920&&v.videoHeight===1080),'Retried network master plays at actual 1080p');
 // Navigation is real pages, not empty sections. Preview never becomes live.
 for(const target of ['gallery','location','contact']){
  const before=mediaRequests().length;await page.goto(origin+'/property/synthetic-video?page='+target+'&preview_theme=signature-estate',{waitUntil:'networkidle'});
  check(mediaRequests().length===before,'Preview '+target+' does not eagerly load video');
  check(await page.locator('.property-preview-banner').isVisible(),'Preview '+target+' has prominent label');
  check(await page.locator('form').count()===0,'Preview '+target+' cannot submit enquiry');
  check(await page.locator('meta[name="robots"]').getAttribute('content')==='noindex, nofollow','Preview '+target+' stays noindex');
  check((await page.locator('#listing-nav .listing-nav-links a').evaluateAll(links=>links.map(link=>link.getAttribute('href')))).filter(x=>x.includes('preview_theme=signature-estate')).length===4,'Preview '+target+' preserves every alias navigation/style');
  if(target==='gallery'){
   check(await page.locator('[data-property-photo]').count()===9,'Gallery has every selected photo');
   check(await page.getByRole('heading',{name:'A closer look',exact:true}).count()===1,'Standalone Gallery has one clear headline');
  }
 }
 await page.goto(origin+'/property/synthetic-video?preview_theme=coastal-luxe',{waitUntil:'networkidle'});const beaconBefore=requests.filter(x=>x.path.includes('/beacon/')).length;
 await page.locator('#property-video-play').click();await page.waitForFunction(()=>document.getElementById('property-video').currentTime>.2);
 await page.locator('#property-video').evaluate(v=>v.pause());
 check(requests.filter(x=>x.path.includes('/beacon/')).length===beaconBefore,'Actual preview playback emits no analytics/billing requests');
 await page.setViewportSize({width:1440,height:1000});await page.goto(origin+'/property/synthetic-video?published_theme=signature-estate',{waitUntil:'networkidle'});
 await page.screenshot({path:join(evidence,'signature-estate-desktop.png'),fullPage:false});
 const desktop=await page.evaluate(()=>({overflow:document.documentElement.scrollWidth>innerWidth,width:document.querySelector('.property-video-stage').getBoundingClientRect().width}));
 check(!desktop.overflow&&desktop.width<=1200,'Desktop hero retains bounded usable content');
 await page.emulateMedia({reducedMotion:'reduce'});
 await page.locator('.lp-gcell').first().hover();
 const stillCard=await page.locator('.lp-gcell').first().evaluate(el=>({transform:getComputedStyle(el).transform,transition:getComputedStyle(el).transitionDuration,imageTransform:getComputedStyle(el.querySelector('img')).transform}));
 check(stillCard.transform==='none'&&stillCard.transition==='0s'&&stillCard.imageTransform==='none','Luxury hover respects reduced motion without zooming photos');
 await page.emulateMedia({reducedMotion:'no-preference'});
 await page.goto(origin+'/property/synthetic-video?published_theme=coastal-luxe',{waitUntil:'networkidle'});
 const coastal=await page.evaluate(()=>{const stage=document.querySelector('.property-video-stage').getBoundingClientRect(),hero=document.querySelector('.property-video-hero');return {display:getComputedStyle(hero).display,width:stage.width,height:stage.height,overflow:document.documentElement.scrollWidth>innerWidth};});
 check(coastal.display==='grid'&&!coastal.overflow&&Math.abs(coastal.width/coastal.height-16/9)<.01,'Coastal desktop layout stays distinct while retaining the full landscape canvas');
 await page.goto(origin+'/u/synthetic-video',{waitUntil:'networkidle'});
 check(await page.locator('#property-video-play').isVisible()&&await page.locator('form').count()===0,'MLS retains normal property video without contact');
 check(errors.length===0,'No actual browser script errors');check(external.length===0,'No external template assets, fonts, trackers or provider requests');
 writeFileSync(join(evidence,'receipt.json'),JSON.stringify({passed:true,checks,measurements,sourceHashes,syntheticMovieSHA256:createHash('sha256').update(movie).digest('hex'),requests,errors,external,fault,scope:'Local Chromium + synthetic H.264/AAC; not phone/customer/live-generation proof'},null,2));
 console.log(`Property-video browser: ${checks.length} real-browser assertions passed; local 1080p master, mobile/desktop/preview/MLS; receipt ${evidence}`);
}catch(error){writeFileSync(join(evidence,'failure.json'),JSON.stringify({passed:false,error:String(error),sourceHashes,requests,errors,external,fault},null,2));throw error;}
finally{if(browser)await browser.close();if(server)await new Promise(resolve=>server.close(resolve));}
