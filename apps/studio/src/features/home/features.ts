import type { IconName } from "../../icons";

export type FeatureId = "tour" | "spatial" | "photos" | "studio" | "reel" | "floorplan" | "aerial" | "agent" | "voice" | "copy" | "animate" | "chapters" | "coach" | "presenter";
export type Feature = { id: FeatureId; title: string; description: string; icon: IconName; ai?: boolean; comingSoon?: boolean };
// Public Studio follows the ordinary iPhone release; these experiments remain
// in the separate TestFlight Lab until they are accepted for release.
export const PUBLIC_SPATIAL_TOOLS_ENABLED = false;
// Labels and ordering follow the iPhone Home shortcuts (photos → AI edits →
// Make a video → optional recorded walkthrough). Desktop promises describe the
// actual available workflow instead of promising local iPhone enhancement.
export const FEATURES: readonly Feature[] = [
  {id:"photos",title:"Add photos",description:"Your phone photos, together here",icon:"photos"},
  {id:"studio",title:"AI Photo Studio",description:"Declutter · staging · twilight · sky",icon:"sparkles",ai:true},
  {id:"reel",title:"Make a video",description:"A listing or social media video from your photos",icon:"film",ai:true},
  {id:"tour",title:"Recorded walkthrough",description:"Optional · turn your walkthrough into a tour",icon:"video",ai:true},
  {id:"aerial",title:"Aerial intro",description:"Coming soon · not included in any plan",icon:"aerial",comingSoon:true},
  {id:"floorplan",title:"Floor plans & measurements",description:"Coming soon · not included in any plan",icon:"floorplan",comingSoon:!PUBLIC_SPATIAL_TOOLS_ENABLED},
  {id:"spatial",title:"3D walkthrough",description:"Coming soon · experiments stay in the TestFlight Lab",icon:"cube",comingSoon:!PUBLIC_SPATIAL_TOOLS_ENABLED},
  {id:"agent",title:"Agent card",description:"You, on every tour you send",icon:"person"},
];
export const AI_FEATURES: readonly Feature[] = [
  {id:"presenter",title:"AI Presenter",description:"Prepare agent-approved video presentations",icon:"person",ai:true},
  {id:"voice",title:"AI voiceover",description:"Give your reel a voice",icon:"mic",ai:true},
  {id:"copy",title:"Scripts & shot plans",description:"Find the words and plan the story",icon:"script",ai:true},
  {id:"animate",title:"Animate a photo",description:"Bring a still photo to life",icon:"video",ai:true},
  {id:"chapters",title:"Room chapters",description:"Help viewers find their way around",icon:"rooms",ai:true},
  {id:"coach",title:"Ask Rendprop",description:"A little help with your next step",icon:"sparkles",ai:true},
];
export function featureFor(id: FeatureId) { return [...FEATURES,...AI_FEATURES].find(item=>item.id===id)!; }
export function homeWords(spaceType: string) {
  const noun = ({real_estate:"listing",venue:"venue",restaurant:"place",retail:"store",fitness:"studio"} as Record<string,string>)[spaceType] ?? "space";
  return {noun,plural:`${noun}s`,collection:`My ${noun[0].toUpperCase()}${noun.slice(1)}s`};
}
export function listingStatus(status:string,sold?:string|null) {
  if(sold)return "Sold";
  return ({draft:"Not finished",capturing:"Not finished",uploading:"Uploading",processing:"Working on it",ready:"Ready",expired:"Expired"} as Record<string,string>)[status]??"Not finished";
}
