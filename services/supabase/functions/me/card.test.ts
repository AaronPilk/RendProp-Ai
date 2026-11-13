import {assert,assertEquals,assertRejects}from "https://deno.land/std@0.224.0/assert/mod.ts";
import {personalCard}from "./card.ts";
import {buildPersonalListingCard}from "../_shared/agentcard.ts";
import {HttpError}from "../_shared/http.ts";
const A="ca100501-0000-4000-8000-000000000001",B="ca100501-0000-4000-8000-000000000002";
function fixture(options:Record<string,unknown>={}){
 const calls:any[]=[];const admin={rpc:async(name:string,args:any)=>{calls.push({name,args});return{data:options.wrongUser?{user_id:B,space_type:null,public_card:null}:options.data??{user_id:A,space_type:null,public_card:null},error:options.error?{message:options.error}:null};}};
 return{admin,calls};
}
Deno.test("personal card read is bound to verified account without workspace or login email",async()=>{
 const f=fixture();assertEquals(await personalCard(f.admin,A),{ok:true,user_id:A,space_type:null,public_card:null});assertEquals(f.calls,[{name:"read_personal_public_card",args:{p_actor:A}}]);
});
Deno.test("personal card save preserves explicit field intent and absent/value baselines",async()=>{
 const f=fixture({data:{user_id:A,space_type:"real_estate",public_card:{name:"Person",email:"reviewed@fixture.invalid"}}});
 const body={changes:{space_type:"real_estate",name:"Person",email:"reviewed@fixture.invalid",phone:null},expected:{space_type:{present:false},name:{present:true,value:"Old Person"},email:{present:false},phone:{present:true,value:"5551110000"}}};
 const r=await personalCard(f.admin,A,body);assertEquals(r.public_card,{name:"Person",email:"reviewed@fixture.invalid"});assertEquals(f.calls,[{name:"merge_personal_public_card",args:{p_actor:A,p_changes:body.changes,p_expected:body.expected}}]);
});
Deno.test("personal card rejects profile/org/system/image fields and injected URLs before DB",async()=>{
 for(const changes of [{user_id:B},{business_logo_url:"https://evil.fixture.invalid"},{avatar_url:"https://evil.fixture.invalid"},{is_admin:"true"},{space_type:"foreign"},{website:"javascript:alert(1)"},{website:"https://user:pass@evil.fixture.invalid"},{name:"private@fixture.invalid"},{email:"invalid"},{phone:"bad\nvalue"}]){
  const f=fixture(),expected=Object.fromEntries(Object.keys(changes).map(key=>[key,{present:false}]));await assertRejects(()=>personalCard(f.admin,A,{changes,expected}),HttpError);assertEquals(f.calls,[]);
 }
 for(const expected of [{name:{}},{name:{present:true}},{name:{present:false,value:"wrong"}},{foreign:{present:false}}]){
  const f=fixture();await assertRejects(()=>personalCard(f.admin,A,{changes:{name:"Person"},expected}),HttpError);assertEquals(f.calls,[]);
 }
});
Deno.test("personal receipt rejects another identity or malformed card and sanitizes DB outages",async()=>{
 for(const options of [{wrongUser:true},{data:{user_id:A,space_type:"foreign",public_card:{}}},{data:{user_id:A,space_type:null,public_card:{business_logo_url:"evil"}}}])await assertRejects(()=>personalCard(fixture(options).admin,A),HttpError);
 for(const [error,status]of [["RP409: card changed",409],["RP403: deleting account",403],["private schema/token/provider detail",503]]as const){try{await personalCard(fixture({error}).admin,A);throw Error("unexpected accepted error");}catch(e){assert(e instanceof HttpError);assertEquals(e.status,status);if(status===503)assert(!e.message.includes("private schema"));}}
 assertEquals((await personalCard(fixture({data:{user_id:A,space_type:null,public_card:{}}}).admin,A)).public_card,{});
});
Deno.test("public team card uses reviewed member identity and scoped business fields",()=>{
 const card=buildPersonalListingCard({personal_card:{name:"Member",email:"member-public@fixture.invalid",phone:"5552220002",avatar_url:"https://unowned.fixture.invalid",business_logo_url:"https://unowned.fixture.invalid"},profile_name:"Member Profile",legacy_owned_single_member:false,legacy_brand:{name:"Inviter",email:"inviter@fixture.invalid"},org_business:{brokerage:"Office",accent:"#123456",business_logo_url:"https://owned.fixture.invalid/logo.png",email:"inviter@fixture.invalid",name:"Inviter"},org_handle:"office"});
 assertEquals(card,{name:"Member",handle:"office",email:"member-public@fixture.invalid",phone:"5552220002",brokerage:"Office",accent:"#123456",business_logo_url:"https://owned.fixture.invalid/logo.png"});
});
Deno.test("no-card team member never inherits inviter contact or private email",()=>{
 assertEquals(buildPersonalListingCard({personal_card:null,profile_name:"Member Profile",legacy_owned_single_member:false,legacy_brand:{name:"Inviter",email:"inviter@fixture.invalid"},org_business:{brokerage:"Office"},org_handle:"office"}),{name:"Member Profile",handle:"office",brokerage:"Office"});
 assertEquals(buildPersonalListingCard({personal_card:null,profile_name:null,legacy_owned_single_member:false}).name,null);
});
Deno.test("verified legacy sole-owner contact and supplied scoped portrait are preserved",()=>{
 assertEquals(buildPersonalListingCard({personal_card:null,profile_name:"Owner",legacy_owned_single_member:true,legacy_brand:{name:"Reviewed Owner",email:"owner-public@fixture.invalid"},org_business:{business_logo_url:"https://owned.fixture.invalid/logo.png"},org_handle:"owner"},"https://owned.fixture.invalid/portrait.jpg"),{name:"Reviewed Owner",handle:"owner",email:"owner-public@fixture.invalid",business_logo_url:"https://owned.fixture.invalid/logo.png",avatar_url:"https://owned.fixture.invalid/portrait.jpg"});
});

