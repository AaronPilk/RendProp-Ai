import assert from 'node:assert/strict';
import {buildSrc} from './build-src.mjs';
const load=buildSrc('property-seo-'+process.pid);
const {propertyAddressPath,propertyAddressSlug}=await load('property-seo');
const {renderTourPage,unbrandedSelfCheck}=await load('player');
const {buildDemoTour}=await load('demo');
const {default:worker}=await load('index');
let assertions=0;const check=(value,message)=>{assertions++;assert.ok(value,message);};
const slug='seo-fixture-A_1',address='4816 Kelly Woods Ln, Charlotte, NC';
const path=propertyAddressPath(slug,address);
check(path==='/property/4816-kelly-woods-ln-charlotte-nc/seo-fixture-A_1','Readable address and stable publication identity');
check(propertyAddressPath('another-id',address)!==path,'Equal addresses never collide');
check(propertyAddressSlug('Élan / </script> & Suite #2')==='elan-script-suite-2','Descriptor cannot introduce markup or route separators');
check(propertyAddressSlug('x'.repeat(500)).length===120,'Descriptor length is bounded');
assert.throws(()=>propertyAddressPath('../different-property',address));assertions++;
let current={...buildDemoTour(),slug,share_url:'https://rendprop.com/f/'+slug,published_at:'2026-10-14T12:00:00Z',
 listing:{...buildDemoTour().listing,address,details:{...buildDemoTour().listing.details,allow_indexing:true}},
 listing_video:{url:'https://media.fixture.invalid/listing.mp4',poster_url:'https://media.fixture.invalid/poster.jpg',width:1920,height:1080,duration_s:22,branding_policy:'unbranded',disclosure:'Photo-based property video.'},duration_s:9};
