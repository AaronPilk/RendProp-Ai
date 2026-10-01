// Local synthetic fixture; actual renderer and engine, no customer data/API.
import { createServer } from 'node:http';
import { buildSrc, ROOT as TOUR_ROOT } from '../../../../services/edge/tour-host/scripts/build-src.mjs';
import { Script } from 'node:vm';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { execFileSync } from 'node:child_process';
import ts from '../../../../services/edge/tour-host/node_modules/typescript/lib/typescript.js';
const revision=process.argv.find(a=>a.startsWith('--revision='))?.split('=')[1] ?? (process.argv.includes('--revision')?process.argv[process.argv.indexOf('--revision')+1]:null);
if(revision && revision!=='7bcc624') throw new Error('baseline --revision supports exactly 7bcc624');
const cache='call-20260919-web-'+(revision??'working-tree');
const load = buildSrc(cache);
if(revision){
  // The only changed player dependency in this repair is player.ts itself.
  // Refuse a mixed baseline if another renderer module later changes.
  const repo=resolve(TOUR_ROOT,'../../..');
  const changed=execFileSync('git',['diff',revision,'--name-only','--','services/edge/tour-host/src'],{cwd:repo,encoding:'utf8'}).trim().split('\n').filter(Boolean);
  if(changed.some(p=>p!=='services/edge/tour-host/src/player.ts')) throw new Error('Baseline renderer dependency changed; use a complete baseline checkout');
  const source=execFileSync('git',['show',revision+':services/edge/tour-host/src/player.ts'],{cwd:repo,encoding:'utf8'});
  const compiled=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext}}).outputText.replace(/(\bfrom\s*["'])(\.\.?\/[^"']+?)(["'])/g,(m,pre,spec,post)=>/\.(js|mjs|json)$/.test(spec)?m:`${pre}${spec}.js${post}`);
  writeFileSync(join(TOUR_ROOT,'node_modules/.cache',cache,'player.js'),compiled);
}
const { renderTourPage } = await load('player');
const port = Number(process.env.AUDIT_TOUR_PORT || 8796);
const base = `http://127.0.0.1:${port}`;
const tour = {
  slug:'synthetic-call-audit', space_type:'real_estate', published_at:'2026-09-17T15:00:00Z',
  listing:{address:'Synthetic audit property',beds:3,baths:2,sqft:1800,price:'$500,000',
    details:{gallery:[{url:base+'/before.svg',label:'Synthetic comparison'}]}},
  video_url:base+'/missing.mp4',scrub_url:base+'/missing.mp4',hls_url:null,
  poster:base+'/before.svg',duration_s:410,speed_factor:1,
  chapters:[{label:'Living room',t_ms:0,sort:0}],
  agent_card:{name:'Synthetic Agent',phone:'555-010-1111',email:'audit@example.invalid'},
  cta:{label:'Book a showing',mode:'lead_form',secondary:[],lead_fields:[]},
  staged:true,altered_media:[{label:'Synthetic room',kind:'declutter',
    disclosure:'Personal items were digitally removed.',
    original_url:base+'/before.svg',altered_url:base+'/after.svg'}],
};
const svg = (after,portrait=false) => {const w=portrait?900:1200,h=portrait?1200:900;return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}"><rect width="${w}" height="${h}" fill="${after?'#154780':'#804015'}"/><rect x="0" y="${h*.25}" width="${w*.16}" height="${h*.5}" fill="#fff"/><rect x="${w*.84}" y="${h*.25}" width="${w*.16}" height="${h*.5}" fill="#fff"/><text x="10" y="${h*.5}" font-size="${w/48}">LEFT DEFECT</text><text x="${w*.85}" y="${h*.5}" font-size="${w/48}">RIGHT DEFECT</text><text x="${w*.28}" y="${h*.4}" font-size="${w/23}" fill="white">${after?'EDITED':'ORIGINAL'}</text><text x="${w*.28}" y="${h*.57}" font-size="${w/50}" fill="white">SYNTHETIC AUDIT — NOT CUSTOMER MEDIA</text></svg>`;};
createServer((req,res)=>{
  const u = new URL(req.url,base);
  if(u.pathname==='/missing.mp4' && process.env.AUDIT_TOUR_VIDEO) {res.writeHead(200,{'content-type':'video/mp4'});res.end(readFileSync(process.env.AUDIT_TOUR_VIDEO));return;}
  if(u.pathname.endsWith('.svg')) {res.writeHead(200,{'content-type':'image/svg+xml'});res.end(svg(u.pathname.includes('after'),u.searchParams.get('shape')==='portrait'));return;}
  if(!['/f/fixture','/u/fixture','/embed/fixture','/nojs/fixture'].includes(u.pathname)){res.writeHead(404);res.end();return;}
  const t=structuredClone(tour);
  const shape=u.searchParams.get('shape');
  if(shape==='portrait') t.altered_media[0].original_url+='?shape=portrait';
  if(shape==='portrait'||shape==='mismatch') t.altered_media[0].altered_url+='?shape=portrait';
  if(u.searchParams.has('date')) t.published_at=u.searchParams.get('date');
  if(u.searchParams.has('duration')) t.duration_s=Number(u.searchParams.get('duration'));
  let html=renderTourPage(t,base+'/functions','synthetic-anon','',{unbranded:u.pathname.startsWith('/u/'),embed:u.pathname.startsWith('/embed/')});
  // Compile every emitted classic script. This catches broken literal splices,
  // not only source-file TypeScript parsing.
  for(const m of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)) {
    if(!m[0].includes('application/ld+json')) new Script(m[1]);
  }
  const nojs=u.pathname.startsWith('/nojs/');
  res.writeHead(200,{'content-type':'text/html','X-Audit-Revision':revision??'working-tree','Content-Security-Policy':`default-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src ${nojs?"'none'":"'self' 'unsafe-inline'"}; img-src 'self' data:; connect-src 'self'`});res.end(html);
}).listen(port,'127.0.0.1',()=>console.log(`Synthetic actual-renderer audit at ${base}`));
