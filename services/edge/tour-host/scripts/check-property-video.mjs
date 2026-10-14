// Actual Worker/renderer and actual shipped player JS. All media, publication,
// DOM and network boundaries are synthetic; no customer/provider calls.
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { buildSrc } from './build-src.mjs';
const load = buildSrc('property-video-check-' + process.pid);
const { renderTourPage, unbrandedSelfCheck } = await load('player');
const { buildDemoTour } = await load('demo');
const { listingVideo, PROPERTY_VIDEO_JS } = await load('property-video');
const { default: worker } = await load('index');
let checks = 0;
const check = (condition, label) => { checks++; assert.ok(condition, label); };
const spec = () => ({ url:'/media/published/master.mp4',poster_url:'/media/published/poster.jpg',duration_s:45,width:1920,height:1080,branding_policy:'unbranded',disclosure:'AI motion from owner-selected photos. Compare the published original photos.' });
const fixture = () => ({ ...buildDemoTour(), slug:'synthetic-video',listing_video:spec(),website_theme:'basic',published_at:'2026-01-01T00:00:00Z',
  listing:{...buildDemoTour().listing,address:'123 Synthetic <script>private()</script>',details:{story:'Actual published description.',show_partners:false,show_app_cta:false,reel_url:'https://unverified.invalid/not-selected.mp4',website_theme:'coastal-luxe',premium_unlocked:true}},
  cover_url:'/published-cover.jpg',gallery:[{url:'/published-photo.jpg',label:'Actual selected photo'}],
  cta:{mode:'lead_form',label:'Request showing',lead_fields:['message'],secondary:[],url:null},
  agent_card:{name:'Synthetic Contact',email:'contact@example.invalid',phone:'555-010-1000'},
});
const env={SUPABASE_FUNCTIONS_URL:'https://publication-fixture.invalid/functions/v1',SUPABASE_ANON_KEY:'synthetic-public-anon'};
const ctx={waitUntil(){},passThroughOnException(){}};
let current=fixture(),upstreamStatus=200,reads=0,cacheReads=0;
globalThis.caches={default:{async match(){cacheReads++;return undefined;},async put(){throw new Error('Customer/preview HTML cannot enter cache');}}};
globalThis.fetch=async(url,init)=>{reads++;assert.equal(url,env.SUPABASE_FUNCTIONS_URL+'/tours/synthetic-video');assert.equal(init.cache,'no-store');return new Response(upstreamStatus===200?JSON.stringify(current):'unpublished',{status:upstreamStatus});};
const get=path=>worker.fetch(new Request('https://rendprop.com'+path),env,ctx);
function cfg(html){return JSON.parse(html.match(/window\.__CFG__=(.*?);<\/script>/s)[1]);}

for(const theme of ['basic','signature-estate','coastal-luxe']){
  const tour=fixture();tour.website_theme=theme;
  for(const page of ['home','gallery','location','contact']){
    const html=renderTourPage(tour,env.SUPABASE_FUNCTIONS_URL,'synthetic-anon','',{page,publicBase:'/property'});
    check(html.includes('site-theme-'+theme),theme+' is server-selected on '+page);
    check(!/<video[^>]*\ssrc=/i.test(html),'No video source before a tap on '+page);
    check(!html.includes('autoplay'),'No unsolicited autoplay on '+page);
    check(!html.includes('https://unverified.invalid'),'Client details cannot select a media master');
    check(cfg(html).listingVideo.url===spec().url,'Actual selected master is retained in config');
    check(html.includes('123 Synthetic &lt;script&gt;private()&lt;/script&gt;'),'Property data is escaped');
    check(html.includes('AI motion from owner-selected photos.'),'Selected video disclosure remains on every page');
    if(page==='home'){
      check(html.includes('id="property-video" preload="none" playsinline'),'Home has normal opt-in primary video');
      check(html.indexOf('id="property-video"')<html.indexOf('id="overview"'),'Primary video precedes description');
      check(html.includes('Optional recorded walkthrough')&&html.includes('id="property-video-nav-play"'),'Primary normal playback precedes the optional recorded walkthrough');
      check(html.includes('poster="/media/published/poster.jpg"'),'Hero uses its selected poster');
    }else check(!html.includes('id="property-video"'),'Other pages do not instantiate the master');
    if(page==='contact')check(html.includes('id="leadform"'),'Published contact still has the genuine enquiry form');
    for(const [,script]of html.matchAll(/<script>([\s\S]*?)<\/script>/g)){new vm.Script(script);checks++;}
  }
}
const raw=fixture();delete raw.website_theme;
check(renderTourPage(raw,'','','').includes('site-theme-basic'),'Raw details premium flags grant no published theme');
raw.website_theme='javascript:private()';
check(renderTourPage(raw,'','','').includes('site-theme-basic'),'Unknown typed theme fails to basic');
for(const invalid of [null,{...spec(),url:'javascript:private()'},{...spec(),width:1080,height:1920},{...spec(),width:1280,height:720},{...spec(),height:1081},{...spec(),duration_s:NaN},{...spec(),duration_s:7201},{...spec(),width:1920.5}]){
  check(listingVideo(invalid)===null,'Unsafe, non-landscape, low-quality or malformed master is refused');
  check(!renderTourPage({...fixture(),listing_video:invalid},'','','').includes('id="property-video"'),'Invalid master preserves usable photo fallback');
}
check(listingVideo({...spec(),width:3840,height:2160}).width===3840,'A verified 4K master is not resolution-capped');
check(!renderTourPage(fixture(),'','','',{embed:true}).includes('id="property-video"'),'Embedded recorded walkthrough remains compatible');
const mls=renderTourPage(fixture(),env.SUPABASE_FUNCTIONS_URL,'synthetic','',{unbranded:true});
check(unbrandedSelfCheck(mls,fixture()).length===0,'Selected video remains MLS unbranded safe');
check(mls.includes('id="property-video"')&&!mls.includes('<form'),'MLS retains server-policy unbranded property video without contact');
for(const policy of [undefined,null,'branded',true]){const unknown={...fixture(),listing_video:{...spec(),branding_policy:policy}};unknown.listing.details.branding_policy='unbranded';const html=renderTourPage(unknown,'','','',{unbranded:true});check(!html.includes('id="property-video"')&&cfg(html).listingVideo===null,'Unknown/branded policy cannot admit a master on MLS via client details');}
const photoOnly=fixture();photoOnly.video_url=photoOnly.scrub_url=photoOnly.hls_url=null;photoOnly.chapters=[];
check(renderTourPage(photoOnly,'','','').includes('id="property-video"')&&!/<button[^>]*data-open-flythrough/.test(renderTourPage(photoOnly,'','','')),'Photo-video-only publication does not require a recorded walkthrough');

