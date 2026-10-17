import {assert,assertEquals,assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {photoJsonResponse} from "./photo-response.ts";
Deno.test("photo response keeps the exact existing JSON/base64 fields with bounded UTF8 chunks",async()=>{
 const metadata={edit:"stage",style:"modern",disclosure:'Quoted "é" and backslash \\',image_b64:"metadata-cannot-override",mime:"bad",asset_key:"bad"};
 const b64="QUJD".repeat(25000),response=photoJsonResponse(metadata,b64,"image/jpeg","private/exact.jpg");
 assertEquals(response.status,200);assertEquals(response.headers.get("content-type"),"application/json; charset=utf-8");
 assert(response.headers.has("access-control-allow-origin"));
 const reader=response.body!.getReader(),chunks:Uint8Array[]=[];let size=0;
 for(;;){const item=await reader.read();if(item.done)break;assert(item.value.byteLength<=32768);chunks.push(item.value);size+=item.value.byteLength;}
 const joined=new Uint8Array(size);let offset=0;for(const chunk of chunks){joined.set(chunk,offset);offset+=chunk.length;}
 assertEquals(JSON.parse(new TextDecoder().decode(joined)),{...metadata,image_b64:b64,mime:"image/jpeg",asset_key:"private/exact.jpg"});
 assert(chunks.length>3,"The image must be emitted through multiple pulls");
 const ordinary=await photoJsonResponse({edit:"twilight"},"AA==","image/jpeg","private/one.jpg").json();
 assertEquals(ordinary,{edit:"twilight",image_b64:"AA==",mime:"image/jpeg",asset_key:"private/one.jpg"});
});
Deno.test("photo response rejects JSON injection and invalid inline syntax before returning a body",()=>{
 for(const invalid of ['AA"=','AA\\=','AA\n=','A===','AA=A','AAAA=',""])
  assertThrows(()=>photoJsonResponse({},invalid,"image/jpeg","private/a.jpg"));
});
