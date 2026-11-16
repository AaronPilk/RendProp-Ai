import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
const encode=(s:string)=>"data:application/typescript,"+encodeURIComponent(s);
const body=(s:string,name:string)=>{const a=s.indexOf(`function ${name}(`),b=s.indexOf("\n}\n",a);assert(a>=0&&b>a);return s.slice(a,b+3);};
async function actualPersistence(dropJournal=false){
 const source=await Deno.readTextFile(new URL("../_shared/providers/common.ts",import.meta.url));
 let method=body(source,"persistResult");
 if(dropJournal){const anchor="await beforeWrite?.({ key: r2Key, bytes: inlineData.bytes.byteLength });";assert(method.includes(anchor));method=method.replace(anchor,"");}
 return await import(encode(`
  // Each compiled fixture owns fresh transport state.
  // ${crypto.randomUUID()}
  type DoneState=any;class ProviderError extends Error{constructor(...v:any[]){super(String(v[2]));}}
  export const order:string[]=[];
  const decodeDataUrl=()=>({bytes:new Uint8Array([1,2,3]),mime:"video/mp4"});
  const R2_BUCKET_RENDERS="renders",MAX_PERSIST_BYTES=200000000,BUDGETS={transferMs:30000};
  const fetchBounded=()=>{throw Error("No remote fixture transport");};
  const putBytes=async(_bucket:any,key:string,bytes:Uint8Array)=>{order.push("put");return {key,bytes:bytes.byteLength};};
  export async ${method}
 `));
}
async function requireBeforeWrite(m:any){
 const stored=await m.persistResult("fal",{status:"done",result_url:"data:video/mp4;base64,AQID",mime:"video/mp4"},"ai-router/synthetic/reel/result.mp4",async(intent:any)=>{m.order.push("journal");assertEquals(intent,{key:"ai-router/synthetic/reel/result.mp4",bytes:3});});
 assertEquals(m.order,["journal","put"],"exact bytes journal must precede the object write");assertEquals(stored.bytes,3);
}
Deno.test("actual video persistence journals exact downloaded bytes before PUT",async()=>{await requireBeforeWrite(await actualPersistence());});
Deno.test("actual video journal authority/storage refusal never writes an untracked object",async()=>{
 const m=await actualPersistence();
 await assertRejects(()=>m.persistResult("fal",{status:"done",result_url:"data:video/mp4;base64,AQID",mime:"video/mp4"},"owned-key",async()=>{throw Error("Deleted listing");}),Error,"Deleted listing");
 assertEquals(m.order,[]);
});
Deno.test("compiled missing-journal fault fails the same exact write boundary",async()=>{
 const mutant=await actualPersistence(true);await assertRejects(()=>requireBeforeWrite(mutant),Error,"exact bytes journal must precede");
});
