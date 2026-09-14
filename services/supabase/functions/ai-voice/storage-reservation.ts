import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { HttpError } from "../_shared/http.ts";
export type VoiceStorageReservation = {reservation_id:string;key:string;write_deadline:string};
export function validateVoiceReservation(raw: unknown, id: string, org: string, now = Date.now()): VoiceStorageReservation {
  const row=raw as Partial<VoiceStorageReservation> | null;
  if (!row || row.reservation_id !== id || row.key !== `ai-voice/${org}/${id}.mp3` || typeof row.write_deadline !== "string") throw new HttpError(503,"Narration storage could not be reserved. No generation was started.");
  const deadline=Date.parse(row.write_deadline);
  if (!Number.isFinite(deadline) || deadline <= now || deadline > now + 16*60*1000) throw new HttpError(503,"Narration storage reservation is unavailable. No generation was started.");
  return row as VoiceStorageReservation;
}
export async function reserveVoiceStorage(admin:SupabaseClient,user:string,org:string,listing?:string):Promise<VoiceStorageReservation>{
  const id=crypto.randomUUID();
  const result=await admin.rpc("reserve_voice_storage",{p_actor:user,p_org:org,p_id:id,p_listing:listing??null}).abortSignal(AbortSignal.timeout(10000));
  if(result.error)throw new HttpError(503,"Narration storage is temporarily unavailable. No generation was started.");
  return validateVoiceReservation(result.data,id,org);
}
export function assertVoiceWriteWindow(reservation:VoiceStorageReservation,now=Date.now()) {
  if(!Number.isFinite(Date.parse(reservation.write_deadline))||now>=Date.parse(reservation.write_deadline)) throw new HttpError(503,"Narration took too long to finish. Its storage window has closed.");
}
