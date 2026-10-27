// Actual renderer/layout checks; localhost and synthetic film only, no API.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,readdirSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import ts from 'typescript';
import {chromium} from '../node_modules/@playwright/test/index.mjs';
import {premiumPreview} from './preview-premium-luxury.mjs';
import {ROOT} from './build-src.mjs';
const output=resolve(process.argv.find(a=>a.startsWith('--evidence='))?.split('=').slice(1).join('=')||'../../../luxury-proof');mkdirSync(output,{recursive:true});
const checks=[],measurements=[];const check=(x,label)=>{assert.ok(x,label);checks.push(label)};
const {server,origin,load,retained}=await premiumPreview();const {renderTourPage}=await load('player'),{buildDemoTour}=await load('demo'),{PROPERTY_DESIGN_CSS}=await load('property-design');
// The pushed parent of the initial handoff commit is available in a full clone.
// Classic and MLS rendering must remain identical across the luxury redesign.
const PRESENTATION_BASELINE='6fc7485a1aae7b8354fd7c21ff2a01e71c3e1376';
// The later shared navigation fix moved this custom property from <html> to
// <body>. Permit exactly that separately committed change while keeping the
// Classic/MLS comparison against the pre-redesign presentation baseline.
const OFFSET_BEFORE="document.documentElement.style.setProperty('--listing-nav-offset',(Math.ceil(Math.max(navHeight,previewHeight))+16)+'px');";
const OFFSET_AFTER="document.body.style.setProperty('--listing-nav-offset',(Math.ceil(Math.max(navHeight,previewHeight))+16)+'px');";
const oldListingPlayer=execFileSync('git',['show',PRESENTATION_BASELINE+':services/edge/tour-host/src/listing-player.ts'],{cwd:ROOT,encoding:'utf8'});
check(oldListingPlayer.includes(OFFSET_BEFORE)&&readFileSync(join(ROOT,'src/listing-player.ts'),'utf8')===oldListingPlayer.replace(OFFSET_BEFORE,OFFSET_AFTER),'shared listing-player differs from pre-redesign baseline only by the verified navigation offset fix');
const baseline=join(output,'baseline-esm');mkdirSync(baseline,{recursive:true});writeFileSync(join(baseline,'package.json'),'{"type":"module"}');
for(const f of readdirSync(join(ROOT,'src')).filter(n=>n.endsWith('.ts'))){const s=execFileSync('git',['show',PRESENTATION_BASELINE+':services/edge/tour-host/src/'+f],{cwd:ROOT,encoding:'utf8',stdio:['ignore','pipe','pipe']});const js=ts.transpileModule(s,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext}}).outputText.replace(/(\bfrom\s*["'])(\.\.?\/[^"']+?)(["'])/g,(_,a,b,c)=>a+b+'.js'+c);writeFileSync(join(baseline,f.replace(/\.ts$/,'.js')),js)}
const before=await import(pathToFileURL(join(baseline,'player.js'))),oldDesign=await import(pathToFileURL(join(baseline,'property-design.js')));
for(const t of[retained.tour,buildDemoTour()])for(const page of['home','gallery','location','contact'])for(const unbranded of[false,true]){const opts={origin,page,unbranded};const after=renderTourPage({...t,website_theme:'basic'},'/closed-api','','',opts).replace(PROPERTY_DESIGN_CSS,'__PAID_CSS__');const prior=before.renderTourPage({...t,website_theme:'basic'},'/closed-api','','',opts).replace(oldDesign.PROPERTY_DESIGN_CSS,'__PAID_CSS__');assert.equal(prior.split(OFFSET_BEFORE).length-1,1,'historical Classic/MLS HTML contains exactly one shared navigation offset');check(after===prior.replace(OFFSET_BEFORE,OFFSET_AFTER),`Classic/MLS markup+scripts+shared CSS exact, apart from verified navigation offset fix: ${t.slug}/${page}/${unbranded}`)}
for(const file of['property-site.ts','property-video.ts']){const old=execFileSync('git',['show',PRESENTATION_BASELINE+':services/edge/tour-host/src/'+file],{cwd:ROOT});check(old.equals(readFileSync(join(ROOT,'src',file))),file+' byte-exact handoff parent')}
const browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
try{
 for(const theme of['signature-estate','coastal-luxe'])for(const width of[390,1497])for(const rich of[false,true]){
  const context=await browser.newContext({viewport:{width,height:width===390?844:759},reducedMotion:'reduce'});const requests=[];
  await context.route('**/*',route=>{const r=route.request(),u=new URL(r.url());requests.push({url:r.url(),type:r.resourceType()});return u.origin===origin||u.protocol==='data:'||(r.resourceType()==='image'&&['pub-70303ef2ff484a179c03ff19b26aa63d.r2.dev','rendprop.com'].includes(u.hostname))?route.continue():route.abort()});
  const p=await context.newPage();const errors=[];p.on('pageerror',e=>errors.push(String(e)));
  const base=origin+'/property/'+(rich?'estate-demo':retained.tour.slug)+'?preview_theme='+theme+(rich?'&fixture=rich':'');await p.goto(base,{waitUntil:'networkidle'});
  const tag=theme+'-'+width+'-'+(rich?'synthetic-listing-film':'actual855-recorded-only');
  const geometry=await p.evaluate(()=>{const box=s=>{const e=document.querySelector(s);return e?e.getBoundingClientRect().toJSON():null};return{title:box('.property-hero-title'),price:box('.property-hero-price'),actions:box('.listing-cover-actions'),copy:box('.property-hero-copy'),media:box('.property-hero-media'),overflow:document.documentElement.scrollWidth>innerWidth,contact:getComputedStyle(document.querySelector('.property-hero-contact')).backgroundColor,buttons:[...document.querySelectorAll('.listing-cover-actions a,.listing-cover-actions button')].map(e=>({height:e.getBoundingClientRect().height,radius:getComputedStyle(e).borderRadius}))}});measurements.push({tag,...geometry});
  const firstScreen=width===390?844:759;
  check(!geometry.overflow,tag+' no horizontal overflow');check(geometry.title.y>=0&&geometry.price.bottom<firstScreen-8&&geometry.actions.bottom<firstScreen-8,tag+' actual identity/price/all hero actions visible firstscreen '+JSON.stringify({title:geometry.title,price:geometry.price,actions:geometry.actions}));check(geometry.buttons.every(b=>b.height>=44&&parseFloat(b.radius)>=44),tag+' capsule actions at least44px');check(geometry.contact!=='rgba(0, 0, 0, 0)',tag+' enquiry is discoverable filled capsule');
  for(const summary of await p.locator('.disc-sum').all())check(await summary.evaluate(e=>e.getBoundingClientRect().height>=44&&parseFloat(getComputedStyle(e).borderRadius)>=44),tag+' disclosures keep44px capsule target and unchanged details action');
  check(await p.locator('form').count()===0&&await p.locator('.property-preview-banner').isVisible(),tag+' preview remains labelled with no enquiry side effects');
  if(rich){const v=p.locator('#property-video');check(await v.count()===1&&await v.getAttribute('src')===null&&await v.getAttribute('preload')==='none'&&await v.getAttribute('autoplay')===null,tag+' actual accepted Listing hero stays explicit-play/no autoplay');check(await p.locator('.property-recorded-option [data-open-flythrough]').count()===1,tag+' recorded walkthrough remains a separate action');check(await v.evaluate(e=>getComputedStyle(e).objectFit)==='contain',tag+' full Listing frame remains contain');await p.locator('#property-video-play').click();await p.waitForFunction(()=>document.getElementById('property-video').getAttribute('src'));check((await v.getAttribute('src')).includes('/local-fixture/synthetic-listing-8s.mp4'),tag+' hero play loads exact synthetic Listing master');check(await v.evaluate(e=>e.controls),tag+' real video playback exposes native controls');await p.waitForFunction(()=>{const v=document.getElementById('property-video');return v.readyState>=2&&v.currentTime>0&&!v.paused},{timeout:15000});check(await v.evaluate(e=>e.videoWidth>0&&e.videoHeight>0&&e.currentTime>0),tag+' actual local Listing film decodes and plays after deliberate click');await v.evaluate(e=>e.pause());check(await p.locator('.property-recorded-option [data-open-flythrough]').count()===1,tag+' hero play does not substitute recorded video');}
  else{check(await p.locator('#property-video').count()===0&&await p.locator('.listing-cover [data-open-flythrough]').count()===1,tag+' recorded-only855 has no invented Listing film');check(await p.locator('#story,#features').count()===0,tag+' no invented story/features on sparse listing');}
  await p.screenshot({path:join(output,tag+'-viewport.png')});
  for(const img of await p.locator('#gallery img.property-thumb').all()){await img.scrollIntoViewIfNeeded();await img.evaluate(i=>i.complete&&i.naturalWidth>1?Promise.resolve():new Promise((r,j)=>{i.addEventListener('load',r,{once:true});i.addEventListener('error',()=>j(Error('fixture gallery image failed')),{once:true})}));}
  await p.evaluate(()=>scrollTo(0,0));
  await p.screenshot({path:join(output,tag+'-full.png'),fullPage:true});
  await p.goto(base+'&page=gallery',{waitUntil:'networkidle'});check(await p.locator('[data-property-photo]').count()===(rich?6:38),tag+' gallery retains every fixture image');
  if(!rich){const hrefs=await p.locator('[data-property-photo]').evaluateAll(xs=>xs.map(e=>e.getAttribute('href')));check(JSON.stringify(hrefs)===JSON.stringify(retained.tour.gallery.map(g=>g.url)),tag+'855 observed gallery order exact; first4 masterlinks retained');}
  if(width===390){const cdp=await context.newCDPSession(p);await cdp.send('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-transparency',value:'reduce'},{name:'prefers-reduced-motion',value:'reduce'}]});check(await p.locator('#listing-nav').evaluate(e=>getComputedStyle(e).backdropFilter)==='none',tag+' reduced transparency uses opaque material fallback');}
  check(!requests.some(r=>r.type==='fetch'&&!r.url.startsWith(origin)),tag+' no API/telemetry leaves localhost');check(errors.length===0,tag+' no pageJS error '+errors.join(';'));await context.close();
 }
 // Published-style geometry, without the preview banner: compact phones and
 // narrow landscape tablets must keep Play, identity, actions and navigation
 // reachable. The film stays unattached; no lead or provider request is made.
 const layoutTour=buildDemoTour();
 layoutTour.listing_video={url:'/local-fixture/synthetic-listing-8s.mp4',poster_url:'/assets/demo-poster.webp',duration_s:8,width:1920,height:1080,disclosure:'Synthetic photo-based film.',branding_policy:'unbranded'};
 for(const [theme,width,height] of [['signature-estate',320,568],['coastal-luxe',320,568],['coastal-luxe',768,600],['signature-estate',601,600],['coastal-luxe',601,600]]){
  const context=await browser.newContext({viewport:{width,height},reducedMotion:'reduce'});
  await context.route('**/*',route=>{const u=new URL(route.request().url());return u.origin===origin||u.protocol==='data:'?route.continue():route.abort()});
  await context.route(origin+'/property/layout-probe',route=>route.fulfill({status:200,contentType:'text/html',body:renderTourPage({...layoutTour,website_theme:theme},'/closed-api','','',{origin,publicBase:'/property'})}));
  const p=await context.newPage();await p.goto(origin+'/property/layout-probe',{waitUntil:'networkidle'});
  const geometry=await p.evaluate(()=>{
   const rect=s=>document.querySelector(s)?.getBoundingClientRect();
   const play=document.querySelector('#property-video-play'),playBox=play.getBoundingClientRect(),menu=document.querySelector('.property-page-menu');
   const hit=e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0&&e.contains(document.elementFromPoint(r.left+r.width/2,r.top+r.height/2))};
   return{playBottom:playBox.bottom,playLowerHit:play.contains(document.elementFromPoint(playBox.left+playBox.width/2,playBox.bottom-5)),eyebrowTop:rect('.property-hero-copy .lp-eyebrow')?.top,titleTop:rect('.property-hero-title')?.top,priceBottom:rect('.property-hero-price')?.bottom,actionsBottom:rect('.listing-cover-actions')?.bottom,menuVisible:menu&&getComputedStyle(menu).display!=='none'&&hit(menu.querySelector('summary')),pageLinksHidden:getComputedStyle(document.querySelector('.listing-nav-links')).display==='none',navActionsHit:[...document.querySelectorAll('#listing-nav .listing-nav-actions > a,#listing-nav .listing-nav-actions > button')].filter(e=>getComputedStyle(e).display!=='none').every(hit),overflow:document.documentElement.scrollWidth>innerWidth};
  });
  const tag=`${theme}-${width}x${height}-published-layout`;measurements.push({tag,...geometry});
  check(!geometry.overflow,tag+' has no horizontal overflow');
  if(theme==='signature-estate'&&width===320)check(geometry.playLowerHit&&geometry.eyebrowTop>=geometry.playBottom+4&&geometry.titleTop>=geometry.playBottom+4,tag+' Play stays fully tappable and clear of the property identity');
  if(theme==='coastal-luxe'&&(width===320||width===768))check(geometry.titleTop>=0&&geometry.priceBottom<height-8&&geometry.actionsBottom<height-8,tag+' identity, price and enquiry action fit the first screen');
  if(width>=601){check(geometry.menuVisible&&geometry.pageLinksHidden&&geometry.navActionsHit,tag+' compact navigation keeps every visible action independently hittable');await p.locator('.property-page-menu summary').click();check(await p.locator('.property-page-menu-links a[href*="page=contact"]').evaluate(e=>{const r=e.getBoundingClientRect();return e.contains(document.elementFromPoint(r.left+r.width/2,r.top+r.height/2))}),tag+' Contact is reachable through the compact page menu');}
  await context.close();
 }
 writeFileSync(join(output,'receipt.json'),JSON.stringify({passed:true,checks:checks.length,assertions:checks,measurements,sourceOnly:true,fixtureLimits:retained.lineage,liveAPI:0,publish:0},null,2)+'\n');console.log('Premium luxury: '+checks.length+' checks passed; Classic exact, both paid designs and separate Listing/recorded video through actual renderer.');
}finally{await browser.close();await new Promise(r=>server.close(r));}
