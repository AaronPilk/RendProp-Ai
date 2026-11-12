import { assert, assertEquals, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { HttpError } from '../_shared/http.ts';

const url = (path: string) => new URL(path, import.meta.url).href;
const actor = '11111111-1111-4111-8111-111111111111';
const org = '22222222-2222-4222-8222-222222222222';
const otherOrg = '33333333-3333-4333-8333-333333333333';
const listing = '44444444-4444-4444-8444-444444444444';
let fixtureCounter = 0;

async function selectedFixture() {
  const source = await Deno.readTextFile(new URL('./selected.ts', import.meta.url));
  const code = source.split('\n').filter(line => !line.startsWith('import')).join('\n');
  const prefix = `
import {assert, HttpError} from ${JSON.stringify(url('../_shared/http.ts'))};
import {createPrivateMediaRequestSigner as actualSigner} from ${JSON.stringify(url('../_shared/private-media.ts'))};
import {mapCatalogueRows} from ${JSON.stringify(url('./catalogue-map.ts'))};
const actor=${JSON.stringify(actor)},org=${JSON.stringify(org)},otherOrg=${JSON.stringify(otherOrg)},listing=${JSON.stringify(listing)};
const ids=Array.from({length:38},(_,index)=>'aaaaaaaa-aaaa-4aaa-8aaa-'+String(index+1).padStart(12,'0'));
export const state={authorization:0,policy:0,directSigns:0,references:0,heads:0,prepared:0,preparedSigns:0,provenanceQueries:0,preparedQueries:0,provenancePassed:[] as (string|null)[],useBatch:false,denyFinal:false,flipOrg:false,foreignPreparation:false,uncertainFinal:false,policyFlip:false,events:[] as string[]};
const createPrivateMediaRequestSigner=(scopeOrg:string)=>actualSigner(scopeOrg,{
 gatewayRequired:async(target:string)=>{state.policy++;state.events.push('policy');assert(target===org,503,'Wrong policy org');if(state.uncertainFinal&&state.policy===2)throw new HttpError(503,'Policy unavailable');return state.policyFlip&&state.policy===2;},
 directSign:async(_bucket:string,key:string)=>{state.directSigns++;state.events.push('sign');return 'https://fixture.invalid/'+key;}
});
const contentOrgForUser=async(user:string,expected:string,target:string)=>{state.authorization++;state.events.push('authorize');assert(user===actor&&expected===org&&target===listing,403,'Wrong scope');if(state.denyFinal&&state.authorization===2)throw new HttpError(403,'Membership revoked');return state.flipOrg&&state.authorization===2?otherOrg:org;};
const selectedGallerySources=async(_db:any,target:string,gallery:string[])=>{assert(target===listing&&gallery.length===38,503,'Wrong gallery');return {count:38,selected:ids.map((id,index)=>({asset:{id,storage_key:'renders/'+listing+'/'+id+'.jpg',bytes:123,sha256:'a'.repeat(64)},photo:id}))};};
const selectedLookupBatch=async()=>state.useBatch?{provenance:new Map(ids.map(id=>['renders/'+listing+'/'+id+'.jpg',id===ids[0]?'provenance-'+id:null])),prepared:new Map(ids.map(id=>[id,[ids[0],ids[17],ids[37]].includes(id)?'prep-'+id:null]))}:{provenance:new Map(),prepared:new Map()};
const adminClient=()=>({from:(table:string)=>{const filters:Record<string,unknown>={};const q:any={select:()=>q,eq:(key:string,value:unknown)=>{filters[key]=value;return q;},in:()=>q,order:()=>q,limit:()=>q,maybeSingle:async()=>{
 if(table==='listings')return {data:{gallery_asset_ids:ids},error:null};
 if(table==='media_provenance'){state.provenanceQueries++;return {data:null,error:null};}
 if(table==='property_video_preparations'){state.preparedQueries++;return {data:[ids[0],ids[17],ids[37]].includes(String(filters.original_asset_id))?{id:'prep-'+filters.original_asset_id}:null,error:null};}
 throw Error('Unexpected table '+table);
 }};return q;}});
const rpc=async(name:string,args:any)=>{if(name==='property_photo_reference'){state.references++;state.provenancePassed.push(args.p_provenance);state.events.push('reference');return{bucket:'renders',storage_key:'renders/'+listing+'/'+args.p_asset+'.jpg',bytes:123,sha256:'a'.repeat(64),content_type:'image/jpeg'};}if(name==='property_video_preparation_scope'){state.prepared++;return{actor_id:actor,org_id:state.foreignPreparation?otherOrg:org,listing_id:listing,storage_key:'prepared/'+args.p_id+'.jpg'};}throw Error('Unexpected RPC '+name);};
const ownedHead=async()=>{state.heads++;state.events.push('head');};
const preparationReply=async(p:any,signMedia:(scope:any)=>Promise<string>)=>{state.heads++;state.events.push('prepared_head');const preview_url=await signMedia({actor:p.actor_id,org:p.org_id,listing:p.listing_id,bucket:'uploads',key:p.storage_key});state.preparedSigns++;return{source:{eligible:true,preview_url}};};
const reply=async(value:any)=>value;
`;
  const bytes = new TextEncoder().encode(prefix + code + `\n// fixture ${fixtureCounter++}`);
  const module = await import('data:application/typescript;base64,' + btoa(String.fromCharCode(...bytes)));
  return module as { selectedSources: (actor: string, listing: string, org: string) => Promise<{ sources: unknown[] }>; state: {
    authorization: number; policy: number; directSigns: number; references: number; heads: number;
    prepared: number; preparedSigns: number; provenanceQueries: number; preparedQueries: number;
    provenancePassed: (string | null)[]; useBatch: boolean;
    denyFinal: boolean; flipOrg: boolean; foreignPreparation: boolean;
    uncertainFinal: boolean; policyFlip: boolean; events: string[];
  } };
}

Deno.test('38 selected source signatures and three prepared signatures share one policy lookup, then recheck after current authority', async () => {
  const f = await selectedFixture();
  const result = await f.selectedSources(actor, listing, org);
  assertEquals(result.sources.length, 38);
  assertEquals(f.state.references, 38);
  assertEquals(f.state.heads, 41);
  assertEquals(f.state.prepared, 3);
  assertEquals(f.state.provenanceQueries, 38);
  assertEquals(f.state.preparedQueries, 38);
  assertEquals(f.state.preparedSigns, 3);
  assertEquals(f.state.directSigns, 41);
  assertEquals(f.state.authorization, 2);
  assertEquals(f.state.policy, 2);
  assertEquals(f.state.events.slice(-2), ['authorize', 'policy']);
  assert(f.state.events.indexOf('head') < f.state.events.indexOf('sign'));
});

Deno.test('complete selected lookup batch avoids row queries but keeps every reference and physical check', async () => {
  const f = await selectedFixture();
  f.state.useBatch = true;
  const result = await f.selectedSources(actor, listing, org);
  assertEquals(result.sources.length, 38);
  assertEquals(f.state.provenanceQueries, 0);
  assertEquals(f.state.preparedQueries, 0);
  assertEquals(f.state.references, 38);
  assertEquals(f.state.heads, 41);
  assertEquals(f.state.prepared, 3);
  assertEquals(f.state.provenancePassed[0], 'provenance-aaaaaaaa-aaaa-4aaa-8aaa-000000000001');
  assertEquals(f.state.directSigns, 41);
  assertEquals(f.state.authorization, 2);
  assertEquals(f.state.policy, 2);
});

Deno.test('paid gateway activation or uncertain final policy discards the entire selected source response', async () => {
  for (const mode of ['flip', 'uncertain'] as const) {
    const f = await selectedFixture();
    f.state.useBatch = true;
    if (mode === 'flip') f.state.policyFlip = true;
    else f.state.uncertainFinal = true;
    await assertRejects(() => f.selectedSources(actor, listing, org), HttpError);
    assertEquals(f.state.references, 38);
    assertEquals(f.state.heads, 41);
    assertEquals(f.state.directSigns, 41);
    assertEquals(f.state.authorization, 2);
    assertEquals(f.state.policy, 2);
  }
});

Deno.test('revoked or changed workspace authority discards selected source response before final transport check', async () => {
  for (const mode of ['revoked', 'different_org'] as const) {
    const f = await selectedFixture();
    f.state.useBatch = true;
    if (mode === 'revoked') f.state.denyFinal = true;
    else f.state.flipOrg = true;
    await assertRejects(() => f.selectedSources(actor, listing, org), HttpError);
    assertEquals(f.state.references, 38);
    assertEquals(f.state.heads, 41);
    assertEquals(f.state.authorization, 2);
    assertEquals(f.state.policy, 1);
  }
});

Deno.test('prepared source from another workspace cannot reuse the request policy or return a URL', async () => {
  const f = await selectedFixture();
  f.state.useBatch = true;
  f.state.foreignPreparation = true;
  await assertRejects(() => f.selectedSources(actor, listing, org), HttpError);
  assert(f.state.prepared > 0);
  assertEquals(f.state.authorization, 1);
  assertEquals(f.state.policy, 1);
});

Deno.test('ready preparation keeps default signer for every caller outside selected catalogue', async () => {
  const source = await Deno.readTextFile(new URL('./prepared.ts', import.meta.url));
  const code = source.split('\n').find(line => line.startsWith('export async function preparationReply('));
  assert(code);
  const prefix = `
export const state={heads:0,defaultSigns:0,injectedSigns:0};
const privateMediaUrl=async()=>{state.defaultSigns++;return 'https://fixture.invalid/default';};
const rpc=async()=>({bucket:'uploads',storage_key:'prepared.jpg'});
const ownedHead=async()=>{state.heads++;};
`;
  const bytes = new TextEncoder().encode(prefix + code);
  const f = await import('data:application/typescript;base64,' + btoa(String.fromCharCode(...bytes)));
  const ready = {state:'ready',actor_id:actor,org_id:org,listing_id:listing,asset_id:'a',photo_id:'p',version_id:'asset:a',storage_key:'prepared.jpg',original_source:{sha256:'a'.repeat(64)}};
  assertEquals((await f.preparationReply(ready)).source.preview_url, 'https://fixture.invalid/default');
  assertEquals((await f.preparationReply(ready, () => {f.state.injectedSigns++;return Promise.resolve('https://fixture.invalid/injected');})).source.preview_url, 'https://fixture.invalid/injected');
  assertEquals((await f.preparationReply({...ready,state:'queued'})).source, null);
  assertEquals(f.state.heads, 2);
  assertEquals(f.state.defaultSigns, 1);
  assertEquals(f.state.injectedSigns, 1);
});
