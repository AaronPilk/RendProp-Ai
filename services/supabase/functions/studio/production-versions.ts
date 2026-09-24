import { assert, HttpError, json, pathSegments, readJsonLimited } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const headers={"Cache-Control":"private, no-store","X-Content-Type-Options":"nosniff"};
export function versionScope(input:Record<string,unknown>,actor:string){
  assert(typeof input.key==='string' && input.key.startsWith('edit:') && UUID.test(input.key.slice(5)),400,'Choose a saved property reel.');
  const owner=input.document_user_id??actor;
  assert(typeof owner==='string'&&UUID.test(owner),400,'Choose a valid reel author.');
  return {key:input.key,owner,listing:input.key.slice(5)};
}
function revision(value:unknown,min:number){
  assert(Number.isSafeInteger(value)&&Number(value)>=min&&Number(value)<2147483647,400,'Choose a valid saved revision.');return Number(value);
}
export async function handleProductionVersions(req:Request,context:StudioContext):Promise<Response|null>{
  const seg=pathSegments(req,'studio');
  if(seg.length!==2||seg[0]!=='production-review'||!['versions','version','copy'].includes(seg[1]))return null;
  const copying=seg[1]==='copy';
  assert(req.method===(copying?'POST':'GET'),405,copying?'Use the explicit copy action.':'Saved versions are read-only.');
  const url=new URL(req.url),input=copying?await readJsonLimited(req,4096):Object.fromEntries(url.searchParams);
  const scope=versionScope(input,context.userId);await context.authorizeListing(scope.listing);
  const args:Record<string,unknown>={p_actor:context.userId,p_org_id:context.orgId,p_document_user_id:scope.owner,p_key:scope.key};
  if(copying){args.p_document_revision=revision(input.document_revision,1);args.p_expected_target_revision=revision(input.expected_target_revision,0);}
  else {
    const raw=url.searchParams.get('document_revision');
    assert(seg[1]==='versions'||raw!==null&&/^[1-9][0-9]{0,9}$/.test(raw),400,'Choose a saved version.');
    args.p_document_revision=seg[1]==='version'?revision(Number(raw),1):null;
    const offset=url.searchParams.get('offset')??'0';
    assert(/^(0|[1-9][0-9]{0,4})$/.test(offset)&&Number(offset)<=10000&&Number(offset)%50===0,400,'Choose a valid version history page.');args.p_offset=Number(offset);
  }
  const {data,error}=await context.admin.rpc(copying?'studio_production_copy':'studio_production_versions_read',args).abortSignal(req.signal);
  if(error){const match=/^RP(400|403|404|409|422): ([^\r\n]{1,240})$/.exec(error.message??'');throw new HttpError(match?Number(match[1]):503,match?match[2]:'Saved versions are temporarily unavailable. Reload before trying again.');}
  assert(data&&(copying?data.document&&data.source_version:seg[1]==='version'?data.document&&data.version:Array.isArray(data.versions)),503,'Saved version information could not be read.');
  return json(data,200,headers);
}
