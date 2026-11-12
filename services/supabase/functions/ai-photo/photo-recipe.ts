// The versioned identity of the AI photo recipe: the prompt templates,
// guardrail text and their composition that turn a request into the final
// prompt string handed to the provider adapter.
//
// Every prospective generation records PHOTO_RECIPE_REVISION and the SHA-256
// of that exact final prompt on its own evidence row, once, BEFORE any
// provider dispatch (SQL photo_quality_set_recipe, migration
// 20261017200000_photo_output_feedback). Feedback, the admin quality report
// and regression cases are grouped by this revision; prompt_sha256 is the
// exact per-generation identity, the revision is the human-readable label.
// Generations made before this existed keep both columns null (= unknown).
//
// BUMP PHOTO_RECIPE_REVISION whenever any prompt template, guardrail text or
// their composition changes: ai-photo/index.ts (PROFILES, the locks and prompt
// builders, customPrompt and the handler's prompt composition),
// _shared/fairhousing.ts guardrails, _shared/custom-photo-prompt.ts,
// _shared/photo-stage-prompt.ts and _shared/photo-declutter-prompt.ts.
// photo-recipe.test.ts fingerprints those sources and fails until the
// revision and its pinned fingerprint move together.
//
// Recording a recipe never calls a provider, never charges anything and never
// triggers a regeneration.
import {HttpError} from "../_shared/http.ts";
import {photoQualityRpc,type PhotoAdmin,type PhotoQualityEnvelope} from "./photo-qc-store.ts";

export const PHOTO_RECIPE_REVISION = "photo-recipe/2026-10-17.1";
/** Same bound as the SQL check on photo_edit_evidence.recipe_revision. */
export const PHOTO_RECIPE_PATTERN = /^[a-z0-9][a-z0-9./_-]{1,79}$/;

export interface PhotoRecipeReceipt {evidence_id:string;recipe_revision:string;prompt_sha256:string;replay:boolean}

/** SHA-256 (lowercase hex) of the exact UTF-8 prompt string. */
export async function photoPromptSha256(prompt:string):Promise<string>{
 const digest=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(prompt));
 return Array.from(new Uint8Array(digest),byte=>byte.toString(16).padStart(2,"0")).join("");
}

function recipeUnavailable():HttpError{
 return new HttpError(503,"The edit recipe could not be recorded. No edit was sent or charged. Please try again.","upstream",{no_provider_dispatch:true,failure_phase:"recipe_recording"});
}

/** Record the recipe identity on this exact new evidence row. Resolves only
 * when the server confirms exactly this evidence, revision and prompt hash;
 * anything else throws so the caller aborts before any provider dispatch. */
export async function recordPhotoRecipe(admin:PhotoAdmin,row:PhotoQualityEnvelope,prompt:string,revision=PHOTO_RECIPE_REVISION):Promise<PhotoRecipeReceipt>{
 const evidence=row?.evidence;
 if(typeof prompt!=="string"||prompt.length===0||!PHOTO_RECIPE_PATTERN.test(revision)||typeof evidence?.id!=="string"||typeof evidence?.actor_id!=="string")throw recipeUnavailable();
 const sha=await photoPromptSha256(prompt);
 let receipt:PhotoRecipeReceipt;
 try{receipt=await photoQualityRpc(admin,"photo_quality_set_recipe",{p_actor:evidence.actor_id,p_evidence:evidence.id,p_revision:revision,p_prompt_sha256:sha});}
 catch{throw recipeUnavailable();}
 if(!receipt||typeof receipt!=="object"||receipt.evidence_id!==evidence.id||receipt.recipe_revision!==revision||receipt.prompt_sha256!==sha)throw recipeUnavailable();
 return receipt;
}
