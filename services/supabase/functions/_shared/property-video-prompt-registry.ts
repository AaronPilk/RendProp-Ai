/** Offline-reviewed prompt-family registry. No selector, route or admission default is changed here.
 * A future SQL/helper registration must bind one of these complete identities at admission.
 * Never relabel existing jobs or infer v2 from timestamps/current config. */
import {KIE_PROPERTY_IDENTITY,kiePropertyIdentityConsistent,sameJsonValue} from './property-video-kie.ts';
import {buildSteadyPropertyReelPrompt} from '../ai-video/reel-framing.ts';

export const GENTLE_PUSH_IN_PROMPT_PROFILE='steady-property-v2-gentle-push-in' as const;
export const GENTLE_PUSH_IN_TEMPLATE_SHA256='58a03de3b9b55ea8174bcd7e6d4fe7eaa44c4bb4d251e50f8e187d544bcb5c2c';
const V1_CAMERA='A shallow straight forward microdolly translation. Maintain very slow constant speed, constant height, a level horizon, fixed orientation and fixed focal length. No bobbing, sway, shake, orbit, speed ramp or zoom.';
const V2_CAMERA='A barely perceptible straight forward microdolly translation. Across the complete five-second shot, no stationary visible feature may become more than 10% larger in width or height than in its first frame (maximum 1.10x apparent scale). Start the same tiny forward motion immediately after the first frame and maintain a uniform velocity through the last frame; no initial hold, pause, freeze, acceleration, deceleration or speed ramp. Keep camera height, horizon, orientation and focal length fixed. No lens zoom, digital zoom, bobbing, sway, shake or orbit.';
const V1_FRAMING='Preserve the photographed field of view; the delivery canvas will be cropped separately.';
const V2_FRAMING='Keep the complete photographed scene readable throughout; any fixed delivery-canvas crop is performed separately.';
const MOTIONS=['fly_through','push_in','side_glide','pull_back'] as const;
type Motion=typeof MOTIONS[number];
export const KIE_GENTLE_PROMPT_IDENTITY=Object.freeze({
 ...KIE_PROPERTY_IDENTITY,
 prompt_profile:GENTLE_PUSH_IN_PROMPT_PROFILE,
 prompt_template_sha256:Object.freeze({...KIE_PROPERTY_IDENTITY.prompt_template_sha256,push_in:GENTLE_PUSH_IN_TEMPLATE_SHA256}),
});
/** Exact complete identities: changed price, route, cap, permission or an extra key never matches. */
export const PROPERTY_PROMPT_IDENTITY_REGISTRY=Object.freeze([
 Object.freeze({version:'v1' as const,identity:KIE_PROPERTY_IDENTITY}),
 Object.freeze({version:'v2' as const,identity:KIE_GENTLE_PROMPT_IDENTITY}),
]);
export function registeredPropertyPromptIdentity(identity:unknown){
 if(!kiePropertyIdentityConsistent())return null;
 return PROPERTY_PROMPT_IDENTITY_REGISTRY.find(entry=>sameJsonValue(identity,entry.identity))??null;
}
function replaceOnce(text:string,from:string,to:string):string{
 if(text.split(from).length!==2)throw new RangeError('The frozen v1 prompt anchor changed.');
 return text.replace(from,to);
}
/** Requires a chosen frozen identity. No default/current-profile fallback or activation exists. */
export function buildRegisteredPropertyPrompt(identity:unknown,sceneNoun:unknown,motion:unknown,aspect:unknown):string{
 const registered=registeredPropertyPromptIdentity(identity);
 if(!registered||typeof sceneNoun!=='string'||!KIE_PROPERTY_IDENTITY.prompt_scene_nouns.includes(sceneNoun)
  ||typeof motion!=='string'||!(MOTIONS as readonly string[]).includes(motion)||(aspect!=='16:9'&&aspect!=='9:16'))
  throw new RangeError('Choose a complete registered property prompt identity and closed recipe.');
 const original=buildSteadyPropertyReelPrompt(sceneNoun,motion as Motion,aspect);
 if(registered.version==='v1'||motion!=='push_in')return original;
 return replaceOnce(replaceOnce(original,V1_CAMERA,V2_CAMERA),V1_FRAMING,V2_FRAMING);
}
/** Adapter guard for one complete frozen identity and an exact saved prompt. */
export async function registeredPropertyPromptPinned(identity:unknown,prompt:unknown,motion:unknown):Promise<boolean>{
 const registered=registeredPropertyPromptIdentity(identity);
 if(!registered||typeof prompt!=='string'||prompt.length===0||prompt.length>8000||typeof motion!=='string'||!(MOTIONS as readonly string[]).includes(motion))return false;
 const token=KIE_PROPERTY_IDENTITY.prompt_template_token;
 for(const noun of KIE_PROPERTY_IDENTITY.prompt_scene_nouns){
  const at=prompt.indexOf(noun);if(at<0)continue;
  const template=prompt.slice(0,at)+token+prompt.slice(at+noun.length);if(template.split(token).length!==2)continue;
  const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(template))),x=>x.toString(16).padStart(2,'0')).join('');
  if(digest===registered.identity.prompt_template_sha256[motion as Motion])return true;
 }
 return false;
}

/** A server-only envelope discriminator. Legacy v1 has exactly no added field. */
export function propertyPromptIdentityForExtra(extra:Record<string,unknown>|undefined){
 if(!extra||!Object.hasOwn(extra,'property_video_prompt_profile'))return registeredPropertyPromptIdentity(KIE_PROPERTY_IDENTITY);
 return extra.property_video_prompt_profile===GENTLE_PUSH_IN_PROMPT_PROFILE?registeredPropertyPromptIdentity(KIE_GENTLE_PROMPT_IDENTITY):null;
}
export function propertyPromptExtraForIdentity(identity:unknown):Record<string,string>{
 const entry=registeredPropertyPromptIdentity(identity);if(!entry)throw new RangeError('Choose an exact registered saved prompt identity.');
 return entry.version==='v1'?{}:{property_video_prompt_profile:GENTLE_PUSH_IN_PROMPT_PROFILE};
}
export async function registeredPropertyAnyPromptPinned(identity:unknown,prompt:unknown):Promise<boolean>{
 for(const motion of MOTIONS)if(await registeredPropertyPromptPinned(identity,prompt,motion))return true;
 return false;
}
export function registeredPropertyPromptQuote(value:unknown){
 if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).sort().join(',')!=='profile,quality_identity,quote_profile,revision')return null;
 const v=value as Record<string,unknown>,entry=registeredPropertyPromptIdentity(v.quality_identity);
 if(!entry||v.profile!==KIE_PROPERTY_IDENTITY.profile||v.revision!==entry.version||v.quote_profile!==(entry.version==='v1'?KIE_PROPERTY_IDENTITY.profile:KIE_PROPERTY_IDENTITY.profile+'@prompt-v2'))return null;
 return{profile:KIE_PROPERTY_IDENTITY.profile,quality_identity:entry.identity,quote_profile:v.quote_profile,revision:entry.version};
}
