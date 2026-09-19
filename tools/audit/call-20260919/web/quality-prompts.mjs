// Execute the complete production handler and real pure guards. Only external
// boundaries (database, auth, quota storage and provider) are mocked. No fetch.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createContext, Script } from 'node:vm';
import { execFileSync } from 'node:child_process';
import ts from '../../../../services/edge/tour-host/node_modules/typescript/lib/typescript.js';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../../../..');
const fnroot=resolve(root,'services/supabase/functions');
const file=resolve(fnroot,'ai-photo/index.ts');
const revArg=process.argv.find(a=>a.startsWith('--revision='))?.split('=')[1] ?? (process.argv.includes('--revision')?process.argv[process.argv.indexOf('--revision')+1]:null);
assert.ok(!revArg||revArg==='7bcc624','baseline --revision supports exactly 7bcc624');
const sourceAt=(revision,path)=>revision?execFileSync('git',['show',`${revision}:${path}`],{cwd:root,encoding:'utf8'}):readFileSync(resolve(root,path),'utf8');
let assertions=0;
const check=(v,m)=>{assertions++;assert.ok(v,m);};
function harness(source,revision=null){
  let handler, providerOutput='{"prompt":"Add a family in the living room"}';
  let listingSpace='real_estate', listingReads=0;
  const events=[], prompts=[];
  const context=createContext({Request,Response,Headers,URL,TextEncoder,TextDecoder,AbortController,
    console,Buffer,Uint8Array,atob,btoa,setTimeout,clearTimeout,
    Deno:{env:{get:k=>k==='GEMINI_API_KEY'?'synthetic-not-a-key':undefined},serve:h=>handler=h},
    fetch:async()=>{events.push('provider-text');return Response.json({candidates:[{content:{parts:[{text:providerOutput}]}}]});}});
  const cache=new Map();
  const db={from:()=>({select:()=>({eq:()=>({eq:()=>({maybeSingle:async()=>({data:{role:'owner'}})})})})})};
  const adapters={submit:async(step,input)=>{events.push('provider-image');prompts.push(input.prompt);return {id:'synthetic'};}};
  const stubs={
    '_shared/supabase.ts':{getUser:async()=>({id:'synthetic-user'}),adminClient:()=>db,userClient:()=>db,orgForUser:async()=> 'synthetic-org',preferredOrg:()=>null,listingSpaceType:async()=>{listingReads++;return listingSpace;}},
    '_shared/ratelimit.ts':{durableRateLimit:async k=>{events.push('charge:'+k);return true;},refundRateLimit:async k=>events.push('refund:'+k)},
    '_shared/entitlements.ts':{entitlementForCharge:async()=>({plan:'pro',photo_edits_per_month:100}),quotaError:()=>new Error('unexpected quota')},
    '_shared/provenance.ts':{recordProvenance:async(req,p)=>{events.push('provenance:'+p.kind);return {id:'synthetic-provenance',recorded:true,disclosure:'Synthetic disclosure'};}},
    '_shared/ledger.ts':{APP_AI_UNIT_CENTS:{gemini_image:3.9},recordRoutedAiCost:async()=>events.push('ledger')},
    '_shared/router.ts':{routerEnabled:async()=>false},
    '_shared/providers/index.ts':{adapterFor:()=>adapters},
    '_shared/providers/chain.ts':{resolveChain:async(task,ctx,step)=>{events.push('resolve');return [step];},runChain:async(task,steps,run)=>({step:steps[0],value:await run(steps[0])})},
    '_shared/providers/common.ts':{BUDGETS:{totalImageMs:100},ProviderError:Error,awaitJob:async()=>({}),inlineBase64:()=> 'synthetic-image-bytes',inlineImageResult:async()=>({mime:'image/png'}),routedR2Key:()=> 'unused'},
  };
  function load(path,override){
    if(cache.has(path)) return cache.get(path).exports;
    const key=path.slice(fnroot.length+1);
    if(stubs[key]) return stubs[key];
    check(['_shared/http.ts','_shared/cors.ts','_shared/fairhousing.ts','ai-copy/prompt.ts','ai-photo/index.ts'].includes(key),'Only audited pure modules may load: '+key);
    const module={exports:{}};cache.set(path,module);
    const js=ts.transpileModule(override??sourceAt(revision,'services/supabase/functions/'+key),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
    const wrapper=new Script('(function(require,module,exports){'+js+'\n})',{filename:key}).runInContext(context);
    wrapper(spec=>load(resolve(dirname(path),spec)),module,module.exports);return module.exports;
  }
  load(file,source);
  const guard=load(resolve(fnroot,'_shared/fairhousing.ts'));
  return {events,prompts,guard,setOutput:text=>providerOutput=text,setListingSpace:space=>listingSpace=space,getListingReads:()=>listingReads,call:async body=>{events.length=0;prompts.length=0;listingReads=0;const response=await handler(new Request('http://synthetic.invalid/ai-photo',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)}));return {status:response.status,body:await response.json()};}};
}

const cases=[];
for(const revision of ['8d32f85','7bcc624']) {
 for(const edit of ['declutter','stage']) {
  const h=harness(sourceAt(revision,'services/supabase/functions/ai-photo/index.ts'),revision);
  const response=await h.call({space_type:'real_estate',edit,image_b64:'synthetic-only',style:'modern'});
  assert.equal(response.status,200);assert.equal(h.prompts.length,1);
  cases.push({revision,edit,prompt:h.prompts[0]});
 }
}
console.log(JSON.stringify(cases,null,2));
