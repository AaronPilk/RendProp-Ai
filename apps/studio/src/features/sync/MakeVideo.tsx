import {useCallback,useEffect,useMemo,useRef,useState} from "react";
import type {Listing,Workspace} from "../../data/contracts";
import {belongsToLibrary,canEditListing} from "../../data/contracts";
import type {StudioServices} from "../../data/services";
import {decodeResult} from "../creative/model";
import {abandonVideoOperation,assertVideoScope,decodeJob,decodeSources,enqueueVideo,MUSIC,planVideoSources,publishVideo,readVideoJournal,inspectVideoOperation,retainAbandonedVideo,retainRejectedVideo,resumeVideo,saveVideoJournal,selectedSources,videoClosure,videoScopeKey,type VideoClosure,type VideoInput,type VideoJob,type VideoJournal,type VideoPurpose,type VideoScope,type VideoSource,type VideoPresentation,type VideoPreparation} from "./property-video";
import {appendVisibleSelection,filterByOrientation,framingSummary,orientationCounts,orientationLabel,orientationSummary,PHOTO_ORIENTATIONS,photoFrame,recordPreviewGeometry,withPreviewGeometry,type PhotoGeometry,type PhotoOrientationFilter} from "./video-framing";
import {prepareVideoSources} from "./source-preparation";
import {CONSENT_V2,PROCESSOR_DISCLOSURE,fetchProcessorAvailability,knownVideoPermission,permissionBeforePaidWork,permissionForSavedJob,sameVideoPermission,readVideoStops,reconcileVideoStop,saveVideoStop,type ProcessorAvailability,type VideoPermission} from "./processor-consent";
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
 const control=useRef(new AbortController()),mounted=useRef(true),flight=useRef(false),prospective=useRef<AbortController|null>(null),stopFlight=useRef<Promise<void>|null>(null),unsavedStops=useRef(new Set<string>());
 const [sources,setSources]=useState<VideoSource[]>([]),[selection,setSelection]=useState<string[]>([]),[jobs,setJobs]=useState<VideoJob[]>([]),[job,setJob]=useState<VideoJob|null>(null),[journal,setJournal]=useState<VideoJournal|null>(null);
 const [purpose,setPurpose]=useState<VideoPurpose>("listing"),[voice,setVoice]=useState<"off"|"own"|"ai">("off"),[script,setScript]=useState(""),[voiceID,setVoiceID]=useState(""),[voices,setVoices]=useState<{id:string;name:string}[]>([]),[ownFile,setOwnFile]=useState<File|null>(null),[music,setMusic]=useState("");
 const [camera,setCamera]=useState("automatic"),[transition,setTransition]=useState<VideoPresentation['transition']>("cut"),[caption,setCaption]=useState<VideoPresentation['shot_caption_style']>("off"),[labels,setLabels]=useState<Record<string,string>>({}),[spoken,setSpoken]=useState(false),[titleCard,setTitleCard]=useState(false);
 // A server-confirmed closure (capacity refusal or C2 discard) unlocks a new recipe; the saved one is archived.
 const [framingReviewed,setFramingReviewed]=useState(false),[closed,setClosed]=useState<VideoClosure|null>(null),[recordingChanged,setRecordingChanged]=useState(false);
 const [consent,setConsent]=useState(false),[busy,setBusy]=useState(""),[notice,setNotice]=useState(""),[error,setError]=useState(""),[loaded,setLoaded]=useState(false),[reviewed,setReviewed]=useState(false),[share,setShare]=useState("");
 const [stopPending,setStopPending]=useState(false);
 const [processor,setProcessor]=useState<ProcessorAvailability|null>(null),[processorError,setProcessorError]=useState(""),[allowedProcessor,setAllowedProcessor]=useState<VideoPermission|null>(null);
 const [orientationFilter,setOrientationFilter]=useState<PhotoOrientationFilter>('all');
 const [previewGeometry,setPreviewGeometry]=useState<Record<string,PhotoGeometry>>({});
 const previewKey=(source:VideoSource)=>JSON.stringify([source.photo_id,source.photo_asset_id,source.photo_version_id,source.sha256,source.preview_url]);
 const activePreviewKeys=useRef<Set<string>>(new Set());activePreviewKeys.current=new Set(sources.map(previewKey));
 const framedSources=sources.map(source=>withPreviewGeometry(source,previewGeometry[previewKey(source)]));
 const orientation=(source:VideoSource)=>photoFrame(source,purpose).orientation;
 const visibleSources=filterByOrientation(framedSources,orientationFilter,orientation);
 const counts=orientationCounts(framedSources.map(orientation));
 const sourceIndices=new Map(sources.map((source,index)=>[source.photo_id,index]));
 function observePreview(source:VideoSource,width:number,height:number){
  if(!mounted.current||control.current.signal.aborted)return;
  const key=previewKey(source);setPreviewGeometry(previous=>recordPreviewGeometry(previous,key,width,height,activePreviewKeys.current));
 }
 const writable=!readOnly&&canEditListing(workspace,listing);
 const current=useCallback(()=>{if(!mounted.current)throw Error("This video workspace was closed.");assertVideoScope(services,scope,control.current.signal);},[services,scope]);
 const api=useCallback(async(path:string,options:Parameters<StudioServices['api']>[1]={orgId:scope.library})=>{current();const signal=options.signal??control.current.signal;assertVideoScope(services,scope,signal);const value=await services.api(`/functions/v1/${path}`,{...options,orgId:scope.library,signal});assertVideoScope(services,scope,signal);current();return value;},[services,scope,current]);
 const loadProcessor=useCallback(async(signal=control.current.signal)=>{
  try{const value=await fetchProcessorAvailability(services,scope,signal);assertVideoScope(services,scope,signal);current();setProcessor(value);setProcessorError("");return value;}
  catch(value){assertVideoScope(services,scope,signal);current();setProcessor(null);setAllowedProcessor(null);setProcessorError(value instanceof Error?value.message:"The AI processor disclosure is unavailable. New paid video work is paused.");throw value;}
 },[services,scope,current]);
 const settleStops=useCallback(()=>{
  if(stopFlight.current)return stopFlight.current;
  const signal=control.current.signal;
  // Assign the joined promise before its work can finish. Every caller waits
  // for the same current operation read and confirmed abandon/cancel result.
  const run=Promise.resolve().then(async()=>{
   const stopCurrent=()=>{current();assertVideoScope(services,scope,signal);};
   try{stopCurrent();for(const operation of unsavedStops.current){saveVideoStop(localStorage,scope,operation);unsavedStops.current.delete(operation);}let intents=readVideoStops(localStorage,scope);setStopPending(intents.length>0);
    for(let count=0;intents.length&&count<1000;count++){
     const stopped=await reconcileVideoStop(services,scope,intents[0]!,localStorage,signal);stopCurrent();
     if(stopped){setJob(shown=>shown?.operation_id===stopped.operation_id?stopped:shown);setJobs(rows=>rows.map(row=>row.operation_id===stopped.operation_id?stopped:row));}
     intents=readVideoStops(localStorage,scope);
    }
    if(intents.length)throw Error("More saved video stop requests remain. Retry stopping before new paid work.");
    setStopPending(false);
   }catch(value){stopCurrent();setStopPending(true);throw value;}
  });
  const joined=run.finally(()=>{if(stopFlight.current===joined)stopFlight.current=null;});
  stopFlight.current=joined;return joined;
 },[services,scope,current]);
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
   let stopUnconfirmed=false;try{await settleStops();}catch(value){assertVideoScope(services,scope,controller.signal);current();stopUnconfirmed=true;setError(value instanceof Error?value.message:"Stopping saved video work is not confirmed.");}
   assertVideoScope(services,scope,controller.signal);current();
   const saved=readVideoJournal(localStorage,scope);setJournal(saved);if(!stopUnconfirmed&&saved&&!saved.job_id&&saved.permission?.token===CONSENT_V2)setAllowedProcessor(saved.permission);
   if(saved){setFramingReviewed(saved.preparation?.framingReviewed===true);setPurpose(saved.input.purpose);setMusic(saved.input.music?.track_id??"");setTransition(saved.input.presentation.transition);setCaption(saved.input.presentation.shot_caption_style);setSpoken(saved.input.presentation.spoken_captions);setTitleCard(!!saved.input.presentation.title_card);if(saved.preparation){setVoice(saved.preparation.voice);setVoiceID(saved.preparation.voiceID);setScript(saved.preparation.script);setCamera(saved.preparation.camera);}}
   const [photos,existing]=await Promise.all([loadSources(),refresh(),loadProcessor().catch(()=>null)]);
   current();setSources(photos);setSelection(saved?saved.input.sources.map(item=>item.photo_id):[]);
   if(saved){const operation=await inspectVideoOperation(services,scope,saved,controller.signal);const recovered=operation.job;current();if(recovered){setJob(recovered);setAllowedProcessor(null);const next={...saved,job_id:recovered.job_id};saveVideoJournal(localStorage,scope,next);setJournal(next);}else if(videoClosure(operation))closeSaved(saved,videoClosure(operation)!);
   else setNotice("Your saved request was not found on the server. Resume that same request after checking consent, or discard it to change photos or options.");}
   else {const pub=localStorage.getItem(`${videoScopeKey(scope)}:publication`);let target:string|undefined;try{target=pub?JSON.parse(pub).job_id:undefined;}catch{/* invalid publication is refused again before any mutation */}setJob(existing.find(item=>item.job_id===target)??existing.find(item=>!["ready","failed","cancelled","needs_reconciliation"].includes(item.state))??null);}
   setLoaded(true);
  }catch(value){if(mounted.current&&!controller.signal.aborted)setError(value instanceof Error?value.message:"Saved property videos are unavailable.");}})();
  return()=>{mounted.current=false;controller.abort();prospective.current?.abort();};
 },[api,refresh,loadSources,loadProcessor,settleStops,scope,current,services]);
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
  setClosed(reason);setAllowedProcessor(null);
 }
 // C2: the server resolves the exact saved operation first. A lost reply leaves this request pending; retrying is safe.
 async function discard(){
  if(!journal||journal.job_id||closed||!writable)return;
  const outcome=await abandonVideoOperation(services,scope,journal,control.current.signal);current();
  if(outcome.job){updateJournal({...journal,job_id:outcome.job.job_id});setJob(outcome.job);setReviewed(false);setShare("");setNotice("The server had already accepted this request, so its video was kept. Cancel it below if you don't want it.");void refresh().catch(()=>{/* The accepted job is retained; manual refresh reports any outage. */});return;}
  const closure=videoClosure(outcome);if(closure)closeSaved(journal,closure);
 }
 function withdrawProcessorPermission(){
  setAllowedProcessor(null);prospective.current?.abort(Error("Kie permission was withdrawn. No further paid video work was started; the saved request is retained."));
  const targets=new Set([...jobs,...(job?[job]:[])].filter(item=>item.consent_revision===CONSENT_V2&&!['ready','cancelled'].includes(item.state)).map(item=>item.operation_id));
  if(journal&&!journal.job_id&&!closed&&journal.permission?.token===CONSENT_V2)targets.add(journal.input.operation_id);
  if(!targets.size)return;
  try{for(const operation of targets)unsavedStops.current.add(operation);for(const operation of targets){saveVideoStop(localStorage,scope,operation);unsavedStops.current.delete(operation);}setStopPending(true);void settleStops().then(()=>{current();if(unsavedStops.current.size||readVideoStops(localStorage,scope).length)throw Error("Stopping saved video work is not confirmed. Retry the saved stop requests.");if(mounted.current)setNotice("Video work is stopped. Already accepted provider work may finish; saved videos and receipts stay available.");}).catch(value=>{if(mounted.current&&!control.current.signal.aborted)setError(value instanceof Error?value.message:"Stopping saved video work is not confirmed.");});}
  catch(value){setStopPending(true);setError(value instanceof Error?value.message:"The video stop request could not be saved. Retry stopping before new paid work.");}
 }
 async function narration(operation:string,frozen:VideoPreparation,signal:AbortSignal):Promise<{result:string|null;asset:string|null;words:VideoInput['narration_words']}>{
  if(frozen.voice==="off")return{result:null,asset:null,words:[]};
  if(frozen.voice==="ai"){
   if(!frozen.voiceID||!frozen.script.trim()||frozen.script.length>1000)throw Error("Choose a voice and a reviewed script of up to 1,000 characters.");
   setBusy("Preparing your voiceover…");
   const raw=await api("studio/voice",{orgId:scope.library,method:"POST",idempotencyKey:`video-voice:${operation}`,timeoutMs:360_000,signal,body:{listing_id:scope.listing,text:frozen.script.trim(),voice_id:frozen.voiceID,label:"Property video narration"}}) as {result?:unknown};
   const result=decodeResult(raw.result,{actor:scope.actor,org:scope.org,listing:scope.listing});
   if(result.kind!=="voice"||result.state!=="completed")throw Error("The voiceover is not complete yet. Its saved request is preserved.");
   return{result:result.id,asset:null,words:result.words};
  }
  if(!ownFile||ownFile.size>20*1024*1024||!ownFile.size)throw Error("Choose your M4A or MP3 voice recording under 20 MB.");
  const mime=/\.m4a$/i.test(ownFile.name)?"audio/mp4":/\.mp3$/i.test(ownFile.name)?"audio/mpeg":null;
  if(!mime)throw Error("Export your recording as M4A or MP3 before adding it.");
  setBusy("Saving your voice recording…");
  const bytes=await ownFile.arrayBuffer();current();assertVideoScope(services,scope,signal);const sha=[...new Uint8Array(await crypto.subtle.digest("SHA-256",bytes))].map(value=>value.toString(16).padStart(2,"0")).join("");
  const prepared=await api("property-video-jobs/audio/prepare",{orgId:scope.library,method:"POST",signal,body:{operation_id:operation,listing_id:scope.listing,expected_org_id:scope.library,bytes:ownFile.size,sha256:sha,mime}}) as {narration_asset_id?:string;listing_id?:string;selected_library_org_id?:string;sha256?:string;ready?:boolean};
  if(!prepared.narration_asset_id||prepared.listing_id!==scope.listing||prepared.selected_library_org_id!==scope.library||prepared.sha256!==sha)throw Error("Your recording was not saved for this property.");
  if(!prepared.ready){await api(`property-video-jobs/audio/${prepared.narration_asset_id}/content`,{orgId:scope.library,method:"PUT",binary:new Blob([bytes],{type:mime}),timeoutMs:120_000,signal});}
  const confirmed=await api(`property-video-jobs/audio/${prepared.narration_asset_id}/complete`,{orgId:scope.library,method:"POST",signal,body:{}}) as typeof prepared;
  if(confirmed.ready!==true||confirmed.narration_asset_id!==prepared.narration_asset_id||confirmed.sha256!==sha||confirmed.listing_id!==scope.listing||confirmed.selected_library_org_id!==scope.library)throw Error("Your recording upload was not confirmed. Its reserved identity is preserved.");
  return{result:null,asset:confirmed.narration_asset_id,words:[]};
 }
 async function start(){
  if(stopPending||readVideoStops(localStorage,scope).length)throw Error("Confirm the saved video stop requests before new paid work.");
  if(!writable||!consent)throw Error("Confirm AI processing of your selected property photos first.");
  const phase=new AbortController(),sessionSignal=control.current.signal;prospective.current=phase;
  const abortPhase=()=>phase.abort(sessionSignal.reason);sessionSignal.addEventListener("abort",abortPhase,{once:true});if(sessionSignal.aborted)abortPhase();
  const prospectiveCurrent=()=>{current();assertVideoScope(services,scope,phase.signal);};
  try{
  let next=journal&&!journal.job_id&&!closed?journal:null;
  if(next){
   // A pending/lost reply is read before any preparation, planning or voice.
   const outcome=await inspectVideoOperation(services,scope,next,control.current.signal);current();
   if(outcome.job){updateJournal({...next,job_id:outcome.job.job_id});setJob(outcome.job);setAllowedProcessor(null);setNotice("Recovered the same saved server job. No new paid work was started.");return;}
   const closure=videoClosure(outcome);if(closure){closeSaved(next,closure);return;}
  }
  const availability=await loadProcessor(phase.signal);prospectiveCurrent();
  const permission=permissionBeforePaidWork(availability,allowedProcessor,next??undefined);

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
   next={schema:1,actor:scope.actor,org:scope.org,library:scope.library,listing:scope.listing,permission,input,preparation:{photosComplete:false,framingReviewed:false,planned:false,voiceComplete:!!priorVoice,automatic:false,camera,voice,voiceID,script}};setClosed(null);setRecordingChanged(false);updateJournal(next); // before any paid planner/voice request
  }
  let frameSources=next.input.sources.map(old=>sources.find(saved=>saved.photo_id===old.photo_id&&saved.photo_version_id===old.photo_version_id)!);
  if(next.preparation?.photosComplete===false){
   setBusy('Preparing selected photos for video…');
   const originals=next.input.sources.map(old=>sources.find(saved=>saved.photo_id===old.photo_id&&saved.photo_version_id===old.photo_version_id&&saved.photo_provenance_id===old.photo_provenance_id)!);
   if(originals.some(source=>!source))throw Error('The selected gallery version changed before preparation.');
   const prepared=await prepareVideoSources(services,scope,originals,localStorage,phase.signal,(complete,total)=>{if(flight.current&&mounted.current)setBusy(`Preparing selected photos for video… ${complete}/${total}. Originals stay unchanged.`);});prospectiveCurrent();
   frameSources=prepared;
   setSources(old=>old.map(source=>prepared.find(item=>item.photo_id===source.photo_id)??source));
   next={...next,input:{...next.input,sources:selectedSources(prepared,next.input.sources.map(source=>source.photo_id))},preparation:{...next.preparation,photosComplete:true}};updateJournal(next);
  }
  const framing=framingSummary(frameSources.map(source=>withPreviewGeometry(source,previewGeometry[previewKey(source)])),next.input.purpose);
  if(framing.unknown){setNotice('Your selected photo previews are still loading or unavailable. No AI video has started. Reopen this property or choose another saved photo if a preview cannot load.');return;}
  if(framing.majorCrop&&!next.preparation?.framingReviewed&&!framingReviewed){setNotice('Review the final frames below, then keep this framing to create the video. No AI video has started.');return;}
  if(next.preparation&&framingReviewed&&!next.preparation.framingReviewed){next={...next,preparation:{...next.preparation,framingReviewed:true}};updateJournal(next);}
  if(next.preparation&&!next.preparation.planned){
   const frozen=next.preparation;let planned=next.input.sources;setBusy("Choosing movement for your photos…");
   if(frozen.camera==="automatic"){try{planned=await planVideoSources(services,scope,planned,next.input.operation_id,false,phase.signal);}catch{prospectiveCurrent();setNotice("Automatic planning is unavailable. This video keeps your selected order with gentle push-in movement.");}}
   else planned=planned.map(source=>({...source,motion:frozen.camera as FrozenMotion}));
   prospectiveCurrent();
   const labelsByID=new Map(next.input.sources.map((source,index)=>[source.photo_id,next!.input.presentation.shot_labels[index]??null]));
   next={...next,input:{...next.input,sources:planned,presentation:{...next.input.presentation,shot_labels:planned.map(source=>labelsByID.get(source.photo_id)??null)}},preparation:{...frozen,automatic:false,planned:true}};updateJournal(next);
  }
  if(next.preparation&&!next.preparation.voiceComplete){
   const spokenVoice=await narration(next.input.operation_id,next.preparation,phase.signal);prospectiveCurrent();
   next={...next,input:{...next.input,narration_result_id:spokenVoice.result,narration_asset_id:spokenVoice.asset,narration_words:spokenVoice.words},preparation:{...next.preparation,voiceComplete:true}};updateJournal(next);
  }
  prospectiveCurrent();setBusy("Starting your saved video…");let accepted:VideoJob;
  try{accepted=await enqueueVideo(services,scope,next,localStorage,phase.signal);}
  catch(value){
   // Resolve the same operation after a lost reply, including ordinary network
   // failures. A failed/not-found read never sends a second POST automatically.
   let operation;
   try{operation=await inspectVideoOperation(services,scope,next,control.current.signal);current();}catch{throw value;}
   if(operation.job)accepted=operation.job;
   else if(videoClosure(operation)){const closure=videoClosure(operation)!;closeSaved(next,closure);if(closure==="capacity_refused")setError(value instanceof Error?value.message:REFUSED_NOTICE);return;}
   else throw value;
  }
  current();
  updateJournal({...next,job_id:accepted.job_id});setAllowedProcessor(null);setJob(accepted);setReviewed(false);setShare("");setNotice("Your video is creating on the server. You can leave Studio or lock your phone; open this property to check its progress.");void refresh().catch(()=>{/* The accepted job is retained; manual refresh reports any outage. */});
 }finally{sessionSignal.removeEventListener("abort",abortPhase);if(prospective.current===phase)prospective.current=null;}
 }
 async function recover(){if(!journal)return;const operation=await inspectVideoOperation(services,scope,journal,control.current.signal);current();if(operation.job){updateJournal({...journal,job_id:operation.job.job_id});setAllowedProcessor(null);setJob(operation.job);setClosed(null);setNotice("Recovered the same saved server job. No new video was started.");}else if(videoClosure(operation))closeSaved(journal,videoClosure(operation)!);else setNotice("No job was found for that saved operation. Resume the same request after confirming consent, or discard it to change photos or options.");}
 async function cancel(){if(!job)return;const updated=decodeJob(await api(`property-video-jobs/${job.job_id}/cancel`,{orgId:scope.library,method:"POST",body:{}}),scope,job.operation_id);setJob(updated);if(updated.state!=="cancelled")throw Error("Cancellation is not confirmed yet. Refresh this saved job before retrying.");setNotice("The video is cancelled. Already accepted provider work remains accounted for.");void refresh().catch(()=>{/* The accepted job is retained; manual refresh reports any outage. */});}
 async function publish(){if(!job?.result||!reviewed||!writable)throw Error("Review the full video and property details before selecting it for the website.");
  const key=`${videoScopeKey(scope)}:publication`;const saved=localStorage.getItem(key);let prior:{id:string;job_id:string;asset_id:string}|null=null;
  if(saved){try{const value=JSON.parse(saved);if(![value.id,value.job_id,value.asset_id].every((id:unknown)=>typeof id==="string"&&/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(id)))throw Error();prior=value;}catch{throw Error("The saved publication request is unreadable. Keep the server's current website selection and contact support.");}}
  const publication=prior?.job_id===job.job_id&&prior.asset_id===job.result.asset_id?prior:{id:crypto.randomUUID(),job_id:job.job_id,asset_id:job.result.asset_id};
  localStorage.setItem(key,JSON.stringify(publication));const url=await publishVideo(services,scope,job,publication.id,control.current.signal);current();setShare(url);setNotice("This reviewed video is selected for your property website.");onChanged();
 }
 const working=job!==null&&!["ready","failed","cancelled","needs_reconciliation"].includes(job.state);
 const pending=journal!==null&&!journal.job_id&&!closed;
 const chosenFrames=framedSources.filter(source=>selection.includes(source.photo_id));
 const framing=framingSummary(chosenFrames,purpose);
 const reviewFraming=!working&&framing.majorCrop>0;
 const processorAllowed=processor?.kind==="legacy"||processor?.kind==="known"&&sameVideoPermission(allowedProcessor,knownVideoPermission(processor.contract));
 const resumePermission=job?permissionForSavedJob(job,processor?.kind==="legacy"):null;
 const resumeAllowed=!stopPending&&!!resumePermission&&(resumePermission.token!==CONSENT_V2||sameVideoPermission(allowedProcessor,resumePermission));
 return <div className="video-simple-session">
  {error&&<p className="video-message error" role="alert">{error}</p>}{notice&&<p className="video-message" role="status">{notice}</p>}
  {busy&&<p role="status">{busy}</p>}
  <section><h3>1. Choose your photos</h3><p>Up to 100 saved photos, including your chosen edits.</p><details><summary>Photo tips</summary><p>Use landscape photos for the property website and portrait for social. Use 0.5× whenever you need it to fit the whole room. Keep the phone level and avoid stretched edges. Your original files stay unchanged.</p></details>
   <div className="video-photo-actions"><button disabled={!loaded||!!busy||working||pending} onClick={()=>{setSelection(old=>appendVisibleSelection(old,visibleSources.filter(s=>s.eligible||s.needs_preparation).map(s=>s.photo_id)));setFramingReviewed(false);}}>{orientationFilter==='all'?'Select up to 100':'Select visible photos'}</button><button disabled={!!busy||working||pending} onClick={()=>{setSelection([]);setFramingReviewed(false);}}>Clear selection</button><span>{selection.length} selected · about {selection.length*5} seconds</span></div>
   {loaded&&sources.length>0&&<div className="video-photo-actions"><label>Photo orientation <select aria-label="Photo orientation" value={orientationFilter} onChange={event=>setOrientationFilter(event.target.value as PhotoOrientationFilter)}><option value="all">All photos ({sources.length})</option>{PHOTO_ORIENTATIONS.map(value=><option key={value} value={value}>{orientationLabel(value)} ({counts[value]})</option>)}</select></label><span>{orientationSummary(framedSources.map(orientation))}</span>{orientationFilter!=='all'&&<small>All {selection.length} selected photos keep their order, including photos hidden by this filter.</small>}{counts.unknown>0&&<small>Some photos haven’t loaded yet. {orientationFilter!=='all'&&visibleSources.length>0&&framing.unknown===0&&<button onClick={()=>setOrientationFilter('all')}>Show all photos</button>}</small>}</div>}
   {!loaded?<p role="status">Loading saved photos and videos…</p>:sources.length===0?<p>Choose and save your gallery photos in the property first. An empty saved gallery is kept empty.</p>:<div className="video-photo-grid">{visibleSources.map(source=>{const index=sourceIndices.get(source.photo_id)!;const order=selection.indexOf(source.photo_id);return <label key={source.photo_id} className={order>=0?"selected":""}><input type="checkbox" aria-label={`Choose photo ${index+1}`} checked={order>=0} disabled={!source.eligible&&!source.needs_preparation||!!busy||working||pending||!writable||order<0&&selection.length>=100} onChange={event=>{setSelection(old=>event.target.checked?[...old,source.photo_id]:old.filter(id=>id!==source.photo_id));setFramingReviewed(false);}}/>{source.preview_url?<img style={{aspectRatio:purpose==="listing"?"16/9":"9/16",objectFit:"contain"}} src={source.preview_url} alt={`Saved property photo ${index+1}`} loading={order>=0?"eager":"lazy"} referrerPolicy="no-referrer" onLoad={event=>{const image=event.currentTarget;if(image.currentSrc===source.preview_url)observePreview(source,image.naturalWidth,image.naturalHeight);}}/>:<div className="video-photo-unavailable">Preview unavailable</div>}<span>{order>=0?`${order+1}. `:""}Photo {index+1}{` · ${orientationLabel(orientation(source))}`}</span>{!source.eligible&&!source.needs_preparation&&<small>{source.reason||"This exact saved photo needs a prepared JPEG before video creation."}</small>}</label>;})}</div>}
   {loaded&&sources.length>0&&visibleSources.length===0&&<p className="video-message">No {orientationFilter} photos are visible yet. Your selection is kept. <button onClick={()=>setOrientationFilter('all')}>Show all photos</button></p>}
  </section>
  <fieldset disabled={!!busy||!writable||working||pending} className="video-options"><legend>2. Choose the format</legend><div className="video-purpose"><label><input type="radio" name="video-purpose" checked={purpose==="listing"} onChange={()=>{setPurpose("listing");setFramingReviewed(false);}}/>Listing video<small>Landscape · 16:9 · property website</small></label><label><input type="radio" name="video-purpose" checked={purpose==="social"} onChange={()=>{setPurpose("social");setFramingReviewed(false);}}/>Social media<small>Portrait · 9:16 · Instagram &amp; social</small></label></div></fieldset>
  {reviewFraming&&<section className="video-framing" aria-label="Review final framing"><h3>Review final framing</h3><p>{framing.mixed?'Your selection mixes portrait and landscape photos. ':''}{framing.majorCrop} {framing.majorCrop===1?'photo trims':'photos trim'} the edges to fill {purpose==='listing'?'landscape':'portrait'}. Full photos are shown above; the finished video may trim their edges.</p><label><input type="checkbox" checked={framingReviewed} onChange={event=>setFramingReviewed(event.target.checked)} disabled={!!busy||framing.unknown>0}/>Keep this framing</label></section>}
  <details><summary>Voice and music (optional)</summary><fieldset disabled={!!busy||working||pending||!writable} className="video-options"><legend>Sound</legend><label>Voice<select aria-label="Voice" value={voice} onChange={event=>{setVoice(event.target.value as typeof voice);setSpoken(false);}}><option value="off">Off — no narration</option><option value="own">My voice</option><option value="ai">AI voice</option></select></label>
   {voice==="own"&&<label>Your M4A or MP3 recording<input aria-label="Your M4A or MP3 recording" type="file" accept=".m4a,.mp3,audio/mp4,audio/mpeg" onChange={event=>{setOwnFile(event.target.files?.[0]??null);setRecordingChanged(true);}}/><small>Your saved recording is used as-is, without voice cloning.</small></label>}
   {voice==="ai"&&<><label>AI voice<select aria-label="AI voice" value={voiceID} onChange={event=>setVoiceID(event.target.value)}><option value="">Choose a voice</option>{voices.map(v=><option key={v.id} value={v.id}>{v.name}</option>)}</select></label><label>Reviewed narration<textarea value={script} onChange={event=>setScript(event.target.value)} maxLength={1000} rows={4} placeholder="Describe the property using accurate details. This text will be spoken."/></label><small>Voiceover is saved before the background video starts.</small></>}
   <label>Music<select aria-label="Music" value={music} onChange={event=>setMusic(event.target.value)}><option value="">Off</option>{MUSIC.map(item=><option key={item.track_id} value={item.track_id}>{item.track_id[0]!.toUpperCase()+item.track_id.slice(1)}</option>)}</select></label><small>Optional CC0 instrumental music. It stays quiet under narration.</small>
  </fieldset></details>
  <details className="video-advanced"><summary>Advanced options</summary><fieldset disabled={!!busy||working||pending||!writable} className="video-options"><label>Camera movement<select value={camera} onChange={event=>setCamera(event.target.value)}><option value="automatic">Automatic — choose per photo</option><option value="fly_through">Fly through</option><option value="push_in">Push in</option><option value="side_glide">Side glide</option><option value="pull_back">Pull back</option></select></label><label>Between shots<select value={transition} onChange={event=>setTransition(event.target.value as typeof transition)}><option value="cut">Cut</option><option value="dissolve">Blend</option><option value="whip">Whip</option></select></label>
   <><label>Words on each photo<select value={caption} onChange={event=>setCaption(event.target.value as typeof caption)}><option value="off">Off</option><option value="lowerThird">Clean</option><option value="punchCard">Centred</option><option value="highlightBox">Highlight</option></select></label>{caption!=="off"&&selection.map((photo,index)=><label key={photo}>Photo {index+1} caption<input value={labels[photo]??""} maxLength={180} onChange={event=>setLabels(old=>({...old,[photo]:event.target.value}))}/></label>)}{purpose==="social"&&<label><input type="checkbox" checked={titleCard} onChange={event=>setTitleCard(event.target.checked)}/>Property title and small Rendprop mark</label>}</>
   {voice!=="off"&&<label><input type="checkbox" checked={spoken} onChange={event=>setSpoken(event.target.checked)} disabled={voice==="own"}/>Spoken captions{voice==="own"&&<small>Timed captions need a saved transcript; your uploaded recording remains unchanged.</small>}</label>}
  </fieldset></details>
  <label className="video-consent"><input type="checkbox" checked={consent} onChange={event=>{setConsent(event.target.checked);if(!event.target.checked)withdrawProcessorPermission();}} disabled={!!busy||!writable}/>I allow AI processing of these selected property photos. I’ll review the result for property accuracy.</label>
  {processor?.kind==="known"&&<section className="video-message" aria-label="Kie permission"><h4>{PROCESSOR_DISCLOSURE.title}</h4><p>{PROCESSOR_DISCLOSURE.body}</p><div className="video-photo-actions"><button className="primary" disabled={!!busy||!writable||processorAllowed} onClick={()=>setAllowedProcessor(knownVideoPermission(processor.contract))}>{processorAllowed?"Allowed for this request":PROCESSOR_DISCLOSURE.allow_label}</button><button disabled={!writable} onClick={()=>{withdrawProcessorPermission();setNotice("Kie permission was not granted. New paid video work is paused; your saved videos stay available.");}}>{PROCESSOR_DISCLOSURE.decline_label}</button><a href={PROCESSOR_DISCLOSURE.privacy_url} target="_blank" rel="noreferrer">Privacy</a><a href={PROCESSOR_DISCLOSURE.provider_terms_url} target="_blank" rel="noreferrer">Kie terms</a></div></section>}
  {!processor&&<p className="video-message" role="status">{processorError||"Checking this video's AI processor disclosure…"} <button disabled={!!busy} onClick={()=>void action("Checking AI processors…",async()=>{await loadProcessor();})}>Retry processor disclosure</button></p>}
  {stopPending&&<p className="video-message" role="status">Stopping saved video work is not confirmed. New paid work is paused. <button disabled={!!stopFlight.current} onClick={()=>void action("Checking saved video stops…",settleStops)}>Retry stopping video work</button></p>}
  {framing.unknown>0&&<p role="status">Waiting for {framing.unknown} selected photo {framing.unknown===1?"preview":"previews"}. {orientationFilter!=='all'?<>Selected previews may be hidden by your filter. <button onClick={()=>setOrientationFilter('all')}>Show selected previews</button></>:<>If a preview cannot load, reopen this property or choose another saved photo.</>} Your selection stays saved.</p>}
  <div className="video-photo-actions"><button className="primary" disabled={!loaded||!!busy||!writable||working||!consent||stopPending||!processorAllowed||(!pending&&selection.length===0)||framing.unknown>0||reviewFraming&&!framingReviewed} onClick={()=>void action(pending?"Resuming saved request…":"Preparing your video…",start)}>{pending?"Resume same saved request":working?"Video is creating…":"Create video"}</button>{pending&&<button disabled={!!busy} onClick={()=>void action("Checking saved operation…",recover)}>Recover saved job</button>}{pending&&<button disabled={!!busy||!writable} onClick={()=>{if(window.confirm(DISCARD_CONFIRM))void action("Discarding saved request…",discard);}}>Discard saved request</button>}<button disabled={!!busy} onClick={()=>void action("Refreshing videos…",async()=>{await refresh();if(job)setJob(decodeJob(await api(`property-video-jobs/${job.job_id}`),scope,job.operation_id));})}>Refresh videos</button></div>
  {pending&&journal.preparation?.voice==="own"&&!journal.preparation.voiceComplete&&<label>Choose the same original recording to resume<input type="file" accept=".m4a,.mp3,audio/mp4,audio/mpeg" disabled={!!busy} onChange={event=>{setOwnFile(event.target.files?.[0]??null);setRecordingChanged(true);}}/></label>}
  {job&&<section className="video-job" aria-label="Current property video"><h3>{job.state==="ready"?"Your finished video":"Saved video progress"}</h3><p>{job.state.replaceAll("_"," ")} · {job.completed_sources}/{job.source_count} photos complete</p>{job.message&&<p>{job.message}</p>}{working&&<p>This is a saved server job. You can close Studio while it works.</p>}{(working||job.resume_available===true)&&<><button disabled={!!busy||!writable} onClick={()=>void action("Cancelling saved video…",cancel)}>Cancel video</button></>}
   {job.resume_available===true&&<button disabled={!!busy||!writable||!consent||!resumeAllowed} onClick={()=>void action("Resuming saved video…",async()=>{const resumed=await resumeVideo(services,scope,job,control.current.signal,processor?.kind==="legacy");current();setJob(resumed);setNotice("Resumed the same saved video. Completed shots are retained.");})}>Resume saved video</button>}
   {job.resume_available===true&&!resumePermission&&<p>This saved video’s original AI permission is incomplete. Refresh its status or cancel it; paid resume is paused.</p>}
   {job.result&&<><video key={`${job.job_id}:${job.result.download_url}`} controls playsInline preload="metadata" src={job.result.download_url}/><p>{job.result.width}×{job.result.height} · {Math.round(job.result.duration_s)}s{job.result.original_photo_count>0?` · ${job.result.original_photo_count} shots use the saved photo`:""}</p><small>AI motion can introduce visual errors. Review the full video and selected photo versions before sharing.</small><div className="video-photo-actions"><a href={job.result.download_url} download rel="noreferrer">Download finished video</a>{job.result.branding_policy==="unbranded"&&<><label><input type="checkbox" checked={reviewed} onChange={event=>setReviewed(event.target.checked)}/>I reviewed the video and property details</label><button disabled={!reviewed||!!busy||!writable} onClick={()=>void action("Selecting website video…",publish)}>Use on property website</button></>}</div>{share&&<a href={share} target="_blank" rel="noreferrer">Open property website</a>}</>}
  </section>}
  {jobs.length>0&&<details><summary>Saved videos for this property ({jobs.length})</summary><ul className="video-job-list">{jobs.map(item=><li key={item.job_id}><span>{item.state.replaceAll("_"," ")} · {item.source_count} photos</span><button disabled={!!busy} onClick={()=>void action("Opening saved video…",async()=>{setJob(decodeJob(await api(`property-video-jobs/${item.job_id}`),scope,item.operation_id));setReviewed(false);setShare("");})}>Open video</button></li>)}</ul></details>}
 </div>;
}
type FrozenMotion="fly_through"|"push_in"|"side_glide"|"pull_back";
