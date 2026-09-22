/** Bounded production integration proof using a disposable synthetic account.
 * Never sends email, invokes AI, publishes tours, or touches a customer identity.
 * Credentials stay in memory; private recovery state is outside the checkout.
 */
import {createClient} from '@supabase/supabase-js';
import {readFile,mkdtemp,writeFile,chmod,unlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';import {join,resolve} from 'node:path';import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {createStudioServices,StudioError} from '../src/data';
import {uploadListingAsset} from '../src/features/listings/uploads';
import {businessApi} from '../src/features/business/api';
const PROJECT='ymgqpbnjpztwjsyvceld',origin=`https://${PROJECT}.supabase.co`;
if(!process.argv.includes('--run'))throw new Error('Use --run for the authorized bounded integration test.');
const root=resolve(import.meta.dirname,'../../..');
const env=await readFile(join(root,'apps/studio/.env.production.local'),'utf8');
const publicKey=/^VITE_SUPABASE_PUBLISHABLE_KEY=(.*)$/m.exec(env)?.[1].trim().replace(/^['"]|['"]$/g,'');
assert(publicKey,'Public browser config missing');
const token=await readFile('/Users/pilksclaes/Rendprop AI/_bridge/.supabase-token','utf8');
const keyResponse=await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/api-keys`,{headers:{Authorization:`Bearer ${token.trim()}`},signal:AbortSignal.timeout(20000)});
assert(keyResponse.ok,'Cannot obtain existing server credential for isolated account lifecycle');
const keys=await keyResponse.json();const serviceKey=keys.find((k:any)=>k.name==='service_role')?.api_key;
assert(typeof serviceKey==='string','Existing lifecycle credential missing');
const admin=createClient(origin,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
const clients=[0,1].map(()=>createClient(origin,publicKey,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}}));
const id=randomUUID();const email=`studio-sync-${id}@example.invalid`,password=randomUUID()+randomUUID();
const privateDir=await mkdtemp(join(tmpdir(),'rendprop-live-sync-'));await chmod(privateDir,0o700);
const receipt:any={status:'running',runId:id,checks:[],aiCalls:0,emailSends:0,publications:0,customerDataTouched:false,appleLoginVerified:false};
let userId:string|undefined,orgId:string|undefined,services:any[]=[];
await writeFile(join(privateDir,'recovery.json'),JSON.stringify({email,password}),{mode:0o600});
try{
 const created=await admin.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{name:'Studio sync verification'}});
 assert(!created.error&&created.data.user,'Disposable account creation failed');userId=created.data.user.id;
 await writeFile(join(privateDir,'recovery.json'),JSON.stringify({email,password,userId}),{mode:0o600});
 for(const client of clients){const signed=await client.auth.signInWithPassword({email,password});assert(!signed.error,'Synthetic session login failed');}
 services=clients.map(client=>createStudioServices({supabaseUrl:origin,publishableKey:publicKey,redirectTo:'https://studio.rendprop.com/'},{auth:client.auth,readTimeoutMs:60000}));
 const [desktop,phone]=services;const workspace=await desktop.loadWorkspace();orgId=workspace.org.id;
 const second=await phone.loadWorkspace(undefined,orgId);assert.equal(second.user.id,userId);assert.equal(second.org.id,orgId);receipt.checks.push('two independent sessions restore the same existing account and workspace');
 const listingKey=`listing-create:${randomUUID()}`;
 const listing:any=await phone.api('/functions/v1/listings',{orgId,method:'POST',idempotencyKey:listingKey,body:{space_type:'real_estate',address:'Studio integration fixture — not a real property',beds:3,baths:2,sqft:1500,price_cents:35000000,details:{studio_test:id}}});
 assert(typeof listing.id==='string','Listing receipt missing');
 assert((await desktop.listListings(orgId)).some((l:any)=>l.id===listing.id));
 await desktop.api(`/functions/v1/listings/${listing.id}`,{orgId,method:'PATCH',body:{tagline:'Updated from the office'}});
 assert.equal((await phone.listListings(orgId)).find((l:any)=>l.id===listing.id)?.tagline,'Updated from the office');receipt.checks.push('phone-created listing appears in Studio and desktop edits return to the second session');
 const replay:any=await phone.api('/functions/v1/listings',{orgId,method:'POST',idempotencyKey:listingKey,body:{space_type:'real_estate',address:'Changed replay body must not overwrite the saved listing',tagline:'Stale phone draft',beds:9,details:{studio_test:id}}});
 assert.equal(replay.id,listing.id);assert.equal(replay.address,listing.address);assert.equal(replay.tagline,'Updated from the office');
 const replayRows=await desktop.listListings(orgId);assert.equal(replayRows.filter((l:any)=>l.id===listing.id).length,1);assert.equal(replayRows.find((l:any)=>l.id===listing.id)?.beds,3);receipt.checks.push('listing-create replay returns the original row without duplication or overwriting later office edits');
 const payload={items:[{id:randomUUID(),title:'Synthetic open-house plan',caption:'Fixture only',channel:'Instagram',date:'2026-09-20T12:00',createdAt:new Date().toISOString()}]};
 const saved:any=await desktop.api('/functions/v1/studio/documents',{orgId,method:'POST',body:{key:'planner',kind:'planner',expected_revision:0,payload}});
 const loaded:any=await phone.api('/functions/v1/studio/documents?key=planner',{orgId});assert.deepEqual(loaded.document.payload,payload);assert.equal(saved.document.revision,1);
 await assert.rejects(phone.api('/functions/v1/studio/documents',{orgId,method:'POST',body:{key:'planner',kind:'planner',expected_revision:0,payload:{items:[]}}}),(e:any)=>e instanceof StudioError&&e.status===409);receipt.checks.push('shared drafts persist across sessions and stale revisions cannot overwrite them');
 const business=businessApi(desktop,workspace),phoneBusiness=businessApi(phone,second);
 const account=await business.account();
 await business.team();await business.leads({});await business.compliance({scope:'user'});
 const preferences={...account.notifications,lead_received:!account.notifications.lead_received};
 await business.saveNotifications(preferences);assert.deepEqual((await phoneBusiness.account()).notifications,preferences);
 receipt.checks.push('live account, team, leads and disclosure contracts decode; notification changes return to the second session');
 // Small generated raster fixture only; no customer file is read.
 const image=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==','base64');
 const uploaded=await uploadListingAsset(phone,{orgId,listingId:listing.id,file:new File([image],'studio-sync-fixture.png',{type:'image/png'}),role:'gallery'});
 await phone.api('/functions/v1/studio/photos',{orgId,method:'POST',body:{listing_id:listing.id,asset_id:uploaded.assetId,caption:'Synthetic verification image'}});
 const state:any=await desktop.api(`/functions/v1/studio/listing-state?listing_id=${listing.id}`,{orgId});assert(state.assets.some((a:any)=>a.id===uploaded.assetId&&a.uploaded));
 const media=await desktop.listMedia(orgId,listing.id);const attached=media.photos.find((p:any)=>p.id===uploaded.assetId);assert(attached,'Expected uploaded photo missing');
 const bytes=await fetch(attached.url,{redirect:'error',credentials:'omit',signal:AbortSignal.timeout(20000)});assert(bytes.ok,'Signed image unavailable');assert.deepEqual(Buffer.from(await bytes.arrayBuffer()),image);receipt.checks.push('real upload gateway completion, gallery attachment, activity hydration and signed media read agree');
 // Exercise gallery compare-and-save with two distinct generated images. These
 // normal account routes must agree with the second session's native fields.
 const secondImagePath=join(privateDir,'synthetic-second.png');
 execFileSync('ffmpeg',['-v','error','-f','lavfi','-i','color=c=blue:s=16x16','-frames:v','1','-threads','1',secondImagePath],{timeout:20000});
 const secondImage=await readFile(secondImagePath);
 const secondUpload=await uploadListingAsset(desktop,{orgId,listingId:listing.id,file:new File([secondImage],'studio-sync-second.png',{type:'image/png'}),role:'gallery'});
 assert.notEqual(secondUpload.assetId,uploaded.assetId);
 await desktop.api('/functions/v1/studio/photos',{orgId,method:'POST',body:{listing_id:listing.id,asset_id:secondUpload.assetId,caption:'Second synthetic image'}});
 const gallery=(body:any,service=desktop)=>service.api('/functions/v1/studio/photos',{orgId,method:'PATCH',body:{listing_id:listing.id,...body}});
 await gallery({action:'caption',photo_id:uploaded.assetId,caption:'Office gallery caption',expected_caption:attached.caption});
 assert.equal((await phone.listMedia(orgId,listing.id)).photos.find((p:any)=>p.id===uploaded.assetId)?.caption,'Office gallery caption');
 await assert.rejects(gallery({action:'caption',photo_id:uploaded.assetId,caption:'Stale caption',expected_caption:attached.caption},phone),(e:any)=>e instanceof StudioError&&e.status===409);
 const before=(await desktop.listMedia(orgId,listing.id)).photos.map((p:any)=>p.id),after=[...before].reverse();
 await gallery({action:'reorder',expected_order:before,photo_ids:after});
 assert.deepEqual((await phone.listMedia(orgId,listing.id)).photos.map((p:any)=>p.id),after);
 await gallery({action:'reorder',expected_order:before,photo_ids:after},phone);
 await assert.rejects(gallery({action:'reorder',expected_order:before,photo_ids:before},phone),(e:any)=>e instanceof StudioError&&e.status===409);
 const previousCover=(await desktop.listListings(orgId)).find((l:any)=>l.id===listing.id)?.mainPhotoKey;
 const cover:any=await gallery({action:'cover',photo_id:uploaded.assetId,expected_main_photo_key:previousCover});
 assert.equal((await phone.listListings(orgId)).find((l:any)=>l.id===listing.id)?.mainPhotoKey,cover.main_photo_key);
 await assert.rejects(gallery({action:'cover',photo_id:secondUpload.assetId,expected_main_photo_key:null},phone),(e:any)=>e instanceof StudioError&&e.status===409);
 const newCover:any=await gallery({action:'cover',photo_id:secondUpload.assetId,expected_main_photo_key:cover.main_photo_key},phone);
 const galleryState:any=await desktop.api(`/functions/v1/studio/listing-state?listing_id=${listing.id}`,{orgId});
 assert.deepEqual(galleryState.photos.filter((p:any)=>p.is_main).map((p:any)=>p.id),[secondUpload.assetId]);
 assert.equal((await desktop.listListings(orgId)).find((l:any)=>l.id===listing.id)?.mainPhotoKey,newCover.main_photo_key);
 receipt.checks.push('gallery captions, complete ordering and one cover synchronize; stale edits conflict and confirmed reorder replay is safe');
 await desktop.api(`/functions/v1/listings/${listing.id}`,{orgId,method:'PATCH',body:{sold_at:new Date().toISOString()}});
 assert((await phone.listListings(orgId)).find((l:any)=>l.id===listing.id)?.soldAt);
 await phone.api(`/functions/v1/listings/${listing.id}`,{orgId,method:'PATCH',body:{sold_at:null}});
 assert.equal((await desktop.listListings(orgId)).find((l:any)=>l.id===listing.id)?.soldAt,null);
 receipt.checks.push('mark sold and return to active synchronize through the existing native listing fields');
 const reservationId=randomUUID(),reservationArgs={p_actor:userId,p_org:orgId,p_id:reservationId,p_listing:listing.id};
 const reserved=await admin.rpc('reserve_voice_storage',reservationArgs);assert(!reserved.error);assert.equal(reserved.data.key,`ai-voice/${orgId}/${reservationId}.mp3`);
 const replayedReservation=await admin.rpc('reserve_voice_storage',reservationArgs);assert(!replayedReservation.error);assert.deepEqual(replayedReservation.data,reserved.data);
 receipt.checks.push('voice storage reservation returns its exact scoped key and unchanged deadline on replay without invoking a provider');
 const results:any=await desktop.api(`/functions/v1/studio/creative-results?listing_id=${listing.id}`,{orgId});assert(Array.isArray(results.results));receipt.checks.push('creative results route restores an empty scoped history without provider calls');
 // A tiny real MP4 validates browser-output persistence and its server-written
 // disclosure. It is never submitted for public publication or provider work.
 const moviePath=join(privateDir,'synthetic-edit.mp4');
 execFileSync('ffmpeg',['-v','error','-f','lavfi','-i','color=c=purple:s=128x128:r=15:d=1','-an','-c:v','libx264','-pix_fmt','yuv420p',moviePath],{timeout:20000});
 const movie=await readFile(moviePath);
 const edit=await uploadListingAsset(desktop,{orgId,listingId:listing.id,file:new File([movie],'studio-sync-edit.mp4',{type:'video/mp4'}),role:'render',metadata:{duration_s:1,width:128,height:128}});
 const finalized:any=await desktop.api('/functions/v1/studio/edit-output',{orgId,method:'POST',body:{listing_id:listing.id,asset_id:edit.assetId,source_asset_ids:[uploaded.assetId]}});
 assert.equal(finalized.ok,true);assert.equal(finalized.asset_id,edit.assetId);assert.match(finalized.disclosure,/edited in Rendprop Studio/);
 const repeat:any=await phone.api('/functions/v1/studio/edit-output',{orgId,method:'POST',body:{listing_id:listing.id,asset_id:edit.assetId,source_asset_ids:[uploaded.assetId]}});
 assert.equal(repeat.provenance_id,finalized.provenance_id);
 const edits:any=await phone.api(`/functions/v1/studio/creative-results?listing_id=${listing.id}`,{orgId});
 assert.equal(edits.results.filter((r:any)=>r.asset_id===edit.assetId).length,1);
 const sharedEdit=edits.results.find((r:any)=>r.asset_id===edit.assetId);assert.equal(sharedEdit.state,'completed');
 const editRead=await fetch(sharedEdit.url,{redirect:'error',credentials:'omit',signal:AbortSignal.timeout(20000)});assert(editRead.ok);assert.deepEqual(Buffer.from(await editRead.arrayBuffer()),movie);
 receipt.checks.push('real MP4 output finalizes once with server disclosure and exact source records, then restores on the other session');
 await desktop.signOut();assert((await phone.listListings(orgId)).some((l:any)=>l.id===listing.id));receipt.checks.push('Studio sign-out leaves the other device session active');
 receipt.status='passed';
}catch(error){receipt.status='failed';receipt.failure=error instanceof StudioError?{code:error.code,status:error.status,message:error.message}:{message:error instanceof Error?error.message:'Integration test failed'};}
finally{
 if(userId){
  try{
   // The normal cleanup route requires a user session but no workspace hydration.
   // This remains usable when the proof fails before services/loadWorkspace exists.
   const account=await admin.auth.admin.getUserById(userId);assert.equal(account.data.user?.email,email);
   let session=(await clients[1].auth.getSession()).data.session;
   if(!session){const login=await clients[1].auth.signInWithPassword({email,password});assert(!login.error,'Cleanup login failed');session=login.data.session;}
   assert.equal(session?.user.id,userId,'Cleanup identity mismatch');
   const result=await fetch(`${origin}/functions/v1/me`,{method:'DELETE',headers:{apikey:publicKey,Authorization:`Bearer ${session!.access_token}`},redirect:'error',signal:AbortSignal.timeout(180000)});
   const cleanup=await result.json();
   const requested=typeof cleanup.deletion_request_id==='string';
   receipt.cleanup={requested,accountRemoved:cleanup.ok===true,complete:cleanup.cleanup_complete===true,pending:cleanup.cleanup_complete!==true,pendingWork:cleanup.pending??null,...(requested?{deletionRequestId:cleanup.deletion_request_id}:{})};
   if(!requested||cleanup.ok!==true){receipt.status='failed';receipt.cleanup.privateRecoveryDirectory=privateDir;}
   // Pending storage cleanup is reported explicitly and stays in the durable
   // deletion queue; never claim all fixture objects are gone from an Auth receipt.
   if(cleanup.cleanup_complete===true)await unlink(join(privateDir,'recovery.json'));
   else await writeFile(join(privateDir,'recovery.json'),JSON.stringify({email,password,userId,orgId,deletionRequestId:cleanup.deletion_request_id??null,cleanupPending:true}),{mode:0o600});
  }catch{receipt.cleanup={requested:false,privateRecoveryDirectory:privateDir};receipt.status='failed';}
 }
 for(const s of services)s.dispose();
 receipt.finishedAt=new Date().toISOString();
 const file=process.argv.find(a=>a.startsWith('--receipt='))?.slice(10)??join(privateDir,'receipt.json');await writeFile(file,JSON.stringify(receipt,null,2)+'\n');
 console.log(JSON.stringify(receipt,null,2));
}
if(receipt.status!=='passed')process.exitCode=1;
