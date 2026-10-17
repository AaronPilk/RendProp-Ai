#!/usr/bin/env node
// Owner review sheet for the three property-website designs (W3).
// Separate visual QA, never a substitute for provider/functional acceptance.
//
// Fixture: Rendprop's OWN hosted demo estate (1180 Crestline Ridge, the same
// photos the Worker serves at /f/estate-demo from public/assets) — one coherent
// real property, no customer identity, no remote media, no purchase, no live
// API. The hero film is local test motion made from the demo poster, not a
// provider result. Everything runs on loopback; any external request fails.
//
// Output: PNGs for every design × page × width, plus ONE self-contained HTML
// contact sheet (inline images) the owner can open anywhere, offline.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync,readFileSync,writeFileSync,readdirSync,existsSync } from 'node:fs';
import { join,resolve,extname,basename } from 'node:path';
import { pathToFileURL } from 'node:url';
import { buildSrc,ROOT } from './build-src.mjs';
const argument=name=>process.argv.slice(2).find(x=>x.startsWith(name+'='))?.slice(name.length+1);
assert.ok(argument('--evidence'),'An explicit private evidence directory is required');
const evidence=resolve(argument('--evidence'));mkdirSync(evidence,{recursive:true});
// The film is H.264 by default (what production serves). `--codec=vp9` only
// lets the playback frame be captured on a Linux Chromium without proprietary
// codecs; the receipt records which one was used.
const codec=argument('--codec')||'h264';assert.ok(['h264','vp9'].includes(codec));
const assetRoot=resolve(ROOT,'public/assets');
const ASSET_TYPES={'.webp':'image/webp','.jpg':'image/jpeg','.jpeg':'image/jpeg','.png':'image/png','.mp4':'video/mp4'};
const load=buildSrc('real-property-design-preview-'+process.pid),{renderTourPage}=await load('player'),{buildDemoTour}=await load('demo'),{propertyPage}=await load('property-site'),{websiteThemeName,WEBSITE_THEMES}=await load('property-design');
const { chromium }=await import(pathToFileURL(resolve(ROOT,'../../../apps/studio/node_modules/@playwright/test/index.mjs')).href);

const posterPath=join(assetRoot,'demo-poster.webp');
const moviePath=join(evidence,'LOCAL-QA-PHOTO-MOTION-NOT-A-PROVIDER-RESULT.mp4');
const FILM_SECONDS=8;
execFileSync('ffmpeg',['-hide_banner','-loglevel','error','-y','-loop','1','-i',posterPath,'-t',String(FILM_SECONDS),'-vf',"scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,zoompan=z='1+0.00015*on':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=1920x1080:fps=24",...(codec==='vp9'?['-c:v','libvpx-vp9','-deadline','realtime','-cpu-used','8','-crf','34','-b:v','0']:['-c:v','libx264','-preset','fast','-crf','18']),'-pix_fmt','yuv420p','-movflags','+faststart','-an',moviePath],{timeout:120000});
const movie=readFileSync(moviePath),metadata=JSON.parse(execFileSync('ffprobe',['-v','quiet','-show_streams','-of','json',moviePath],{encoding:'utf8'}));
const video=metadata.streams.find(x=>x.codec_type==='video');assert.equal(video.width,1920);assert.equal(video.height,1080);
const sourceHashes=Object.fromEntries(readdirSync(join(ROOT,'src')).filter(x=>x.endsWith('.ts')).map(name=>['src/'+name,createHash('sha256').update(readFileSync(join(ROOT,'src',name))).digest('hex')]));

