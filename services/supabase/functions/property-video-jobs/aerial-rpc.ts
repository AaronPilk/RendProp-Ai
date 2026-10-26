/** Only the six SQL functions returning property_video_aerial_openings.
 * PostgREST can wrap a composite row in a singleton array; an absent composite
 * can be null, an empty array or an all-null row. None is an existing job.
 * This transport boundary does not grant scope or relax saved recipe checks. */
import {adminClient} from '../_shared/supabase.ts';
import {assert,throwRpc} from '../_shared/http.ts';
export const AERIAL_COMPOSITE_RPCS=['property_video_aerial_operation','property_video_aerial_scope','property_video_aerial_admit','property_video_aerial_cancel','property_video_aerial_worker_read','property_video_aerial_cpu_output'] as const;
export type AerialCompositeRPC=typeof AERIAL_COMPOSITE_RPCS[number];
export type AerialCompositeRow=Record<string,any>&{id:string;actor_id:string;operation_id:string;org_id:string;library_org_id:string;listing_id:string;manifest_sha256:string;manifest:Record<string,unknown>;consent:Record<string,unknown>};
const UUID=/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const object=(v:unknown):v is Record<string,unknown>=>v!==null&&typeof v==='object'&&!Array.isArray(v);
export function aerialCompositeValue(name:AerialCompositeRPC,value:unknown,args:Record<string,unknown>):AerialCompositeRow|null{
 assert(AERIAL_COMPOSITE_RPCS.includes(name),500,'Use the exact aerial composite RPC.');
 let row=value;
 if(Array.isArray(row)){assert(row.length<=1,503,'Saved aerial work returned more than one row.');row=row.length===0?null:row[0];}
 const absent=row===null||(object(row)&&Object.keys(row).length>0&&Object.values(row).every(v=>v===null));
 if(absent){assert(name==='property_video_aerial_operation',503,'Saved aerial work could not be read.');return null;}
 assert(object(row)&&['id','actor_id','operation_id','org_id','library_org_id','listing_id'].every(k=>typeof row[k]==='string'&&UUID.test(row[k]as string))&&typeof row.manifest_sha256==='string'&&/^[a-f0-9]{64}$/.test(row.manifest_sha256)&&typeof row.state==='string'&&object(row.manifest)&&object(row.consent),503,'Saved aerial work returned an invalid row.');
 const r=row as AerialCompositeRow;
 assert(r.manifest.operation_id===r.operation_id&&r.manifest.listing_id===r.listing_id,409,'The saved aerial operation identity changed.');
 for(const[k,column]of[['p_id','id'],['p_actor','actor_id'],['p_operation','operation_id'],['p_listing','listing_id']]as const)if(args[k]!==undefined&&args[k]!==null)assert(typeof args[k]==='string'&&String(args[k]).toLowerCase()===r[column].toLowerCase(),409,'The saved aerial operation identity changed.');
 // expected_org_id may be a physical or logical library alias. SQL remains the
 // authority for canonical library mapping; do not replace it with an ID guess.
 return r;
}
export function aerialCompositeRpc(name:'property_video_aerial_operation',args:Record<string,unknown>):Promise<AerialCompositeRow|null>;
export function aerialCompositeRpc(name:Exclude<AerialCompositeRPC,'property_video_aerial_operation'>,args:Record<string,unknown>):Promise<AerialCompositeRow>;
export async function aerialCompositeRpc(name:AerialCompositeRPC,args:Record<string,unknown>):Promise<AerialCompositeRow|null>{
 assert(AERIAL_COMPOSITE_RPCS.includes(name),500,'Use the exact aerial composite RPC.');
 const{data,error}=await adminClient().rpc(name,args);if(error)throwRpc(error.message);return aerialCompositeValue(name,data,args);
}
/** The only nullable JSONB lookup used here; an absent Stop is not an RPC error. */
export async function aerialStoppedRpc(args:Record<string,unknown>):Promise<Record<string,unknown>|null>{
 const{data,error}=await adminClient().rpc('property_video_aerial_stopped',args);if(error)throwRpc(error.message);
 if(data===null)return null;
 assert(object(data)&&data.operation_id===args.p_operation&&data.operation_confirmed===true&&data.admitted===false&&data.cancelled===true&&data.may_submit===false,503,'The saved aerial stop returned an invalid receipt.');return data;
}
