/** Retained synthetic-account proof. No deletion, email, AI, publication or Apple operation.
 * Run only after the property-document edge handler is deployed.
 * Credentials and upload recovery receipts stay mode 0600 outside the checkout.
 */
import {createClient} from "@supabase/supabase-js";
import {readFile,writeFile,mkdtemp,mkdir,chmod} from "node:fs/promises";
import {writeFileSync,chmodSync,renameSync} from "node:fs";
import {join,resolve,relative,isAbsolute} from "node:path";
import {randomUUID,createHash} from "node:crypto";
import {execFileSync} from "node:child_process";
import assert from "node:assert/strict";
import {createStudioServices,StudioError} from "../src/data/index.ts";
import {validateUploadUrl} from "../src/data/services.ts";
import {canonicalDocument,DocumentSync,decodeDocument} from "../src/data/documents.ts";
import {uploadListingAsset,type UploadJournal} from "../src/features/listings/uploads.ts";
import {newDraft,validateDraft} from "../src/editor/model.ts";
import {propertyReelKey,reelPayload} from "../src/features/sync/property-reels.ts";

const PROJECT="ymgqpbnjpztwjsyvceld",origin=`https://${PROJECT}.supabase.co`;
const root=resolve(import.meta.dirname,"../../..");
const outputBase="/Users/pilksclaes/LocalRendpropAudits";
const sha=(bytes:Uint8Array)=>createHash("sha256").update(bytes).digest("hex");
const methods=new Set(["GET","POST","PATCH","PUT","HEAD"]);
const functionMethods:Record<string,readonly string[]>={
  me:["GET"],listings:["POST"],"studio/documents":["GET","POST"],"studio/photos":["POST"],
  "studio/listing-state":["GET"],"studio/media":["GET"],"studio/edit-output":["POST"],
  "studio/creative-results":["GET"],uploads:["POST"],
};
function permitted(raw:string,method:string){
  const url=new URL(raw);
  if(!methods.has(method)||url.username||url.password||url.protocol!=="https:")throw new Error("Unpermitted verification request");
  if(url.origin===origin){
    const allowed=url.pathname==="/auth/v1/admin/users"&&method==="POST" || url.pathname==="/auth/v1/token"&&method==="POST" || url.pathname==="/auth/v1/logout"&&method==="POST" || url.pathname==="/auth/v1/user"&&method==="GET" || ["/rest/v1/memberships","/rest/v1/listings"].includes(url.pathname)&&method==="GET" || Object.entries(functionMethods).some(([path,allowedMethods])=>url.pathname===`/functions/v1/${path}`&&allowedMethods.includes(method)) || method==="POST"&&/^\/functions\/v1\/uploads\/[0-9a-f-]{36}\/(renew|complete)$/.test(url.pathname) || method==="PATCH"&&/^\/functions\/v1\/listings\/[0-9a-f-]{36}$/.test(url.pathname);
    if(!allowed)throw new Error("Unpermitted verification route");
    return;
  }
  if(url.origin==="https://api.supabase.com"&&url.pathname===`/v1/projects/${PROJECT}/api-keys`&&method==="GET")return;
  if(url.origin==="https://uploads.rendprop.com"&&method==="PUT"){validateUploadUrl(raw);return;}
  if(/^[0-9a-f]{32}\.r2\.cloudflarestorage\.com$/.test(url.hostname)&&!url.port&&method==="GET")return;
  throw new Error("Unpermitted verification origin");
}
const observed:{method:string;origin:string;path:string}[]=[];
const guardedFetch:typeof fetch=async(input,init)=>{
  const raw=typeof input==="string"?input:input instanceof URL?input.href:input.url;
  const method=(init?.method??(input instanceof Request?input.method:"GET")).toUpperCase();
  permitted(raw,method);
  const url=new URL(raw);observed.push({method,origin:url.origin,path:url.pathname});
  return fetch(input,{...init,redirect:"error",signal:AbortSignal.any([...(init?.signal?[init.signal]:[]),AbortSignal.timeout(60000)])});
};
async function boundedBytes(response:Response,limit:number){
  assert(response.ok&&response.body,"Synthetic asset read failed");
  assert(Number(response.headers.get("content-length"))<=limit,"Synthetic response exceeds byte limit");
  const reader=response.body.getReader(),chunks:Uint8Array[]=[];let length=0;
  try{for(;;){const {done,value}=await reader.read();if(done)break;length+=value.byteLength;assert(length<=limit,"Synthetic response exceeds byte limit");chunks.push(value);}}
  finally{void reader.cancel().catch(()=>{});reader.releaseLock();}
  return Buffer.concat(chunks);
}
function syntheticPayload(listingId:string,title:string,image:Buffer,assetId:string){
  const draft=validateDraft({...newDraft(),title,clips:[{id:randomUUID(),source:{name:"synthetic-room.png",size:image.length,lastModified:0,sha256:sha(image),kind:"image",width:640,height:360,duration:0},start:0,end:2,caption:"Synthetic verification media",focusX:.5,focusY:.5}]});
  return reelPayload({draft,listingId,sources:[{sha256:sha(image),assetId,listingId}]},listingId);
}
async function selfTest(){
  const id="10000000-0000-4000-8000-000000000001";
  for(const [url,method] of [[origin+"/functions/v1/me","DELETE"],[origin+"/functions/v1/me","POST"],[origin+"/functions/v1/ai-video/reel-clip","POST"],[origin+"/functions/v1/team/invite","POST"],[origin+"/functions/v1/tours/publish","POST"],["https://other.example/file","GET"]])assert.throws(()=>permitted(url,method));
  permitted(origin+"/functions/v1/studio/documents","POST");
  permitted(`https://uploads.rendprop.com/v2/${id}?expires=9999999999999&signature=${"a".repeat(64)}`,"PUT");
  assert.throws(()=>permitted(`https://uploads.rendprop.com/v2/${id}?signature=unsafe`,"PUT"));
  assert.equal(syntheticPayload(id,"Synthetic reel",Buffer.from([1,2,3]),id).listingId,id);
  console.log(JSON.stringify({status:"passed",checks:9,networkRequests:0,scope:"Request allowlist and actual upload URL/reel validators"}));
}

