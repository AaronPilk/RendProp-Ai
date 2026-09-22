import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,extname} from 'node:path';
import {createServer} from 'node:http';
import {build} from 'vite';
import {chromium,expect} from '@playwright/test';
const root=resolve(import.meta.dirname,'..'),artifacts=await mkdtemp(join(tmpdir(),'rendprop-brand-flow-')),dist=join(artifacts,'dist');
const receipt={status:'running',proof:'Real App and StudioServices, isolated Auth/API and synthetic phone media; no customer data or AI provider calls.',checks:[],errors:[],externalRequests:[],visuals:[]};
const first='55555555-5555-4555-8555-555555555555',second='66666666-6666-4666-8666-666666666666';
let browser,server,page;
try{
 await build({configFile:false,root,publicDir:'public',logLevel:'error',build:{outDir:dist,rollupOptions:{input:join(root,'tests/fixtures/branded.html')}}});
 server=createServer(async(req,res)=>{const path=resolve(dist,`.${new URL(req.url,'http://localhost').pathname}`);if(!path.startsWith(`${dist}/`)||req.method!=='GET')return res.writeHead(400).end();try{res.setHeader('Content-Type',({'.html':'text/html','.js':'application/javascript','.css':'text/css','.svg':'image/svg+xml'})[extname(path)]??'application/octet-stream');res.end(await readFile(path));}catch{res.writeHead(404).end();}});
 await new Promise(done=>server.listen(0,'127.0.0.1',done));const origin=`http://127.0.0.1:${server.address().port}`;
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});
 const context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});
 page=await context.newPage();page.on('pageerror',e=>receipt.errors.push(e.message));page.setDefaultTimeout(10000);
 const png=Buffer.from(await page.evaluate(()=>{const c=document.createElement('canvas');c.width=800;c.height=450;const g=c.getContext('2d');g.fillStyle='#dbd6ee';g.fillRect(0,0,800,450);g.fillStyle='#77698f';g.fillRect(0,310,800,140);g.fillStyle='#faf8ff';g.fillRect(120,75,180,170);g.fillRect(440,100,230,150);g.fillStyle='#b7a4c6';g.fillRect(310,270,270,120);return c.toDataURL().split(',')[1];}),'base64');
 await context.route('**/*',route=>{const u=new URL(route.request().url());if(u.origin===origin&&route.request().method()==='GET')return route.continue();if(['012345678901234567890123456789ab.r2.cloudflarestorage.com','pub-70303ef2ff484a179c03ff19b26aa63d.r2.dev'].includes(u.hostname)&&route.request().method()==='GET')return route.fulfill({status:200,contentType:'image/png',headers:{'Access-Control-Allow-Origin':'*'},body:png});receipt.externalRequests.push(u.origin);return route.abort();});
 const nav=name=>page.getByRole('navigation',{name:'Studio navigation'}).getByRole('button',{name,exact:true});
 const home=async()=>{await nav('Home').click();await expect(page.getByRole('heading',{name:'Make something',exact:true})).toBeVisible();};
 const card=id=>page.locator(`.app-dashboard .feature-${id}`);
 const check=s=>receipt.checks.push(s);
 await page.goto(`${origin}/tests/fixtures/branded.html`);await expect(page.getByText(/^Updated \d/)).toBeVisible();await expect(page.locator('.app-property-card')).toHaveCount(2);
 await expect(page.locator('.app-dashboard .app-feature-card')).toHaveCount(12);await expect(card('spatial')).toHaveCount(0);
 await card('studio').click();await expect(page.getByRole('dialog')).toBeVisible();await page.keyboard.press('Escape');await expect(page.getByRole('dialog')).toHaveCount(0);await expect(card('studio')).toBeFocused();
 await card('studio').click();await page.getByRole('dialog').getByRole('button',{name:/10 Oak Street/}).click();
 await expect(page.getByRole('navigation',{name:'Creative tools'}).getByRole('button',{name:'AI Photo Studio',exact:true})).toHaveAttribute('aria-current','page');await expect(page.getByRole('combobox',{name:'Property',exact:true})).toHaveValue(first);
 check('native home cards use a keyboard-dismissable home picker and route the chosen property to AI Photo Studio');
 await home();await page.getByLabel('Home for creation tools').selectOption(second);
 for(const [id,panel,kind] of [['aerial','AI video','aerial'],['voice','Voiceover'],['copy','Scripts & shot plans'],['animate','AI video','reel'],['chapters','Room chapters'],['coach','Ask Rendprop']]){
  await card(id).click();await expect(page.getByRole('navigation',{name:'Creative tools'}).getByRole('button',{name:panel,exact:true})).toHaveAttribute('aria-current','page');await expect(page.getByRole('combobox',{name:'Property',exact:true})).toHaveValue(second);if(kind)await expect(page.getByRole('combobox',{name:'What would you like to make?',exact:true})).toHaveValue(kind);await home();
 }
 check('all six additional AI cards open their exact tool and preset with the selected second property');
 for(const [id,tab] of [['tour','Create & publish'],['floorplan','Floor plan & 3D'],['photos','Media']]){await card(id).click();await expect(page.getByRole('tab',{name:new RegExp(tab.replace('&','&'))})).toHaveAttribute('aria-selected','true');await expect(page.getByLabel('Working on',{exact:true})).toHaveValue(second);await home();}
 check('tour, photo and floor-plan cards select the matching property task');
 await card('agent').click();await expect(page.getByRole('navigation',{name:'Business tools'}).getByRole('button',{name:'Agent card',exact:true})).toHaveAttribute('aria-current','page');await page.getByLabel('Display name',{exact:true}).fill('Unfinished profile change');await home();await card('agent').click();await expect(page.getByLabel('Display name',{exact:true})).toHaveValue('Unfinished profile change');await home();await page.locator('.app-leads-banner').click();await expect(page.getByRole('navigation',{name:'Business tools'}).getByRole('button',{name:'Leads',exact:true})).toHaveAttribute('aria-current','page');
 check('Agent card and leads go directly to their business tools; unfinished profile text survives Home navigation');
 await home();await page.getByRole('button',{name:'Add a home',exact:true}).click();await page.getByLabel('Address or property name').fill('Unfinished home');await home();await nav('My homes').click();await expect(page.getByLabel('Address or property name')).toHaveValue('Unfinished home');await page.getByRole('button',{name:'Cancel',exact:true}).click();
 check('an unfinished new-home form survives moving Home and back');
 await home();await page.getByLabel('Home for creation tools').selectOption(first);
 // Visual assertions use only synthetic homes/media and never capture an owner account.
 for(const mode of ['light','dark']){await page.getByRole('combobox',{name:'Appearance',exact:true}).selectOption(mode);for(const width of [1440,390]){await page.setViewportSize({width,height:1000});await page.evaluate(()=>window.scrollTo(0,0));const style=await page.evaluate(()=>({bg:getComputedStyle(document.documentElement).backgroundColor,overflow:document.documentElement.scrollWidth>innerWidth}));assert.equal(style.bg,mode==='light'?'rgb(250, 250, 252)':'rgb(14, 13, 20)');assert.equal(style.overflow,false);const screenshot=`home-${mode}-${width}.png`;await page.screenshot({path:join(artifacts,screenshot),fullPage:true});receipt.visuals.push({mode,width,...style,screenshot});}}
 check('home matches exact native light/dark backgrounds with no horizontal overflow at1440 and390');
 await page.setViewportSize({width:1440,height:1000});await page.getByRole('combobox',{name:'Appearance',exact:true}).selectOption('system');await page.emulateMedia({colorScheme:'light'});await expect.poll(()=>page.evaluate(()=>getComputedStyle(document.documentElement).backgroundColor)).toBe('rgb(250, 250, 252)');await page.emulateMedia({colorScheme:'dark'});await expect.poll(()=>page.evaluate(()=>getComputedStyle(document.documentElement).backgroundColor)).toBe('rgb(14, 13, 20)');
 check('System appearance follows operating-system changes while explicit choices persist');
 const calls=await page.evaluate(()=>window.brandFixture.calls());assert.equal(calls.filter(c=>c.method!=='GET').length,0,'Opening cards must not dispatch paid actions or autosave untouched drafts');
 check('all card navigation is read-only: zero generation, upload, property, or profile writes');
 await page.goto(`${origin}/tests/fixtures/branded.html?spatial=on`);await expect(card('spatial')).toBeVisible();await card('spatial').click();await page.getByRole('dialog').getByRole('button',{name:/10 Oak Street/}).click();await expect(page.getByRole('tab',{name:/Floor plan & 3D/})).toHaveAttribute('aria-selected','true');
 check('3D walkthrough appears only when the real capability contract is enabled');
 await page.goto(`${origin}/tests/fixtures/branded.html?homes=1`);await expect(page.locator('.app-property-card')).toHaveCount(1);await card('studio').click();await expect(page.getByRole('navigation',{name:'Creative tools'})).toBeVisible();await expect(page.getByRole('dialog')).toHaveCount(0);
 await page.goto(`${origin}/tests/fixtures/branded.html?homes=0`);await expect(page.getByRole('button',{name:'Add your first home'})).toBeVisible();await card('studio').click();await expect(page.getByLabel('Address or property name')).toBeVisible();
 check('one-home accounts go directly into the tool; zero-home accounts open the creation form');
 await page.goto(`${origin}/tests/fixtures/branded.html`);await expect(page.locator('.app-property-card')).toHaveCount(2);
 await card('reel').click();await page.getByRole('dialog').getByRole('button',{name:/10 Oak Street/}).click();
 const picker=page.getByRole('region',{name:'Choose property photos and video'});
 await expect(picker).toBeVisible();await expect(picker.getByRole('checkbox')).toHaveCount(3);
 await picker.getByRole('checkbox',{name:'Living room',exact:true}).check();await picker.getByRole('button',{name:'Add 1 file to reel',exact:true}).click();
 await expect(page.getByRole('button',{name:/Select clip 1:/})).toBeVisible();await page.getByLabel('Title overlay',{exact:true}).fill('Office reel');
 await expect.poll(()=>page.evaluate(()=>window.brandFixture.calls().filter(c=>c.path==='/functions/v1/studio/documents'&&c.method==='POST').some(c=>c.body.payload.draft?.title==='Office reel'))).toBe(true);
 assert.equal((await page.evaluate(()=>window.brandFixture.calls())).filter(c=>c.path.includes('/uploads')).length,0);
 check('Home Make a reel imports actual selected phone-photo bytes into the editor and autosaves with source reuse, without another upload');
 await home();await page.getByLabel('Home for creation tools').selectOption(second);await card('reel').click();
 await expect(picker).toContainText('22 Pine Street');await expect(page.getByLabel('Property reel',{exact:true})).toHaveValue(second);await expect(page.getByLabel('Title overlay',{exact:true})).toHaveValue('');
 await picker.getByRole('button',{name:'Close media picker',exact:true}).click();
 await page.getByLabel('Property reel',{exact:true}).selectOption(first);await expect(page.getByLabel('Title overlay',{exact:true})).toHaveValue('Office reel');await expect(page.getByRole('button',{name:/Select clip 1:/})).not.toHaveAccessibleName(/original file missing/);
 check('Opening another home starts its own reel; returning restores the prior title, original files and property assignment without an upload');
 await page.getByRole('button',{name:'Choose property photos & video',exact:true}).click();
 for(const mode of ['light','dark']){await page.getByRole('combobox',{name:'Appearance',exact:true}).selectOption(mode);for(const width of [1440,390]){await page.setViewportSize({width,height:1000});await page.evaluate(()=>window.scrollTo(0,0));assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);const screenshot=`reel-${mode}-${width}.png`;await page.screenshot({path:join(artifacts,screenshot),fullPage:true});receipt.visuals.push({mode,width,screenshot});}}
 check('reel journey and real synthetic media picker remain usable at desktop and mobile widths in both appearances');
 assert.deepEqual(receipt.errors,[]);assert.deepEqual(receipt.externalRequests,[]);receipt.status='passed';
}catch(error){receipt.status='failed';receipt.failure=String(error.stack??error);if(page){await page.screenshot({path:join(artifacts,'failure.png'),fullPage:true}).catch(()=>{});await writeFile(join(artifacts,'failure.txt'),await page.locator('body').innerText().catch(()=>''));}throw error;}
finally{await writeFile(join(artifacts,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify({status:receipt.status,checks:receipt.checks.length,artifacts}));await browser?.close();await new Promise(done=>server?server.close(done):done());}