for(const theme of ['basic','signature-estate','coastal-luxe'])for(const page of ['home','gallery','location','contact']){
  const suffix=(page==='home'?'':'page='+page+'&')+'preview_theme='+theme;
  current=fixture();current.listing.details.search_indexing=true;
  const before=reads,response=await get('/property/synthetic-video?'+suffix),html=await response.text();
  check(response.status===200&&reads===before+1,'Preview reads fresh publication');
  check(response.headers.get('cache-control')==='no-store'&&response.headers.get('x-robots-tag')==='noindex, nofollow','Preview cannot be cached/indexed');
  check(html.includes('site-preview')&&html.includes('DESIGN PREVIEW')&&html.includes('Design preview'),'Preview is visibly labeled');
  check(!html.includes('<form')&&!html.includes('id="leadform"')&&!html.includes('application/ld+json'),'Preview contains no enquiry form or structured indexing data');
  check(!html.includes('navigator.share')&&!html.includes('rp_wanted_tour')&&!html.includes('challenges.cloudflare.com'),'Preview contains no share/app handoff/Turnstile flow');
  check(cfg(html).preview===true&&cfg(html).listingVideo.url===spec().url,'Preview uses exact authorized media, never fake template data');
  for(const target of ['home','gallery','location','contact']){
    const query=(target==='home'?'':'page='+target+'&amp;')+'preview_theme='+theme;
    check(html.includes('href="/property/synthetic-video?'+query+'"'),'Preview navigation retains alias and chosen style');
  }
  upstreamStatus=404;const revoked=await get('/property/synthetic-video?'+suffix);
  check(revoked.status===404&&!(await revoked.text()).includes('123 Synthetic'),'Revoked listing has no remaining preview');upstreamStatus=200;
}
current=fixture();const invalidPreview=await get('/property/synthetic-video?theme=coastal-luxe&premium_unlocked=true&preview_theme=unknown');
const invalidHtml=await invalidPreview.text();
check(invalidHtml.includes('site-theme-basic')&&!/<body[^>]*class="[^"]*site-preview/.test(invalidHtml)&&invalidHtml.includes('id="leadform"'),'Arbitrary query flags cannot unlock or change published style');
check(cacheReads===0,'Customer preview and normal HTML never read stale cache');
current={...fixture(),space_type:'venue'};const nonProperty=await get('/property/synthetic-video?preview_theme=coastal-luxe');
check(nonProperty.status===404&&!(await nonProperty.text()).includes('<form'),'Non-property data cannot produce an unlabeled preview with a live form');

