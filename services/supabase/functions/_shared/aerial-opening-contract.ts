/** Closed source-bound aerial receipt. Shape validation grants no acceptance authority. */
export const AERIAL_OPENING_PROFILE='photo-motion-v2-opening-cfr24' as const;
export const AERIAL_OPENING_BYTES=134217728;
export const AERIAL_OPENING_FRAMES=[120,121,144,192] as const;
export interface AerialOpeningSource {photo_asset_id:string;photo_version_id:string;photo_provenance_id:string|null;sha256:string;bytes:number}
export interface AerialOpeningReference {aerial_job_id:string;asset_id:string;provenance_id:string;sha256:string;bytes:number;visible_frames:120|121|144|192;source:AerialOpeningSource}
export interface AerialOpeningScope {actor_id:string;org_id:string;selected_library_org_id:string;listing_id:string}
export interface AerialOpeningReceipt extends AerialOpeningReference {schema:1;kind:'aerial_opening';position:0;scope:AerialOpeningScope;fps:24;available_frames:120|121|144|192;width:1920|1080;height:1080|1920;duration_s:number;aspect:'16:9'|'9:16';disclosure:string;accepted_at:string}
export interface AerialOpeningTask {receipt:AerialOpeningReceipt;media:{url:string;sha256:string;bytes:number;etag:string}}
const UUID=/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i,HEX=/^[a-f0-9]{64}$/;
function object(v:unknown):v is Record<string,unknown>{return !!v&&typeof v==='object'&&!Array.isArray(v);}
function keys(v:unknown,allowed:string[]):v is Record<string,unknown>{return object(v)&&Object.keys(v).sort().join(',')===[...allowed].sort().join(',');}
function id(v:unknown):string{if(typeof v!=='string'||!UUID.test(v))throw Error('aerial_opening_identity_refused');return v.toLowerCase();}
function bytes(v:unknown,max:number):number{if(!Number.isSafeInteger(v)||(v as number)<1||(v as number)>max)throw Error('aerial_opening_bytes_refused');return v as number;}
function hash(v:unknown):string{if(typeof v!=='string'||!HEX.test(v))throw Error('aerial_opening_digest_refused');return v;}
const referenceKeys=['aerial_job_id','asset_id','provenance_id','sha256','bytes','visible_frames','source'];
export function aerialOpeningReference(value:unknown):AerialOpeningReference{
 if(!keys(value,referenceKeys)||!AERIAL_OPENING_FRAMES.includes(value.visible_frames as 120|121|144|192)||!Number.isSafeInteger(value.visible_frames)||!keys(value.source,['photo_asset_id','photo_version_id','photo_provenance_id','sha256','bytes']))throw Error('closed_aerial_opening_reference_required');
 const s=value.source,asset=id(s.photo_asset_id);if(typeof s.photo_version_id!=='string'||s.photo_version_id.toLowerCase()!=='asset:'+asset)throw Error('aerial_opening_source_version_refused');
 return{aerial_job_id:id(value.aerial_job_id),asset_id:id(value.asset_id),provenance_id:id(value.provenance_id),sha256:hash(value.sha256),bytes:bytes(value.bytes,AERIAL_OPENING_BYTES),visible_frames:value.visible_frames as 120|121|144|192,source:{photo_asset_id:asset,photo_version_id:'asset:'+asset,photo_provenance_id:s.photo_provenance_id===null?null:id(s.photo_provenance_id),sha256:hash(s.sha256),bytes:bytes(s.bytes,52428800)}};
}
export function aerialOpeningReceipt(value:unknown,aspect:'16:9'|'9:16'):AerialOpeningReceipt{
 const extra=['schema','kind','position','scope','fps','available_frames','width','height','duration_s','aspect','disclosure','accepted_at'];
 if(!keys(value,[...referenceKeys,...extra]))throw Error('closed_aerial_opening_receipt_required');
 const ref=aerialOpeningReference(Object.fromEntries(referenceKeys.map(k=>[k,value[k]])));
 if(value.schema!==1||value.kind!=='aerial_opening'||value.position!==0||!Number.isSafeInteger(value.position)||value.fps!==24||value.available_frames!==ref.visible_frames||value.duration_s!==ref.visible_frames/24||value.aspect!==aspect||value.width!==(aspect==='16:9'?1920:1080)||value.height!==(aspect==='16:9'?1080:1920)||!keys(value.scope,['actor_id','org_id','selected_library_org_id','listing_id'])||typeof value.disclosure!=='string'||value.disclosure.length<1||value.disclosure.length>2000||/[\u0000-\u001f]/.test(value.disclosure)||typeof value.accepted_at!=='string'||value.accepted_at.length>64||!/(?:Z|[+-]\d{2}:\d{2})$/.test(value.accepted_at)||!Number.isFinite(Date.parse(value.accepted_at)))throw Error('exact_aerial_opening_receipt_required');
 for(const k of Object.keys(value.scope))id(value.scope[k]);
 return value as unknown as AerialOpeningReceipt;
}
export function aerialOpeningTask(value:unknown,aspect:'16:9'|'9:16'):AerialOpeningTask{
 if(!keys(value,['receipt','media'])||!keys(value.media,['url','sha256','bytes','etag']))throw Error('closed_aerial_opening_media_required');
 const r=aerialOpeningReceipt(value.receipt,aspect),m=value.media;
 if(m.sha256!==r.sha256||m.bytes!==r.bytes||typeof m.url!=='string'||typeof m.etag!=='string'||!m.etag||m.etag.length>512)throw Error('exact_aerial_opening_media_required');
 return value as unknown as AerialOpeningTask;
}
export function sameAerialOpening(a:unknown,b:unknown):boolean{
 const stable=(v:unknown):unknown=>Array.isArray(v)?v.map(stable):object(v)?Object.fromEntries(Object.keys(v).sort().map(k=>[k,stable(v[k])])):v;
 return JSON.stringify(stable(a))===JSON.stringify(stable(b));
}
