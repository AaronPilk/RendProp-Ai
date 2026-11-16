import {assertEquals,assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {HttpError} from "../_shared/http.ts";
import {PHOTO_INPUT_POLICY,PHOTO_OUTPUT_POLICY,validatePhotoInput,validatePhotoOutput} from "./input-policy.ts";
import {preparePhoto2KInput,preparePhoto4KInput,PHOTO_4K_PREPARED_INPUT_BYTES} from "./photo-quality.ts";
import type {GenerateInput} from "../_shared/providers/types.ts";
const b64=(bytes:Uint8Array)=>{const parts:string[]=[];for(let n=0;n<bytes.length;n+=32768)parts.push(String.fromCharCode(...bytes.subarray(n,n+32768)));return btoa(parts.join(""));};
function jpeg(size:number,width=1536,height=2048){
 const frame=new Uint8Array([255,216,255,192,0,11,8,height>>8,height&255,width>>8,width&255,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]);
 const bytes=new Uint8Array(size);bytes.set(frame.subarray(0,2));let offset=2,left=size-frame.length;
 while(left){let length=Math.min(65000,left);if(left-length>0&&left-length<4)length-=4;bytes.set([255,224,(length-2)>>8,(length-2)&255],offset);offset+=length;left-=length;}
 bytes.set(frame.subarray(2),offset);return b64(bytes);
}
Deno.test("normal4K editing copies retain the combined9MB contract and saved2K compatibility",()=>{
 assertEquals(PHOTO_INPUT_POLICY.maxDecodedBytes,9_000_000);assertEquals(PHOTO_4K_PREPARED_INPUT_BYTES,9_000_000);
 const input=(image:string,reference?:string):GenerateInput=>({task:"photo.stage",prompt:"Add movable furniture only.",image_b64:image,extra:{image_mime:"image/jpeg",...(reference?{staging_reference_b64:reference,staging_reference_mime:"image/jpeg"}:{})}});
 const at=jpeg(9_000_000),legacy=jpeg(1_612_009),above=jpeg(9_000_001),half=jpeg(4_500_000),halfAbove=jpeg(4_500_001);
 assertEquals(preparePhoto4KInput(input(at)).image_b64,at,"The exact accepted source is preserved without recompression");
 assertEquals(preparePhoto4KInput(input(legacy)).image_b64,legacy,"Installed clients above1MB remain compatible");
 assertEquals(preparePhoto2KInput(input(at)).image_b64,at);
 assertThrows(()=>preparePhoto4KInput(input(above)),HttpError);
 // The helper retains its complete combined bound; the public reference flow
 // is separately unavailable and must still refuse before supplier dispatch.
 assertEquals(preparePhoto4KInput(input(half,half)).extra?.staging_reference_b64,half);
 assertThrows(()=>preparePhoto4KInput(input(half,halfAbove)),HttpError,"9 MB combined");
});
Deno.test("4K output exact25MiB succeeds while one byte above is rejected before binary decode with incurred-cost detail",()=>{
 assertEquals(PHOTO_OUTPUT_POLICY.maxDecodedBytes,25*1024*1024);
 const at=jpeg(25*1024*1024,3584,4780),above=jpeg(25*1024*1024+1,3584,4780);
 assertEquals(above.length,at.length,"The byte limit must still refuse when the base64 quartet count is unchanged");
 assertEquals(validatePhotoOutput(at,"image/jpeg").bytes,25*1024*1024);
 const saved=globalThis.atob;let decoded=0;globalThis.atob=(s)=>{decoded++;return saved(s);};
 try{const error=assertThrows(()=>validatePhotoOutput(above,"image/jpeg"),HttpError,"already processed");
  assertEquals(decoded,0);assertEquals(error.details?.failure_phase,"photo_output_size");assertEquals(error.details?.provider_cost_incurred,true);
 }finally{globalThis.atob=saved;}
});

Deno.test("calibration parser admits exact9MB existing source and refuses its next byte",async()=>{
 const {calibrationRequest}=await import("./photo-qc-calibration.ts");
 const raw=(source:string)=>({generation_request_key:"existing-paid-photo",generation_request_body:{listing_id:"f8200000-0000-4000-8000-000000000011",original_asset_id:"f8200000-0000-4000-8000-000000000031",image_b64:source,mime:"image/jpeg",edit:"declutter"}});
 const at=jpeg(9_000_000);assertEquals(calibrationRequest(raw(at)).generation_request_body.image_b64,at);
 assertThrows(()=>calibrationRequest(raw(jpeg(9_000_001))),HttpError);
});
