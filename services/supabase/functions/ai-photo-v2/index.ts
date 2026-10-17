// Only a versioned transport alias. Authentication, scope, input, recovery,
// payment and photo-quality authority remain inside the single strict handler.
import {handleAIPhoto} from "../ai-photo/index.ts";
import {HttpError,respondError} from "../_shared/http.ts";
import {corsHeaders} from "../_shared/cors.ts";
import {PHOTO_QUALITY_PROTOCOL_HEADER} from "../ai-photo/protocol.ts";
const cors={...corsHeaders,"Access-Control-Allow-Headers":corsHeaders["Access-Control-Allow-Headers"]+", "+PHOTO_QUALITY_PROTOCOL_HEADER,"Access-Control-Allow-Methods":"GET, POST, OPTIONS"};
function reply(response:Response):Response{
 const headers=new Headers(response.headers);for(const[k,v]of Object.entries(cors))headers.set(k,v);
 headers.set("cache-control","no-store");
 return new Response(response.body,{status:response.status,statusText:response.statusText,headers});
}
/** No target parameter, body read/clone, redirect or extra HTTP hop. */
export function canonicalPhotoRequest(req:Request):Request{
 const url=new URL(req.url),paths:Record<string,string>={
  "/ai-photo-v2":"/ai-photo","/ai-photo-v2/status":"/ai-photo/status",
  "/functions/v1/ai-photo-v2":"/functions/v1/ai-photo","/functions/v1/ai-photo-v2/status":"/functions/v1/ai-photo/status",
 };
 const path=paths[url.pathname];
 if(!path)throw new HttpError(404,"This photo route is unavailable.","not_found");
 const status=path.endsWith("/status");
 if(req.method!=="OPTIONS"&&req.method!==(status?"GET":"POST"))throw new HttpError(405,"Use POST for a photo edit or GET for its saved status.");
 url.pathname=path;
 // Request-as-init forwards the existing body stream/signal and all transport
 // fields. It does not parse, clone/tee or stringify the image payload.
 return new Request(url,req);
}
export async function handleAIPhotoV2(req:Request,run:(req:Request)=>Promise<Response>=handleAIPhoto):Promise<Response>{
 try{return reply(await run(canonicalPhotoRequest(req)));}catch(error){return reply(respondError(error));}
}
export const handler=(req:Request)=>handleAIPhotoV2(req);
if(import.meta.main)Deno.serve(handler);