// Run the exact /me wrapper, substituting only verified Auth and RPC transport.
async function route(){
 const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url)),start=source.indexOf("Deno.serve(async (req) => {"),end=source.indexOf("\n});",start)+5;
 assert(start>=0&&end>start);
 const body=source.slice(start,end).trimEnd().replace("Deno.serve(async (req) => {","export const handler=async(req:Request)=>{").replace(/\n\}\);$/,"\n};");
 const code=`import{HttpError,assert,json,pathSegments,readJsonLimited,respondError}from ${JSON.stringify(new URL("../_shared/http.ts",import.meta.url).href)};import{handleOptions}from ${JSON.stringify(new URL("../_shared/cors.ts",import.meta.url).href)};import{personalCard}from ${JSON.stringify(new URL("./card.ts",import.meta.url).href)};export const state:any={actor:${JSON.stringify(A)},calls:[]};const getUser=async()=>{if(!state.actor)throw new HttpError(401,"Sign in required");return{id:state.actor}};const adminClient=()=>({rpc:async(name:string,args:any)=>{state.calls.push({name,args});return{error:null,data:{user_id:args.p_actor,space_type:null,public_card:null}}}});${body}`;
 return import("data:application/typescript;base64,"+btoa(String.fromCharCode(...new TextEncoder().encode(code))));
}
Deno.test("actual /me card route ignores selected team and binds current A/B account",async()=>{
 const f=await route();for(const actor of[A,B]){f.state.actor=actor;f.state.calls=[];const r=await f.handler(new Request("https://fixture.invalid/me/card",{headers:{"X-Org-Id":"foreign-or-absent"}}));assertEquals(r.status,200);assertEquals((await r.json()).user_id,actor);assertEquals(f.state.calls,[{name:"read_personal_public_card",args:{p_actor:actor}}]);}
 f.state.calls=[];let r=await f.handler(new Request("https://fixture.invalid/me/card",{method:"PATCH",body:JSON.stringify({changes:{name:"Reviewed"},expected:{name:{present:false}},user_id:A})}));assertEquals(r.status,400);assertEquals(f.state.calls,[]);
 f.state.actor=null;r=await f.handler(new Request("https://fixture.invalid/me/card"));assertEquals(r.status,401);
});
