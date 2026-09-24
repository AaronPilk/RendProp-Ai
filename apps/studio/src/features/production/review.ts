import {decodeProductionPlan,type ProductionPlan} from "./model";
import {decodeDocument,type CloudDocument} from "../../data/documents";
import {reelPayload} from "../sync/property-reels";
export type ReviewAction="submit"|"comment"|"request_changes"|"approve"|"withdraw";
export type ReviewStatus="draft"|"in_review"|"changes_requested"|"approved";
export type ReviewEvent={id:string;action:string;author_id:string;created_at:string;document_revision:number;message:string|null;position_ms:number|null};
export type ProductionReview={document_user_id:string;org_id:string;key:string;listing_id:string;revision:number;document_revision:number;status:ReviewStatus;events:ReviewEvent[];updated_at:string};
export type ReviewPermissions={can_submit:boolean;can_comment:boolean;can_request_changes:boolean;can_approve:boolean;can_withdraw:boolean};
export type ReviewBundle={review:ProductionReview;document:CloudDocument|null;permissions:ReviewPermissions;source_revision:number;brief:ProductionPlan|null};
export const REVIEW_LABELS:Record<ReviewStatus,string>={draft:"Draft",in_review:"Ready for review",changes_requested:"Changes requested",approved:"Approved"};
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
function record(value:unknown):Record<string,unknown>{if(!value||typeof value!=="object"||Array.isArray(value))throw new Error("Review information could not be read.");return value as Record<string,unknown>;}
function revision(value:unknown,zero=false):number{if(!Number.isSafeInteger(value)||Number(value)<(zero?0:1))throw new Error("Review version could not be read.");return Number(value);}
export function decodeReview(value:unknown,orgId:string,listingId?:string):ProductionReview {
  const row=record(value);
  if(row.org_id!==orgId||typeof row.listing_id!=="string"||!uuid.test(row.listing_id)||(listingId&&row.listing_id!==listingId)||row.key!==`edit:${row.listing_id}`||typeof row.document_user_id!=="string"||!uuid.test(row.document_user_id)||!Object.hasOwn(REVIEW_LABELS,String(row.status))||!Array.isArray(row.events)||row.events.length>500||typeof row.updated_at!=="string"||!Number.isFinite(Date.parse(row.updated_at)))throw new Error("This review does not belong to the selected workspace or property.");
  const events=row.events.map(raw=>{
    const event=record(raw);
    if(typeof event.id!=="string"||!uuid.test(event.id)||typeof event.author_id!=="string"||!uuid.test(event.author_id)||typeof event.action!=="string"||event.action.length>48||typeof event.created_at!=="string"||!Number.isFinite(Date.parse(event.created_at))||(event.message!=null&&(typeof event.message!=="string"||event.message.length>2000))||(event.position_ms!=null&&(!Number.isSafeInteger(event.position_ms)||Number(event.position_ms)<0||Number(event.position_ms)>180000)))throw new Error("A review comment could not be read.");
    return {id:event.id,action:event.action,author_id:event.author_id,created_at:event.created_at,document_revision:revision(event.document_revision),message:event.message??null,position_ms:event.position_ms??null} as ReviewEvent;
  });
  return {...row,revision:revision(row.revision,true),document_revision:revision(row.document_revision),events} as ProductionReview;
}
export function decodePermissions(value:unknown):ReviewPermissions {
  const row=record(value);for(const key of ["can_submit","can_comment","can_request_changes","can_approve","can_withdraw"])if(typeof row[key]!=="boolean")throw new Error("Review permissions could not be verified.");return row as ReviewPermissions;
}
export function decodeReviewBundle(value:unknown,orgId:string,listingId:string,authorId?:string):ReviewBundle {
  const row=record(value),review=decodeReview(row.review,orgId,listingId),permissions=decodePermissions(row.permissions),sourceRevision=revision(row.source_revision);
  if(authorId&&review.document_user_id!==authorId)throw new Error("This review belongs to a different author.");
  const document=decodeDocument({document:row.document},review.key);
  if(document&&(document.listing_id!==listingId||document.revision!==sourceRevision))throw new Error("This review's saved edit changed. Refresh before continuing.");
  if(document)reelPayload(document.payload,listingId);
  return {review,document,permissions,source_revision:sourceRevision,brief:row.brief==null?null:decodeProductionPlan(row.brief,listingId)};
}
export function timeLabel(milliseconds:number):string {const seconds=Math.floor(milliseconds/1000);return `${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,"0")}`;}
export function commentPosition(value:string,durationSeconds?:number):number|null {
  if(!value.trim())return null;
  const match=/^(?:(\d{1,2}):)?(\d{1,2})(?:\.(\d{1,3}))?$/.exec(value.trim());
  if(!match||(match[1]&&Number(match[2])>=60))throw new Error("Use a video time such as 0:12 or 1:05.");
  const milliseconds=((Number(match[1]??0)*60)+Number(match[2]))*1000+Number((match[3]??"").padEnd(3,"0"));
  if(milliseconds>180000||(durationSeconds!==undefined&&milliseconds>durationSeconds*1000))throw new Error("Choose a time inside this video.");
  return milliseconds;
}
