import{assert}from'../_shared/http.ts';
import{registeredPropertyPromptQuote}from'../_shared/property-video-prompt-registry.ts';
import{rpc}from'./runtime.ts';
export async function propertyVideoPromptQuote(actor:string,manifest:unknown,grant:string|null){
 const chosen=registeredPropertyPromptQuote(await rpc('property_video_prompt_recipe_quote',{p_actor:actor,p_manifest:manifest,p_grant:grant}));
 assert(chosen,409,'The saved video prompt recipe changed before admission. No video was created.');return chosen;
}
