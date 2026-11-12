import {mapCatalogueRows} from './catalogue-map.ts';
import {assert} from '../_shared/http.ts';

type Row = Record<string, any>;
type Kind = 'original'|'declutter'|'stage'|'edited'|'unknown';
type Preview = {actor:string;org:string;listing:string;asset_id:string;bucket:'renders';key:string};
/** Existing owner/library, exact-source, HEAD and private-media boundaries. */
export type SavedVersionIO = {
  db:any;
  scope:(actor:string,expected:string,listing:string,write:boolean)=>Promise<string>;
  rpc:(name:string,args:Row)=>Promise<any>;
  head:(source:Row)=>Promise<unknown>;
  preview:(scope:Preview)=>Promise<string>;
};
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const SHA=/^[a-f0-9]{64}$/;
const MIME=['image/jpeg','image/png','image/webp'];
const COLUMNS='id,kind,bucket,storage_key,bytes,sha256,content_type,uploaded,upload_aborted';
const object=(v:any):v is Row=>v!==null&&typeof v==='object'&&!Array.isArray(v);
const known=(kind:any):Kind=>kind==='declutter'?'declutter':kind==='virtual_stage'?'stage':kind==='photo_edit'?'edited':'unknown';

function publicationMatches(v:any,asset:Row,actor:string,org:string,listing:string,library:string):boolean{
  return object(v)&&v.phase==='prepared'&&v.target?.output_asset_id===asset.id&&v.target?.org_id===org&&v.target?.listing_id===listing&&v.target?.library_org_id===library&&
    v.source?.actor_id===actor&&v.source?.org_id===org&&v.source?.library_org_id===library&&
    v.output?.sha256===asset.sha256&&v.output?.bytes===asset.bytes&&v.output?.mime===asset.content_type;
}

function provenKind(asset:Row,rows:Row[],originals:Row[],actor:string,org:string,listing:string,library:string):{kind:Kind;provenance:string|null}{
  // An absent/unknown edit record is never evidence that an upload is Original.
  if(rows.length===0)return originals.some(p=>p.original_key===asset.storage_key)?{kind:'original',provenance:null}:{kind:'unknown',provenance:null};
  if(rows.length!==1)return{kind:'unknown',provenance:null};
  const p=rows[0],kind=known(p.kind),q=p.qc;
  if(kind==='unknown'||!UUID.test(p.id)||p.org_id!==org||p.listing_id!==listing||p.altered_key!==asset.storage_key||
    !object(q)||q.publishable!==true||q.action!=='accept'||q.verdict!=='pass'||q.output_sha256!==asset.sha256)return{kind:'unknown',provenance:null};
  if(p.photo_publication!==null){
    const v=p.photo_publication;
    if(!publicationMatches(v,asset,actor,org,listing,library))return{kind:'unknown',provenance:null};
  }
  return{kind,provenance:p.id};
}

