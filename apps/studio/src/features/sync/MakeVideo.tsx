import {useCallback,useEffect,useMemo,useRef,useState} from "react";
import type {Listing,Workspace} from "../../data/contracts";
import {belongsToLibrary,canEditListing} from "../../data/contracts";
import {StudioError} from "../../data/config";
import type {StudioServices} from "../../data/services";
import {decodeResult} from "../creative/model";
import {abandonVideoOperation,assertVideoScope,decodeJob,decodeSources,enqueueVideo,MUSIC,planVideoSources,publishVideo,readVideoJournal,inspectVideoOperation,retainAbandonedVideo,retainRejectedVideo,resumeVideo,saveVideoJournal,selectedSources,videoClosure,videoScopeKey,type VideoClosure,type VideoInput,type VideoJob,type VideoJournal,type VideoPurpose,type VideoScope,type VideoSource,type VideoPresentation,type VideoPreparation} from "./property-video";
import {framingSummary,photoFrame} from "./video-framing";
import {prepareVideoSources} from "./source-preparation";
import "./make-video.css";

const REFUSED_NOTICE="No video job was accepted. Choose fewer photos or change the options, then create a new video.";
const DISCARDED_NOTICE="This saved request is discarded. No video was started from it, and it can't start later. Choose your photos and options for a new video.";
const DISCARD_CONFIRM="Discard this saved request? If the server never accepted it, it can't start later. If it was already accepted, that video is kept.";

type Props={services:StudioServices;workspace:Workspace;listings:Listing[];listingId?:string;active?:boolean;onChanged:()=>void;onSelectListing?:(id:string)=>boolean|void;readOnly?:boolean};
export default function MakeVideo(props:Props){
 const available=props.listings.filter(listing=>belongsToLibrary(listing,props.workspace));
 const [chosen,setChosen]=useState(props.listingId??"");
 const requested=props.listingId??chosen;
 const listing=available.find(item=>item.id===requested);
 return <section className="make-video" aria-label="Make a video"><header><div><p className="eyebrow">Photos → a finished video</p><h2>Make a video</h2><p>Use your saved property photos. We keep your selected photo order and choose gentle movement for each photo.</p></div></header>
  <label>Property<select aria-label="Video property" value={listing?.id??""} onChange={event=>{const id=event.target.value;if(props.onSelectListing?.(id)===false)return;setChosen(id);}}><option value="">Choose a property</option>{available.map(item=><option value={item.id} key={item.id}>{item.address||"Untitled property"}</option>)}</select></label>
  {listing?<VideoSession {...props} listing={listing} key={`${props.workspace.user.id}:${props.workspace.libraryOrgId??props.workspace.org.id}:${listing.id}`}/>:<p>Add a property and save its photos first, then choose it here.</p>}
 </section>;
}

