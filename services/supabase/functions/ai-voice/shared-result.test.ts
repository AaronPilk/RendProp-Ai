import { assertEquals, assertThrows } from "jsr:@std/assert";
import { sharedVoiceRow, saveSharedVoice, type SharedVoice } from "./shared-result.ts";
const user="10000000-0000-4000-8000-000000000001",org="20000000-0000-4000-8000-000000000002",listing="30000000-0000-4000-8000-000000000003",result="40000000-0000-4000-8000-000000000004";
const input:SharedVoice={userId:user,orgId:org,listingId:listing,key:`ai-voice/${org}/${result}.mp3`,requestKey:"phone-request",label:"Kitchen narration",voiceName:"Voice",duration:2,words:[{text:"Kitchen",start:0,end:1}],disclosure:"AI narration",provenanceId:null};
function fixture(options:{visible?:boolean;reserved?:boolean;failure?:boolean;stalled?:boolean}={}){
 const writes:unknown[]=[];const filters:unknown[]=[];
 const db={from(table:string){let signal:AbortSignal;const q:any={select(){return q;},eq(key:string,value:unknown){filters.push([table,key,value]);return q;},is(){return q;},abortSignal(value:AbortSignal){signal=value;return q;},insert(row:unknown){writes.push(row);return q;},async maybeSingle(){if(options.failure)throw Error("database unavailable");if(options.stalled)await new Promise((_,reject)=>{signal.addEventListener('abort',()=>reject(signal.reason),{once:true});});return {data:table==="studio_creative_results"?(options.reserved?{id:result,kind:"voice",listing_id:listing}:null):options.visible===false?null:{id:listing,org_id:org},error:null};},async single(){return {data:{id:result},error:null};}};return q;}};
 return {db:db as any,writes,filters};
}
Deno.test("phone voice history contains durable identity and actual alignment without signed links",()=>{
 const row=sharedVoiceRow(input);assertEquals(row.storage_key,input.key);assertEquals(row.metadata.words,input.words);assertEquals(row.metadata.duration_s,2);assertEquals(row.request_key,`native-voice:${result}`);assertEquals(JSON.stringify(row).includes("https:"),false);
});
Deno.test("voice history rejects malformed storage and unsupported timing",()=>{
 assertThrows(()=>sharedVoiceRow({...input,key:`ai-voice/${user}/${result}.mp3`}));
 assertThrows(()=>sharedVoiceRow({...input,duration:NaN}));
 assertThrows(()=>sharedVoiceRow({...input,words:[{text:"bad",start:2,end:1}]}));
});
Deno.test("named phone result is saved only after current listing and workspace reads",async()=>{
 const f=fixture();assertEquals(await saveSharedVoice(f.db,f.db,input),result);assertEquals(f.writes.length,1);
 assertEquals(f.filters.some(v=>JSON.stringify(v)===JSON.stringify(["listings","org_id",org])),true);
 assertEquals(f.filters.some(v=>JSON.stringify(v)===JSON.stringify(["studio_creative_results","user_id",user])),true);
});
Deno.test("Studio reservation prevents duplicate phone history entry",async()=>{
 const f=fixture({reserved:true});assertEquals(await saveSharedVoice(f.db,f.db,input),null);assertEquals(f.writes.length,0);
});
Deno.test("missing workspace and unavailable history preserve paid response without inserting",async()=>{
 for(const options of [{visible:false},{failure:true}]){const f=fixture(options);assertEquals(await saveSharedVoice(f.db,f.db,input),null);assertEquals(f.writes.length,0);}
});
Deno.test("one shared deadline releases already generated audio when history stalls",async()=>{
 const f=fixture({stalled:true});const signal=AbortSignal.timeout(20);
 assertEquals(await saveSharedVoice(f.db,f.db,input,signal),null);assertEquals(signal.aborted,true);assertEquals(f.writes.length,0);
});