/** Opt-in catalog only. Never changes the gallery, prepares an alias or resumes a job. */
export async function savedVersionSources(actor:string,listing:string,expected:string,offset:number,io:SavedVersionIO){
  assert(UUID.test(actor)&&UUID.test(listing)&&UUID.test(expected)&&Number.isSafeInteger(offset)&&offset>=0&&offset<=10000,400,'Use one bounded saved-photo page.');
  const org=await io.scope(actor,expected,listing,true),prefix=`renders/${org}/${listing}/gallery-`;
  const loaded=await io.db.from('capture_assets').select(COLUMNS,{count:'exact'}).eq('listing_id',listing)
    .eq('kind','photo').eq('bucket','renders').eq('uploaded',true).like('storage_key',prefix+'%')
    .order('created_at').order('id').range(offset,offset+99);
  assert(!loaded.error&&Array.isArray(loaded.data)&&loaded.data.length<=100&&Number.isSafeInteger(loaded.count)&&loaded.count>=0&&loaded.data.length===Math.min(100,Math.max(0,loaded.count-offset)),503,'Saved photo versions could not be read.');
  const count=Math.min(1000,loaded.count),assets:Row[]=loaded.data.slice(0,Math.max(0,Math.min(100,count-offset)));
  assert(assets.every(a=>UUID.test(a.id))&&new Set(assets.map(a=>a.id)).size===assets.length,503,'Saved photo identities could not be verified.');
  const keys=assets.map(a=>a.storage_key).filter((k):k is string=>typeof k==='string');
  const provenance=keys.length?await io.db.from('media_provenance').select('id,org_id,listing_id,kind,altered_key,qc,photo_publication')
    .eq('org_id',org).eq('listing_id',listing).in('altered_key',keys).limit(1001):{data:[],error:null};
  const originals=keys.length?await io.db.from('photos').select('id,original_key').eq('listing_id',listing).in('original_key',keys).limit(1001):{data:[],error:null};
  assert(!provenance.error&&Array.isArray(provenance.data)&&provenance.data.length<=1000&&!originals.error&&Array.isArray(originals.data)&&originals.data.length<=1000,503,'Saved photo history could not be read.');
  const sources=await mapCatalogueRows(assets,async(a)=>{
    let kind:Kind='unknown',photo_provenance_id:string|null=null,preview_url:string|null=null;
    const candidate=provenKind(a,provenance.data.filter((p:Row)=>p.altered_key===a.storage_key),originals.data,actor,org,listing,expected);
    const valid=a.kind==='photo'&&a.bucket==='renders'&&a.uploaded===true&&a.upload_aborted===false&&typeof a.storage_key==='string'&&a.storage_key.startsWith(prefix)&&
      Number.isSafeInteger(a.bytes)&&a.bytes>0&&a.bytes<=52_428_800&&typeof a.sha256==='string'&&SHA.test(a.sha256)&&MIME.includes(a.content_type);
    if(valid&&candidate.kind!=='unknown')try{
      const target=await io.rpc('photo_publication_target',{p_actor:actor,p_org:org,p_library:expected,p_listing:listing,p_asset:a.id});
      assert(target?.actor_id===actor&&target.org_id===org&&target.library_org_id===expected&&target.listing_id===listing&&
        target.target?.asset_id===a.id&&target.target.key===a.storage_key&&target.target.bytes===a.bytes&&target.target.sha256===a.sha256&&target.target.mime===a.content_type,409,'The saved full master changed.');
      if(candidate.provenance){
        const p=provenance.data.find((p:Row)=>p.id===candidate.provenance);
        if(p.photo_publication!==null)assert(target.publication?.id===p.id&&publicationMatches(target.publication?.photo_publication,a,actor,org,listing,expected),409,'The saved edit disclosure changed.');
        else assert(target.publication===null,409,'Keep the saved edit disclosure.');
      }else assert(target.publication===null,409,'This saved version has an edit disclosure.');
      const source=await io.rpc('property_photo_reference',{p_actor:actor,p_listing:listing,p_asset:a.id,p_provenance:candidate.provenance});
      assert(source?.actor_id===actor&&source.org_id===org&&source.listing_id===listing&&source.asset_id===a.id&&source.bucket==='renders'&&
        source.storage_key===a.storage_key&&source.bytes===a.bytes&&source.sha256===a.sha256&&source.content_type===a.content_type,409,'Keep the exact saved master receipt.');
      await io.head(source);
      preview_url=await io.preview({actor,org,listing,asset_id:a.id,bucket:'renders',key:a.storage_key});
      kind=candidate.kind;photo_provenance_id=candidate.provenance;
    }catch{kind='unknown';photo_provenance_id=null;preview_url=null;}
    return{photo_id:a.id,photo_asset_id:a.id,photo_version_id:'asset:'+a.id,photo_provenance_id,
      preview_url,bytes:a.bytes??null,sha256:a.sha256??null,eligible:false,needs_preparation:kind!=='unknown',version_kind:kind,preparation_mode:'chosen',
      reason:kind==='unknown'?'This saved photo needs its retained edit and source checks before video.':'Prepare this exact saved version for video; its original stays unchanged.'};
  });
  assert(await io.scope(actor,expected,listing,true)===org,409,'The selected property library changed.');
  return{listing_id:listing,org_id:org,selected_library_org_id:expected,selected_count:count,sources,next_offset:offset+100<count?offset+100:null};
}
