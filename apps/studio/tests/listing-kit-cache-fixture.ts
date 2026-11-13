import {buildKit,loadKit} from "../src/features/listings/delivery-kit";
import {kitFixture,workspace,listingA} from "./kit-fixtures";
type CacheCase={name:string;mediaOrigin:string;prime:boolean};
Object.assign(window,{runKitCache:async(params:CacheCase)=>{
 const f=kitFixture(),signal=new AbortController().signal,snapshot=await loadKit(f.services,workspace,listingA,signal);
 snapshot.published=null;snapshot.script="";const mapped=`${params.mediaOrigin}/image/${params.name}.png`;
 let image:HTMLImageElement|undefined;if(params.prime){image=new Image();image.src=mapped;document.body.append(image);await image.decode();if(!image.complete||image.naturalWidth!==1)throw new Error("The synthetic cache image did not load.");}
 const requestOptions:Record<string,unknown>[]=[];let result;
 try{const kit=await buildKit(snapshot,[snapshot.items[0].id],{services:f.services,workspace,signal,progress:()=>{},fetcher:(verified,init)=>{
  if(new URL(String(verified)).hostname!==`${"a".repeat(32)}.r2.cloudflarestorage.com`)throw new Error("Only the synthetic admitted R2 fixture may map to loopback.");
  requestOptions.push({cache:init?.cache??"default",credentials:init?.credentials,referrerPolicy:init?.referrerPolicy,redirect:init?.redirect});
  return fetch(mapped,init);
 }});result={outcome:"zip",bytes:Array.from(new Uint8Array(await kit.blob.arrayBuffer())),mediaCount:kit.mediaCount};}
 catch(error){result={outcome:"error",errorName:error instanceof Error?error.name:"unknown",errorMessage:error instanceof Error?error.message:"unknown"};}
 image?.remove();return{...result,requestOptions,fixtureMutationCount:f.calls.filter(x=>x.method!=="GET").length};
}});
