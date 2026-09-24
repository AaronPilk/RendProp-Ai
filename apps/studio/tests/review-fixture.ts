import {StudioError} from "../src/data/config";
import type {CloudDocument} from "../src/data/documents";
import type {ProductionReview,ReviewAction} from "../src/features/production/review";
import type {SavedVersion,VersionSnapshot} from "../src/features/production/versions";
import type {ProductionPlan} from "../src/features/production/model";
export function reviewFixture(org:string,user:()=>string,documents:()=>Record<string,CloudDocument>,documentsFor=(id:string)=>documents()){
  const reviews=new Map<string,ProductionReview>(JSON.parse(localStorage.getItem("fixture-reviews")??"[]")),versions=new Map<string,VersionSnapshot>(JSON.parse(localStorage.getItem("fixture-versions")??"[]"));
  const persist=()=>{localStorage.setItem("fixture-reviews",JSON.stringify([...reviews]));localStorage.setItem("fixture-versions",JSON.stringify([...versions]));};
  function archive(author:string,doc:CloudDocument,reason:SavedVersion["reason"]){
    const identity=`${author}:${doc.key}:${doc.revision}`,old=versions.get(identity);if(old)return old;
    const version:SavedVersion={id:crypto.randomUUID(),document_user_id:author,org_id:org,key:doc.key,listing_id:doc.listing_id!,document_revision:doc.revision,reason,created_at:new Date().toISOString()};
    const brief=reason==="submitted"?structuredClone(documentsFor(author)[`production:${doc.listing_id}`]?.payload??null) as ProductionPlan|null:null;
    const snapshot={version,document:structuredClone(doc),brief};versions.set(identity,snapshot);persist();return snapshot;
  }
  function bundle(key:string,author=user()){
    const doc=documentsFor(author)[key];if(!doc)throw new StudioError("missing","Save a reel first.",404);
    const previous=reviews.get(`${author}:${key}`);
    const review=previous??{document_user_id:author,org_id:org,key,listing_id:key.slice(5),revision:0,document_revision:doc.revision,status:"draft",events:[],updated_at:new Date().toISOString()};
    if(review.document_revision!==doc.revision){review.status="draft";review.document_revision=doc.revision;review.revision++;review.updated_at=new Date().toISOString();}
    return {review:structuredClone(review),document:author===user()||review.status!=="draft"?structuredClone(doc):null,brief:versions.get(`${author}:${key}:${doc.revision}`)?.brief??null,source_revision:doc.revision,permissions:{can_submit:author===user()&&review.status!=="in_review",can_comment:review.status!=="draft",can_request_changes:review.status==="in_review",can_approve:review.status==="in_review",can_withdraw:author===user()&&review.status!=="draft"}};
  }
  return (path:string,body?:Record<string,unknown>)=>{
    if(path.includes("/production-review-queue"))return {reviews:[...reviews.values()].map(review=>{const {document,brief,...entry}=bundle(review.key,review.document_user_id);return entry;}),next_offset:null};
    if(!path.includes("/production-review"))return undefined;
    const params=new URL(path,"https://fixture.invalid").searchParams,key=body?String(body.key):params.get("key")!,author=String(body?.document_user_id??params.get("document_user_id")??user());
    if(path.includes("/production-review/versions?")){
      const offset=Number(params.get("offset")??0),rows=[...versions.values()].map(snapshot=>snapshot.version).filter(row=>row.document_user_id===author&&row.key===key&&(author===user()||row.reason==="submitted")).sort((a,b)=>b.document_revision-a.document_revision);
      return {versions:structuredClone(rows.slice(offset,offset+50)),next_offset:offset+50<rows.length?offset+50:null};
    }
    if(path.includes("/production-review/version?")||path.endsWith("/production-review/copy")){
      const revision=Number(body?.document_revision??params.get("document_revision")),snapshot=versions.get(`${author}:${key}:${revision}`);
      if(!snapshot||author!==user()&&snapshot.version.reason!=="submitted")throw new StudioError("missing","This saved version is unavailable.",404);
      if(!body)return structuredClone(snapshot);
      const target=documents()[key];if((target?.revision??0)!==body.expected_target_revision)throw new StudioError("conflict","Your saved target changed. Open this version again.",409);
      const preserved=target?archive(user(),target,"before_replace").version:null;
      const document={...structuredClone(snapshot.document),revision:(target?.revision??0)+1,updated_at:new Date().toISOString()};documents()[key]=document;persist();
      return {document:structuredClone(document),source_version:structuredClone(snapshot.version),preserved_version:structuredClone(preserved)};
    }
    const current=bundle(key,author);
    if(body){
      if(body.expected_document_revision!==current.source_revision||body.expected_review_revision!==current.review.revision)throw new StudioError("conflict","This version changed. Refresh the review.",409);
      const action=body.action as ReviewAction,review=current.review;
      if(action==="submit"){review.status="in_review";archive(author,current.document!,"submitted");}
      else if(action==="approve")review.status="approved";
      else if(action==="request_changes")review.status="changes_requested";
      else if(action==="withdraw")review.status="draft";
      review.revision++;review.updated_at=new Date().toISOString();review.events.push({id:crypto.randomUUID(),action,author_id:user(),created_at:review.updated_at,document_revision:current.source_revision,message:typeof body.message==="string"?body.message:null,position_ms:typeof body.position_ms==="number"?body.position_ms:null});reviews.set(`${author}:${key}`,review);persist();
    }
    return bundle(key,author);
  };
}
