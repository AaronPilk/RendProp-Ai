import { HttpError, assert } from "../_shared/http.ts";

type Authority = {rpc(name:string, args:Record<string,unknown>):PromiseLike<{data:unknown;error:{message?:string}|null}>};
export type PhotoDelivery = {schema:1;slug:string;objects:Record<string,"renders">;stream_uid:null};

/** One current per-key database authority check, including exact saved-edit
 * lineage, canonical visibility, hosting and byte admission. SQL null alone
 * delegates unsupported legacy lineage to the unchanged complete authority.
 * The gateway still calls this separately at entry, after HEAD and before
 * bytes/HEAD/304; no permission, publication or source result is cached. */
export async function photoDelivery(admin:Authority, slug:string, key:unknown, bytes=0):Promise<PhotoDelivery|null> {
  assert(/^[A-Za-z0-9_-]{1,64}$/.test(slug) && typeof key==="string" && key.length>0 && key.length<=500,
    400,"Choose an exact published photo.");
  assert(Number.isSafeInteger(bytes) && bytes>=0 && bytes<=2*1024*1024,400,"Use bounded photo previews.");
  let result:Awaited<ReturnType<Authority["rpc"]>>;
  try {
    result=await admin.rpc("published_photo_delivery",{p_slug:slug,p_key:key,p_bytes:bytes});
  } catch {
    throw new HttpError(503,"Published photo could not be verified.");
  }
  const {data,error}=result;
  if(error){
    const code=/^RP(400|401|403|404|429):/.exec(error.message??"");
    throw new HttpError(code?Number(code[1]):503,"Published photo could not be verified.");
  }
  if(data===null)return null;
  assert(data && typeof data==="object" && !Array.isArray(data),503,"Published photo authority could not be verified.");
  const value=data as Record<string,unknown>, objects=value.objects;
  assert(Object.keys(value).length===4 && value.schema===1 && value.slug===slug && value.stream_uid===null &&
    objects && typeof objects==="object" && !Array.isArray(objects) &&
    Object.keys(objects).length===1 && Object.hasOwn(objects,key) && (objects as Record<string,unknown>)[key]==="renders",
    503,"Published photo authority could not be verified.");
  return {schema:1,slug,objects:{[key]:"renders"},stream_uid:null};
}
