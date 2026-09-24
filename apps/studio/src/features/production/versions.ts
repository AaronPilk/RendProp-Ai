import {decodeDocument,type CloudDocument} from "../../data/documents";
import {reelPayload} from "../sync/property-reels";
import {decodeProductionPlan,type ProductionPlan} from "./model";
import type {Workspace} from "../../data/contracts";

export type VersionChoice={listingId:string;authorId:string;revision:number};
export type SavedVersion={id:string;document_user_id:string;org_id:string;key:string;listing_id:string;document_revision:number;reason:"submitted"|"before_replace";created_at:string};
export type VersionSnapshot={version:SavedVersion;document:CloudDocument;brief:ProductionPlan|null};
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
export function canCopyVersion(workspace:Pick<Workspace,"org"|"memberships">):boolean{return ["owner","admin","agent"].includes(workspace.memberships.find(item=>item.orgId===workspace.org.id)?.role??"");}
function object(value:unknown):Record<string,unknown>{if(!value||typeof value!=="object"||Array.isArray(value))throw new Error("Saved version information could not be read.");return value as Record<string,unknown>;}
export function versionPath(route:"versions"|"version",choice:Omit<VersionChoice,"revision">&{revision?:number},offset=0){
  const params=new URLSearchParams({key:`edit:${choice.listingId}`,document_user_id:choice.authorId});
  if(route==="versions")params.set("offset",String(offset));else params.set("document_revision",String(choice.revision));
  return `/functions/v1/studio/production-review/${route}?${params}`;
}
export function decodeVersion(value:unknown,orgId:string,choice?:Partial<VersionChoice>):SavedVersion{
  const row=object(value);
  if(typeof row.id!=="string"||!uuid.test(row.id)||row.org_id!==orgId||typeof row.document_user_id!=="string"||!uuid.test(row.document_user_id)||typeof row.listing_id!=="string"||!uuid.test(row.listing_id)||row.key!==`edit:${row.listing_id}`||!Number.isSafeInteger(row.document_revision)||Number(row.document_revision)<1||!["submitted","before_replace"].includes(String(row.reason))||typeof row.created_at!=="string"||!Number.isFinite(Date.parse(row.created_at))||choice?.authorId&&row.document_user_id!==choice.authorId||choice?.listingId&&row.listing_id!==choice.listingId||choice?.revision&&row.document_revision!==choice.revision)throw new Error("This saved version does not match the selected author, property and revision.");
  return {id:row.id,document_user_id:row.document_user_id,org_id:orgId,key:String(row.key),listing_id:row.listing_id,document_revision:Number(row.document_revision),reason:row.reason as SavedVersion["reason"],created_at:row.created_at};
}
export function decodeVersionPage(value:unknown,orgId:string,choice:Omit<VersionChoice,"revision">,offset:number){
  const row=object(value);
  if(!Array.isArray(row.versions)||row.versions.length>50||row.next_offset!==null&&row.next_offset!==offset+50)throw new Error("Saved version history could not be read.");
  const versions=row.versions.map(item=>decodeVersion(item,orgId,choice));
  if(new Set(versions.map(item=>item.document_revision)).size!==versions.length)throw new Error("Saved history contains duplicate revisions.");
  return {versions,nextOffset:row.next_offset as number|null};
}
export function decodeVersionSnapshot(value:unknown,orgId:string,choice:VersionChoice):VersionSnapshot{
  const row=object(value),version=decodeVersion(row.version,orgId,choice),document=decodeDocument({document:row.document},`edit:${choice.listingId}`);
  if(!document||document.kind!=="edit"||document.listing_id!==choice.listingId||document.revision!==choice.revision)throw new Error("The saved edit does not match this version.");
  reelPayload(document.payload,choice.listingId);
  return {version,document,brief:row.brief==null?null:decodeProductionPlan(row.brief,choice.listingId)};
}
export function decodeCopyResult(value:unknown,orgId:string,actorId:string,choice:VersionChoice,expectedTargetRevision:number){
  const row=object(value),sourceVersion=decodeVersion(row.source_version,orgId,choice),document=decodeDocument({document:row.document},`edit:${choice.listingId}`);
  if(!document||document.kind!=="edit"||document.listing_id!==choice.listingId||document.revision!==expectedTargetRevision+1)throw new Error("The copy confirmation did not match the expected saved edit. Reload its server copy before editing.");
  reelPayload(document.payload,choice.listingId);
  const preservedVersion=row.preserved_version===null?null:decodeVersion(row.preserved_version,orgId,{listingId:choice.listingId,authorId:actorId,revision:expectedTargetRevision});
  if(expectedTargetRevision===0?preservedVersion!==null:!preservedVersion)throw new Error("The copy confirmation did not include the previous saved version.");
  return {document,sourceVersion,preservedVersion};
}
