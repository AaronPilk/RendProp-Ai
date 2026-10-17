import { HttpError } from "../_shared/http.ts";
import { corsHeaders } from "../_shared/cors.ts";

/** Preserve the existing JSON/base64 wire contract without materializing a
 * second whole base64 JSON string and its UTF8 copy inside the edge isolate.
 * Pull-based32KiB chunks respect backpressure; clients still use response.json(). */
export function photoJsonResponse(metadata:Record<string,unknown>,imageB64:string,mime:string,assetKey:string):Response {
 const padding=imageB64.endsWith("==")?2:imageB64.endsWith("=")?1:0;
 if(!imageB64.length||imageB64.length%4||/[^A-Za-z0-9+/=]/.test(imageB64)
  ||imageB64.indexOf("=")!==(padding?imageB64.length-padding:-1))
  throw new HttpError(502,"The saved photo response could not be encoded safely.","upstream");
 const encoder=new TextEncoder();
 // Explicit fields keep the same override semantics as {...metadata,image_b64,
 // mime,asset_key}; a stored metadata field cannot inject another image value.
 const small=JSON.stringify({...metadata,image_b64:undefined,mime,asset_key:assetKey});
 const prefix=encoder.encode(small.slice(0,-1)+',"image_b64":"');
 let image=imageB64,offset=0,started=false;
 const stream=new ReadableStream<Uint8Array>({
  pull(controller){
   if(!started){started=true;controller.enqueue(prefix);return;}
   if(offset<image.length){const end=Math.min(offset+32768,image.length);controller.enqueue(encoder.encode(image.slice(offset,end)));offset=end;return;}
   controller.enqueue(new Uint8Array([34,125]));image="";controller.close();
  },
  cancel(){image="";}
 },{highWaterMark:0});
 return new Response(stream,{status:200,headers:{...corsHeaders,"Content-Type":"application/json; charset=utf-8"}});
}
