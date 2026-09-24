/** Original Rendprop recipes. Community repositories are research references,
 * never executable instructions or evidence that a generated result is accurate. */
export type PromptTarget = "editing-brief" | "seedance-2.5" | "genjutsu";
export type PromptVerdict = "untested" | "needs-work" | "usable";
export type PromptInputs = {
  scene: string; subject: string; sourceSeconds: number;
  videoReference: string; imageReference: string;
};
export type PromptRecipe = {
  id: string; version: 1; title: string; category: "Property" | "Agent" | "Creative";
  summary: string; target: PromptTarget; referenceNeed: string;
  technique: "push" | "detail" | "exterior" | "walkthrough" | "cutaways" | "social" | "presenter" | "multicam" | "twilight" | "staging";
  experimental: boolean;
};
export const PROMPT_RECIPES: readonly PromptRecipe[] = [
  { id:"room-push",version:1,title:"Gentle room reveal",category:"Property",summary:"A restrained move through the visible room, with a settled ending.",target:"seedance-2.5",referenceNeed:"One actual room image",technique:"push",experimental:false },
  { id:"detail-shot",version:1,title:"Feature close-up",category:"Property",summary:"Draw attention to a finish or fixture already visible in the source.",target:"seedance-2.5",referenceNeed:"One photo clearly showing the feature",technique:"detail",experimental:false },
  { id:"exterior-opening",version:1,title:"Exterior opening",category:"Property",summary:"A subtle entrance shot within the photographed facade.",target:"seedance-2.5",referenceNeed:"One actual exterior photo",technique:"exterior",experimental:false },
  { id:"real-walkthrough",version:1,title:"Polished walkthrough",category:"Property",summary:"An editing brief for real footage, preserving the home's layout.",target:"editing-brief",referenceNeed:"Your original walkthrough video",technique:"walkthrough",experimental:false },
  { id:"agent-cutaways",version:1,title:"Agent with property cutaways",category:"Agent",summary:"Keep the recorded delivery while showing genuine property details.",target:"editing-brief",referenceNeed:"An agent performance and actual property footage",technique:"cutaways",experimental:false },
  { id:"social-teaser",version:1,title:"Listing teaser",category:"Property",summary:"A clear opening, two visual highlights, and a clean closing beat.",target:"editing-brief",referenceNeed:"Original listing clips or stills",technique:"social",experimental:false },
  { id:"approved-presenter",version:1,title:"Approved agent performance",category:"Agent",summary:"A motion-transfer brief using an approved person's reference photos.",target:"genjutsu",referenceNeed:"A source performance and approved likeness photos",technique:"presenter",experimental:false },
  { id:"multicam-performance",version:1,title:"One take, several angles",category:"Creative",summary:"A timed camera-angle experiment inspired by your multicamera example.",target:"seedance-2.5",referenceNeed:"One continuous performance and identity reference",technique:"multicam",experimental:true },
  { id:"twilight-concept",version:1,title:"Twilight concept",category:"Creative",summary:"A disclosed lighting concept that preserves visible exterior features.",target:"seedance-2.5",referenceNeed:"Actual exterior photo",technique:"twilight",experimental:true },
  { id:"staged-room-concept",version:1,title:"Staged room concept",category:"Creative",summary:"Present an approved staged still without a construction or renovation claim.",target:"seedance-2.5",referenceNeed:"An approved staged still plus its original for review",technique:"staging",experimental:true },
];
export const TARGET_LABELS: Record<PromptTarget,string> = {"editing-brief":"Original-footage edit", "seedance-2.5":"Seedance 2.5 preparation",genjutsu:"Genjutsu preparation"};
export const DEFAULT_PROMPT_INPUTS: PromptInputs = {scene:"",subject:"the visible property",sourceSeconds:15,videoReference:"@Video1",imageReference:"@Image1"};
const clean = (value: string, max: number) => value.trim().replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "").slice(0,max);
const alias = (value: string) => /^@[A-Za-z][A-Za-z0-9_-]{0,31}$/.test(value);
const seconds = (value: number) => (value/100).toFixed(2).replace(/\.00$/, "").replace(/(\.\d)0$/, "$1");
export type PromptCompilation = {recipeId:string;recipeVersion:1;prompt:string;settings:string[];checklist:string[];warnings:string[];timeline:{start:number;end:number;direction:string}[]};
export function compilePrompt(recipeId: string, input: PromptInputs): PromptCompilation {
  const recipe = PROMPT_RECIPES.find(r=>r.id===recipeId);
  if (!recipe) throw new Error("Choose a prompt recipe.");
  const scene=clean(input.scene,600), subject=clean(input.subject,120);
  if (!scene) throw new Error("Describe the scene using details visible in your source.");
  if (!subject) throw new Error("Name the subject of the shot.");
  if (!Number.isFinite(input.sourceSeconds) || input.sourceSeconds<4 || input.sourceSeconds>30 || Math.abs(Math.round(input.sourceSeconds*100)-input.sourceSeconds*100)>1e-8) throw new Error("Use a source duration from 4 to 30 seconds, with at most two decimal places.");
  if (!alias(input.videoReference) || !alias(input.imageReference) || input.videoReference===input.imageReference) throw new Error("Use distinct reference labels, such as @Video1 and @Image1.");
  const video=input.videoReference, image=input.imageReference;
  const directions: Record<PromptRecipe["technique"],string[]> = {
    push:["Start at the photographed eye-level composition. Make one slow, small forward move within visible source coverage; keep vertical lines straight.","Ease to a stop on the visible focal feature. Hold the final composition without revealing an unseen corner."],
    detail:["Begin with the feature already visible. Make a small push toward its real material and edges; keep its proportions unchanged.","Settle on a stable detail framing. Preserve the actual surface finish without adding texture or objects."],
    exterior:["Hold the photographed facade, then make a gentle forward move with the entrance as the focal point.","Stop before the camera would need to reveal an unseen side. Keep the street, boundaries and visible neighboring structures unchanged."],
    walkthrough:["Choose the strongest stable opening from the real recording. Preserve the real order of rooms.","Trim hesitations and select steady movement; use cuts between actual recorded viewpoints.","Finish on a stable original shot. Do not generate connecting corridors or new rooms."],
    cutaways:["Start on the agent's original performance and keep its audio timeline intact.","Cut to supplied real property footage that supports the spoken point. Do not change or invent listing facts.","Return to the original agent shot for the recorded closing. Keep speech continuous underneath all cuts."],
    social:["Open with the strongest actual property image or clip; leave clear space for titles added in the editor.","Cut between two real features with simple cuts and restrained motion. Keep each view legible.","Finish on a genuine hero view. Add the approved call to action later in the editor."],
    presenter:["Use the approved reference identity for the source performer; retain source gestures, gaze, framing and performance sequence.","Continue the same performance without adding actions or altering the property. End at the original performance endpoint."],
    multicam:["Use the original front-facing medium composition as the opening reference.","Request a restrained three-quarter medium angle on the same performance beat, without restarting the action.","Cut to a tighter view of the same subject and preserve the ongoing gesture and delivery.","Return to the original front composition and finish on the source take's ending."],
    twilight:["Keep the photographed facade and composition fixed while gradually moving the lighting toward a restrained twilight concept.","Settle on the concept lighting. Keep architecture and landscaping unchanged; add no fixtures, illuminated rooms, stars or scenery."],
    staging:["Use the supplied approved staged still as the visual anchor. Make only a small movement within its visible composition.","Hold the final framing. Keep the depicted furniture count and placement stable; do not imply these furnishings are included in the listing."],
  };
  const actions=directions[recipe.technique], total=Math.round(input.sourceSeconds*100);
  const timeline=actions.map((direction,i)=>({start:Math.round(total*i/actions.length)/100,end:Math.round(total*(i+1)/actions.length)/100,direction}));
  const isPhoto=["push","detail","exterior","twilight","staging"].includes(recipe.technique);
  const references=isPhoto?`${image} supplies the visible property and starting composition.`:recipe.target==="editing-brief"?`${video} supplies the original footage and recorded timing; use only separately supplied original cutaways.`:`${video} supplies performance, timing and original surroundings. ${image} supplies only the approved subject's appearance; do not transfer its background or pose.`;
  const camera=recipe.technique==="multicam"?"Use straight cuts between camera setups. Do not combine this with a continuous moving-camera take or morph between faces.":recipe.target==="editing-brief"?"Use deliberate cuts between real shots; keep framing readable and avoid unnecessary transitions.":"Use one restrained camera idea per beat and a stable ending. Preserve visible geometry and camera-axis consistency.";
  const audio=isPhoto?"Leave room for the real agent's narration and licensed music to be added in the editor. No generated speech, music or text.":"The source recording is the authority for spoken content. Do not invent dialogue. Preserve its wording and timing as a goal; compare the rendered audio and lip timing to the original before use. Add no music or subtitles.";
  const locks="Keep walls, doors, windows, fixtures, finishes, dimensions, views, boundaries, signage and object placement consistent with supplied evidence. Do not beautify or invent property features. Add final titles and verified listing facts in the editor, not inside generated pixels.";
  const prompt=[`SCENE\n${scene}\nSubject: ${subject}`,`REFERENCE ROLES\n${references}`,`SHOT PLAN\n${timeline.map(t=>`${seconds(Math.round(t.start*100))}–${seconds(Math.round(t.end*100))}s: ${t.direction}`).join("\n")}`,`CAMERA\n${camera}`,`AUDIO\n${audio}`,`CONTINUITY\n${locks}`].join("\n\n");
  const settings=recipe.target==="editing-brief"?["Apply this brief to original footage in your editor.","Keep the source audio as a separate original track when exact words and timing matter."]:recipe.target==="genjutsu"?["Preparation only: the approved Presenter workflow uses its own fixed, versioned server instruction.","Documented Genjutsu resolution: 480p or 720p. Source performance: 4–30 seconds."]:isPhoto?["Preparation only: select Seedance 2.5 image-to-video with your actual source image.",`Request a ${input.sourceSeconds}-second clip using the provider’s duration control.`,"The image reference label must match your uploaded image. Copying this prompt does not upload or attach it."]:["Preparation only: select the verified Seedance 2.5 video-edit mode with your reference performance.","For BytePlus 2.5 video-edit tasks, duration is -1 (approximately matches the input); do not send a numeric duration for that mode.","Reference labels must match actual uploads. Copying this prompt does not upload or attach files."];
  const warnings=["No generated result has been tested for this recipe. Instructions are goals, not guarantees.",...(recipe.experimental?["Creative experiment: new camera angles or altered lighting can invent unseen property details. Review and label generated visuals before publishing."]:[]),...(recipe.technique==="multicam"?["A new angle inferred from one take is synthetic. A prompt cannot guarantee frame-for-frame performance or exact lip sync."]:[])];
  return {recipeId:recipe.id,recipeVersion:1,prompt,settings,warnings,timeline,checklist:["Compare the full result with original media, including the first and last frames.","Check architecture, feature placement, text, reflections and temporal distortion.","For people, verify permission, identity, gestures, spoken words and audio timing.","Record what failed and change one prompt variable for the next test."]};
}
export type SavedPrompt = {id:string;title:string;prompt:string;target:PromptTarget;sourceUrl:string;notes:string;verdict:PromptVerdict;revision:number;createdAt:string;updatedAt:string;recipeId:string|null;recipeVersion:number|null};
export type PromptLibraryData = {schema:1;entries:SavedPrompt[]};
export const EMPTY_PROMPT_LIBRARY:PromptLibraryData={schema:1,entries:[]};
export const MAX_SAVED_PROMPTS=50;
export function decodePromptLibrary(value:unknown):PromptLibraryData {
  if (!value || typeof value!=="object" || Array.isArray(value)) throw new Error("Saved prompts could not be read.");
  const raw=value as Record<string,unknown>;
  if(raw.schema!==1||!Array.isArray(raw.entries)||raw.entries.length>MAX_SAVED_PROMPTS)throw new Error("This prompt library version or size is not supported.");
  const ids=new Set<string>();
  const entries=raw.entries.map((v):SavedPrompt=>{
    if(!v||typeof v!=="object"||Array.isArray(v))throw new Error("A saved prompt is invalid.");
    const e=v as SavedPrompt;
    const bounded=(x:unknown,max:number,required=false)=>typeof x==="string"&&x.length<=max&&(!required||x.trim().length>0)&&!/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(x);
    if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(e.id)||ids.has(e.id)||!bounded(e.title,120,true)||!bounded(e.prompt,16000,true)||!bounded(e.notes,2000)||!bounded(e.sourceUrl,2000)||!Object.hasOwn(TARGET_LABELS,e.target)||!["untested","needs-work","usable"].includes(e.verdict)||!Number.isSafeInteger(e.revision)||e.revision<1||!bounded(e.createdAt,40,true)||!bounded(e.updatedAt,40,true)||!Number.isFinite(Date.parse(e.createdAt))||!Number.isFinite(Date.parse(e.updatedAt))||!(e.recipeId===null||bounded(e.recipeId,80,true))||!(e.recipeVersion===null||Number.isSafeInteger(e.recipeVersion)&&e.recipeVersion>0))throw new Error("A saved prompt has invalid or unsupported fields.");
    if(e.sourceUrl){let u:URL;try{u=new URL(e.sourceUrl);}catch{throw new Error("Use a valid source link.");}if(u.protocol!=="https:"||u.username||u.password)throw new Error("Use a public HTTPS source link without credentials.");}
    ids.add(e.id);return {id:e.id,title:e.title,prompt:e.prompt,target:e.target,sourceUrl:e.sourceUrl,notes:e.notes,verdict:e.verdict,revision:e.revision,createdAt:e.createdAt,updatedAt:e.updatedAt,recipeId:e.recipeId,recipeVersion:e.recipeVersion};
  });
  return {schema:1,entries};
}
export function promptExport(compilation:PromptCompilation):string {
  return `${compilation.prompt}\n\nSETTINGS — OUTSIDE THE PROMPT\n${compilation.settings.join("\n")}\n\nREVIEW\n${[...compilation.warnings,...compilation.checklist].join("\n")}\n\nRecipe: ${compilation.recipeId} v${compilation.recipeVersion}\n`;
}