const canonical='https://rendprop.com'+path;
for(const page of ['home','gallery','location','contact']){
 const html=renderTourPage(current,'https://edge.fixture.invalid','inert-public','',{origin:'https://rendprop.com',page,addressUrls:true});
 const pageUrl=canonical+(page==='home'?'':'?page='+page);
 check(html.includes(`rel="canonical" href="${pageUrl}"`),page+' has its own canonical');
 check(html.includes(`property="og:url" content="${pageUrl}"`),page+' shares accurate page identity');
 for(const target of ['home','gallery','location','contact'])check(html.includes(`href="${path}${target==='home'?'':'?page='+target}"`),page+' has crawlable '+target+' navigation');
 check(!html.includes('name="robots" content="noindex'),page+' opted-in public page can be indexed');
 if(page==='home'){
  const graph=JSON.parse(html.match(/<script type="application\/ld\+json">(.*?)<\/script>/s)[1])['@graph'];
  const video=graph.find(node=>node['@type']==='VideoObject');
  check(video.contentUrl===current.listing_video.url,'Structured video is the visible property video');
  check(video.duration==='PT22S','Structured duration matches visible video, not separate recorded tour');
  check(!video.embedUrl,'No false embed that actually plays a different recorded video');
 }else check(!html.includes('"@type":"VideoObject"'),page+' does not claim an unseen video');
}
for(const opts of [{unbranded:true},{previewTheme:'signature-estate'}]){
 const html=renderTourPage(current,'https://edge.fixture.invalid','inert-public','',{origin:'https://rendprop.com',addressUrls:true,...opts});
 check(html.includes('name="robots" content="noindex'),'Unbranded/preview remains excluded');
 check(!html.includes('application/ld+json'),'Unbranded/preview exposes no indexed property graph');
 if(opts.unbranded)check(unbrandedSelfCheck(html,current).length===0,'Unbranded SEO changes remain MLS-safe');
}
const env={SUPABASE_FUNCTIONS_URL:'https://edge.fixture.invalid/functions/v1',SUPABASE_ANON_KEY:'inert-public'},ctx={waitUntil(){},passThroughOnException(){}};
globalThis.caches={default:{async match(){return null;},async put(){throw new Error('Customer HTML must not enter cache');}}};
let status=200,calls=0;
globalThis.fetch=async(url,init)=>{calls++;assert.equal(url,env.SUPABASE_FUNCTIONS_URL+'/tours/'+slug);assert.equal(init.cache,'no-store');return new Response(status===200?JSON.stringify(current):'not published',{status});};
const get=(target)=>worker.fetch(new Request('https://rendprop.com'+target),env,ctx);
for(const short of ['/f/'+slug,'/property/'+slug]){const response=await get(short);check(response.status===200,'Existing shared links still work');check((await response.text()).includes(`rel="canonical" href="${canonical}"`),'Old link names the readable canonical');}
check((await get(path)).status===200,'Readable property path serves actual current authority');
let response=await get('/property/old-address/'+slug+'?page=gallery');
check(response.status===308 && response.headers.get('location')===canonical+'?page=gallery','Changed address preserves same property and selected page');
check(response.headers.get('cache-control')==='no-store','Address redirect cannot survive revocation');
status=404;response=await get('/property/old-address/'+slug);
check(response.status===404 && !response.headers.has('location'),'Unpublished property cannot disclose its new address');
check(!(await response.text()).includes(address),'Unpublished response contains no private address');
status=200;current={...current,listing:{...current.listing,details:{...current.listing.details,allow_indexing:false}}};
response=await get(path);const html=await response.text();
check(response.headers.get('x-robots-tag')==='noindex, nofollow' && html.includes('noindex, nofollow'),'No automatic indexing of unanswered/private search preference');
check(!html.includes('application/ld+json'),'Opted-out page has no machine-readable identity graph');
check(calls===6,'Every real property request uses the fresh publication authority');
const {propertySitemapCursors,propertySitemapXml}=await load('sitemap');
const cursor='12345678-1234-4567-89ab-123456789abc';
const pages={page_size:200,pages:[{cursor:null},{cursor}],truncated:false};
const publicRows={tours:[{slug,address,published_at:'2026-10-14T12:00:00Z',allow_indexing:true}],portfolios:[],next_cursor:null};
let indexValue=pages,pageValue=publicRows,indexStatus=200;
globalThis.fetch=async(url,init)=>{
 check(init.cache==='no-store','Sitemap metadata also uses fresh publication authority');
 check(url.startsWith(env.SUPABASE_FUNCTIONS_URL+'/tours/index?'),'Index cannot dispatch a foreign API');
 return new Response(JSON.stringify(url.includes('pages=1')?indexValue:pageValue),{status:indexStatus});
};
response=await get('/sitemap.xml');let xml=await response.text();
check(response.status===200&&xml.includes('<sitemapindex'),'Actual Worker emits a sitemap index');
check(xml.includes('https://rendprop.com/sitemap-site.xml')&&xml.includes('sitemap-properties.xml?cursor='+cursor),'Index has marketing and each bounded customer page');
check(response.headers.get('cache-control')==='no-store','Customer index cannot cache revoked publications');
response=await get('/sitemap-properties.xml?cursor='+cursor);xml=await response.text();
check(response.status===200&&xml.includes('<loc>'+canonical+'</loc>'),'Child emits readable current public identity');
check(xml.includes('<lastmod>2026-10-14</lastmod>'),'Child uses actual publication date');
check(!xml.includes('/u/')&&!xml.includes('preview_theme')&&!xml.includes('agent_card'),'No unbranded, preview or contact metadata');
check(response.headers.get('cache-control')==='no-store','Customer child cannot cache stale public addresses');
for(const bad of ['/sitemap.xml?cursor='+cursor,'/sitemap-properties.xml?cursor=private-address','/sitemap-properties.xml?cursor='+cursor+'&cursor='+cursor]){
 check((await get(bad)).status===400,'Malformed/repeated cursors refuse before metadata fetch');
}
for(const bad of [{...pages,truncated:true},{...pages,page_size:201},{...pages,pages:[{cursor}]},{...pages,pages:[{cursor:null},{cursor:null}]},{...pages,pages:Array.from({length:251},(_,i)=>({cursor:i?cursor:null}))}]){
 check(propertySitemapCursors(bad)===null,'Invalid/truncated index refuses as a whole');
 indexValue=bad;check((await get('/sitemap.xml')).status===503,'Actual Worker never calls an incomplete index successful');
}
indexValue=pages;
for(const row of [{...publicRows.tours[0],allow_indexing:false},{...publicRows.tours[0],slug:'../private'}, {...publicRows.tours[0],published_at:'not-a-date'}, {...publicRows.tours[0],address:{private:true}}]){
 pageValue={...publicRows,tours:[row]};check(propertySitemapXml('https://rendprop.com',pageValue)===null,'Invalid or opted-out publication refuses as a whole');
 check((await get('/sitemap-properties.xml')).status===503,'Worker never exposes a malformed private fallback');
}
pageValue={...publicRows,tours:[]};response=await get('/sitemap-properties.xml');xml=await response.text();
check(response.status===200&&!xml.includes(address),'Publication withdrawal removes its address on next request');
indexStatus=503;response=await get('/sitemap.xml');check(response.status===503&&response.headers.get('cache-control')==='no-store','Upstream outage is explicit and cannot preserve private data');
response=await get('/sitemap-site.xml');check(response.status===200&&(await response.text()).includes('https://rendprop.com/pricing'),'Marketing/demo child remains available without database authority');
console.log(`Property SEO: ${assertions} actual-renderer/Worker checks passed; closed publication transport, no live SEO claims.`);
