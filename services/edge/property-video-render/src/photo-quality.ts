/** Separate photo-check identity. No video job, provider or judge authority. */
import {UUID,mediaURL} from './controller.ts';
import type {EgressProps} from './controller.ts';
export type PhotoRole='source'|'candidate';
export type PhotoRegion='whole'|'tl'|'tr'|'bl'|'br';
export interface PhotoInput {bucket:string;key:string;etag:string;bytes:number;sha256:string;mime:'image/jpeg'|'image/png'|'image/webp';url:string}
export interface PhotoAction {action:'prepare_photo_quality';policy:'photo-fixed-features-v1';check_id:string;evidence_id:string;lease_token:string;expires_at:string;prepared_source:PhotoInput;candidate:PhotoInput;state?:string}
export interface PhotoSlotState {
  kind:'photo_quality';checkID:string;slot:'slot-0'|'slot-1';token:string;
  task?:PhotoAction;taskID?:string;capabilities?:EgressProps;startedAt?:number;heartbeatAt?:number;
  pendingCallback?:{path:'derivatives-finish'|'failure';body:Record<string,unknown>};
}
const SHA=/^[a-f0-9]{64}$/;
const REGIONS=['whole','tl','tr','bl','br'];
const rows=(value:unknown):Record<string,unknown>[]=>{if(!Array.isArray(value)||value.some(v=>!v||typeof v!=='object'||Array.isArray(v)))throw Error('photo_quality_rows_required');return value;};
export function photoCapabilities(task:PhotoAction,hosts:Set<string>):EgressProps {
  const expiresAt=Date.parse(task.expires_at);
  if(task.action!=='prepare_photo_quality'||task.policy!=='photo-fixed-features-v1'||!UUID.test(task.check_id)||!UUID.test(task.evidence_id)||!UUID.test(task.lease_token)||!Number.isFinite(expiresAt)||expiresAt<=Date.now()||expiresAt>Date.now()+610_000)throw Error('photo_quality_lease_required');
  return{expiresAt,capabilities:[task.prepared_source,task.candidate].map(input=>{
    if(!input||!Number.isSafeInteger(input.bytes)||input.bytes<1||input.bytes>50*1024*1024||!SHA.test(input.sha256)||!['image/jpeg','image/png','image/webp'].includes(input.mime)||!input.bucket||!input.key||!input.etag)throw Error('photo_quality_input_required');
    return{url:mediaURL(input.url,hosts),method:'GET',bytes:input.bytes};
  })};
}
export function checkedPhotoResult(result:unknown,task:PhotoAction):Record<string,unknown> {
  if(!result||typeof result!=='object'||Array.isArray(result))throw Error('photo_quality_result_required');
  const value=result as Record<string,unknown>;
  if(value.check_id!==task.check_id||value.evidence_id!==task.evidence_id||value.lease_token!==task.lease_token||'job_id'in value)throw Error('photo_quality_receipt_conflict');
  return value;
}
export function photoOutputCapabilities(output:Record<string,unknown>,receipt:Record<string,unknown>,hosts:Set<string>):EgressProps {
  if(output.check_id!==receipt.check_id||output.evidence_id!==receipt.evidence_id)throw Error('photo_quality_output_identity_conflict');
  const expiresAt=Date.parse(String(output.expires_at));
  if(!Number.isFinite(expiresAt)||expiresAt<=Date.now())throw Error('photo_quality_output_expired');
  const manifest=receipt.manifest as Record<string,unknown>;
  const measured=rows(manifest?.images),reserved=rows(output.images);
  const keys=(values:Record<string,unknown>[])=>values.map(x=>`${x.role}:${x.region}`).sort().join(',');
  const canonical=['source','candidate'].flatMap(role=>REGIONS.map(region=>`${role}:${region}`)).sort().join(',');
  if(keys(measured)!==canonical||keys(reserved)!==canonical)throw Error('photo_quality_output_roles_conflict');
  let total=0;
  const capabilities=reserved.map(item=>{
    const actual=measured.find(x=>x.role===item.role&&x.region===item.region)!;
    if(['sha256','bytes','width','height'].some(k=>item[k]!==actual[k])||['left','top','width','height'].some(k=>(item.crop as Record<string,unknown>)?.[k]!==(actual.crop as Record<string,unknown>)?.[k])||item.mime!=='image/jpeg'||item.bucket!=='renders'||typeof item.key!=='string'||!item.key)throw Error('photo_quality_output_measurement_conflict');
    if(!Number.isSafeInteger(item.bytes)||Number(item.bytes)<1||!SHA.test(String(item.sha256)))throw Error('photo_quality_output_bound');
    total+=Number(item.bytes);
    const headers=item.headers as Record<string,string>;
    if(!headers||Object.keys(headers).sort().join(',')!=='content-length,content-type,if-none-match,x-amz-meta-sha256'||headers['content-length']!==String(item.bytes)||headers['content-type']!=='image/jpeg'||headers['if-none-match']!=='*'||headers['x-amz-meta-sha256']!==item.sha256)throw Error('photo_quality_output_headers_conflict');
    return{url:mediaURL(String(item.put_url),hosts),method:'PUT' as const,bytes:Number(item.bytes),headers};
  });
  if(total>6_000_000)throw Error('photo_quality_aggregate_bound');
  return{expiresAt,capabilities};
}
export function photoFailure(task:PhotoAction):Record<string,unknown> {return{check_id:task.check_id,lease_token:task.lease_token,code:'cpu_photo_comparison_failed'};}
