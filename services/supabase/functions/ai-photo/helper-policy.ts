// Price the same complete payload that is sent. No tools, grounding, caching,
// URL inputs or extra candidates can enter this helper contract.
import {TARIFF_VERSION,visionInputTokenBound,type AttemptQuote} from "../_shared/funded-serving.ts";
import {HttpError} from "../_shared/http.ts";
export const PHOTO_HELPER_MAX_OUTPUT_TOKENS=1024;
export type PhotoHelperPart={text:string}|{inline_data:{mime_type:string;data:string}};
export interface PhotoHelperPayload {
 contents:{role:"user";parts:PhotoHelperPart[]}[];
 generationConfig:{candidateCount:1;maxOutputTokens:1024;temperature:0.4;responseMimeType:"application/json"};
}
export function photoHelperPayload(parts:PhotoHelperPart[]):PhotoHelperPayload {
 const payload:PhotoHelperPayload={contents:[{role:"user",parts}],generationConfig:{candidateCount:1,maxOutputTokens:1024,temperature:0.4,responseMimeType:"application/json"}};
 if(!inspect(payload))throw new HttpError(400,"Use one bounded still photo or a short text instruction.");
 return payload;
}
function inspect(value:unknown):{media:boolean;textBytes:number}|null {
 const exact=(v:unknown,keys:string[])=>!!v&&typeof v==="object"&&!Array.isArray(v)&&Object.keys(v).sort().join("|")===keys.sort().join("|");
 if(!exact(value,["contents","generationConfig"]))return null;
 const p=value as PhotoHelperPayload,c=p.generationConfig;
 if(!exact(c,["candidateCount","maxOutputTokens","temperature","responseMimeType"])||c.candidateCount!==1||c.maxOutputTokens!==1024||c.temperature!==.4||c.responseMimeType!=="application/json"
  ||!Array.isArray(p.contents)||p.contents.length!==1||!exact(p.contents[0],["role","parts"])||p.contents[0].role!=="user")return null;
 const parts=p.contents[0].parts;if(!Array.isArray(parts)||parts.length<1||parts.length>2)return null;
 let texts=0,images=0,textBytes=0;
 for(const part of parts){
  if(exact(part,["text"])&&typeof (part as {text?:unknown}).text==="string"){
   texts++;textBytes+=new TextEncoder().encode((part as {text:string}).text).byteLength;
  }else if(exact(part,["inline_data"])){
   const image=(part as {inline_data:Record<string,unknown>}).inline_data;
   if(!exact(image,["mime_type","data"])||!["image/jpeg","image/png","image/webp"].includes(String(image.mime_type))||typeof image.data!=="string"||image.data.length>12000000||!image.data.length)return null;
   images++;
  }else return null;
 }
 if(texts!==1||images>1||textBytes===0||textBytes>8192)return null;
 return{media:images===1,textBytes};
}
/** The helper sends at most one ≤12 MB still plus ≤8 KB of text. Its input is
 * bounded by Google's documented image tokenisation (258 tokens per 768px
 * tile; a 2048px photo ≈ 2,322 tokens — visionInputTokenBound allows 2,048
 * per image plus text) rather than the whole context window. Output is the
 * hard maxOutputTokens cutoff over thought+answer tokens. The 1.5/7.5 rates
 * are the announced 2027 standard rates, higher than today's promotion.
 * This is a request liability hold, not an invoice reconciliation. */
export function photoHelperQuote(model:string,payload:unknown):AttemptQuote|null {
 const input=inspect(payload);if(model!=="gemini-3.6-flash"||!input)return null;
 const tokens=input.media?visionInputTokenBound(1,input.textBytes):Math.ceil(input.textBytes/2)+1024;
 return{cents:(tokens*1.5+PHOTO_HELPER_MAX_OUTPUT_TOKENS*7.5)/10000,version:TARIFF_VERSION};
}
