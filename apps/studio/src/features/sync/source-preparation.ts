import type {StudioServices} from '../../data/services';
import {assertVideoScope,decodeSources,videoScopeKey,type VideoScope,type VideoSource} from './property-video';
const UUID=/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
type StorageLike=Pick<Storage,'getItem'|'setItem'>;
type PrepRecord={operation_id:string;preparation_id?:string;photo_id:string;photo_asset_id:string;photo_version_id:string;photo_provenance_id:string|null;source_sha256:string};
/** Only Edge can register a derivative. The browser preserves exactmasterrefs. */
export async function prepareVideoSources(services:Pick<StudioServices,'api'|'getSnapshot'>,scope:VideoScope,selected:VideoSource[],storage:StorageLike,signal?:AbortSignal,onProgress?:(complete:number,total:number)=>void,delay=(milliseconds:number)=>new Promise<void>(resolve=>setTimeout(resolve,milliseconds))):Promise<VideoSource[]>{
 const result:VideoSource[]=Array(selected.length);let cursor=0,completed=0,stopped=false;
 async function one(index:number){
  const source=selected[index]!;assertVideoScope(services,scope,signal);
  if(source.eligible){result[index]=source;onProgress?.(++completed,selected.length);return;}
  if(!source.needs_preparation||!source.photo_asset_id||!source.sha256)throw Error('This exact saved photo is unavailable for video preparation.');
  const key=`${videoScopeKey(scope)}:prepare:${source.photo_asset_id}:${source.sha256}`;
  let saved:PrepRecord;const text=storage.getItem(key);
  if(text){try{saved=JSON.parse(text);if(!UUID.test(saved.operation_id)||saved.preparation_id&&!UUID.test(saved.preparation_id)||saved.photo_id!==source.photo_id||saved.photo_asset_id!==source.photo_asset_id||saved.photo_version_id!==source.photo_version_id||saved.photo_provenance_id!==source.photo_provenance_id||saved.source_sha256!==source.sha256)throw Error();}catch{throw Error('The saved photo preparation identity is unreadable. Your original is preserved.');}}
  else {saved={operation_id:crypto.randomUUID(),photo_id:source.photo_id,photo_asset_id:source.photo_asset_id,photo_version_id:source.photo_version_id,photo_provenance_id:source.photo_provenance_id,source_sha256:source.sha256};storage.setItem(key,JSON.stringify(saved));}
  async function request(path:string,options:Parameters<StudioServices['api']>[1]){assertVideoScope(services,scope,signal);const value=await services.api(`/functions/v1/property-video-jobs/${path}`,{...options,orgId:scope.library,signal});assertVideoScope(services,scope,signal);return value as {preparation_id:string;operation_id:string;listing_id:string;org_id:string;selected_library_org_id:string;state:string;source:unknown;message?:string};}
  let reply=await request(saved.preparation_id?`sources/prepare/${saved.preparation_id}`:'sources/prepare',saved.preparation_id?{orgId:scope.library}:{orgId:scope.library,method:'POST',idempotencyKey:`property-video-source:${saved.operation_id}`,body:{operation_id:saved.operation_id,listing_id:scope.listing,expected_org_id:scope.library,photo_id:saved.photo_id,photo_asset_id:saved.photo_asset_id,photo_version_id:saved.photo_version_id,photo_provenance_id:saved.photo_provenance_id}});
  for(let poll=0;poll<120;poll++){
   if(!UUID.test(reply.preparation_id)||reply.operation_id!==saved.operation_id||reply.listing_id!==scope.listing||reply.org_id!==scope.org||reply.selected_library_org_id!==scope.library||!['queued','preparing','ready','failed'].includes(reply.state)||saved.preparation_id&&reply.preparation_id!==saved.preparation_id)throw Error('The processing copy belongs to another property or operation.');
   saved={...saved,preparation_id:reply.preparation_id};storage.setItem(key,JSON.stringify(saved));
   if(reply.state==='failed')throw Error(reply.message||'This photo could not be prepared. Its original is unchanged.');
   if(reply.state==='ready'){
    const [prepared]=decodeSources({listing_id:scope.listing,org_id:scope.org,selected_library_org_id:scope.library,selected_count:1,sources:[reply.source],next_offset:null},scope);
    if(!prepared?.eligible||prepared.photo_id!==source.photo_id||prepared.photo_version_id!==source.photo_version_id||prepared.photo_provenance_id!==source.photo_provenance_id||prepared.preparation?.source_asset_id!==source.photo_asset_id||prepared.preparation.source_sha256!==source.sha256||prepared.preparation.preparation_id!==saved.preparation_id)throw Error('The prepared copy did not retain the selected master identity.');
    result[index]=prepared;onProgress?.(++completed,selected.length);return;
   }
   await delay(3000);assertVideoScope(services,scope,signal);reply=await request(`sources/prepare/${saved.preparation_id}`,{orgId:scope.library});
  }
  throw Error('Photo preparation is saved on the server and is still running. Resume this same request later.');
 }
 await Promise.all(Array.from({length:Math.min(4,selected.length)},async()=>{while(!stopped&&cursor<selected.length){const index=cursor++;try{await one(index);}catch(error){stopped=true;throw error;}}}));
 assertVideoScope(services,scope,signal);return result;
}
