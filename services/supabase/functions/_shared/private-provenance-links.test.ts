import {assert,assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {privateProvenanceLinks} from "./private-provenance-links.ts";
const org="10000000-0000-4000-8000-000000000001",listing="20000000-0000-4000-8000-000000000002",other="30000000-0000-4000-8000-000000000003",key=`renders/${org}/${listing}/original.jpg`,altered=`renders/${org}/${listing}/edited.jpg`;
Deno.test("private export signs only exact actor-authorized provenance mapping and truthfully distinguishes public availability",async()=>{
 let calls=0;const selected:string[]=[];const db={rpc:(_name:string,args:Record<string,unknown>)=>{calls++;assertEquals(args.p_listing,listing);return Promise.resolve({error:null,data:{assets:{},renders:{},keys:Object.fromEntries((args.p_keys as string[]).map(k=>[k,true]))}});}};
 const rows=await privateProvenanceLinks(db,org,[{listing_id:listing,original_key:key,altered_key:altered},{listing_id:listing,original_key:key.replace(listing,other),altered_key:"https://private.invalid/object"}],async(bucket,k,seconds)=>{assertEquals(seconds,600);assert(bucket.endsWith("renders"));selected.push(k);return "signed:"+k;});
 assertEquals(selected,[key,altered]);assertEquals(calls,3);assertEquals(rows[0],{original_url:"signed:"+key,altered_url:"signed:"+altered,original_available:false,original_download_available:true});assertEquals(rows[1],{original_url:null,altered_url:null,original_available:false,original_download_available:false});
});
Deno.test("private export discards a source withdrawn during capability signing",async()=>{
 let calls=0;const db={rpc:(_name:string,args:Record<string,unknown>)=>Promise.resolve({error:null,data:{assets:{},renders:{},keys:Object.fromEntries((args.p_keys as string[]).map(k=>[k,++calls===1]))}})};
 const [row]=await privateProvenanceLinks(db,org,[{listing_id:listing,original_key:key}],async()=>"private-signed-url");assertEquals(row.original_url,null);assertEquals(row.original_download_available,false);
});
Deno.test("private export final pass withdraws earlier groups while a later group signs",async()=>{
 const second=`renders/${org}/${other}/source.jpg`;let withdrawn=false;const db={rpc:(_name:string,args:Record<string,unknown>)=>Promise.resolve({error:null,data:{assets:{},renders:{},keys:Object.fromEntries((args.p_keys as string[]).map(k=>[k,!(withdrawn&&k===key)]))}})};
 const rows=await privateProvenanceLinks(db,org,[{listing_id:listing,original_key:key},{listing_id:other,original_key:second}],async(_bucket,k)=>{if(k===second)withdrawn=true;return "signed:"+k;});assertEquals(rows[0].original_url,null);assertEquals(rows[1].original_url,"signed:"+second);
});
