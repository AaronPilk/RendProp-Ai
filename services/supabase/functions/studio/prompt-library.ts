import { assert } from "../_shared/http.ts";
/** Prompt text is inert user content. Saving it cannot select a provider,
 * change consent/price settings, install skills or execute a generation. */
export function promptLibraryInput(value: unknown): Record<string, unknown> {
  const raw=value as Record<string,unknown>;
  assert(raw && typeof raw==='object' && !Array.isArray(raw) && raw.schema===1 && Array.isArray(raw.entries) && raw.entries.length<=50,400,"Use a supported prompt library with at most 50 saved prompts.");
  assert(Object.keys(raw).every(k=>['schema','entries'].includes(k)),400,"Unsupported prompt library fields.");
  const ids=new Set<string>();
  const fields=['id','title','prompt','target','sourceUrl','notes','verdict','revision','createdAt','updatedAt','recipeId','recipeVersion'];
  const text=(v:unknown,max:number,required=false)=>typeof v==='string'&&v.length<=max&&(!required||v.trim().length>0)&&!/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(v);
  for(const item of raw.entries){
    const e=item as Record<string,unknown>;
    assert(e && typeof e==='object'&&!Array.isArray(e)&&Object.keys(e).every(k=>fields.includes(k)),400,"A saved prompt contains unsupported fields.");
    assert(typeof e.id==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(e.id)&&!ids.has(e.id),400,"Saved prompts need distinct identifiers.");ids.add(e.id);
    assert(text(e.title,120,true)&&text(e.prompt,16000,true)&&text(e.notes,2000)&&text(e.sourceUrl,2000)&&['editing-brief','seedance-2.5','genjutsu'].includes(String(e.target))&&['untested','needs-work','usable'].includes(String(e.verdict))&&Number.isSafeInteger(e.revision)&&Number(e.revision)>0&&text(e.createdAt,40,true)&&text(e.updatedAt,40,true)&&Number.isFinite(Date.parse(String(e.createdAt)))&&Number.isFinite(Date.parse(String(e.updatedAt)))&&(e.recipeId===null||text(e.recipeId,80,true))&&(e.recipeVersion===null||Number.isSafeInteger(e.recipeVersion)&&Number(e.recipeVersion)>0),400,"A saved prompt has invalid or unsupported fields.");
    if(e.sourceUrl){let u:URL|undefined;try{u=new URL(String(e.sourceUrl));}catch{/* fail below */}assert(u?.protocol==='https:'&&!u.username&&!u.password,400,"Use a public HTTPS source link without credentials.");}
  }
  return raw;
}
