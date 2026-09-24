export type ProductionRecipe = "listing-highlight" | "agent-tour" | "market-update";
export type Presentation = "music" | "voiceover" | "on-camera";
export type ProductionShot = {id:string;title:string;guidance:string;required:boolean;status:"needed"|"captured"|"not-needed";sourcePhotoIds:string[];sourceVideoIds:string[];notes:string};
export type ProductionPlan = {schema:1;listingId:string;recipe:ProductionRecipe;presentation:Presentation;targetSeconds:30|45|60;shots:ProductionShot[];notes:string};
export const FORMATS: {id:ProductionRecipe;title:string;description:string}[] = [
  {id:"listing-highlight",title:"Listing highlight",description:"Show the home's strongest features. Being on camera is optional."},
  {id:"agent-tour",title:"Agent-led tour",description:"Keep your explanation flowing while property shots show the details."},
  {id:"market-update",title:"Market update",description:"Make one useful point, support it, and give viewers a clear next step."},
];
const propertyShots: [string,string,string,boolean][] = [
  ["exterior","Set the scene","Film a steady approach or use a clear exterior photo. Leave a moment before and after moving.",true],
  ["entry","Welcome inside","Show how the entrance connects to the main living space. Move slowly and keep the phone level.",true],
  ["living","Main living space","Show the room from a useful corner, then capture one detail. Avoid fast pans and bright windows filling the frame.",true],
  ["kitchen","Kitchen","Capture a wide view and one useful detail. Check mirrors and reflective appliances before recording.",true],
  ["primary-bedroom","Primary bedroom","Show the room and its connection to adjacent spaces without stretching the perspective.",false],
  ["bathroom","Bathroom","Choose a clear angle and check whether you or the phone appear in a mirror.",false],
  ["standout-feature","Standout feature","Show the actual feature that makes this property distinctive. Include only verified claims.",true],
  ["closing","Closing shot","End on a strong view. Leave space for a short, accurate next step.",true],
];
const marketShots: [string,string,string,boolean][] = [
  ["hook","Opening point","Record the one question this update answers. Use a quiet place and speak naturally.",true],
  ["explanation","Explain it clearly","Record a concise explanation. Verify every number and date against your source.",true],
  ["supporting-visuals","Supporting visuals","Choose property footage or graphics you can use to support your point.",false],
  ["takeaway","Useful takeaway","Explain what your audience can do with this information. Avoid predictions stated as guarantees.",true],
  ["closing","Next step","Record a short invitation to learn more or contact you.",true],
];
export function newProductionPlan(listingId:string,recipe:ProductionRecipe="listing-highlight"):ProductionPlan {
  const rows=recipe==="market-update" ? marketShots : recipe==="agent-tour" ? [["introduction","Your introduction","Introduce the property in a quiet spot. A separate voice recording works too.",true] as [string,string,string,boolean],...propertyShots] : propertyShots;
  return {schema:1,listingId,recipe,presentation:recipe==="listing-highlight"?"music":"voiceover",targetSeconds:45,notes:"",shots:rows.map(([id,title,guidance,required])=>({id,title,guidance,required,status:"needed",sourcePhotoIds:[],sourceVideoIds:[],notes:""}))};
}
export function changeProductionFormat(plan:ProductionPlan,recipe:ProductionRecipe):ProductionPlan {
  const next=newProductionPlan(plan.listingId,recipe), previous=new Map(plan.shots.map(shot=>[shot.id,shot]));
  // Retain completed work and notes even when a different format does not use it.
  const ids=new Set(next.shots.map(shot=>shot.id));
  const extra=plan.shots.filter(shot=>!ids.has(shot.id)&&(shot.status!=="needed"||shot.notes||shot.sourcePhotoIds.length||shot.sourceVideoIds.length));
  if(next.shots.length+extra.length>16) throw new Error("Keep this plan or remove unused shot notes before changing its format.");
  return {...plan,recipe,shots:[...next.shots.map(shot=>previous.has(shot.id)?{...previous.get(shot.id)!,required:shot.required}:shot),...extra.map(shot=>({...shot,required:false}))]};
}
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export function decodeProductionPlan(value:unknown,listingId:string):ProductionPlan {
  const plan=value as ProductionPlan;
  const string=(value:unknown,max:number)=>typeof value==="string"&&value.length<=max;
  const ids=(value:unknown)=>Array.isArray(value)&&value.length<=12&&value.every(id=>typeof id==="string"&&UUID.test(id))&&new Set(value).size===value.length;
  if(!plan||plan.schema!==1||!UUID.test(listingId)||plan.listingId!==listingId||!FORMATS.some(item=>item.id===plan.recipe)||!["music","voiceover","on-camera"].includes(plan.presentation)||![30,45,60].includes(plan.targetSeconds)||!string(plan.notes,2000)||!Array.isArray(plan.shots)||plan.shots.length>16||plan.shots.length<1)throw new Error("This capture plan could not be read. Its saved version is unchanged.");
  for(const shot of plan.shots) if(!shot||!string(shot.id,48)||!/^[-a-z0-9]+$/.test(shot.id)||!string(shot.title,120)||!shot.title.trim()||!string(shot.guidance,500)||typeof shot.required!=="boolean"||!["needed","captured","not-needed"].includes(shot.status)||!ids(shot.sourcePhotoIds)||!ids(shot.sourceVideoIds)||!string(shot.notes,500))throw new Error("A shot in this capture plan could not be read.");
  if(new Set(plan.shots.map(shot=>shot.id)).size!==plan.shots.length)throw new Error("Capture plan shots must have different identifiers.");
  return structuredClone(plan);
}
export function planProgress(plan:ProductionPlan) {
  const required=plan.shots.filter(shot=>shot.required&&shot.status!=="not-needed");
  const covered=required.filter(shot=>shot.status==="captured").length;
  return {covered,required:required.length,missing:required.filter(shot=>shot.status==="needed"),linked:plan.shots.filter(shot=>shot.sourcePhotoIds.length+shot.sourceVideoIds.length>0).length};
}
