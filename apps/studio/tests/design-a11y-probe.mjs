#!/usr/bin/env node
// Prepared only: real App/components, closed fixture Auth/fetch, no provider use.
import assert from 'node:assert/strict';
import {mkdir,mkdtemp,readFile,writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {tmpdir} from 'node:os';
import {dirname,extname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {build} from 'vite';
import {chromium,expect} from '@playwright/test';
const args=Object.fromEntries(process.argv.slice(2).map(a=>{assert(a.startsWith('--')&&a.includes('='));const at=a.indexOf('=');return[a.slice(2,at),a.slice(at+1)];}));
assert(Object.keys(args).every(k=>['out','check','baseline-css'].includes(k)));
const mode=args.check??'all';assert(['all','close-targets','text-input','focus-control','contrast-control'].includes(mode));
assert(!args['baseline-css']||['close-targets','text-input'].includes(mode),'Historical CSS belongs only to the two target controls');
const root=fileURLToPath(new URL('../',import.meta.url));
const dir=await mkdtemp(join(tmpdir(),'rendprop-design-a11y-')),dist=join(dir,'dist');
const hash=x=>createHash('sha256').update(x).digest('hex');
const sourceFiles=['src/App.tsx','src/data/services.ts','src/styles.css','src/design/studio.css','src/features/home/Dashboard.tsx','tests/fixtures/connected.tsx','tests/fixtures/branded.tsx','tests/make-video-fixture.tsx','tests/design-a11y-probe.mjs'];
const sourceHashes=Object.fromEntries(await Promise.all(sourceFiles.map(async n=>[n,hash(await readFile(join(root,n)))])));
const report={status:'running',mode,startedAt:new Date().toISOString(),sourceHashes,checks:[],failures:[],errors:[],externalRequests:[],contrastUnmeasured:[],targetMeasurements:[],motion:[],artifacts:dir,proof:'Actual styled App/component fixtures; no live Auth, provider/model, export, upload or publication. Computed text contrast has explicit complex-background limits.'};
const pass=(name,detail)=>report.checks.push({name,detail});
const fail=(name,detail)=>report.failures.push({name,detail});
const views=['overview','properties','editor','creative','library','workspace','planner','noproperties'];
const LISTING='55555555-5555-4555-8555-555555555500';
let server,browser,changedBaseline=false;
// Full alpha compositing includes html. Gradients/images/material backdrops are
// reported as unmeasured, never silently counted as AA contrast passes.
function contrastRows(){
 const rgba=s=>{const m=s.match(/^rgba?\(([^)]+)\)$/);if(!m)return null;const v=m[1].replaceAll('/',' ').replaceAll(',',' ').trim().split(/\s+/).map(Number);return v.every(Number.isFinite)&&v.length>=3?{r:v[0],g:v[1],b:v[2],a:v[3]??1}:null;};
 const over=(f,b)=>{const a=f.a+b.a*(1-f.a);return a?{r:(f.r*f.a+b.r*b.a*(1-f.a))/a,g:(f.g*f.a+b.g*b.a*(1-f.a))/a,b:(f.b*f.a+b.b*b.a*(1-f.a))/a,a}:{r:0,g:0,b:0,a:0};};
 const lum=c=>[c.r,c.g,c.b].map(v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;}).reduce((s,v,i)=>s+v*[.2126,.7152,.0722][i],0);
 const rows=[];
 for(const el of document.querySelectorAll('button,a,p,span,small,label,h1,h2,h3,strong,summary,legend,li')){
  if(!el.getClientRects().length||getComputedStyle(el).visibility==='hidden')continue;
  if(![...el.childNodes].some(n=>n.nodeType===3&&n.textContent.trim()))continue;
  if(el.closest(':disabled,[aria-disabled="true"]'))continue;
  const cs=getComputedStyle(el),fg=rgba(cs.color),text=el.textContent.trim().slice(0,70);let acc={r:0,g:0,b:0,a:0},reason='';
  for(let node=el;node;node=node.parentElement){const s=getComputedStyle(node);if(Number(s.opacity)!==1||s.filter!=='none'){reason='opacity/filter compositing';break;}}
  for(let node=el;node&&!reason;node=node.parentElement){const s=getComputedStyle(node),bg=rgba(s.backgroundColor);if(s.backgroundImage!=='none'){reason='gradient/image background';break;}if(s.backdropFilter&&s.backdropFilter!=='none'||s.webkitBackdropFilter&&s.webkitBackdropFilter!=='none'){reason='material backdrop';break;}if(!bg){reason='unsupported computed background colour';break;}acc=over(acc,bg);if(acc.a>=.999999)break;}
  if(!fg||acc.a<.999999)reason||='unresolved colour/transparent backdrop';
  const size=parseFloat(cs.fontSize),large=size>=24||(size>=18.6667&&parseFloat(cs.fontWeight)>=700),required=large?3:4.5;
  if(reason){rows.push({text,reason,required,sample:el.dataset.probeContrast??null});continue;}const f=over(fg,acc),a=lum(f),b=lum(acc);rows.push({text,ratio:(Math.max(a,b)+.05)/(Math.min(a,b)+.05),required,size,large,sample:el.dataset.probeContrast??null});
 }
 return rows;
}
async function context(options={}){
 const c=await browser.newContext({serviceWorkers:'block',...options});
 await c.route('**/*',route=>{const u=new URL(route.request().url());if(u.origin===origin&&route.request().method()==='GET')return route.continue();if(/^[a-f0-9]{32}\.r2\.cloudflarestorage\.com$/.test(u.hostname)&&route.request().method()==='GET')return route.fulfill({status:200,contentType:'image/svg+xml',body:'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="9"><rect width="16" height="9" fill="#847393"/></svg>'});report.externalRequests.push(u.href);return route.abort();});
 c.on('page',p=>p.on('pageerror',e=>report.errors.push(e.message)));return c;
}
let origin;
async function open(c,view,{branded=false}={}){
 const p=await c.newPage();p.setDefaultTimeout(8000);
 const q=branded?'?view=overview&homes=2':view==='noproperties'?'?view=properties&noProperties':`?view=${view}&listing=${LISTING}`;
 await p.goto(`${origin}/tests/fixtures/${branded?'branded':'connected'}.html${q}`,{waitUntil:'networkidle'});
 await expect(p.locator('.studio-shell')).toBeVisible();assert(await p.evaluate(()=>matchMedia('(pointer:coarse)').matches),'Actual coarse pointer context');await expect(p.locator(".connection")).toHaveText(/^Updated /);
 await p.waitForFunction(()=>[...document.querySelectorAll('main')].some(e=>e.getClientRects().length));await p.waitForTimeout(350);
 // Measure page controls with the actual nonmodal navigation popover closed.
 // Open-menu targets and keyboard behavior are checked separately below.
 if(await p.locator('.secondary-navigation[open]').count()){await p.locator('.secondary-navigation>summary').click();await expect(p.locator('.secondary-navigation[open]')).toHaveCount(0);}
 return p;
}
async function target(locator,name){
 assert(await locator.count()===1,`Exact target exists: ${name}`);
 const r=await locator.evaluate(el=>{
  const control=el;
  const target=el.matches('input[type=checkbox],input[type=radio]')?(el.labels?.length===1?el.labels[0]:null):el;
  if(!target)return{missingAssociatedLabel:true};
  target.scrollIntoView({block:'center',inline:'center',behavior:'instant'});
  const r=target.getBoundingClientRect();
  const points=[[r.x+r.width/2,r.y+r.height/2],[r.x+r.width/2-20,r.y+r.height/2],[r.x+r.width/2+20,r.y+r.height/2],[r.x+r.width/2,r.y+r.height/2-20],[r.x+r.width/2,r.y+r.height/2+20]];
  const hits=points.map(([x,y])=>{
   const hit=document.elementFromPoint(x,y);
   if(!hit||!target.contains(hit))return false;
   // A label's nested unrelated interactive child is not the input's hit area.
   const interactive=hit.closest('button,a[href],input,select,textarea,summary');
   return target===control||!interactive||interactive===control;
  });
  return{x:r.x,y:r.y,width:r.width,height:r.height,targetTag:target.tagName,controlTag:control.tagName,disabled:control.matches(':disabled'),hits,viewport:{width:innerWidth,height:innerHeight}};
 });
 report.targetMeasurements.push({name,...r});
 if(r.disabled)return;
 const valid=!r.missingAssociatedLabel&&r.width+1e-6>=44&&r.height+1e-6>=44&&r.hits.every(Boolean);
 (valid?pass:fail)(name+' target44',JSON.stringify(r));
}
async function visibleTargets(p,scope,name){
 const all=scope.locator('button,a[href],summary,select,textarea,input:not([type=hidden])');
 for(let i=0;i<await all.count();i++){const el=all.nth(i);if(!await el.isVisible())continue;await target(el,`${name}:${i}:${await el.getAttribute('aria-label')??(await el.textContent()??'').trim().slice(0,36)}`);}
}
// Keep baseline focus inside a modal: App correctly redirects focus outside it.
// The temporary heading tabindex is test-only, excluded from Tab order, and
// restored in finally. Every candidate must be unfocused when measured.
async function focusSamples(p,scope,name,{modal=false}={}){
 const selector='button,a[href],summary,select,textarea,input:not([type=hidden]),[tabindex]:not([tabindex="-1"])';
 const heading=scope.locator('h1,h2,h3').first();
 const seed=await heading.count()?heading:scope;
 const oldTabindex=await seed.getAttribute('tabindex');
 const rootHandle=await scope.elementHandle();assert(rootHandle,'Exact focus scope exists: '+name);
 const rows=[];
 const observe=()=>rootHandle.evaluate((root,selector)=>{
  const e=document.activeElement;
  const shared={documentHasFocus:document.hasFocus(),scopeConnected:root.isConnected,scopeTag:root.tagName,scopeOpen:root instanceof HTMLDialogElement?root.open:null,scopeNativeModal:root instanceof HTMLDialogElement&&root.matches(':modal'),dialogContainsActive:!!e&&root.contains(e)};
  if(!e||!root.contains(e))return{inScope:false,activeTag:e?.tagName??null,activeID:e?.id??null,activeRole:e?.getAttribute('role')??null,activeText:(e?.getAttribute('aria-label')??e?.textContent??'').trim().slice(0,80),activeIsBody:e===document.body,activeFocusable:!!e?.matches('button,a[href],input,select,textarea,summary,[tabindex]'),activeTabIndex:e?.tabIndex??null,activeInert:!!e?.closest('[inert]'),activeMatchesFocus:!!e?.matches(':focus'),...shared};
  const controls=[...root.querySelectorAll(selector)].filter(n=>n.getClientRects().length&&getComputedStyle(n).visibility!=='hidden'&&!n.matches(':disabled')&&n.tabIndex>=0);
  const index=controls.indexOf(e),s=getComputedStyle(e),r=e.getBoundingClientRect();
  return{inScope:true,index,tag:e.tagName,text:(e.getAttribute('aria-label')||e.textContent||'').trim().slice(0,50),outline:s.outline,outlineWidth:parseFloat(s.outlineWidth),outlineStyle:s.outlineStyle,shadow:s.boxShadow,focusVisible:e.matches(':focus-visible'),rect:{x:r.x,y:r.y,width:r.width,height:r.height},...shared};
 },selector);
 try{
  await seed.evaluate(e=>{e.setAttribute('tabindex','-1');e.focus({preventScroll:true});});
  assert(await seed.evaluate(e=>document.activeElement===e),'In-scope baseline seed owns focus: '+name);
  const before=await rootHandle.evaluate((root,selector)=>[...root.querySelectorAll(selector)].filter(e=>e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden'&&!e.matches(':disabled')&&e.tabIndex>=0).map((e,index)=>{const s=getComputedStyle(e);return{index,text:(e.getAttribute('aria-label')||e.textContent||'').trim().slice(0,50),focused:document.activeElement===e,outline:s.outline,shadow:s.boxShadow};}),selector);
  assert(before.length>0&&before.length<=32,'Bounded nonempty focus candidates: '+name);
  assert(before.every(r=>!r.focused),'All focus baselines are unfocused: '+name);
  const directions=modal?['forward','backward']:['forward'];
  for(const direction of directions){
   await seed.focus();
   const seen=new Set(),key=direction==='forward'?'Tab':'Shift+Tab';
   for(let i=0;i<=before.length;i++){
    await p.keyboard.press(key);
    let row=await observe(),phase='tab';
    if(!row.inScope){
     rows.push({direction,step:i,...row});
     const nativeChrome=modal&&row.documentHasFocus===false&&row.activeTag==='BODY'&&row.activeIsBody===true&&row.activeFocusable===false&&row.activeMatchesFocus===false&&row.scopeConnected===true&&row.scopeOpen===true&&row.scopeNativeModal===true;
     if(nativeChrome){
      const boundary=row;
      await p.keyboard.press(key);row=await observe();
      const reentered=row.inScope===true&&row.documentHasFocus===true&&row.scopeConnected===true&&row.scopeOpen===true&&row.scopeNativeModal===true&&row.dialogContainsActive===true;
      report.nativeChromeReentries??=[];report.nativeChromeReentries.push({name,direction,step:i,sameModalElementHandle:true,boundary,reentry:row,reentered});
      (reentered?pass:fail)('native browser chrome reenters same modal '+name,JSON.stringify(report.nativeChromeReentries.at(-1)));
      if(!reentered)break;
      phase='native-chrome-reentry';
     }else{
      if(modal)fail('dialog focus stays in scope '+name,JSON.stringify(rows.at(-1)));
      break;
     }
    }
    const old=before[row.index];
    assert(old,'Focused target has its exact unfocused baseline: '+name);
    seen.add(row.index);
    const ring=row.outlineWidth>=2&&row.outlineStyle!=='none'&&row.outline!==old.outline;
    const shadow=row.shadow!=='none'&&row.shadow!==old.shadow;
    rows.push({direction,step:i,phase,...row,baseline:old,changedIndicator:ring||shadow});
    if(!row.focusVisible||!(ring||shadow))fail('visible keyboard focus '+name,JSON.stringify(rows.at(-1)));
   }
   if(seen.size!==before.length)fail('all scoped keyboard controls reached '+name,JSON.stringify({direction,seen:[...seen],expected:before.length}));
   else pass('all scoped keyboard controls reached '+name,JSON.stringify({direction,count:seen.size,modalWrap:modal}));
  }
  report.keyboard??=[];report.keyboard.push({name,modal,baseline:before,rows});
 }finally{
  try{await seed.evaluate((e,old)=>{if(old===null)e.removeAttribute('tabindex');else e.setAttribute('tabindex',old);},oldTabindex);}finally{await rootHandle.dispose();}
 }
}
async function settledModal(dialog,name){
 const facts=await dialog.evaluate(async root=>{
  const rect=()=>{const r=root.getBoundingClientRect(),s=getComputedStyle(root);return{x:r.x,y:r.y,width:r.width,height:r.height,transform:s.transform,opacity:s.opacity,filter:s.filter};};
  const before=rect(),ancestors=[];
  for(let e=root;e;e=e.parentElement)ancestors.push(e);
  const animations=[...new Set(ancestors.flatMap(e=>e.getAnimations()))];
  const finite=animations.filter(a=>a.effect&&Number.isFinite(a.effect.getComputedTiming().endTime)&&a.playState!=='finished'&&a.playState!=='idle');
  const observed=finite.map(a=>({type:a.constructor.name,property:a.transitionProperty??null,playState:a.playState,pending:a.pending,endTime:a.effect.getComputedTiming().endTime}));
  let timer;
  try{
   const stable=await Promise.race([
    (async()=>{
     await Promise.all(finite.map(a=>a.finished));
     await new Promise(done=>requestAnimationFrame(done));const first=rect();
     await new Promise(done=>requestAnimationFrame(done));const second=rect();
     return{first,second};
    })(),
    new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Finite modal entry did not settle within the existing5s assertion bound')),5000);})
   ]);
   return{before,observed,...stable};
  }finally{clearTimeout(timer);}
 });
 assert(facts.second.width>0&&facts.second.height>0&&['x','y','width','height'].every(k=>Math.abs(facts.first[k]-facts.second[k])<=1e-6),'Actual modal bounds stable after finite entry: '+name);
 report.settledDialogs??=[];report.settledDialogs.push({name,...facts});pass('settled modal bounds '+name,JSON.stringify(facts));
}
async function dialogSemantics(dialog,name){
 await settledModal(dialog,name);
 const s=await dialog.evaluate(e=>({tag:e.tagName,role:e.getAttribute('role'),ariaModal:e.getAttribute('aria-modal'),nativeModal:e instanceof HTMLDialogElement&&e.open&&e.matches(':modal'),labels:(e.getAttribute('aria-labelledby')??'').split(/\s+/).filter(Boolean).map(id=>document.getElementById(id)?.textContent?.trim())}));
 assert(s.nativeModal||s.role==='dialog'&&s.ariaModal==='true','Actual modal semantics: '+name);
 assert(s.labels.length>0&&s.labels.every(Boolean),'Actual accessible dialog name: '+name);
 pass('dialog semantics '+name,JSON.stringify(s));
}
async function dialogs(c,scheme,reduced=false){
 let p=await open(c,'overview',{branded:true});
 await p.locator('.app-all-tools>summary').click();
 const home=p.getByRole('combobox',{name:'Home for creation tools',exact:true});await home.selectOption('');await expect(home).toHaveValue('');
 const opener=p.locator('.app-feature-card.feature-studio');await opener.focus();await opener.click();
 const picker=p.getByRole('dialog',{name:'Which listing is this for?',exact:true});await expect(picker).toBeVisible();
 await dialogSemantics(picker,'chooser '+scheme);
 if(mode==='focus-control')await p.addStyleTag({content:':focus-visible{outline:none!important;box-shadow:none!important}'});
 await target(p.getByRole('button',{name:'Close home picker',exact:true}),`Close home picker ${scheme}`);
 if(mode==='all')await visibleTargets(p,picker,`chooser ${scheme}`);
 await p.screenshot({path:join(dir,`chooser-${scheme}${reduced?'-reduce':''}.png`)});
 if(reduced)await motionRoots(p,'chooser');else if(mode==='all'||mode==='focus-control')await focusSamples(p,picker,'chooser '+scheme,{modal:true});
 await p.getByRole('button',{name:'Close home picker',exact:true}).click();await expect(opener).toBeFocused();pass('chooser restores opener '+scheme,'Actual opening feature card owns focus after close');await p.close();
 p=await open(c,'workspace');await p.getByRole('button',{name:'Sign out',exact:true}).click();
 const loginOpener=p.getByRole('button',{name:'Sign in',exact:true});await loginOpener.focus();await loginOpener.click();
 const login=p.getByRole('dialog',{name:/Your phone/});await expect(login).toBeVisible();await dialogSemantics(login,'login '+scheme);
 if(mode==='focus-control')await p.addStyleTag({content:':focus-visible{outline:none!important;box-shadow:none!important}'});
 await target(p.getByRole('button',{name:'Close sign in',exact:true}),`Close sign in ${scheme}`);
 if(mode==='all')await visibleTargets(p,login,`login ${scheme}`);
 await p.screenshot({path:join(dir,`login-${scheme}${reduced?'-reduce':''}.png`)});
 if(reduced)await motionRoots(p,'login');else if(mode==='all'||mode==='focus-control')await focusSamples(p,login,'login '+scheme,{modal:true});
 await p.getByRole('button',{name:'Close sign in',exact:true}).click();await expect(loginOpener).toBeFocused();pass('login restores opener '+scheme,'Actual sign-in opener owns focus after close');await p.close();
}
async function contrastControl(c){
 const p=await open(c,'library');
 const normal=p.locator('.page-title .subtitle'),large=p.locator('.page-title h1');
 assert(await normal.count()===1&&await large.count()===1,'Exact existing App text samples');
 for(const [el,name,size]of[[normal,'normal',16],[large,'large',24]])await el.evaluate((e,{name,size})=>{e.dataset.probeContrast=name;for(const[k,v]of Object.entries({color:'rgb(127,127,127)','background-color':'rgb(255,255,255)','background-image':'none',opacity:'1',filter:'none','backdrop-filter':'none','font-size':size+'px','font-weight':'400'}))e.style.setProperty(k,v,'important');},{name,size});
 const rows=(await p.evaluate(contrastRows)).filter(r=>r.sample);
 assert(rows.length===2&&rows.every(r=>r.ratio>=3&&r.ratio<4.5),'Actual control ratios sit between3 and4.5');
 const n=rows.find(r=>r.sample==='normal'),l=rows.find(r=>r.sample==='large');
 assert(n&&l&&n.required===4.5&&l.required===3&&Math.abs(n.ratio-l.ratio)<1e-6,'Normal/large rules apply to the same measured contrast');
 report.contrastControl=rows;
 (n.ratio<n.required?fail:pass)('normal text AA control',JSON.stringify(n));
 (l.ratio<l.required?fail:pass)('large text AA control',JSON.stringify(l));
 await p.close();
}
async function motionRoots(p,name){
 const states=await p.locator('.app-dashboard,.listing-workflow,.make-video,.creative-workspace,.business-workspace,.library-layout,.planner-grid,.lw-empty,.video-job,.notice,.lw-error,.video-message,.app-feature-gate,.login-dialog,.secondary-navigation-menu,.cloud-editor,.video-editor,.panel,.settings-grid,.empty-connect').evaluateAll(els=>els.filter(e=>e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden').map(e=>{const s=getComputedStyle(e);return{class:e.className,opacity:s.opacity,transform:s.transform,filter:s.filter,transition:s.transitionDuration,animation:s.animationDuration};}));
 assert(states.length>0,'Actual animated root is present: '+name);report.motion.push({name,states});
 const good=states.every(s=>Number(s.opacity)===1&&(s.transform==='none'||s.transform==='matrix(1, 0, 0, 1, 0, 0)')&&s.filter==='none'&&s.transition.split(',').every(n=>parseFloat(n)===0)&&s.animation.split(',').every(n=>parseFloat(n)===0));(good?pass:fail)('reduced motion settled '+name,JSON.stringify(states));
}
try{
 const baseline=args['baseline-css']?await readFile(args['baseline-css'],'utf8'):null;
 if(baseline){assert.equal(hash(baseline),'4258029ddc2602d4576c30aa7c5b48a663244328f20b85b88a2e213a0bc01e1b');report.baselineCssSHA256=hash(baseline);}
 await build({configFile:false,root,publicDir:'public',logLevel:'error',plugins:[{name:'exact-historical-design-css',enforce:'pre',transform(code,id){if(baseline&&id.split('?')[0]===join(root,'src/design/studio.css')){changedBaseline=true;return baseline;}}}],build:{outDir:dist,rollupOptions:{input:['connected','branded'].map(x=>join(root,`tests/fixtures/${x}.html`))}}});
 if(baseline)assert(changedBaseline);
 server=createServer(async(req,res)=>{const p=resolve(dist,`.${new URL(req.url,'http://localhost').pathname}`);if(!p.startsWith(dist+'/')||req.method!=='GET')return res.writeHead(400).end();try{res.setHeader('Content-Type',({'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml'})[extname(p)]??'application/octet-stream');res.end(await readFile(p));}catch{res.writeHead(404).end();}});await new Promise(done=>server.listen(0,'127.0.0.1',done));origin=`http://127.0.0.1:${server.address().port}`;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
 if(mode==='close-targets'){const c=await context({viewport:{width:390,height:844},isMobile:true,hasTouch:true});await dialogs(c,'light');await c.close();}
 else if(mode==='focus-control'){const c=await context({viewport:{width:390,height:844},isMobile:true,hasTouch:true});await dialogs(c,'light');await c.close();}
 else if(mode==='contrast-control'){const c=await context({viewport:{width:390,height:844},isMobile:true,hasTouch:true});await contrastControl(c);await c.close();}
 else if(mode==='text-input'){const c=await context({viewport:{width:390,height:844},isMobile:true,hasTouch:true});const p=await open(c,'library');await target(p.locator('.search-field input'),'Search spaces input');await p.close();await c.close();}
 else{
  for(const scheme of['light','dark']){
   const c=await context({viewport:{width:390,height:844},isMobile:true,hasTouch:true,colorScheme:scheme});
   for(const view of views){const p=await open(c,view);const rows=await p.evaluate(contrastRows),measured=rows.filter(r=>r.ratio!==undefined),bad=measured.filter(r=>r.ratio<r.required);assert(measured.length>0,'Measured text is nonempty');report.contrastUnmeasured.push({view,scheme,rows:rows.filter(r=>r.reason)});(bad.length?fail:pass)(`measured text AA ${view}/${scheme}`,JSON.stringify({measured:measured.length,unmeasured:rows.length-measured.length,bad}));const width=await p.evaluate(()=>({scroll:document.documentElement.scrollWidth,inner:innerWidth}));(width.scroll<=width.inner+1?pass:fail)(`390px overflow ${view}/${scheme}`,JSON.stringify(width));await visibleTargets(p,p.locator('body'),`${view}/${scheme}`);await p.close();}
   await dialogs(c,scheme);const p=await open(c,'properties');await p.locator('.secondary-navigation>summary').click();const menu=p.locator('.secondary-navigation[open] .secondary-navigation-menu');await expect(menu).toBeVisible();await settledModal(menu,'bottom menu '+scheme);await visibleTargets(p,menu,`bottom menu/${scheme}`);await focusSamples(p,p.locator('.secondary-navigation[open]'),'bottom menu '+scheme);await p.screenshot({path:join(dir,`more-tools-${scheme}.png`)});await p.close();await c.close();
  }
  const c=await context({viewport:{width:390,height:844},isMobile:true,hasTouch:true,reducedMotion:'reduce'});
  for(const view of views){const p=await open(c,view);await motionRoots(p,view);const press=p.locator('button:not(:disabled)').first();if(await press.isVisible()){await press.scrollIntoViewIfNeeded();const r=await press.boundingBox();await p.mouse.move(r.x+r.width/2,r.y+r.height/2);await p.mouse.down();const s=await press.evaluate(e=>({transform:getComputedStyle(e).transform,transition:getComputedStyle(e).transitionDuration}));await p.mouse.move(1,1);await p.mouse.up();const good=s.transform==='none'&&s.transition.split(',').every(n=>parseFloat(n)===0);(good?pass:fail)('reduced motion press '+view,JSON.stringify(s));}await p.close();}
  await dialogs(c,'light',true);const p=await open(c,'properties');await p.locator('.secondary-navigation>summary').click();await motionRoots(p,'bottom menu');await p.close();await c.close();
 }
 report.status=report.failures.length||report.errors.length||report.externalRequests.length?'failed':'passed';
}catch(e){report.status='failed';report.failure=String(e.stack??e);}
finally{await browser?.close();if(server)await new Promise(done=>server.close(done));report.sourceStable=(await Promise.all(sourceFiles.map(async n=>sourceHashes[n]===hash(await readFile(join(root,n)))))).every(Boolean);if(!report.sourceStable)report.status='failed';report.finishedAt=new Date().toISOString();if(args.out){await mkdir(dirname(resolve(args.out)),{recursive:true});await writeFile(resolve(args.out),JSON.stringify(report,null,2)+'\n',{flag:'wx'});}console.log(JSON.stringify(report));if(report.status!=='passed')process.exitCode=1;}
