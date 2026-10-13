// Actual POST handler and unchanged private-media signer/authority. Auth,
// funding, provider, ledger/history and R2 transports are closed doubles: no
// paid request, customer account, object write or production key is used.
import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { privateMediaAuthority, privateMediaIdentity, privateMediaUrl, verifyPrivateCapability } from "../_shared/private-media.ts";
const actor="10000000-0000-4000-8000-000000000001",org="20000000-0000-4000-8000-000000000002",listing="30000000-0000-4000-8000-000000000003",result="40000000-0000-4000-8000-000000000004";
const key=`ai-voice/${org}/${result}.mp3`;
const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
const constants = ["MAX_TEXT_CHARS", "AUDIO_URL_TTL_SECONDS", "ELEVEN_BASE", "OUTPUT_FORMAT", "OUTPUT_BITRATE", "OUTPUT_MIME", "VOICE_ID_RE"].map(name=>{
  const match=source.match(new RegExp(`const ${name}[^;]*;`)); assert(match,`${name} actual constant`); return match[0];
}).join("\n");
const helperStart=source.indexOf("interface CaptionWord"),helperEnd=source.indexOf("// ── Routes",helperStart);
assert(helperStart>0&&helperEnd>helperStart);
const helpers=source.slice(helperStart,helperEnd);
const bodyStart=source.indexOf("interface TtsBody"),handlerStart=source.indexOf("Deno.serve(async (req) => {");
assert(bodyStart>helperEnd&&handlerStart>bodyStart&&source.trimEnd().endsWith("});"));
const bodyType=source.slice(bodyStart,source.indexOf("/** Voice ids",bodyStart));
const handler=source.slice(handlerStart+"Deno.serve(".length).trimEnd().slice(0,-2);
const dataModule=(text:string)=>"data:application/typescript;base64,"+btoa(String.fromCharCode(...new TextEncoder().encode(text)));
async function fixture(oldTTL=false){
  const usedConstants=oldTTL?constants.replace("const AUDIO_URL_TTL_SECONDS = 600;","const AUDIO_URL_TTL_SECONDS = 900;"):constants;
  if(oldTTL)assert(usedConstants!==constants,"Old 900-second caller control must compile a real mutation");
  const mod=await import(dataModule(`
    import {HttpError,assert,json,pathSegments,readJson,respondError} from ${JSON.stringify(new URL("../_shared/http.ts",import.meta.url).href)};
    import {ProviderError,definitiveSubmitRejection} from ${JSON.stringify(new URL("../_shared/providers/common.ts",import.meta.url).href)};
    import {assertMarketingCopy} from ${JSON.stringify(new URL("../_shared/fairhousing.ts",import.meta.url).href)};
    import {privateMediaUrl} from ${JSON.stringify(new URL("../_shared/private-media.ts",import.meta.url).href)};
    ${usedConstants}\n${helpers}\n${bodyType}
    export function make(state:any){
      const ELEVENLABS_MODEL_ID="eleven_multilingual_v2",TARIFF_VERSION="closed-fixture",R2_BUCKET_UPLOADS="closed-uploads",voicesCache=null;
      const handleOptions=()=>new Response(null,{status:204}),requireElevenLabs=()=>{},elevenHeaders=()=>({"xi-api-key":"inert-fixture"});
      const getUser=async()=>({id:${JSON.stringify(actor)},is_anonymous:false});
      const userClient=()=>({}),adminClient=()=>({rpc:()=>{throw Error("Unexpected database dispatch");}});
      const listingSpaceType=async()=>"real_estate",voiceNameFor=async()=>"Synthetic Voice";
      const orgForUser=async()=>${JSON.stringify(org)},preferredOrg=()=>${JSON.stringify(org)},durableRateLimit=async()=>true,fetchVoices=async()=>[];
      const guardTTS=async()=>{state.charges++;return{orgId:${JSON.stringify(org)},plan:"team"};};
      const refundCharge=async()=>{state.refunds++;};
      const reserveVoiceStorage=async()=>({key:${JSON.stringify(key)}}),assertVoiceWriteWindow=()=>{};
      const ttsStep=async()=>({provider:"elevenlabs",model:"with-timestamps",unit:"1k_chars",unit_cents:22});
      const fundingContext=async()=>({requestKey:"synthetic-voice-request"});
      const fundedAttempt=async(_a:any,_b:any,_c:any,_d:any,_e:any,execute:()=>Promise<any>)=>{state.fundedAttempts++;return await execute();};
      const presignPut=async()=>"https://closed-storage.invalid/voice.mp3";
      const fetch=async(url:string,init:any)=>{
        if(url.startsWith("https://api.elevenlabs.io/v1/text-to-speech/")){
          assert(init.method==="POST",500,"Unexpected provider method");state.providerCalls++;
          return Response.json({audio_base64:btoa("SYNTHETIC-MP3-BYTES"),alignment:{characters:["H","e","l","l","o"],character_start_times_seconds:[0,.1,.2,.3,.4],character_end_times_seconds:[.1,.2,.3,.4,.5]}});
        }
        assert(url==="https://closed-storage.invalid/voice.mp3"&&init.method==="PUT",500,"Unexpected network boundary");
        state.puts++;state.bytes=new Uint8Array(init.body);return new Response(null,{status:200});
      };
      const recordRoutedAiCost=async()=>{state.ledgers++;};
      const recordProvenance=async()=>({id:${JSON.stringify(result)},recorded:true,disclosure:"AI generated narration"});
      const saveSharedVoice=async(_a:any,_b:any,row:any)=>{state.saved=row;return ${JSON.stringify(result)};};
      return ${handler};
    }
  `));
  const state={charges:0,refunds:0,fundedAttempts:0,providerCalls:0,puts:0,ledgers:0,bytes:new Uint8Array(),saved:null as any};
  return{state,run:()=>mod.make(state)(new Request("https://fixture.invalid/ai-voice/tts",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":"synthetic-voice-request"},body:JSON.stringify({text:"Hello",voice_id:"synthetic-voice",listing_id:listing})}))};
}
async function setup<T>(run:()=>Promise<T>){
  const keys=["PRIVATE_MEDIA_DELIVERY","MEDIA_GATEWAY_SECRET"],prior=keys.map(k=>Deno.env.get(k));
  Deno.env.set(keys[0],"gateway-v1");Deno.env.set(keys[1],"a".repeat(64));
  try{return await run();}finally{keys.forEach((k,i)=>prior[i]===undefined?Deno.env.delete(k):Deno.env.set(k,prior[i]!));}
}
function downloadAuthority(revoked=false){
  return{async rpc(name:string,args:any){
    if(name==="library_media_delivery_admit")return{data:{admitted:true,legacy_unbudgeted:false},error:null};
    if(name==="listing_library_scope")return revoked?{data:null,error:{message:"RP403: Revoked library"}}:{data:{actor_id:actor,listing_id:listing,org_id:org,library_org_id:org,billing_org_id:org,team_org_id:null,library_owner_user_id:actor,listing_owner_user_id:actor,can_read:true,can_write:true,can_manage_subscription:true,role:"owner",access_mode:"own"},error:null};
    if(name==="hosting_retention_state")return{data:{org_id:org,policy:"preserved",protected:true,retention_ends_at:null,hosting_available:true},error:null};
    if(name==="studio_presenter_media_visibility")return{data:{assets:{},renders:{},keys:Object.fromEntries(args.p_keys.map((k:string)=>[k,true]))},error:null};
    throw Error("Unexpected authority RPC "+name);
  },from(table:string){
    const filters:any={};const q:any={select:()=>q,eq:(k:string,v:unknown)=>{filters[k]=v;return q;},is:()=>q,in:()=>q,limit:()=>q,maybeSingle:async()=>reply(),then:(resolve:any)=>Promise.resolve(reply()).then(resolve)};
    function reply(){
      if(table==="profiles")return{data:{id:actor},error:null};
      if(table==="deletion_requests")return{data:[],error:null};
      if(table==="listings")return{data:{id:listing,org_id:org,deleted_at:null},error:null};
      if(table==="private_ai_outputs")return{data:null,error:null};
      if(table==="voice_storage_reservations")return{data:{actor_id:actor,org_id:org,listing_id:listing,storage_key:filters.storage_key===key?key:null},error:null};
      throw Error("Unexpected authority table "+table);
    }return q;
  }};
}
Deno.test("actual voice POST returns a valid <=600-second private download and keeps exact audio/history",()=>setup(async()=>{
  const f=await fixture(),before=Math.floor(Date.now()/1000),response=await f.run();assertEquals(response.status,200);
  const body=await response.json(),identity=privateMediaIdentity(body.audio_url);assert(identity);
  assert(identity.exp>=before+600&&identity.exp<=Math.floor(Date.now()/1000)+600,"600-second expiry is measured inside the actual request, across possible clock rollover");
  assertEquals({actor:identity.actor,org:identity.org,listing:identity.listing,bucket:identity.bucket,key:identity.key},{actor,org,listing,bucket:"uploads",key});
  const token=new URL(body.audio_url).pathname.slice("/private-media/".length);assertEquals(await verifyPrivateCapability(token),identity);
  assertEquals(await privateMediaAuthority(downloadAuthority(),token,f.state.bytes.length),{schema:1,slug:"private",objects:{[key]:"uploads"},stream_uid:null});
  assertEquals(new TextDecoder().decode(f.state.bytes),"SYNTHETIC-MP3-BYTES");assertEquals(f.state.refunds,0);assertEquals([f.state.charges,f.state.fundedAttempts,f.state.providerCalls,f.state.puts,f.state.ledgers],[1,1,1,1,1]);
  assertEquals(f.state.saved.key,key);assert(!JSON.stringify(f.state.saved).includes("private-media"));assertEquals(body.words,[{text:"Hello",start:0,end:.5}]);assertEquals(body.shared_result_id,result);
}));
Deno.test("actual returned voice capability still requires fresh ownership on download",()=>setup(async()=>{
  const f=await fixture(),body=await(await f.run()).json(),token=new URL(body.audio_url).pathname.slice("/private-media/".length);
  await assertRejects(()=>privateMediaAuthority(downloadAuthority(true),token,f.state.bytes.length),HttpError,"Revoked library");
}));
Deno.test("compiled old 900-second caller reproduces the phone refusal after storage, without deleting paid bytes",()=>setup(async()=>{
  const f=await fixture(true),response=await f.run();assertEquals(response.status,503);const body=await response.json();assertEquals(body.error,"Media expiry could not be verified.");assertEquals(body.audio_url,undefined);
  assertEquals([f.state.providerCalls,f.state.puts,f.state.refunds],[1,1,1]);assertEquals(new TextDecoder().decode(f.state.bytes),"SYNTHETIC-MP3-BYTES");assertEquals(f.state.saved,null);
}));
Deno.test("shared privacy bound remains strict for extended caller lifetimes",()=>setup(async()=>{
  for(const ttl of [601,900])await assertRejects(()=>privateMediaUrl({actor,org,listing,bucket:"uploads",key},ttl),HttpError,"Media expiry could not be verified.");
}));
