import {validateDraft, type EditDraft} from "../../editor/model";
import {decodeConversation, type ConversationState} from "../../editor/conversation-state";

export type ProjectSource = {sha256:string; assetId:string; listingId:string};
export type VideoProject = {schema:1; name:string; archived:boolean; listingId:string|null; draft:EditDraft; sources:ProjectSource[]; conversation?:ConversationState};
export type ProjectSummary = {key:string; name:string; archived:boolean; listingId:string|null; revision:number; updatedAt:string};
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
export function projectKey(id:string):string {if(!uuid.test(id))throw new Error("Choose a valid video project.");return `project:${id}`;}
export function projectName(value:unknown):string {if(typeof value!=="string"||!value.trim()||value.trim().length>80||/[\u0000-\u001f]/.test(value))throw new Error("Give your project a name of 1–80 characters.");return value.trim();}
export function decodeProject(value:unknown):VideoProject {
 const p=value as VideoProject;
 if(!p||p.schema!==1||typeof p.archived!=="boolean"||(p.listingId!==null&&!uuid.test(p.listingId)))throw new Error("This project could not be read. Its saved copy is preserved.");
 const draft=validateDraft(p.draft);
 if(!Array.isArray(p.sources)||p.sources.length>24)throw new Error("Project source references could not be read.");
 const seen=new Set<string>();
 const sources=p.sources.map(s=>{if(!s||!/^[a-f0-9]{64}$/.test(s.sha256)||!uuid.test(s.assetId)||!uuid.test(s.listingId)||seen.has(s.sha256))throw new Error("Project source references could not be read.");seen.add(s.sha256);return {sha256:s.sha256,assetId:s.assetId,listingId:s.listingId};});
 return {schema:1,name:projectName(p.name),archived:p.archived,listingId:p.listingId,draft,sources,...(p.conversation?{conversation:decodeConversation(p.conversation,draft.id)}:{})};
}
export function decodeProjectIndex(value:unknown):ProjectSummary[] {
 const rows=(value as {projects?:unknown})?.projects;
 if(!Array.isArray(rows)||rows.length>100)throw new Error("Your project list could not be read.");
 return rows.map(p=>{if(!p||typeof p.key!=="string"||!p.key.startsWith("project:")||projectKey(p.key.slice(8))!==p.key||typeof p.archived!=="boolean"||!Number.isSafeInteger(p.revision)||p.revision<1||!Number.isFinite(Date.parse(p.updatedAt))||(p.listingId!==null&&!uuid.test(p.listingId)))throw new Error("Your project list could not be read.");return {...p,name:projectName(p.name)};});
}
