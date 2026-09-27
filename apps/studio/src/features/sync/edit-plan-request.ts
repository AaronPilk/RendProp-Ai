import type {EditDraft} from "../../editor/model";
import type {ConversationMessage} from "../../editor/conversation-state";

/** Explicit metadata allowlist: original filenames, URLs, fingerprints and media
 * bytes never become model input. Keep old turns within the server's limits. */
export function buildEditPlanRequest(draft:EditDraft,message:string,history:ConversationMessage[],listingId?:string){
  const request={
    ...(listingId?{listing_id:listingId}:{}),
    draft:{
      id:draft.id,revision:draft.revision,ratio:draft.ratio,audio:draft.audio,title:draft.title,
      hasNarration:!!draft.narration,hasOverlays:!!draft.overlays?.length,
      hasMusic:!!draft.music,hasSpeech:!!draft.speech?.length,
      clips:draft.clips.map(clip=>({id:clip.id,kind:clip.source.kind,start:clip.start,end:clip.end,speed:clip.speed??1,caption:clip.caption,motion:clip.motion??"still",transition:clip.transition??"cut"})),
    },
    message,
    history:history.slice(-8).map(item=>({role:item.role,content:item.text.slice(0,1200)})),
  };
  const encoder=new TextEncoder(),maximum=24*1024;
  while(request.history.length&&encoder.encode(JSON.stringify(request)).byteLength>maximum)request.history.shift();
  if(encoder.encode(JSON.stringify(request)).byteLength>maximum)throw new Error("This request is too long. Shorten your message and try again; your edit is unchanged.");
  return request;
}
