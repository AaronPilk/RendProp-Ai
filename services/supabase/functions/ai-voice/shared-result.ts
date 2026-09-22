import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

type Word = {text: string; start: number; end: number};
export type SharedVoice = {
  userId: string; orgId: string; listingId: string; key: string;
  requestKey?: string | null; label: string; voiceName: string;
  duration: number; words: Word[]; disclosure: string; provenanceId: string | null;
};
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
/** Only server-produced storage identity and measured timings enter shared history. */
export function sharedVoiceRow(input: SharedVoice) {
  if (![input.userId,input.orgId,input.listingId].every(value => UUID.test(value))) throw new Error("Invalid voice scope");
  const file = input.key.slice(`ai-voice/${input.orgId}/`.length);
  if (!input.key.startsWith(`ai-voice/${input.orgId}/`) || !file.endsWith(".mp3") || !UUID.test(file.slice(0,-4))) throw new Error("Invalid voice storage identity");
  if (!Number.isFinite(input.duration) || input.duration <= 0 || input.duration > 300) throw new Error("Invalid voice duration");
  if (input.provenanceId !== null && !UUID.test(input.provenanceId)) throw new Error("Invalid voice provenance");
  if (input.words.length > 1500 || input.words.some(word => typeof word.text !== "string" || word.text.length > 1000 ||
      !Number.isFinite(word.start) || !Number.isFinite(word.end) || word.start < 0 || word.end < word.start || word.end > 300)) throw new Error("Invalid voice alignment");
  return {user_id:input.userId,org_id:input.orgId,listing_id:input.listingId,kind:"voice",bucket:"uploads",storage_key:input.key,
    provenance_id:input.provenanceId,request_key:`native-voice:${file.slice(0,-4)}`,
    metadata:{state:"completed",origin:"native-voice",label:input.label.trim().slice(0,80)||"Reel voiceover",voice_name:input.voiceName.slice(0,100),
      duration_s:input.duration,words:input.words,disclosure:input.disclosure.slice(0,1000)}};
}

/** Never destroys or refunds an already generated voice if history is unavailable.
 * Studio's reserved generation owns its own completion; do not create a duplicate.
 */
export async function saveSharedVoice(userDb: SupabaseClient, admin: SupabaseClient, input: SharedVoice, signal = AbortSignal.timeout(2500)): Promise<string | null> {
  try {
    const row = sharedVoiceRow(input);
    const [listing, org] = await Promise.all([
      userDb.from("listings").select("id,org_id").eq("id",input.listingId).eq("org_id",input.orgId).is("deleted_at",null).abortSignal(signal).maybeSingle(),
      userDb.from("orgs").select("id").eq("id",input.orgId).is("deleted_at",null).abortSignal(signal).maybeSingle(),
    ]);
    if (listing.error || org.error || !listing.data || !org.data) return null;
    if (input.requestKey) {
      const existing = await admin.from("studio_creative_results").select("id,kind,listing_id")
        .eq("user_id",input.userId).eq("org_id",input.orgId).eq("request_key",input.requestKey).abortSignal(signal).maybeSingle();
      if (existing.error) return null;
      if (existing.data?.kind === "voice" && existing.data.listing_id === input.listingId) return null;
    }
    // A provenance ID can be omitted when its best-effort write failed, but a
    // supplied ID must still belong to this exact property and workspace.
    if (row.provenance_id) {
      const proof = await admin.from("media_provenance").select("id").eq("id",row.provenance_id)
        .eq("org_id",input.orgId).eq("listing_id",input.listingId).abortSignal(signal).maybeSingle();
      if (proof.error || !proof.data) return null;
    }
    const saved = await admin.from("studio_creative_results").insert(row).select("id").abortSignal(signal).single();
    if (saved.error || !saved.data || !UUID.test(saved.data.id)) return null;
    return saved.data.id;
  } catch {
    return null;
  }
}
