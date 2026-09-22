import {assertEquals,assertRejects,assertThrows} from "jsr:@std/assert";
import {validateVoiceReservation,reserveVoiceStorage,assertVoiceWriteWindow} from "./storage-reservation.ts";
const id="10000000-0000-4000-8000-000000000001",org="20000000-0000-4000-8000-000000000002",now=Date.parse("2026-09-14T18:00:00Z");
const reservation={reservation_id:id,key:`ai-voice/${org}/${id}.mp3`,write_deadline:"2026-09-14T18:15:00Z"};
Deno.test("reserved voice key stays bound to its generated identity and workspace",()=>{
 assertEquals(validateVoiceReservation(reservation,id,org,now),reservation);
 assertThrows(()=>validateVoiceReservation({...reservation,key:`ai-voice/${id}/${id}.mp3`},id,org,now));
 assertThrows(()=>validateVoiceReservation({...reservation,reservation_id:org},id,org,now));
});
Deno.test("expired and extended storage windows refuse new voice writes",()=>{
 assertThrows(()=>validateVoiceReservation(reservation,id,org,now+15*60*1000));
 assertThrows(()=>validateVoiceReservation({...reservation,write_deadline:"2026-09-14T19:00:00Z"},id,org,now));
 assertVoiceWriteWindow(reservation,now);assertThrows(()=>assertVoiceWriteWindow(reservation,now+15*60*1000));
});
Deno.test("reservation outage rejects before generation and uses a bounded database request",async()=>{
 let aborted=false;
 const admin:any={rpc(name:string,scope:Record<string,unknown>){assertEquals(name,"reserve_voice_storage");assertEquals(scope.p_actor,id);assertEquals(scope.p_org,org);return {abortSignal(signal:AbortSignal){aborted=signal instanceof AbortSignal;return Promise.resolve({data:null,error:{message:"unavailable"}});}};}};
 await assertRejects(()=>reserveVoiceStorage(admin,id,org));assertEquals(aborted,true);
});
