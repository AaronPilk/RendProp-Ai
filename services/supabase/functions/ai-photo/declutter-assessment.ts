// Analysis only. This cannot authorize an image generation or alter a photo.
export const DECLUTTER_ASSESSMENT_PROTOCOL="declutter-assessment-v1";
export const DECLUTTER_TARGETS=["papers","loose_items","personal_items","cords","laundry","trash","dishes","shoes","bags","small_countertop_items"]as const;
export interface DeclutterAssessment{decision:"needed"|"unnecessary"|"uncertain";confidence:number;reason:string;targets:string[]}
export const unavailableDeclutterAssessment=():DeclutterAssessment=>({decision:"uncertain",confidence:0,reason:"This photo needs your review. No image edit has been selected.",targets:[]});
export const DECLUTTER_ASSESSMENT_INSTRUCTION=`Also return declutter_assessment:{"decision":"needed|unnecessary|uncertain","confidence":0.0,"reason":"one short sentence, at most160characters","targets":[]}.
Inspect only actually visible removable clutter. Doors, walls, floors, windows, installed fixtures, furniture and empty/clear rooms are NOT clutter targets. An isolated door or already-clear surface needs no declutter. Use decision unnecessary for clear photos with no removable target; needed ONLY when specific visible movable clutter should be removed with confidence at least0.85. Never infer clutter hidden by furniture or beyond the frame. Low confidence, unclear attachment, unreadable photo or any ambiguity means uncertain, never needed. Targets must be at most6 unique codes from: ${DECLUTTER_TARGETS.join(",")}. Unnecessary requires an empty target list. Preserve architecture and furniture; a staged/furnished room is not automatically cluttered. Analysis is not an image edit; never promise generation or mark a photo edited.`;
/** Invalid, absent, inconsistent or low-confidence model fields never opt in. */
export function parseDeclutterAssessment(value:unknown):DeclutterAssessment{
 const no=unavailableDeclutterAssessment();
 if(!value||typeof value!=="object"||Array.isArray(value)||Object.keys(value).sort().join(",")!=="confidence,decision,reason,targets")return no;
 const v=value as Record<string,unknown>;
 if(!["needed","unnecessary","uncertain"].includes(String(v.decision))||typeof v.confidence!=="number"||!Number.isFinite(v.confidence)||v.confidence<0||v.confidence>1||typeof v.reason!=="string"||!v.reason.trim()||v.reason.length>160||/[\p{Cc}\p{Cf}]/u.test(v.reason)||!Array.isArray(v.targets)||v.targets.length>6||new Set(v.targets).size!==v.targets.length||!v.targets.every(t=>typeof t==="string"&&(DECLUTTER_TARGETS as readonly string[]).includes(t)))return no;
 if(v.decision==="uncertain"||v.confidence<.85)return{...no,reason:v.reason.trim(),confidence:v.confidence};
 if(v.decision==="needed"&&v.targets.length===0||v.decision==="unnecessary"&&v.targets.length!==0)return no;
 return{decision:v.decision as"needed"|"unnecessary",confidence:v.confidence,reason:v.reason.trim(),targets:[...v.targets]};
}