// Run the exact browser player source against a controllable media element.
async function exercise(script,{preview=false,fail=false,late=false}={}){
  const handlers={},globalHandlers={},timers=new Map(),requests=[],classes=new Set();let timerID=0,loads=0,plays=0,pauses=0,time=1000,rejectLate;
  const video={src:'',paused:true,ended:false,seeking:false,readyState:0,duration:45,currentTime:0,preload:'none',controls:false,
    buffered:{length:0,start(){return 0;},end(){return 5;}},parentElement:{classList:{add(x){classes.add(x);},remove(x){classes.delete(x);}}},
    addEventListener(n,cb){handlers[n]=cb;},removeAttribute(n){if(n==='src')this.src='';},load(){loads++;},pause(){pauses++;this.paused=true;handlers.pause?.();},
    play(){plays++;if(late)return new Promise((_,reject)=>{rejectLate=reject;});if(fail){fail=false;return Promise.reject(new Error('synthetic denied'));}this.paused=false;this.readyState=4;handlers.playing?.();return Promise.resolve();},
  };
  const button={hidden:false,textContent:'Play property video',addEventListener(n,cb){handlers['button.'+n]=cb;}},status={textContent:''};
  const doc={hidden:false,getElementById(id){return {'property-video':video,'property-video-play':button,'property-video-status':status}[id]||null;},addEventListener(n,cb){globalHandlers[n]=cb;}};
  const context={window:{__CFG__:{listingVideo:spec(),slug:'synthetic-video',functionsBase:env.SUPABASE_FUNCTIONS_URL,preview}},document:doc,performance:{now(){return time;}},navigator:{sendBeacon(url,body){requests.push({url,body});return true;}},Blob,
    addEventListener(n,cb){globalHandlers[n]=cb;},setTimeout(cb){timers.set(++timerID,cb);return timerID;},clearTimeout(id){timers.delete(id);},fetch(){throw new Error('Unexpected fixture fetch');}};
  vm.runInNewContext(script,context);
  assert.equal(video.src,'','Initialization cannot download a master');assert.equal(plays,0,'Initialization cannot autoplay');
  const click=async()=>{handlers['button.click']();await Promise.resolve();await Promise.resolve();};
  await click();
  if(button.textContent==='Retry property video'){
    assert.equal(video.src,'','Failed playback releases background downloads');
    const oldLoads=loads;await click();assert.ok(loads>oldLoads,'Retry actually reloads the failed master');
  }
  assert.equal(video.src,spec().url,'Only exact chosen master is attached');assert.equal(video.controls,true,'Normal native video controls are exposed');
  if(late){globalHandlers.pagehide();rejectLate(new Error('stale play rejection'));await Promise.resolve();assert.equal(button.textContent,'Play property video ▶','Late promise cannot overwrite a newer page lifecycle');return;}
  assert.equal(button.hidden,true,'Tap starts playback without a modal or swipe');
  video.currentTime=10;video.buffered.length=1;time+=500;handlers.timeupdate();handlers.progress();
  globalHandlers['property:walkthrough-open']();assert.equal(video.paused,true,'Opening optional walkthrough pauses primary video');
  globalHandlers.pagehide();assert.equal(video.src,'','Navigation releases media decoder/source');assert.equal(video.preload,'none','Navigation returns media to opt-in loading');assert.equal(button.hidden,false,'Back-forward restored page retains usable Play button');
  if(preview)assert.equal(requests.length,0,'Preview viewing cannot create analytics/billing beacons');else assert.ok(requests.length>0,'Published watch/delivery is accounted through existing beacon');
  await click();assert.equal(video.src,spec().url,'Restored page can replay after explicit tap');assert.ok(plays>=2);
}
await exercise(PROPERTY_VIDEO_JS);checks+=11;
await exercise(PROPERTY_VIDEO_JS,{preview:true});checks+=11;
await exercise(PROPERTY_VIDEO_JS,{fail:true});checks+=12;
await exercise(PROPERTY_VIDEO_JS,{late:true});checks+=6;
const mutants=[
  ['eager download',PROPERTY_VIDEO_JS.replace("  function playPropertyVideo(){","  video.src=spec.url;\n  function playPropertyVideo(){"),{},/Initialization cannot download/],
  ['preview beacon',PROPERTY_VIDEO_JS.replace('if(CFG.preview || !viewed','if(!viewed'),{preview:true},/Preview viewing cannot/],
  ['retain media',PROPERTY_VIDEO_JS.replace("generation++;clearTimeout(deadline);video.pause();video.removeAttribute('src');video.preload='none'","generation++;clearTimeout(deadline);video.pause();video.preload='none'"),{},/Navigation releases media/],
  ['failed download retention',PROPERTY_VIDEO_JS.replace("attached=false;video.removeAttribute('src');video.preload='none';video.load();button.hidden=false","attached=false;button.hidden=false"),{fail:true},/Failed playback releases background/],
  ['stale play rejection',PROPERTY_VIDEO_JS.replace('if(token===generation)failure();','failure();'),{late:true},/Late promise cannot/],
];
for(const [name,script,options,pattern]of mutants){assert.notEqual(script,PROPERTY_VIDEO_JS,name+' mutation binds shipped source');await assert.rejects(exercise(script,options),pattern,name+' must fail intended product assertion');checks++;}
console.log(`Property video/design: ${checks} assertions; 5 runtime negative controls rejected; actual renderer/Worker/player, closed synthetic boundaries.`);