// Real-estate fixture photos the demo suites already use (public/assets).
const GALLERY=[
 {url:'/assets/demo-g1.webp',label:'Twilight arrival'},{url:'/assets/demo-g2.webp',label:"Chef's kitchen"},{url:'/assets/demo-g3.webp',label:'Great room'},
 {url:'/assets/demo-g4.webp',label:'Primary bath'},{url:'/assets/demo-g5.webp',label:'Sunken lounge'},{url:'/assets/demo-g6.webp',label:'The estate'},
 {url:'/assets/luxury-kitchen-interior.webp',label:'Kitchen island'},{url:'/assets/living-room-walkthrough.webp',label:'Living room'},
 {url:'/assets/glass-house-exterior.webp',label:'Garden elevation'},{url:'/assets/modern-home-exterior-tour.webp',label:'Motor court'},
];
const NEARBY={status:'available',attribution:'© OpenStreetMap contributors',places:[
 {name:'Fixture Bistro',category:'Restaurant',distance_m:420,source_url:'https://www.openstreetmap.org/node/1001'},
 {name:'Harbor Coffee (fixture)',category:'Cafe',distance_m:650,source_url:'https://www.openstreetmap.org/node/1002'},
 {name:'Ridge Market (fixture)',category:'Shop',distance_m:900,source_url:'https://www.openstreetmap.org/node/1003'},
 {name:'Canyon Grill (fixture)',category:'Restaurant',distance_m:1300,source_url:'https://www.openstreetmap.org/node/1004'},
 {name:'Oak & Stone Bakery (fixture)',category:'Cafe',distance_m:1750,source_url:'https://www.openstreetmap.org/node/1005'},
 {name:'Crestline Provisions (fixture)',category:'Shop',distance_m:2100,source_url:'https://www.openstreetmap.org/node/1006'},
]};
function fixture(theme){
 const t=buildDemoTour();t.slug='visual-design';t.website_theme=theme;t.share_url='https://rendprop.com/f/visual-design';
 t.listing={...t.listing,lat:27.7712,lng:-82.6412,details:{...t.listing.details,gallery:GALLERY,show_app_cta:false,show_partners:false}};
 t.cover_url='/assets/demo-g1.webp';t.poster='/assets/demo-poster.webp';t.gallery=GALLERY;
 t.listing_video={url:'/visual/property-film.mp4',poster_url:'/assets/demo-poster.webp',width:1920,height:1080,duration_s:FILM_SECONDS,disclosure:'Photo-based property film. This review fixture uses local test motion made from the demo poster, not the production AI service.',branding_policy:'unbranded'};
 t.agent_card={...t.agent_card,name:'Alexandra Reyes',brokerage:'Meridian Estates',email:'aaron@pilk.ai',website:'https://pilk.ai/',instagram:'pilk.ai',show_partners:false};
 return t;
}
const THEMES=[...WEBSITE_THEMES],PAGES=['home','gallery','location','contact'],WIDTHS=[390,1440];
const failures=[],network=[],captures=[],metrics=[];
let server,browser,origin;
try{
 server=createServer((req,res)=>{const url=new URL(req.url,'http://127.0.0.1');network.push(url.pathname);
  if(url.pathname.startsWith('/assets/')){const file=basename(url.pathname),type=ASSET_TYPES[extname(file)],path=join(assetRoot,file);
   if(type&&existsSync(path)){res.writeHead(200,{'Content-Type':type,'Cache-Control':'no-store'});res.end(readFileSync(path));return;}}
  if(url.pathname==='/visual/property-film.mp4'){const range=/bytes=(\d+)-(\d*)/.exec(req.headers.range||'');const start=range?Number(range[1]):0,end=range&&range[2]?Math.min(movie.length-1,Number(range[2])):movie.length-1;
   res.writeHead(range?206:200,{'Content-Type':'video/mp4','Content-Length':end-start+1,'Accept-Ranges':'bytes',...(range?{'Content-Range':`bytes ${start}-${end}/${movie.length}`}:{})});res.end(movie.subarray(start,end+1));return;}
  if(url.pathname==='/f/visual-design/nearby'){res.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(NEARBY));return;}
  if(url.pathname==='/property/visual-design'){
   const theme=THEMES.includes(url.searchParams.get('theme'))?url.searchParams.get('theme'):'basic',page=propertyPage(url.searchParams.get('page'));
   const preview=url.searchParams.get('mode')==='preview',tour=fixture(preview?'basic':theme);
   const html=renderTourPage(tour,origin+'/closed-api','','',{origin,page,publicBase:'/property',previewTheme:preview?theme:null});
   writeFileSync(join(evidence,theme+'-'+(preview?'preview-':'')+page+'.html'),html);res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store'});res.end(html);return;
  }res.writeHead(404);res.end('Private visual fixture route unavailable');
 });await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
 const context=await browser.newContext({reducedMotion:'reduce'});await context.route('**/*',route=>{const url=new URL(route.request().url());if(url.origin===origin||url.protocol==='data:')return route.continue();failures.push('External request '+url.origin+url.pathname);return route.abort();});
 const page=await context.newPage();page.on('pageerror',error=>failures.push(String(error)));page.setDefaultTimeout(8000);
 const settlePhotos=async()=>{for(const photo of await page.locator('img.property-thumb').all()){
   await photo.scrollIntoViewIfNeeded();
   await photo.evaluate(image=>new Promise((resolve,reject)=>{const limit=setTimeout(()=>reject(new Error('Visible property photo did not load')),8000);const check=()=>{if(!image.hasAttribute('data-property-src')&&image.complete&&image.naturalWidth>1){clearTimeout(limit);resolve();}else requestAnimationFrame(check);};check();}));
  }await page.evaluate(()=>scrollTo(0,0));};
 const capture=async(name,{theme,pageName,width,mode,fullPage=true})=>{
  const png=join(evidence,name+'.png');await page.screenshot({path:png,fullPage});
  const jpeg=await page.screenshot({type:'jpeg',quality:82,fullPage});
  captures.push({name,theme,design:websiteThemeName(theme),pageName,width,mode,png:basename(png),data:'data:image/jpeg;base64,'+jpeg.toString('base64'),bytes:jpeg.length});
 };
 // 1. Published look: every design × page × width. This is what the $25 buys.
 for(const theme of THEMES)for(const width of WIDTHS)for(const pageName of PAGES){
  await page.setViewportSize({width,height:width===390?844:1000});
  await page.goto(origin+'/property/visual-design?theme='+theme+(pageName==='home'?'':'&page='+pageName),{waitUntil:'networkidle'});
  if(pageName==='location')await page.waitForFunction(()=>document.querySelector('#property-nearby-list li'));
  await settlePhotos();
  const layout=await page.evaluate(()=>({overflow:document.documentElement.scrollWidth>innerWidth,blur:getComputedStyle(document.getElementById('listing-nav')).backdropFilter,body:document.body.className,forms:document.querySelectorAll('form').length,banner:document.querySelectorAll('.property-preview-banner').length,headlineCount:document.querySelectorAll('h1').length,photos:document.querySelectorAll('[data-property-photo]').length,hero:document.querySelector('.property-video-stage')?.textContent.replace(/\s+/g,' ').trim()??null,images:Array.from(document.images).filter(x=>x.getAttribute('data-property-src')===null).map(x=>({src:x.getAttribute('src'),width:x.naturalWidth,height:x.naturalHeight}))}));
  const tag=theme+' '+pageName+' '+width;
  assert.equal(layout.overflow,false,tag+' horizontal overflow');assert.equal(layout.banner,0,tag+' published fixture has no preview label');assert.equal(layout.headlineCount,1,tag+' one clear page headline');
  assert.ok(layout.body.includes('site-theme-'+theme),tag+' actual server design class');
  if(theme!=='basic')assert.notEqual(layout.blur,'none',tag+' luxury design uses its floating glass navigation');
  if(pageName==='gallery')assert.equal(layout.photos,GALLERY.length,tag+' gallery keeps every fixture photo');
  if(pageName==='contact')assert.equal(await page.locator('#leadform').count(),1,tag+' published contact shows the actual enquiry fields');
  if(pageName==='home')assert.equal(/\d\s*×\s*\d/.test(layout.hero),theme==='basic',tag+' only Classic shows the pixel-dimension status line');
  await capture(theme+'-'+width+'-'+pageName,{theme,pageName,width,mode:'published'});metrics.push({theme,pageName,width,mode:'published',...layout,images:layout.images.length});
 }
 // 2. Design preview chrome (what a Studio "Preview design" link opens): no
 // enquiry form, labelled banner, never an entitlement.
 for(const theme of THEMES)for(const width of WIDTHS){
  await page.setViewportSize({width,height:width===390?844:1000});
  await page.goto(origin+'/property/visual-design?theme='+theme+'&mode=preview',{waitUntil:'networkidle'});await settlePhotos();
  assert.equal(await page.locator('.property-preview-banner').count(),1,'Preview is labelled');assert.equal(await page.locator('form').count(),0,'Preview cannot submit buyer enquiries');
  assert.ok((await page.evaluate(()=>document.body.className)).includes('site-theme-'+theme),'Preview renders the requested design');
  await capture(theme+'-'+width+'-preview-home',{theme,pageName:'home',width,mode:'preview',fullPage:false});
 }
 // 3. The film actually playing in each design (viewport frame), so the owner
 // sees the loading-only status and native controls, not just the poster.
 for(const theme of THEMES)for(const width of WIDTHS){
  await page.setViewportSize({width,height:width===390?844:1000});
  await page.goto(origin+'/property/visual-design?theme='+theme,{waitUntil:'networkidle'});
  await page.locator('#property-video-play').click();
  await page.waitForFunction(()=>document.getElementById('property-video').currentTime>.5);
  assert.equal(await page.locator('#property-video').evaluate(v=>v.videoWidth),1920,'Film decodes at 1080p');
  const status=await page.locator('#property-video-status').textContent();
  assert.equal(status==='',theme!=='basic',theme+' playing status is silent only on premium designs');
  await page.locator('#property-video').evaluate(v=>v.pause());
  await capture(theme+'-'+width+'-playing',{theme,pageName:'home (film playing)',width,mode:'playing',fullPage:false});
 }
 assert.deepEqual(failures,[]);

 // 4. One self-contained contact sheet. Inline JPEGs; the PNGs sit beside it.
 const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
 const groups=[['Published websites — Home','published','home'],['Published websites — Gallery','published','gallery'],['Published websites — Location','published','location'],['Published websites — Contact','published','contact'],['Film playing (viewport frame)','playing','home (film playing)'],['Design preview chrome (Studio link target)','preview','home']];
 const cell=c=>`<figure class="cap" data-width="${c.width}"><figcaption><b>${esc(c.design)}</b> · ${esc(c.pageName)} · ${c.width}px<span>${esc(c.png)} · ${(c.bytes/1024).toFixed(0)} kB</span></figcaption><a href="#" class="zoom" title="Toggle actual size"><img loading="lazy" src="${c.data}" alt="${esc(c.design)} ${esc(c.pageName)} at ${c.width}px"></a></figure>`;
 const section=([title,mode,pageName])=>{const rows=WIDTHS.map(width=>`<div class="row"><h3>${width===390?'iPhone · 390px':'Desktop · 1440px'}</h3><div class="cols">${THEMES.map(theme=>cell(captures.find(c=>c.theme===theme&&c.mode===mode&&c.pageName===pageName&&c.width===width))).join('')}</div></div>`).join('');return `<section><h2>${esc(title)}</h2>${rows}</section>`;};
 const sheet=`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Rendprop property website design review</title>
<style>
:root{color-scheme:light;--ink:#1c1b19;--dim:#6b665d;--line:#e3dfd6;--paper:#fbfaf7}
body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
header{padding:40px 32px 24px;border-bottom:1px solid var(--line)}h1{margin:0 0 8px;font-size:28px;letter-spacing:-.02em}header p{margin:4px 0;color:var(--dim);max-width:80ch}
nav{display:flex;flex-wrap:wrap;gap:8px 18px;padding:14px 32px;border-bottom:1px solid var(--line);position:sticky;top:0;background:rgba(251,250,247,.92);backdrop-filter:blur(12px);font-size:13px}nav a{color:var(--ink)}
section{padding:28px 32px;border-bottom:1px solid var(--line)}h2{margin:0 0 12px;font-size:20px}h3{margin:18px 0 10px;font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:var(--dim)}
.cols{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:20px;align-items:start}
.cap{margin:0;border:1px solid var(--line);background:#fff;border-radius:10px;overflow:hidden}
figcaption{padding:10px 12px;font-size:13px;border-bottom:1px solid var(--line)}figcaption span{display:block;color:var(--dim);font-size:11px}
.cap img{display:block;width:100%;height:auto}.cap[data-width="390"] img{max-width:390px;margin:0 auto}
.cap.actual{grid-column:1/-1}.cap.actual img{width:auto;max-width:none}.cap.actual .zoom{display:block;overflow:auto;max-height:90vh}
.legend{font-size:13px;color:var(--dim)}
@media(max-width:1100px){.cols{grid-template-columns:1fr}}
</style></head><body>
<header><h1>Property website designs — owner review sheet</h1>
<p><b>Classic</b> (included) beside the two $25 designs, <b>Signature Estate</b> and <b>Coastal Luxe</b>, rendered by the real tour-host renderer at the commit below. Every page, both widths, from one closed local run — nothing was deployed and no account, phone, purchase or provider was used.</p>
<p class="legend">Fixture: Rendprop's own hosted demo estate (1180 Crestline Ridge; the same photos served at /f/estate-demo). Hero film: ${esc(FILM_SECONDS)} s of local ${esc(codec.toUpperCase())} test motion made from the demo poster. Nearby places: a labelled OpenStreetMap-shaped fixture. Click any capture to toggle actual size. Generated ${new Date().toISOString()}; src hashes in receipt.json.</p></header>
<nav>${groups.map(([title])=>`<a href="#${esc(title.replace(/\W+/g,'-').toLowerCase())}">${esc(title)}</a>`).join('')}</nav>
${groups.map(group=>section(group).replace('<section>','<section id="'+esc(group[0].replace(/\W+/g,'-').toLowerCase())+'">')).join('')}
<script>document.querySelectorAll('.zoom').forEach(function(a){a.addEventListener('click',function(e){e.preventDefault();a.closest('.cap').classList.toggle('actual');});});</script>
</body></html>`;
 writeFileSync(join(evidence,'DESIGN-REVIEW-SHEET.html'),sheet);
 writeFileSync(join(evidence,'receipt.json'),JSON.stringify({passed:true,scope:'Visual QA of all three website designs with Rendprop demo-estate photos and local 1080p photo motion. Not one customer listing, not a paid AI model result, not a customer/phone/purchase test.',sourceHashes,codec,fixturePhotos:Object.fromEntries(GALLERY.map(g=>[g.url,createHash('sha256').update(readFileSync(join(assetRoot,basename(g.url)))).digest('hex')])),movie:{sha256:createHash('sha256').update(movie).digest('hex'),width:video.width,height:video.height,codec:video.codec_name,duration:video.duration},captures:captures.map(({data,...rest})=>rest),metrics,failures,network:[...new Set(network)],sheet:'DESIGN-REVIEW-SHEET.html',sheetBytes:Buffer.byteLength(sheet)},null,2));
 console.log(`Property design review: ${captures.length} captures (3 designs × 4 pages × 2 widths published, + preview chrome + film playing); sheet ${join(evidence,'DESIGN-REVIEW-SHEET.html')} (${(Buffer.byteLength(sheet)/1048576).toFixed(1)} MB)`);
}finally{if(browser)await browser.close();if(server)await new Promise(resolve=>server.close(resolve));}
