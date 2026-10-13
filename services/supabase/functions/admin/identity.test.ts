// Exact admin route guard, with closed Auth and profile boundaries.
import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
const encode = (value: string) => btoa(String.fromCharCode(...new TextEncoder().encode(value)));
async function compile(removeVerifiedGuard = false) {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  const a = source.indexOf("async function requireAdmin("), b = source.indexOf("\n}\n", a);
  assert(a > 0 && b > a); let body = source.slice(a,b+3);
  if (removeVerifiedGuard) {
    const guard = /  if \(user\.is_anonymous !== false \|\| !user\.email_confirmed_at\) \{[\s\S]*?\n  }/;
    assert(guard.test(body)); body = body.replace(guard, "");
  }
  return await import("data:application/typescript;base64,"+encode(`
    import {HttpError} from ${JSON.stringify(new URL("../_shared/http.ts",import.meta.url).href)};
    type AdminCaller={userId:string};let user:any,profile:any,reads=0;
    const getUser=async()=>user,adminClient=()=>({from:()=>({select:()=>({eq:()=>({maybeSingle:async()=>{reads++;return profile;}})})})});
    ${body}
    export async function check(u:any,p:any){user=u;profile=p;reads=0;return requireAdmin(new Request("https://fixture.invalid/admin"));}
    export const readCount=()=>reads;
  `));
}
Deno.test("actual admin guard requires verified named Auth identity before its profile lookup", async()=>{
  const m=await compile(),p={data:{is_admin:true},error:null};
  for(const u of [{id:"owner",is_anonymous:false,email_confirmed_at:null},{id:"guest",is_anonymous:true,email_confirmed_at:"verified"},{id:"unknown",email_confirmed_at:"verified"}]){
    const error=await assertRejects(()=>m.check(u,p),HttpError);assertEquals(error.status,403);assertEquals(m.readCount(),0);
  }
  assertEquals(await m.check({id:"owner",is_anonymous:false,email_confirmed_at:"verified"},p),{userId:"owner"});
  assertEquals(m.readCount(),1);
});
Deno.test("verified identity cannot override absent or unreadable admin authority",async()=>{
  const m=await compile(),u={id:"tenant",is_anonymous:false,email_confirmed_at:"verified"};
  for(const p of [{data:{is_admin:false},error:null},{data:null,error:null},{data:{is_admin:true},error:{message:"unavailable"}}]){
    const error=await assertRejects(()=>m.check(u,p),HttpError);assertEquals(error.status,403);
  }
});
Deno.test("compiled missing-verification control exposes unconfirmed administrative access",async()=>{
  const m=await compile(true);
  assertEquals(await m.check({id:"unconfirmed",is_anonymous:false,email_confirmed_at:null},{data:{is_admin:true},error:null}),{userId:"unconfirmed"});
});