function VideoSession({services,workspace,listing,active=true,onChanged,readOnly}:Props&{listing:Listing}){
 const scope=useMemo<VideoScope>(()=>({actor:workspace.user.id,org:listing.orgId,library:workspace.libraryOrgId??workspace.org.id,listing:listing.id,identityVersion:services.getSnapshot().identityVersion}),[services,workspace.user.id,workspace.org.id,workspace.libraryOrgId,listing.id,listing.orgId]);
 const control=useRef(new AbortController()),mounted=useRef(true),flight=useRef(false);
 const [sources,setSources]=useState<VideoSource[]>([]),[selection,setSelection]=useState<string[]>([]),[jobs,setJobs]=useState<VideoJob[]>([]),[job,setJob]=useState<VideoJob|null>(null),[journal,setJournal]=useState<VideoJournal|null>(null);
 const [purpose,setPurpose]=useState<VideoPurpose>("listing"),[voice,setVoice]=useState<"off"|"own"|"ai">("off"),[script,setScript]=useState(""),[voiceID,setVoiceID]=useState(""),[voices,setVoices]=useState<{id:string;name:string}[]>([]),[ownFile,setOwnFile]=useState<File|null>(null),[music,setMusic]=useState("");
 const [camera,setCamera]=useState("automatic"),[transition,setTransition]=useState<VideoPresentation['transition']>("cut"),[caption,setCaption]=useState<VideoPresentation['shot_caption_style']>("off"),[labels,setLabels]=useState<Record<string,string>>({}),[spoken,setSpoken]=useState(false),[titleCard,setTitleCard]=useState(false);
 // A server-confirmed closure (capacity refusal or C2 discard) unlocks a new recipe; the saved one is archived.
 const [framingReviewed,setFramingReviewed]=useState(false),[closed,setClosed]=useState<VideoClosure|null>(null),[recordingChanged,setRecordingChanged]=useState(false);
 const [consent,setConsent]=useState(false),[busy,setBusy]=useState(""),[notice,setNotice]=useState(""),[error,setError]=useState(""),[loaded,setLoaded]=useState(false),[reviewed,setReviewed]=useState(false),[share,setShare]=useState("");
 const writable=!readOnly&&canEditListing(workspace,listing);
 const current=useCallback(()=>{if(!mounted.current)throw Error("This video workspace was closed.");assertVideoScope(services,scope,control.current.signal);},[services,scope]);
 const api=useCallback(async(path:string,options:Parameters<StudioServices['api']>[1]={orgId:scope.library})=>{current();const signal=control.current.signal;const value=await services.api(`/functions/v1/${path}`,{...options,orgId:scope.library,signal});assertVideoScope(services,scope,signal);current();return value;},[services,scope,current]);
 const refresh=useCallback(async()=>{
  const found:VideoJob[]=[];let offset:number|null=0;
  while(offset!==null){const raw=await api(`property-video-jobs?listing_id=${scope.listing}&expected_org_id=${scope.library}&offset=${offset}`) as {jobs?:unknown[];next_offset?:unknown};
   if(!Array.isArray(raw.jobs)||raw.jobs.length>20||found.length+raw.jobs.length>1000)throw Error("The video list is incomplete. Refresh this property.");
   const page=raw.jobs.map(value=>decodeJob(value,scope));if(page.some(item=>found.some(prior=>prior.job_id===item.job_id)))throw Error("The video list changed. Refresh this property.");found.push(...page);
   if(raw.next_offset!==null&&(!Number.isSafeInteger(raw.next_offset)||raw.next_offset!==(offset as number)+20))throw Error("The video list pagination is incomplete.");offset=raw.next_offset as number|null;
  }
  current();setJobs(found);return found;
 },[api,scope,current]);
 const loadSources=useCallback(async()=>{
  const all:VideoSource[]=[];let offset:number|null=0,total:number|undefined;
  while(offset!==null){const raw=await api(`property-video-jobs/sources?listing_id=${scope.listing}&expected_org_id=${scope.library}&offset=${offset}`) as {selected_count:number;next_offset:number|null};
   if(total!==undefined&&raw.selected_count!==total)throw Error("Your gallery selection changed while loading. Refresh the property.");total=raw.selected_count;
   const page=decodeSources(raw,scope,offset);if(page.some(item=>all.some(prior=>prior.photo_id===item.photo_id)))throw Error("The saved gallery contains duplicate photo selections.");all.push(...page);offset=raw.next_offset;
  }
  return all;
 },[api,scope]);
 useEffect(()=>{
  const controller=new AbortController();control.current=controller;mounted.current=true;
  void(async()=>{try{
   const saved=readVideoJournal(localStorage,scope);setJournal(saved);
   if(saved){setFramingReviewed(saved.preparation?.framingReviewed===true);setPurpose(saved.input.purpose);setMusic(saved.input.music?.track_id??"");setTransition(saved.input.presentation.transition);setCaption(saved.input.presentation.shot_caption_style);setSpoken(saved.input.presentation.spoken_captions);setTitleCard(!!saved.input.presentation.title_card);if(saved.preparation){setVoice(saved.preparation.voice);setVoiceID(saved.preparation.voiceID);setScript(saved.preparation.script);setCamera(saved.preparation.camera);}}
   const [photos,existing]=await Promise.all([loadSources(),refresh()]);
   current();setSources(photos);setSelection(saved?saved.input.sources.map(item=>item.photo_id):[]);
   if(saved){const operation=await inspectVideoOperation(services,scope,saved,controller.signal);const recovered=operation.job;current();if(recovered){setJob(recovered);const next={...saved,job_id:recovered.job_id};saveVideoJournal(localStorage,scope,next);setJournal(next);}else if(videoClosure(operation))closeSaved(saved,videoClosure(operation)!);
   else setNotice("Your saved request was not found on the server. Resume that same request after checking consent, or discard it to change photos or options.");}
   else {const pub=localStorage.getItem(`${videoScopeKey(scope)}:publication`);let target:string|undefined;try{target=pub?JSON.parse(pub).job_id:undefined;}catch{/* invalid publication is refused again before any mutation */}setJob(existing.find(item=>item.job_id===target)??existing.find(item=>!["ready","failed","cancelled","needs_reconciliation"].includes(item.state))??null);}
   setLoaded(true);
  }catch(value){if(mounted.current&&!controller.signal.aborted)setError(value instanceof Error?value.message:"Saved property videos are unavailable.");}})();
  return()=>{mounted.current=false;controller.abort();};
 },[api,refresh,loadSources,scope,current,services]);
 useEffect(()=>{
  if(!active||!job||["ready","failed","cancelled","needs_reconciliation"].includes(job.state))return;
  // A reply that lands after the agent opened another saved video must not replace it.
  let running=false,closed=false;
  const tick=async()=>{if(closed||running||document.hidden)return;running=true;try{const updated=decodeJob(await api(`property-video-jobs/${job.job_id}`),scope,job.operation_id);if(closed)return;setJob(current=>current?.job_id===updated.job_id?updated:current);if(updated.state==="ready"){setNotice("Your finished video is ready. Review it before downloading or selecting it for the website.");onChanged();}}catch(value){if(mounted.current&&!closed)setError(value instanceof Error?value.message:"Video status is unavailable. Your saved server job is retained.");}finally{running=false;}};
  const timer=window.setInterval(()=>void tick(),15_000);const visible=()=>{if(!document.hidden)void tick();};document.addEventListener("visibilitychange",visible);
  return()=>{closed=true;window.clearInterval(timer);document.removeEventListener("visibilitychange",visible);};
 },[active,job?.job_id,job?.state,api,scope,onChanged]);
 useEffect(()=>{
  if(voice!=="ai"||voices.length)return;
  void api("ai-voice/voices").then(raw=>{const value=raw as {voices?:unknown[]};if(!Array.isArray(value.voices))throw Error("Voice choices are unavailable.");const rows=value.voices.slice(0,100).flatMap(value=>{const v=value as {voice_id?:unknown;name?:unknown};return typeof v.voice_id==="string"&&typeof v.name==="string"?[{id:v.voice_id,name:v.name}]:[];});setVoices(rows);setVoiceID(rows.find(v=>/willow/i.test(v.name))?.id??rows[0]?.id??"");}).catch(value=>{if(mounted.current)setError(value instanceof Error?value.message:"Voice choices are unavailable.");});
 },[voice,voices.length,api]);
 async function action(label:string,task:()=>Promise<void>){if(flight.current)return;flight.current=true;setBusy(label);setError("");try{await task();}catch(value){if(mounted.current&&!control.current.signal.aborted)setError(value instanceof Error?value.message:"That saved video action could not be confirmed.");}finally{flight.current=false;if(mounted.current)setBusy("");}}
 function updateJournal(next:VideoJournal){saveVideoJournal(localStorage,scope,next);setJournal(next);}
 // Only after the server confirms a closure: archive the saved recipe and unlock a new one.
 function closeSaved(saved:VideoJournal,reason:VideoClosure){
  if(reason==="abandoned"){retainAbandonedVideo(localStorage,scope,saved);setFramingReviewed(false);setNotice(DISCARDED_NOTICE);}
  else{retainRejectedVideo(localStorage,scope,saved);setNotice(REFUSED_NOTICE);}
  setClosed(reason);
 }
 // C2: the server resolves the exact saved operation first. A lost reply leaves this request pending; retrying is safe.
 async function discard(){
  if(!journal||journal.job_id||closed||!writable)return;
  const outcome=await abandonVideoOperation(services,scope,journal,control.current.signal);current();
  if(outcome.job){updateJournal({...journal,job_id:outcome.job.job_id});setJob(outcome.job);setReviewed(false);setShare("");setNotice("The server had already accepted this request, so its video was kept. Cancel it below if you don't want it.");void refresh().catch(()=>{/* The accepted job is retained; manual refresh reports any outage. */});return;}
  const closure=videoClosure(outcome);if(closure)closeSaved(journal,closure);
 }
 async function narration(operation:string,frozen:VideoPreparation):Promise<{result:string|null;asset:string|null;words:VideoInput['narration_words']}>{
  if(frozen.voice==="off")return{result:null,asset:null,words:[]};
  if(frozen.voice==="ai"){
   if(!frozen.voiceID||!frozen.script.trim()||frozen.script.length>1000)throw Error("Choose a voice and a reviewed script of up to 1,000 characters.");
   setBusy("Preparing your voiceover…");
   const raw=await api("studio/voice",{orgId:scope.library,method:"POST",idempotencyKey:`video-voice:${operation}`,timeoutMs:360_000,body:{listing_id:scope.listing,text:frozen.script.trim(),voice_id:frozen.voiceID,label:"Property video narration"}}) as {result?:unknown};
   const result=decodeResult(raw.result,{actor:scope.actor,org:scope.org,listing:scope.listing});
   if(result.kind!=="voice"||result.state!=="completed")throw Error("The voiceover is not complete yet. Its saved request is preserved.");
   return{result:result.id,asset:null,words:result.words};
  }
  if(!ownFile||ownFile.size>20*1024*1024||!ownFile.size)throw Error("Choose your M4A or MP3 voice recording under 20 MB.");
  const mime=/\.m4a$/i.test(ownFile.name)?"audio/mp4":/\.mp3$/i.test(ownFile.name)?"audio/mpeg":null;
  if(!mime)throw Error("Export your recording as M4A or MP3 before adding it.");
  setBusy("Saving your voice recording…");
  const bytes=await ownFile.arrayBuffer();current();const sha=[...new Uint8Array(await crypto.subtle.digest("SHA-256",bytes))].map(value=>value.toString(16).padStart(2,"0")).join("");
  const prepared=await api("property-video-jobs/audio/prepare",{orgId:scope.library,method:"POST",body:{operation_id:operation,listing_id:scope.listing,expected_org_id:scope.library,bytes:ownFile.size,sha256:sha,mime}}) as {narration_asset_id?:string;listing_id?:string;selected_library_org_id?:string;sha256?:string;ready?:boolean};
  if(!prepared.narration_asset_id||prepared.listing_id!==scope.listing||prepared.selected_library_org_id!==scope.library||prepared.sha256!==sha)throw Error("Your recording was not saved for this property.");
  if(!prepared.ready){await api(`property-video-jobs/audio/${prepared.narration_asset_id}/content`,{orgId:scope.library,method:"PUT",binary:new Blob([bytes],{type:mime}),timeoutMs:120_000});}
  const confirmed=await api(`property-video-jobs/audio/${prepared.narration_asset_id}/complete`,{orgId:scope.library,method:"POST",body:{}}) as typeof prepared;
  if(confirmed.ready!==true||confirmed.narration_asset_id!==prepared.narration_asset_id||confirmed.sha256!==sha||confirmed.listing_id!==scope.listing||confirmed.selected_library_org_id!==scope.library)throw Error("Your recording upload was not confirmed. Its reserved identity is preserved.");
  return{result:null,asset:confirmed.narration_asset_id,words:[]};
 }
 async function start(){
  if(!writable||!consent)throw Error("Confirm AI processing of your selected property photos first.");
  let next=journal&&!journal.job_id&&!closed?journal:null;
  if(next&&next.input.sources.some(old=>!sources.some(saved=>(saved.eligible||saved.needs_preparation)&&saved.photo_id===old.photo_id&&(saved.photo_asset_id===old.photo_asset_id||next?.preparation?.photosComplete===false&&saved.preparation?.source_asset_id===old.photo_asset_id)&&saved.photo_version_id===old.photo_version_id&&saved.photo_provenance_id===old.photo_provenance_id)))throw Error("The saved request uses earlier photo versions. Recover its server job, or discard the request to use your new versions. New versions never replace saved sources automatically.");
  if(!next){
   const operation=crypto.randomUUID();const rows=selection.map(id=>sources.find(source=>source.photo_id===id));
   if(!rows.length||rows.length>100||rows.some(row=>!row||!row.photo_asset_id||!row.eligible&&!row.needs_preparation))throw Error('Choose 1–100 saved property photos.');
   const chosen=selectedSources(rows.map(row=>({...row!,eligible:true})),selection);
   if(voice==="ai"&&(!voiceID||!script.trim()))throw Error("Choose an AI voice and reviewed narration first.");
   const priorVoice=closed&&journal?.preparation?.voiceComplete&&journal.preparation.voice===voice&&journal.preparation.voiceID===voiceID&&journal.preparation.script===script&&!recordingChanged?journal.input:null;
   if(voice==="own"&&!ownFile&&!priorVoice?.narration_asset_id)throw Error("Choose your M4A or MP3 recording first.");
   const presentation:VideoPresentation={transition,shot_caption_style:caption,spoken_captions:voice!=="off"&&spoken,title_card:purpose==="social"&&titleCard?{title:listing.address||"Property tour",subtitle:listing.tagline||"",watermark:"Made with Rendprop"}:null,shot_labels:chosen.map(s=>caption!=="off"?labels[s.photo_id]?.trim()||null:null)};
   const input:VideoInput={operation_id:operation,listing_id:scope.listing,expected_org_id:scope.library,purpose,aspect:purpose==="listing"?"16:9":"9:16",sources:chosen,narration_result_id:priorVoice?.narration_result_id??null,narration_asset_id:priorVoice?.narration_asset_id??null,narration_words:priorVoice?.narration_words??[],music:MUSIC.find(item=>item.track_id===music)??null,presentation,allow_original_photo_fallback:false};
   next={schema:1,actor:scope.actor,org:scope.org,library:scope.library,listing:scope.listing,input,preparation:{photosComplete:false,framingReviewed:false,planned:false,voiceComplete:!!priorVoice,automatic:false,camera,voice,voiceID,script}};setClosed(null);setRecordingChanged(false);updateJournal(next); // before any paid planner/voice request
  }
  let frameSources=next.input.sources.map(old=>sources.find(saved=>saved.photo_id===old.photo_id&&saved.photo_version_id===old.photo_version_id)!);
  if(next.preparation?.photosComplete===false){
   setBusy('Preparing selected photos for video…');
   const originals=next.input.sources.map(old=>sources.find(saved=>saved.photo_id===old.photo_id&&saved.photo_version_id===old.photo_version_id&&saved.photo_provenance_id===old.photo_provenance_id)!);
   if(originals.some(source=>!source))throw Error('The selected gallery version changed before preparation.');
   const prepared=await prepareVideoSources(services,scope,originals,localStorage,control.current.signal,(complete,total)=>{if(flight.current&&mounted.current)setBusy(`Preparing selected photos for video… ${complete}/${total}. Originals stay unchanged.`);});current();
   frameSources=prepared;
   setSources(old=>old.map(source=>prepared.find(item=>item.photo_id===source.photo_id)??source));
   next={...next,input:{...next.input,sources:selectedSources(prepared,next.input.sources.map(source=>source.photo_id))},preparation:{...next.preparation,photosComplete:true}};updateJournal(next);
  }
  const framing=framingSummary(frameSources,next.input.purpose);
  if(framing.unknown){setNotice('Your photo framing is not verified yet. Refresh the saved photos before creating this video.');return;}
  if(framing.majorCrop&&!next.preparation?.framingReviewed&&!framingReviewed){setNotice('Review the final frames below, then keep this framing to create the video. No AI video has started.');return;}
  if(next.preparation&&framingReviewed&&!next.preparation.framingReviewed){next={...next,preparation:{...next.preparation,framingReviewed:true}};updateJournal(next);}
  if(next.preparation&&!next.preparation.planned){
   const frozen=next.preparation;let planned=next.input.sources;setBusy("Choosing movement for your photos…");
   if(frozen.camera==="automatic"){try{planned=await planVideoSources(services,scope,planned,next.input.operation_id,false,control.current.signal);}catch{current();setNotice("Automatic planning is unavailable. This video keeps your selected order with gentle push-in movement.");}}
   else planned=planned.map(source=>({...source,motion:frozen.camera as FrozenMotion}));
   const labelsByID=new Map(next.input.sources.map((source,index)=>[source.photo_id,next!.input.presentation.shot_labels[index]??null]));
   next={...next,input:{...next.input,sources:planned,presentation:{...next.input.presentation,shot_labels:planned.map(source=>labelsByID.get(source.photo_id)??null)}},preparation:{...frozen,automatic:false,planned:true}};updateJournal(next);
  }
  if(next.preparation&&!next.preparation.voiceComplete){
   const spokenVoice=await narration(next.input.operation_id,next.preparation);current();
   next={...next,input:{...next.input,narration_result_id:spokenVoice.result,narration_asset_id:spokenVoice.asset,narration_words:spokenVoice.words},preparation:{...next.preparation,voiceComplete:true}};updateJournal(next);
  }
  setBusy("Starting your saved video…");let accepted:VideoJob;
  try{accepted=await enqueueVideo(services,scope,next,localStorage,control.current.signal);}
  catch(value){
   // 402 capacity refusal, or 409 when this request was discarded (C2): resolve the exact operation before anything else.
   if(value instanceof StudioError&&(value.status===402||value.status===409)){
    const operation=await inspectVideoOperation(services,scope,next,control.current.signal);current();
    if(operation.job)accepted=operation.job;
    else if(videoClosure(operation)){const closure=videoClosure(operation)!;closeSaved(next,closure);if(closure==="capacity_refused")setError(value.message);return;}
    else throw value;
   }else throw value;
  }
  current();
  updateJournal({...next,job_id:accepted.job_id});setJob(accepted);setReviewed(false);setShare("");setNotice("Your video is creating on the server. You can leave Studio or lock your phone; open this property to check its progress.");void refresh().catch(()=>{/* The accepted job is retained; manual refresh reports any outage. */});
 }
 async function recover(){if(!journal)return;const operation=await inspectVideoOperation(services,scope,journal,control.current.signal);current();if(operation.job){updateJournal({...journal,job_id:operation.job.job_id});setJob(operation.job);setClosed(null);setNotice("Recovered the same saved server job. No new video was started.");}else if(videoClosure(operation))closeSaved(journal,videoClosure(operation)!);else setNotice("No job was found for that saved operation. Resume the same request after confirming consent, or discard it to change photos or options.");}
 async function cancel(){if(!job)return;const updated=decodeJob(await api(`property-video-jobs/${job.job_id}/cancel`,{orgId:scope.library,method:"POST",body:{}}),scope,job.operation_id);setJob(updated);if(updated.state!=="cancelled")throw Error("Cancellation is not confirmed yet. Refresh this saved job before retrying.");setNotice("The video is cancelled. Already accepted provider work remains accounted for.");void refresh().catch(()=>{/* The accepted job is retained; manual refresh reports any outage. */});}
 async function publish(){if(!job?.result||!reviewed||!writable)throw Error("Review the full video and property details before selecting it for the website.");
  const key=`${videoScopeKey(scope)}:publication`;const saved=localStorage.getItem(key);let prior:{id:string;job_id:string;asset_id:string}|null=null;
  if(saved){try{const value=JSON.parse(saved);if(![value.id,value.job_id,value.asset_id].every((id:unknown)=>typeof id==="string"&&/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(id)))throw Error();prior=value;}catch{throw Error("The saved publication request is unreadable. Keep the server's current website selection and contact support.");}}
  const publication=prior?.job_id===job.job_id&&prior.asset_id===job.result.asset_id?prior:{id:crypto.randomUUID(),job_id:job.job_id,asset_id:job.result.asset_id};
  localStorage.setItem(key,JSON.stringify(publication));const url=await publishVideo(services,scope,job,publication.id,control.current.signal);current();setShare(url);setNotice("This reviewed video is selected for your property website.");onChanged();
 }
 const working=job!==null&&!["ready","failed","cancelled","needs_reconciliation"].includes(job.state);
 const pending=journal!==null&&!journal.job_id&&!closed;
 const chosenFrames=sources.filter(source=>selection.includes(source.photo_id));
 const framing=framingSummary(chosenFrames,purpose);
 const reviewFraming=!working&&framing.majorCrop>0;
 return <div className="video-simple-session">
  {error&&<p className="video-message error" role="alert">{error}</p>}{notice&&<p className="video-message" role="status">{notice}</p>}
  {busy&&<p role="status">{busy}</p>}
  <section><h3>1. Choose your photos</h3><p>Up to 100 saved photos, including your chosen edits.</p><details><summary>Photo tips</summary><p>Use landscape photos for the property website, portrait for social. Capture at 1×; use 0.5× only for tight rooms, keep the phone level, and avoid stretched edges. Your original files stay unchanged.</p></details>
   <div className="video-photo-actions"><button disabled={!loaded||!!busy||working||pending} onClick={()=>{setSelection(sources.filter(s=>s.eligible||s.needs_preparation).slice(0,100).map(s=>s.photo_id));setFramingReviewed(false);}}>Select up to 100</button><button disabled={!!busy||working||pending} onClick={()=>{setSelection([]);setFramingReviewed(false);}}>Clear selection</button><span>{selection.length} selected · about {selection.length*5} seconds</span></div>
   {!loaded?<p role="status">Loading saved photos and videos…</p>:sources.length===0?<p>Choose and save your gallery photos in the property first. An empty saved gallery is kept empty.</p>:<div className="video-photo-grid">{sources.map((source,index)=>{const order=selection.indexOf(source.photo_id);return <label key={source.photo_id} className={order>=0?"selected":""}><input type="checkbox" aria-label={`Choose photo ${index+1}`} checked={order>=0} disabled={!source.eligible&&!source.needs_preparation||!!busy||working||pending||!writable||order<0&&selection.length>=100} onChange={event=>{setSelection(old=>event.target.checked?[...old,source.photo_id]:old.filter(id=>id!==source.photo_id));setFramingReviewed(false);}}/>{source.preview_url?<img style={{aspectRatio:purpose==="listing"?"16/9":"9/16",objectFit:"cover"}} src={source.preview_url} alt={`Saved property photo ${index+1}`} loading="lazy" referrerPolicy="no-referrer"/>:<div className="video-photo-unavailable">Preview unavailable</div>}<span>{order>=0?`${order+1}. `:""}Photo {index+1}{photoFrame(source,purpose).orientation!=="unknown"?` · ${photoFrame(source,purpose).orientation}`:""}</span>{!source.eligible&&!source.needs_preparation&&<small>{source.reason||"This exact saved photo needs a prepared JPEG before video creation."}</small>}</label>;})}</div>}
  </section>
  <fieldset disabled={!!busy||!writable||working||pending} className="video-options"><legend>2. Choose the format</legend><div className="video-purpose"><label><input type="radio" name="video-purpose" checked={purpose==="listing"} onChange={()=>{setPurpose("listing");setFramingReviewed(false);}}/>Listing video<small>Landscape · 16:9 · property website</small></label><label><input type="radio" name="video-purpose" checked={purpose==="social"} onChange={()=>{setPurpose("social");setFramingReviewed(false);}}/>Social media<small>Portrait · 9:16 · Instagram &amp; social</small></label></div></fieldset>
  {reviewFraming&&<section className="video-framing" aria-label="Review final framing"><h3>Review final framing</h3><p>{framing.mixed?'Your selection mixes portrait and landscape photos. ':''}{framing.majorCrop} {framing.majorCrop===1?'photo trims':'photos trim'} the edges to fill {purpose==='listing'?'landscape':'portrait'}. The previews above show the center crop.</p><label><input type="checkbox" checked={framingReviewed} onChange={event=>setFramingReviewed(event.target.checked)} disabled={!!busy}/>Keep this framing</label></section>}
  <details><summary>Voice and music (optional)</summary><fieldset disabled={!!busy||working||pending||!writable} className="video-options"><legend>Sound</legend><label>Voice<select aria-label="Voice" value={voice} onChange={event=>{setVoice(event.target.value as typeof voice);setSpoken(false);}}><option value="off">Off — no narration</option><option value="own">My voice</option><option value="ai">AI voice</option></select></label>
   {voice==="own"&&<label>Your M4A or MP3 recording<input aria-label="Your M4A or MP3 recording" type="file" accept=".m4a,.mp3,audio/mp4,audio/mpeg" onChange={event=>{setOwnFile(event.target.files?.[0]??null);setRecordingChanged(true);}}/><small>Your saved recording is used as-is, without voice cloning.</small></label>}
   {voice==="ai"&&<><label>AI voice<select aria-label="AI voice" value={voiceID} onChange={event=>setVoiceID(event.target.value)}><option value="">Choose a voice</option>{voices.map(v=><option key={v.id} value={v.id}>{v.name}</option>)}</select></label><label>Reviewed narration<textarea value={script} onChange={event=>setScript(event.target.value)} maxLength={1000} rows={4} placeholder="Describe the property using accurate details. This text will be spoken."/></label><small>Voiceover is saved before the background video starts.</small></>}
   <label>Music<select aria-label="Music" value={music} onChange={event=>setMusic(event.target.value)}><option value="">Off</option>{MUSIC.map(item=><option key={item.track_id} value={item.track_id}>{item.track_id[0]!.toUpperCase()+item.track_id.slice(1)}</option>)}</select></label><small>Optional CC0 instrumental music. It stays quiet under narration.</small>
  </fieldset></details>
  <details className="video-advanced"><summary>Advanced options</summary><fieldset disabled={!!busy||working||pending||!writable} className="video-options"><label>Camera movement<select value={camera} onChange={event=>setCamera(event.target.value)}><option value="automatic">Automatic — choose per photo</option><option value="fly_through">Fly through</option><option value="push_in">Push in</option><option value="side_glide">Side glide</option><option value="pull_back">Pull back</option></select></label><label>Between shots<select value={transition} onChange={event=>setTransition(event.target.value as typeof transition)}><option value="cut">Cut</option><option value="dissolve">Blend</option><option value="whip">Whip</option></select></label>
   <><label>Words on each photo<select value={caption} onChange={event=>setCaption(event.target.value as typeof caption)}><option value="off">Off</option><option value="lowerThird">Clean</option><option value="punchCard">Centred</option><option value="highlightBox">Highlight</option></select></label>{caption!=="off"&&selection.map((photo,index)=><label key={photo}>Photo {index+1} caption<input value={labels[photo]??""} maxLength={180} onChange={event=>setLabels(old=>({...old,[photo]:event.target.value}))}/></label>)}{purpose==="social"&&<label><input type="checkbox" checked={titleCard} onChange={event=>setTitleCard(event.target.checked)}/>Property title and small Rendprop mark</label>}</>
   {voice!=="off"&&<label><input type="checkbox" checked={spoken} onChange={event=>setSpoken(event.target.checked)} disabled={voice==="own"}/>Spoken captions{voice==="own"&&<small>Timed captions need a saved transcript; your uploaded recording remains unchanged.</small>}</label>}
  </fieldset></details>
  <label className="video-consent"><input type="checkbox" checked={consent} onChange={event=>setConsent(event.target.checked)} disabled={!!busy||!writable}/>I allow AI processing of these selected property photos. I’ll review the result for property accuracy.</label>
  <div className="video-photo-actions"><button className="primary" disabled={!loaded||!!busy||!writable||working||!consent||(!pending&&selection.length===0)||reviewFraming&&!framingReviewed} onClick={()=>void action(pending?"Resuming saved request…":"Preparing your video…",start)}>{pending?"Resume same saved request":working?"Video is creating…":"Create video"}</button>{pending&&<button disabled={!!busy} onClick={()=>void action("Checking saved operation…",recover)}>Recover saved job</button>}{pending&&<button disabled={!!busy||!writable} onClick={()=>{if(window.confirm(DISCARD_CONFIRM))void action("Discarding saved request…",discard);}}>Discard saved request</button>}<button disabled={!!busy} onClick={()=>void action("Refreshing videos…",async()=>{await refresh();if(job)setJob(decodeJob(await api(`property-video-jobs/${job.job_id}`),scope,job.operation_id));})}>Refresh videos</button></div>
  {pending&&journal.preparation?.voice==="own"&&!journal.preparation.voiceComplete&&<label>Choose the same original recording to resume<input type="file" accept=".m4a,.mp3,audio/mp4,audio/mpeg" disabled={!!busy} onChange={event=>{setOwnFile(event.target.files?.[0]??null);setRecordingChanged(true);}}/></label>}
  {job&&<section className="video-job" aria-label="Current property video"><h3>{job.state==="ready"?"Your finished video":"Saved video progress"}</h3><p>{job.state.replaceAll("_"," ")} · {job.completed_sources}/{job.source_count} photos complete</p>{job.message&&<p>{job.message}</p>}{working&&<><p>This is a saved server job. You can close Studio while it works.</p><button disabled={!!busy||!writable} onClick={()=>void action("Cancelling saved video…",cancel)}>Cancel video</button></>}
   {job.resume_available===true&&<button disabled={!!busy||!writable||!consent} onClick={()=>void action("Resuming saved video…",async()=>{const resumed=await resumeVideo(services,scope,job,control.current.signal);current();setJob(resumed);setNotice("Resumed the same saved video. Completed shots are retained.");})}>Resume saved video</button>}
   {job.result&&<><video key={`${job.job_id}:${job.result.download_url}`} controls playsInline preload="metadata" src={job.result.download_url}/><p>{job.result.width}×{job.result.height} · {Math.round(job.result.duration_s)}s{job.result.original_photo_count>0?` · ${job.result.original_photo_count} shots use the saved photo`:""}</p><small>AI motion can introduce visual errors. Review the full video and selected photo versions before sharing.</small><div className="video-photo-actions"><a href={job.result.download_url} download rel="noreferrer">Download finished video</a>{job.result.branding_policy==="unbranded"&&<><label><input type="checkbox" checked={reviewed} onChange={event=>setReviewed(event.target.checked)}/>I reviewed the video and property details</label><button disabled={!reviewed||!!busy||!writable} onClick={()=>void action("Selecting website video…",publish)}>Use on property website</button></>}</div>{share&&<a href={share} target="_blank" rel="noreferrer">Open property website</a>}</>}
  </section>}
  {jobs.length>0&&<details><summary>Saved videos for this property ({jobs.length})</summary><ul className="video-job-list">{jobs.map(item=><li key={item.job_id}><span>{item.state.replaceAll("_"," ")} · {item.source_count} photos</span><button disabled={!!busy} onClick={()=>void action("Opening saved video…",async()=>{setJob(decodeJob(await api(`property-video-jobs/${item.job_id}`),scope,item.operation_id));setReviewed(false);setShare("");})}>Open video</button></li>)}</ul></details>}
 </div>;
}
type FrozenMotion="fly_through"|"push_in"|"side_glide"|"pull_back";