async function main(){
  if(process.argv.includes("--self-test")){await selfTest();return;}
  if(!process.argv.includes("--run")){console.log("Use --self-test offline, or --run after the Studio backend deployment is confirmed.");process.exitCode=2;return;}
  let stage="prepare",privateDir:string|undefined;
  const services:ReturnType<typeof createStudioServices>[]=[],syncs:DocumentSync[]=[];
  const receipt:Record<string,any>={status:"running",runId:randomUUID(),checks:[],aiCalls:0,emailSends:0,publications:0,deletions:0,customerDataTouched:false,appleLoginVerified:false,physicalCameraTested:false};
  let state:Record<string,any>={};
  // The upload helper calls onJournal synchronously before dispatch. A promise
  // callback would not establish durable recovery before the next network write.
  const persist=()=>{
    assert(privateDir,"Recovery directory unavailable");const temp=join(privateDir,"recovery.next.json");
    writeFileSync(temp,JSON.stringify(state),{mode:0o600});chmodSync(temp,0o600);renameSync(temp,join(privateDir,"recovery.json"));
  };
  try{
    await mkdir(outputBase,{recursive:true});privateDir=await mkdtemp(join(outputBase,"complete-sync-20260922-"));await chmod(privateDir,0o700);
    assert(relative(root,privateDir).startsWith(".."),"Recovery must stay outside the checkout");
    state={runId:receipt.runId,email:`studio-complete-${receipt.runId}@example.invalid`,password:randomUUID()+randomUUID(),createdUser:false,listingKeys:[`listing-create:${randomUUID()}`,`listing-create:${randomUUID()}`],uploads:{}};
    await persist();
    const env=await readFile(join(root,"apps/studio/.env.production.local"),"utf8");
    const publicKey=/^VITE_SUPABASE_PUBLISHABLE_KEY=(.*)$/m.exec(env)?.[1].trim().replace(/^['"]|['"]$/g,"");
    assert(publicKey,"Public browser configuration missing");
    const management=(await readFile("/Users/pilksclaes/Rendprop AI/_bridge/.supabase-token","utf8")).trim();
    stage="read-authorized-account-credential";
    const keys=JSON.parse((await boundedBytes(await guardedFetch(`https://api.supabase.com/v1/projects/${PROJECT}/api-keys`,{headers:{Authorization:`Bearer ${management}`}}),262144)).toString("utf8"));
    const serviceKey=Array.isArray(keys)?keys.find((item:{name?:string})=>item.name==="service_role")?.api_key:null;
    assert(typeof serviceKey==="string","Authorized synthetic-account credential missing");
    const options={auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false},global:{fetch:guardedFetch}};
    const admin=createClient(origin,serviceKey,options),clients=[createClient(origin,publicKey,options),createClient(origin,publicKey,options)];
    stage="create-retained-synthetic-account";state.creationAttempted=true;await persist();
    const created=await admin.auth.admin.createUser({email:state.email,password:state.password,email_confirm:true,user_metadata:{name:"Studio retained integration fixture"}});
    assert(!created.error&&created.data.user,"Synthetic account creation failed; recover the retained attempt before retrying");
    state.userId=created.data.user.id;state.createdUser=true;await persist();
    stage="two-independent-sessions";
    for(const client of clients){const result=await client.auth.signInWithPassword({email:state.email,password:state.password});assert(!result.error&&result.data.user?.id===state.userId,"Synthetic login failed");}
    services.push(...clients.map(client=>createStudioServices({supabaseUrl:origin,publishableKey:publicKey,redirectTo:"https://studio.rendprop.com/"},{auth:client.auth,fetch:guardedFetch,readTimeoutMs:60000})));
    const [desktop,phone]=services;const workspace=await desktop.loadWorkspace();state.orgId=workspace.org.id;await persist();
    const orgId=state.orgId as string;const second=await phone.loadWorkspace(undefined,orgId);assert.equal(second.user.id,state.userId);assert.equal(second.org.id,orgId);receipt.checks.push("Independent authenticated sessions restore the same synthetic user and workspace");
    stage="create-two-properties-and-sync-facts";
    const listings=[];
    for(let i=0;i<2;i++){
      const listing=await phone.api("/functions/v1/listings",{orgId,method:"POST",idempotencyKey:state.listingKeys[i],body:{space_type:"real_estate",address:`Studio retained fixture ${i===0?"A":"B"} — not a real property`,beds:3,baths:2,sqft:1500,price_cents:35000000,details:{studio_test:receipt.runId}}}) as {id:string};
      assert(typeof listing.id==="string","Synthetic listing receipt missing");listings.push(listing);state.listingIds=listings.map(row=>row.id);await persist();
    }
    const [a,b]=listings.map(row=>row.id);
    await desktop.api(`/functions/v1/listings/${a}`,{orgId,method:"PATCH",body:{tagline:"Updated from the office"}});
    assert.equal((await phone.listListings(orgId)).find(row=>row.id===a)?.tagline,"Updated from the office");
    const replay=await phone.api("/functions/v1/listings",{orgId,method:"POST",idempotencyKey:state.listingKeys[0],body:{space_type:"real_estate",address:"Stale replay must not replace saved facts",tagline:"Stale",beds:9,details:{studio_test:receipt.runId}}}) as {id:string;tagline:string};
    assert.equal(replay.id,a);assert.equal(replay.tagline,"Updated from the office");assert.equal((await desktop.listListings(orgId)).filter(row=>row.id===a).length,1);
    receipt.checks.push("Phone-created properties and desktop fact changes synchronize; create replay cannot duplicate or overwrite office edits");
    stage="generate-bounded-public-fixtures";
    const imagePath=join(privateDir,"synthetic-room.png"),moviePath=join(privateDir,"synthetic-edit.mp4");
    execFileSync("ffmpeg",["-v","error","-f","lavfi","-i","color=c=purple:s=640x360","-frames:v","1","-threads","1",imagePath],{timeout:20000,stdio:"pipe"});
    execFileSync("ffmpeg",["-v","error","-f","lavfi","-i","color=c=purple:s=128x128:r=15:d=1","-an","-c:v","libx264","-pix_fmt","yuv420p",moviePath],{timeout:20000,stdio:"pipe"});
    const image=await readFile(imagePath),movie=await readFile(moviePath);assert(image.length<1048576&&movie.length<1048576,"Synthetic media exceeds limit");
    const upload=async(label:string,service:typeof desktop,listingId:string,bytes:Buffer,kind:"image"|"video")=>{
      return uploadListingAsset(service,{orgId,listingId,file:new File([bytes],kind==="image"?"synthetic-room.png":"synthetic-edit.mp4",{type:kind==="image"?"image/png":"video/mp4",lastModified:0}),role:kind==="image"?"gallery":"render",...(kind==="video"?{metadata:{duration_s:1,width:128,height:128}}:{}),onJournal:(journal:UploadJournal)=>{state.uploads[label]=journal;persist();}});
    };
    stage="upload-two-property-images";
    const images=[];
    for(const [index,listingId] of [a,b].entries()){
      const item=await upload(`photo-${index}`,phone,listingId,image,"image");images.push(item);
      await phone.api("/functions/v1/studio/photos",{orgId,method:"POST",body:{listing_id:listingId,asset_id:item.assetId,caption:"Synthetic verification image"}});
      const media=await desktop.listMedia(orgId,listingId),photo=media.photos.find(row=>row.id===item.assetId);assert(photo,"Shared synthetic photo missing");
      assert.deepEqual(await boundedBytes(await guardedFetch(photo.url,{credentials:"omit"}),1048576),image);
    }
    receipt.checks.push("Actual upload gateway, completed-asset receipt, gallery attachment and scoped signed-byte read agree on both properties");
    stage="legacy-and-property-reel-documents";
    const makeSync=async(key:string)=>{const sync=new DocumentSync(desktop,orgId,key,()=>{});syncs.push(sync);assert.equal(await sync.open(),null);return sync;};
    const write=async(sync:DocumentSync,payload:Record<string,unknown>)=>{sync.queue(payload);await sync.flush();assert.equal(sync.state,"saved","Document save did not finish");assert.equal(sync.hasUnsavedWork,false);};
    const payloadA=syntheticPayload(a,"Property A reel",image,images[0].assetId),payloadB=syntheticPayload(b,"Property B reel",image,images[1].assetId);
    const legacy=await makeSync("edit");const earlier={...payloadA,draft:{...payloadA.draft,title:"Preserved earlier workspace reel"}};await write(legacy,earlier);
    const syncA=await makeSync(propertyReelKey(a)),syncB=await makeSync(propertyReelKey(b));await write(syncA,payloadA);await write(syncB,payloadB);
    const read=async(key:string)=>decodeDocument(await phone.api(`/functions/v1/studio/documents?key=${encodeURIComponent(key)}`,{orgId}),key);
    assert.equal(canonicalDocument((await read(propertyReelKey(a)))?.payload),canonicalDocument(payloadA));assert.equal(canonicalDocument((await read(propertyReelKey(b)))?.payload),canonicalDocument(payloadB));
    const secondA={...payloadA,draft:{...payloadA.draft,title:"Property A revised in the office"}};await write(syncA,secondA);
    assert.equal(canonicalDocument((await read(propertyReelKey(a)))?.payload),canonicalDocument(secondA));assert.equal(canonicalDocument((await read(propertyReelKey(b)))?.payload),canonicalDocument(payloadB));assert.equal(canonicalDocument((await read("edit"))?.payload),canonicalDocument(earlier));
    receipt.checks.push("Actual property-scoped editor saves restore across two sessions; changing A leaves B and the earlier workspace reel unchanged");
    stage="adversarial-document-scope-and-revisions";
    const rejected=async(body:Record<string,unknown>,status:number)=>assert.rejects(phone.api("/functions/v1/studio/documents",{orgId,method:"POST",body}),error=>error instanceof StudioError&&error.status===status);
    await rejected({key:propertyReelKey(a),kind:"edit",listing_id:a,expected_revision:0,payload:payloadA},409);
    await rejected({key:propertyReelKey(a),kind:"edit",listing_id:b,expected_revision:2,payload:payloadB},400);
    await rejected({key:propertyReelKey(a),kind:"edit",listing_id:a,expected_revision:2,payload:payloadB},400);
    assert.equal(canonicalDocument((await read(propertyReelKey(a)))?.payload),canonicalDocument(secondA));assert.equal(canonicalDocument((await read(propertyReelKey(b)))?.payload),canonicalDocument(payloadB));assert.equal(canonicalDocument((await read("edit"))?.payload),canonicalDocument(earlier));
    receipt.checks.push("Stale revisions and mismatched key/listing/payload combinations are rejected without overwriting either sibling reel or legacy work");
    stage="save-provider-free-mp4-and-disclosure";
    const video=await upload("finished-video",desktop,a,movie,"video");
    const body={listing_id:a,asset_id:video.assetId,source_asset_ids:[images[0].assetId]};
    const finalized=await desktop.api("/functions/v1/studio/edit-output",{orgId,method:"POST",body}) as {ok:boolean;asset_id:string;provenance_id:string;disclosure:string};
    assert.equal(finalized.ok,true);assert.equal(finalized.asset_id,video.assetId);assert.match(finalized.disclosure,/edited in Rendprop Studio/);
    const replayOutput=await phone.api("/functions/v1/studio/edit-output",{orgId,method:"POST",body}) as {provenance_id:string};assert.equal(replayOutput.provenance_id,finalized.provenance_id);
    const history=await phone.api(`/functions/v1/studio/creative-results?listing_id=${a}`,{orgId}) as {results:{asset_id:string;state:string;url:string}[]};
    const output=history.results.filter(row=>row.asset_id===video.assetId);assert.equal(output.length,1);assert.equal(output[0].state,"completed");
    assert.deepEqual(await boundedBytes(await guardedFetch(output[0].url,{credentials:"omit"}),1048576),movie);
    receipt.checks.push("A real bounded MP4 saves once with immutable source disclosure and is readable byte-for-byte in the second session; nothing is published");
    stage="independent-session-signout";await desktop.signOut();assert((await phone.listListings(orgId)).some(row=>row.id===a));receipt.checks.push("Browser-local sign-out leaves the second device session active");
    receipt.status="passed";receipt.fixtureMedia={pngBytes:image.length,pngSha256:sha(image),mp4Bytes:movie.length,mp4Sha256:sha(movie)};
  }catch(error){receipt.status="failed";receipt.failure={stage,category:error instanceof StudioError?"studio-api":error instanceof Error&&error.name==="AssertionError"?"verification-assertion":"operation",...(error instanceof StudioError?{code:error.code,status:error.status??null}:{})};process.exitCode=1;}
  finally{
    for(const sync of syncs)sync.dispose();for(const service of services)service.dispose();
    receipt.finishedAt=new Date().toISOString();receipt.syntheticAccountRetained=state.createdUser===true;receipt.privateRecoveryRetained=!!privateDir;receipt.recoveryDirectory=privateDir??null;receipt.requests=observed;
    if(privateDir){state.lastStage=stage;state.result=receipt.status;await persist();await writeFile(join(privateDir,"receipt.json"),JSON.stringify(receipt,null,2)+"\n",{mode:0o600});}
    const target=process.argv.find(value=>value.startsWith("--receipt="))?.slice(10);
    if(target){assert(isAbsolute(target),"Receipt path must be absolute");await writeFile(target,JSON.stringify(receipt,null,2)+"\n",{mode:0o600});}
    console.log(JSON.stringify(receipt,null,2));
  }
}
void main().catch(()=>{console.error(JSON.stringify({status:"failed",failure:{stage:"verification-runner",category:"safe-stop"},credentialsPrinted:false}));process.exitCode=1;});
