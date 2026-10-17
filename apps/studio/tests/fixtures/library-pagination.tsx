import {createRoot} from "react-dom/client";
import type {Session, AuthChangeEvent} from "@supabase/auth-js";
import App from "../../src/App";
import {createStudioServices, type StudioAuth} from "../../src/data/services";
import "../../src/styles.css";
import "../../src/design/studio.css";

// Test entry only: actual App and typed services, inert Auth/HTTP, no model or writes.
const A="11111111-1111-4111-8111-111111111111",B="22222222-2222-4222-8222-222222222222";
const OWN="33333333-3333-4333-8333-333333333333",OTHER="44444444-4444-4444-8444-444444444444";
const PHYSICAL="77777777-7777-4777-8777-777777777777",MOVED="99999999-9999-4999-8999-999999999999",FIRST="55555555-5555-4555-8555-555555555555",SECOND="66666666-6666-4666-8666-666666666666";
let actor=A,active=OWN,physical=PHYSICAL,directoryMode="ok",mediaMode="ok",removed=false,revision=0,directoryHeld=false;
const heldOffsets=new Set<number>();
let directoryRelease:(()=>void)[]=[];let pageRelease:(()=>void)[]=[];
let notify:(event:AuthChangeEvent,next:Session|null)=>void=()=>{};
const calls:{path:string;offset?:number;actor:string;library:string;listing?:string;method:string;aborted?:boolean;mapping:number}[]=[];
let mapping=0;
function session():Session{return{access_token:"inert-pagination-fixture-token",refresh_token:"inert-pagination-fixture-refresh",token_type:"bearer",expires_in:3600,user:{id:actor,aud:"authenticated",created_at:"2026-10-16T00:00:00Z",app_metadata:{},user_metadata:{}}};}
const auth:StudioAuth={getSession:async()=>({data:{session:session()},error:null}),refreshSession:async()=>({data:{session:session()},error:null}),onAuthStateChange:cb=>{notify=cb;return{data:{subscription:{unsubscribe(){}}}};},signInWithOAuth:async()=>{throw Error("No live sign-in");},signOut:async()=>{notify("SIGNED_OUT",null);return{error:null};}};
const own=()=>actor===A?OWN:OTHER;
const label=(who:string,lib:string,listing=FIRST)=>`${who===A?"A":"B"} ${lib===OWN?"Own":"Other"} ${listing===FIRST?"House":"Second"}`;
const row=(lib:string,id=FIRST)=>({id,org_id:physical,library_org_id:lib,agent_id:lib===OWN?A:B,space_type:"real_estate",address:label(actor,lib,id),tagline:null,details:{},status:"ready",sold_at:"2026-10-01T00:00:00Z",created_at:"2026-10-01T00:00:00Z",deleted_at:null,main_photo_key:null,beds:null,baths:null,sqft:null,price_cents:null});
function directory(){return{actor_id:actor,own_org_id:own(),billing_org_id:OWN,active_org_id:active,can_switch_agent_libraries:actor===A,workspaces:(actor===A?[OWN,OTHER]:[OTHER]).map(id=>({id,name:id===OWN?"Own library":"Other library",space_type:"real_estate",library_owner_user_id:id===OWN?A:B,role:id===own()?"owner":"team_owner",access_mode:id===own()?"own":"team_owner",billing_org_id:OWN,can_read:true,can_write:true,can_manage_subscription:id===own()}))};}
function media(who:string,lib:string,listing:string,offset:number,org:string){const exp=Math.floor(Date.now()/1000)+550+revision;return{org_id:org,listing_id:listing,photos:Array.from({length:Math.max(0,Math.min(50,101-offset))},(_,i)=>{const n=offset+i+1,id=`88888888-8888-4888-8888-${String(n).padStart(12,"0")}`,payload={v:1,actor:who,org,listing,bucket:"uploads",key:`uploads/${org}/${listing}/${id}.jpg`,exp};return{id,listing_id:listing,caption:`${label(who,lib,listing)} photo${n}`,is_staged:false,sort:n,url:`https://rendprop.com/private-media/${btoa(JSON.stringify(payload)).replaceAll("+","-").replaceAll("/","_").replace(/=+$/,"")}.${"a".repeat(64)}`,expires_at:new Date(exp*1000).toISOString()};}),videos:[],next_offset:offset+50<101?offset+50:null,unavailable_count:0};}
const fetcher:typeof fetch=async(input,options={})=>{
 const url=new URL(String(input)),org=new Headers(options.headers).get("X-Org-Id")??active,lib=url.pathname.endsWith("/media")?active:org,who=actor,listing=url.searchParams.get("listing_id")??undefined;
 const call={path:url.pathname,actor:who,library:lib,org,listing,method:options.method??"GET",mapping,...url.pathname.endsWith("/media")?{offset:Number(url.searchParams.get("offset"))}:{}};calls.push(call);options.signal?.addEventListener("abort",()=>Object.assign(call,{aborted:true}),{once:true});
 if(call.method!=="GET")throw Error("No writes in Library fixture");
 if(url.pathname==="/functions/v1/me/workspaces"){
  if(directoryHeld)await new Promise<void>(done=>directoryRelease.push(done));
  if(directoryMode==="503"||directoryMode==="403")return Response.json({}, {status:Number(directoryMode)});
  if(directoryMode==="malformed")return Response.json({actor_id:actor});
  return Response.json(directory());
 }
 if(url.pathname==="/functions/v1/me"){active=lib;return Response.json({user:{id:actor,name:actor===A?"Account A":"Account B",email:null,avatar_url:null,real_estate_role:"agent"},org:{id:lib,name:lib===OWN?"Own library":"Other library",space_type:"real_estate",handle:null},billing:{content_org_id:lib,org_id:OWN,serving_org_id:OWN,can_manage_subscription:lib===own()},plan:"free",plan_raw:"free",trial_ends_at:null,plan_expires_at:null,usage:{listings:2,leads:0,leads_new:0,renders:0}});}
 if(url.pathname==="/functions/v1/listings"){mapping++;const rows=removed?[]:[row(lib),row(lib,SECOND)];return Response.json({actor_id:actor,listings:rows,total:rows.length,next_offset:null});}
 if(url.pathname==="/functions/v1/studio/media"){
  if(heldOffsets.has(call.offset!))await new Promise<void>(done=>pageRelease.push(done)); // ignore abort intentionally: late bytes must remain fenced
  if(mediaMode==="503"||mediaMode==="403")return Response.json({}, {status:Number(mediaMode)});
  if(mediaMode==="malformed")return Response.json({org_id:org,listing_id:listing,photos:"invalid"});
  return Response.json(media(who,lib,listing!,call.offset!,org));
 }
 if(url.pathname==="/functions/v1/spatial/capability")return Response.json({enabled:false});
 throw Error(`Unexpected Library fixture request ${url.pathname}`);
};
const services=createStudioServices({supabaseUrl:"https://library-pagination-fixture.supabase.co",publishableKey:"sb_publishable_INERT_PAGINATION_FIXTURE",redirectTo:window.location.origin+"/"},{auth,fetch:fetcher,readTimeoutMs:8000});
Object.assign(window,{libraryFixture:{
 ids:{OWN,OTHER,PHYSICAL,MOVED,FIRST,SECOND},calls:()=>structuredClone(calls),holdDirectory(){directoryHeld=true;},releaseDirectory(){directoryHeld=false;directoryRelease.splice(0).forEach(done=>done());},holdPages(offset=50){heldOffsets.add(offset);},releasePages(){heldOffsets.clear();pageRelease.splice(0).forEach(done=>done());},setDirectoryMode(mode:string){directoryMode=mode;},setMediaMode(mode:string){mediaMode=mode;},setRemoved(value:boolean){removed=value;},renew(){revision++;},movePhysical(){physical=MOVED;},switchActor(){actor=actor===A?B:A;active=own();notify("SIGNED_IN",session());},signOut(){notify("SIGNED_OUT",null);}
}});
createRoot(document.getElementById("root")!).render(<App servicesFactory={()=>services}/>);
