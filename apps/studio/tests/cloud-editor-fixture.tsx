import { createRoot } from "react-dom/client";
import { useState } from "react";
import CloudEditor from "../src/features/sync/PropertyReels";
import CloudPlanner from "../src/features/sync/CloudPlanner";
import { canonicalDocument } from "../src/data/documents";
import { StudioError } from "../src/data/config";
import type { StudioServices } from "../src/data/services";
import type {VideoEditorProps} from "../src/editor/VideoEditor";
import type {ShotPlanHandoff, AgentPlanHandoff} from "../src/features/creative/model";
import type { Workspace, Listing } from "../src/data/contracts";
import "../src/styles.css";
import {reviewFixture} from "./review-fixture";
const org = "10000000-0000-4000-8000-000000000001", listing = "20000000-0000-4000-8000-000000000002", other = "20000000-0000-4000-8000-000000000003", user = "40000000-0000-4000-8000-000000000004";
const workspace: Workspace = { user: { id: user, email: "fixture@example.invalid", name: "Fixture Agent", avatarUrl: null }, org: { id: org, name: "Fixture office", handle: "office", spaceType: "real_estate" }, memberships: [{ orgId: org, orgName: "Fixture office", role: "owner", spaceType: "real_estate" }], plan: "team", planRaw: "team", planDegraded: false, planExpiresAt: null, trialEndsAt: null, usage: { listings: 2, leads: 0, leadsNew: 0, renders: 0 } };
const listings: Listing[] = [listing, other].map((id, index) => ({ id, orgId: org, address: index ? "20 Pine Avenue" : "10 Oak Street", tagline: "", spaceType: "real_estate", details: {}, status: "ready", createdAt: "2026-09-14T12:00:00Z", mainPhotoKey: null, beds: 3, baths: 2, sqft: 2000, priceCents: 45000000 }));
type FixtureAsset = { id: string; listing_id: string; storage_key: string; content_type: string; kind: string; uploaded: boolean; base64?: string; bytes: number };
type FixtureDocument = { key: string; kind: string; listing_id: string | null; payload: Record<string, unknown>; revision: number; updated_at: string };
type Cloud = { assets: FixtureAsset[]; documents: Record<string, FixtureDocument>; tickets: number; puts: number; writes: number };
const cloud: Cloud = JSON.parse(localStorage.getItem("fixture-cloud") ?? '{"assets":[],"documents":{},"tickets":0,"puts":0,"writes":0}');
const persist = () => localStorage.setItem("fixture-cloud", JSON.stringify(cloud));
let loseComplete = false;
let failUpload=false;
let actorUser=user, holdRead=false;
let holdCopy=false,loseCopy=false,loseCopyStatus=0,copyCalls=0,reviewNarrationCalls=0;
const delayedCopies:(()=>void)[]=[];
const otherDocuments: Record<string, FixtureDocument> = {};
const reviewAPI=reviewFixture(org,()=>actorUser,()=>actorUser===user?cloud.documents:otherDocuments,id=>id===user?cloud.documents:otherDocuments);
const delayedReads: (()=>void)[]=[];
const voiceId = "50000000-0000-4000-8000-000000000005";
const voiceResult = {id:voiceId,kind:"voice",state:"completed",url:`https://${"a".repeat(32)}.r2.cloudflarestorage.com/fixture/narration.wav`,expires_at:"2099-09-14T12:00:00Z",duration_s:4,voice_name:"Fixture voice",label:"Saved office narration",words:[{text:"Welcome",start:0.2,end:0.8},{text:"home",start:0.8,end:1.4}]};
const services = {
  subscribe: () => () => {},
  getSnapshot: () => ({ status: "signed-in", identityVersion: 1, identity: { userId: user, isAnonymous: false } }),
  upload: async (url: string, blob: Blob) => { if(failUpload)throw new Error("Fixture upload paused");const id = url.split("/").at(-1), asset = cloud.assets.find(a => a.id === id)!; let bytes = ""; for (const n of new Uint8Array(await blob.arrayBuffer())) bytes += String.fromCharCode(n); asset.base64 = btoa(bytes); cloud.puts++; persist(); return { etag: "fixture-receipt" }; },
  listMedia: async (_org: string, id: string, _signal?: AbortSignal, offset=0) => {
    const available=cloud.assets.filter(a=>a.listing_id===id&&a.uploaded),page=available.slice(offset,offset+50);
    const mediaURL=(a:FixtureAsset)=>URL.createObjectURL(new Blob([Uint8Array.from(atob(a.base64!),c=>c.charCodeAt(0))],{type:a.content_type}));
    return {orgId:org,listingId:id,photos:page.filter(a=>a.kind==="photo").map(a=>({id:a.id,listingId:id,url:mediaURL(a),expiresAt:"2099-09-14T12:00:00Z",caption:"Editor source",isStaged:false,sort:0})),videos:page.filter(a=>a.kind==="video").map(a=>({id:a.id,listingId:id,url:mediaURL(a),kind:"video",createdAt:"2026-09-14T12:00:00Z",expiresAt:"2099-09-14T12:00:00Z",durationSeconds:4})),nextOffset:offset+50<available.length?offset+50:null,unavailableCount:0};
  },
  api: async (path: string, options: { method?: string; orgId: string; body?: Record<string, unknown> }) => {
    if (options.orgId !== org) throw new Error("Unexpected fixture workspace");
    const body = options.body;
    if(path.endsWith("/production-review/narration")){
      const saved=(body?.document_user_id===user?cloud.documents:otherDocuments)[String(body?.key)],draft=saved?.payload.draft as {narration?:{resultId:string}}|undefined;
      if(!saved||saved.revision!==body?.expected_document_revision||draft?.narration?.resultId!==body?.result_id||body?.result_id!==voiceId)throw new StudioError("missing","Saved review narration is unavailable.",404);
      reviewNarrationCalls++;
      return {result:voiceResult};
    }
    if(path.endsWith("/production-review/copy")){copyCalls++;if(holdCopy){holdCopy=false;await new Promise<void>(resolve=>delayedCopies.push(resolve));}}
    const review=reviewAPI(path,body);if(review!==undefined){persist();if(path.endsWith("/production-review/copy")&&loseCopy){loseCopy=false;if(loseCopyStatus)throw new StudioError("timeout","Fixture timed out after copying",loseCopyStatus);throw new Error("Fixture lost copy response");}return review;}
    if(path.includes("/studio/listing-state?")){const target=new URL(path,"https://fixture.invalid").searchParams.get("listing_id");return {org_id:org,listing_id:target,assets:cloud.assets.filter(a=>a.listing_id===target),photos:[],next_offset:null};}
    if(path.includes("/studio/creative-results?")) return {results:[voiceResult],next_offset:null};
    if(path.endsWith("/studio/edit-output")) {if(!Array.isArray(body?.source_asset_ids)||!body?.source_asset_ids.length)throw new Error("Edited export must retain source lineage");return {ok:true,asset_id:body?.asset_id};}
    if(path.endsWith("/studio/sign-media") && body?.result_id===voiceId) return {result:voiceResult};
    if (path.startsWith("/functions/v1/studio/documents")) {
      const key = body ? String(body.key) : new URL(path, "https://fixture.invalid").searchParams.get("key")!;
      const documents=actorUser===user?cloud.documents:otherDocuments;
      if (body) {
        if(key.startsWith("edit:")&&(body.listing_id!==key.slice(5)||(body.payload as {listingId?:string}).listingId!==body.listing_id))throw new Error("Fixture property document binding mismatch");
        const previous = documents[key]; if ((previous?.revision ?? 0) !== body.expected_revision) throw new StudioError("conflict", "Fixture concurrent save", 409);
        documents[key] = { key, kind: String(body.kind), listing_id: typeof body.listing_id==="string"?body.listing_id:null, payload: JSON.parse(canonicalDocument(body.payload)), revision: (previous?.revision ?? 0) + 1, updated_at: new Date().toISOString() }; cloud.writes++; persist();
      }
      const result={ document: structuredClone(documents[key] ?? null) };
      if(!body&&holdRead&&key.startsWith("edit:")){holdRead=false;await new Promise<void>(resolve=>delayedReads.push(resolve));}
      return result;
    }
    if (path === "/functions/v1/uploads") {
      const id = crypto.randomUUID(), asset: FixtureAsset = { id, listing_id: String(body!.listing_id), storage_key: `${body!.role === "capture" ? "uploads" : "renders"}/${org}/${body!.listing_id}/${id}.${body!.kind === "video" ? "mp4" : "png"}`, content_type: String(body!.content_type), kind: String(body!.kind), uploaded: false, bytes: Number(body!.bytes) };
      cloud.assets.push(asset); cloud.tickets++; persist(); return { asset_id: id, storage_key: asset.storage_key, uploaded: false, mode: "single", put_url: `https://uploads.rendprop.com/v2/${id}` };
    }
    const id = path.split("/").at(-2), asset = cloud.assets.find(a => a.id === id);
    if (asset && path.endsWith("/renew")) return { asset_id: asset.id, storage_key: asset.storage_key, uploaded: asset.uploaded, mode: "single", put_url: `https://uploads.rendprop.com/v2/${asset.id}` };
    if (asset && path.endsWith("/complete")) { asset.uploaded = true; persist(); if (loseComplete && asset.kind === "video") { loseComplete = false; throw new Error("Fixture lost completion response. Retry to confirm its saved receipt."); } return structuredClone(asset); }
    throw new Error(`Unpermitted fixture action ${path}`);
  },
} as unknown as StudioServices;
Object.assign(window, { cloudFixture: {
  snapshot: () => structuredClone(cloud), loseComplete: () => loseComplete = true,
  remoteEdit: (id=other) => { const key=`edit:${id}`,doc = cloud.documents[key]; cloud.documents[key] = { ...doc, revision: doc.revision + 1, payload: { ...doc.payload, draft: { ...(doc.payload.draft as object), title: "Saved on another device" } } }; persist(); window.dispatchEvent(new Event("focus")); },
  holdNextRead:()=>{holdRead=true;},releaseReads:()=>delayedReads.splice(0).forEach(resolve=>resolve()),pendingReads:()=>delayedReads.length,
  holdNextCopy:()=>{holdCopy=true;},releaseCopies:()=>delayedCopies.splice(0).forEach(resolve=>resolve()),pendingCopies:()=>delayedCopies.length,loseNextCopy:(status=0)=>{loseCopy=true;loseCopyStatus=status;},copyCalls:()=>copyCalls,actorDocuments:()=>structuredClone(actorUser===user?cloud.documents:otherDocuments),versions:()=>JSON.parse(localStorage.getItem("fixture-versions")??"[]"),
  failUpload:(value:boolean)=>{failUpload=value;},
} });
function Fixture() {
  const [activeUser,setActiveUser]=useState(user);
  const [activeRole,setActiveRole]=useState<Workspace["memberships"][number]["role"]>("owner");
  const [entryRequest,setEntryRequest]=useState<{id:string;listingId:string}>();
  const [importRequest,setImportRequest]=useState<VideoEditorProps["importRequest"]>(),[importPlan,setImportPlan]=useState<(ShotPlanHandoff & {id:string})>(),[importAgentPlan,setImportAgentPlan]=useState<(AgentPlanHandoff & {id:string})>();
  const [planner, setPlanner] = useState(false), [notice, setNotice] = useState("");
  Object.assign((window as unknown as {cloudFixture:object}).cloudFixture, {
  setRole:setActiveRole,
    reviewNarrationCalls:()=>reviewNarrationCalls,
    switchAccount:()=>{actorUser=actorUser===user?"40000000-0000-4000-8000-000000000099":user;setActiveUser(actorUser);setImportRequest(undefined);setImportPlan(undefined);setImportAgentPlan(undefined);setEntryRequest(undefined);},
    requestReelEntry: (id=crypto.randomUUID(),listingId=listing) => setEntryRequest({id,listingId}),
    requestOtherPropertyMedia: () => {const asset=cloud.assets.find(a=>a.kind==="photo"&&a.listing_id===listing&&a.uploaded)!;setImportRequest({id:crypto.randomUUID(),listingId:listing,sourceMedia:[{id:asset.id,kind:"photo"}],files:[new File([Uint8Array.from(atob(asset.base64!),c=>c.charCodeAt(0))],"library-photo.png",{type:asset.content_type})]});},
    installNativeRecipe: () => {cloud.documents[`native:${other}`]={key:`native:${other}`,kind:"native",listing_id:other,revision:1,updated_at:new Date().toISOString(),payload:{schema:1,kind:"native-reel-setup",portrait:false,titleCard:true,shotCaptions:true,captionStyle:"punchCard",transition:"dissolve",motionPrompt:"",script:"Saved on the phone",tone:"warm",wordCaptions:false,voiceMode:"off",voiceResultId:null,localNarration:false,photos:cloud.assets.filter(a=>a.listing_id===other&&a.kind==="photo"&&a.uploaded).map((asset,index)=>({localId:`native-${index}`,sourcePhotoId:asset.id})),localExtraClipCount:0,updatedAt:new Date().toISOString()}};persist();},
    requestAgentPlan: (originalOnly=false) => {const asset=cloud.assets.filter(a=>a.listing_id===other&&a.kind==="video"&&a.uploaded&&a.storage_key.startsWith("uploads/")).at(-1)!,photo=cloud.assets.filter(a=>a.listing_id===other&&a.kind==="photo"&&a.uploaded).at(-1)!;setImportPlan(undefined);setImportAgentPlan({id:crypto.randomUUID(),listingId:other,assetId:asset.id,script:"Continuous original speech",cutaways:originalOnly?[]:[{photoId:photo.id,start:1,end:2,caption:"The property detail",motion:"still"}]});},
    requestShotPlan: (missing=false) => {const photos=cloud.assets.filter(a=>a.kind==="photo"&&a.listing_id===other&&a.uploaded).reverse();setImportPlan({id:crypto.randomUUID(),listingId:other,script:"Fixture script",narrationResultId:null,shots:photos.map((asset,index)=>({photoId:missing&&index===0?crypto.randomUUID():asset.id,order:index+1,room:"Room",seconds:index===0?2:3,caption:index===0?"The closing view":"Welcome inside",motion:index===0?"slow push in":"pan left",voiceLine:""}))});}
  });
  return <div style={{ padding: 24 }}><button onClick={() => setPlanner(!planner)}>Switch to {planner ? "editor" : "planner"}</button>{notice && <p role="status">{notice}</p>}<div hidden={planner}><CloudEditor services={services} workspace={{...workspace,user:{...workspace.user,id:activeUser},memberships:workspace.memberships.map(member=>({...member,role:activeRole}))}} listings={listings} listingId={new URL(location.href).searchParams.get("listing")??listing} active={!planner} importRequest={importRequest} importPlan={importPlan} importAgentPlan={importAgentPlan} entryRequest={entryRequest} onOpenCreative={(listingId,tool)=>setNotice(`Open ${tool} for ${listingId}`)} onChanged={() => {}} /></div><div hidden={!planner}><CloudPlanner services={services} workspace={workspace} onNotice={setNotice} /></div></div>;
}
createRoot(document.getElementById("root")!).render(<Fixture />);
