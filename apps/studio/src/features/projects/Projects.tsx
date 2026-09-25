import {useCallback,useEffect,useRef,useState} from "react";
import VideoEditor,{type VideoEditorProps} from "../../editor/VideoEditor";
import {draftMedia,newDraft,type EditDraft} from "../../editor/model";
import type {ConversationState} from "../../editor/conversation-state";
import type {StudioServices,Workspace} from "../../data";
import {DocumentSync,type SyncState} from "../../data/documents";
import {decodeProject,decodeProjectIndex,projectKey,projectName,type ProjectSummary,type VideoProject} from "./model";
import {preserveProjectRecovery,readProjectRecoveries,removeProjectRecovery} from "./recovery";
import {readProjectFile,storeProjectFile} from "./media-store";
import {saveCloudOriginal,decodeSavedMedia,downloadSavedMedia} from "./cloud-media";
import {requestProjectAnalysis} from "./project-analysis-request";
import "./projects.css";

type Props=VideoEditorProps&{services?:StudioServices|null;workspace?:Workspace|null;storageScope:string};
/** Named, private video projects share the editor. A local video is never
 * uploaded until its owner explicitly saves it as an account project. */
export default function Projects(props:Props){
 const {services,workspace,storageScope}=props;
 const connected=!!services&&!!workspace;
 const writable=!!workspace?.memberships.some(member=>member.orgId===workspace.org.id&&["owner","admin","agent"].includes(member.role));
 const canWrite=useRef(writable);canWrite.current=writable;
 const propsRef=useRef(props);propsRef.current=props;
 const scope=`${storageScope}:originals`;
 const [index,setIndex]=useState<ProjectSummary[]>([]),[listError,setListError]=useState("");
 const [selected,setSelected]=useState(""),[name,setName]=useState(""),[showArchived,setShowArchived]=useState(false);
 const [initial,setInitial]=useState<{draft?:EditDraft;conversation?:ConversationState;epoch:number}>({draft:props.initialDraft,conversation:props.initialConversation,epoch:0});
 const current=useRef<VideoProject>({schema:1,name:"Untitled video",archived:false,listingId:null,draft:props.initialDraft??newDraft(),sources:[],conversation:props.initialConversation});
 const actionFlight=useRef(false);
 const tentative=useRef(new Set<DocumentSync>());
 const selectedRef=useRef(""),sync=useRef<DocumentSync|null>(null);
 const [state,setState]=useState<SyncState>("saved"),[busy,setBusy]=useState(false),[message,setMessage]=useState("");
 const [recoveries,setRecoveries]=useState<VideoProject[]>(()=>readProjectRecoveries(localStorage,storageScope)),[recoveryIndex,setRecoveryIndex]=useState(0);
 const recovery=recoveries[recoveryIndex]??null;
 const preserveRecovery=(payload:VideoProject)=>{preserveProjectRecovery(localStorage,storageScope,payload);setRecoveries(readProjectRecoveries(localStorage,storageScope));setRecoveryIndex(0);};
 const [relink,setRelink]=useState<VideoEditorProps["relinkRequest"]>();
 const [filesVersion,setFilesVersion]=useState(0),[writing,setWriting]=useState(0),[editorBlock,setEditorBlock]=useState<string|null>(null);
 const editorBlockRef=useRef<string|null>(null),projectBlockRef=useRef<string|null>(null);
 const observeEditorBlock=useCallback((reason:string|null)=>{editorBlockRef.current=reason;setEditorBlock(reason);propsRef.current.onSwitchBlockChange?.(reason??projectBlockRef.current);},[]);
 const files=useRef(new Map<string,File>()),stored=useRef(new Set<string>()),cloud=useRef(new Set<string>());
 const pending=useRef(new Map<string,Promise<void>>()),controller=useRef(new AbortController()),operation=useRef(0),mounted=useRef(true);
 const backup=(key:string,payload:VideoProject)=>{try{localStorage.setItem(`${storageScope}:${key||"local-video"}:backup`,JSON.stringify(payload));}catch{setMessage("Browser draft backup is unavailable. Keep this tab open until account saving finishes.");}};
 const refreshIndex=useCallback(async()=>{if(!services||!workspace)return;try{const rows=decodeProjectIndex(await services.api("/functions/v1/studio/projects",{orgId:workspace.org.id,signal:controller.current.signal}));if(mounted.current){setIndex(rows);setListError("");}}catch(error){if(mounted.current&&!controller.current.signal.aborted)setListError(error instanceof Error?error.message:"Saved projects could not be loaded.");}},[services,workspace?.org.id]);
 const usedHashes=()=>new Set([...draftMedia(current.current.draft).map(c=>c.source.sha256),...(current.current.draft.music?[current.current.draft.music.source.sha256]:[])]);
 const publish=()=>{if(mounted.current)setFilesVersion(v=>v+1);};
 async function keepFile(hash:string,file:File){
  files.current.set(hash,file);if(stored.current.has(hash)&&(!selectedRef.current||cloud.current.has(hash)))return;
  if(pending.current.has(hash))return pending.current.get(hash);
  const project=selectedRef.current,abort=controller.current.signal;setWriting(v=>v+1);
  const work=(async()=>{
   let browserError:unknown;
   try{if(!stored.current.has(hash)){await storeProjectFile(scope,hash,file,abort);stored.current.add(hash);}}catch(error){browserError=error;}
   if(project&&services&&workspace&&canWrite.current&&!cloud.current.has(hash)){await saveCloudOriginal(services,workspace.org.id,file,hash,abort);cloud.current.add(hash);}
   if(browserError&&!cloud.current.has(hash))throw browserError;
  })();pending.current.set(hash,work);
  try{await work;}catch(error){if(mounted.current&&!abort.aborted)setMessage(error instanceof Error?error.message:"An original could not be saved. Keep this tab open and retry.");throw error;}
  finally{pending.current.delete(hash);if(mounted.current){setWriting(v=>v-1);publish();}}
 }
 async function retryFiles(){setMessage("");for(const hash of usedHashes()){const file=files.current.get(hash);if(file)await keepFile(hash,file);}await sync.current?.retry();}
 const changed=useCallback((draft:EditDraft,conversation?:ConversationState)=>{
  current.current={...current.current,draft,...(conversation?{conversation}:{})};backup(selectedRef.current,current.current);
  if(selectedRef.current){if(canWrite.current)sync.current?.queue(current.current as unknown as Record<string,unknown>);}
  else propsRef.current.onDraftChange?.(draft,conversation);
  publish();
 },[storageScope]);
 const sourcesChanged=useCallback((sources:{file:File;sha256:string}[])=>{
  propsRef.current.onSourcesChange?.(sources);
  for(const source of sources)void keepFile(source.sha256,source.file).catch(()=>{});
 },[scope,services,workspace?.org.id]);
 const resolve=useCallback(async(hash:string,signal:AbortSignal):Promise<File|null>=>{
  const combined=AbortSignal.any([signal,controller.current.signal]);let file=files.current.get(hash)??null;
  if(!file){try{file=await readProjectFile(scope,hash,combined);if(file)stored.current.add(hash);}catch{ /* Cloud restoration remains possible when browser storage is unavailable. */ }}
  if(selectedRef.current&&services&&workspace&&!cloud.current.has(hash)){
   try{const saved=decodeSavedMedia(await services.api(`/functions/v1/studio/project-media?sha256=${hash}`,{orgId:workspace.org.id,signal:combined}),hash);if(saved?.complete){cloud.current.add(hash);if(!file)file=await downloadSavedMedia(saved,combined);}}
   catch(error){combined.throwIfAborted();if(!file)throw error;}
  }
  combined.throwIfAborted();if(file)files.current.set(hash,file);return file;
 },[scope,services,workspace?.org.id]);
 const resolveMusic=useCallback<NonNullable<VideoEditorProps["resolveMusic"]>>(async(source,signal)=>{const file=await resolve(source.sha256,signal);if(!file)throw new Error("Reselect this music file to restore its sound.");return file;},[resolve]);
 const musicChanged=useCallback<NonNullable<VideoEditorProps["onMusicSourceChange"]>>(source=>{if(source)void keepFile(source.source.sha256,source.file).catch(()=>{});},[scope,services,workspace?.org.id]);
 const analyze=useCallback<NonNullable<VideoEditorProps["requestMediaAnalysis"]>>(async(clip,signal)=>{
  if(!services||!workspace)throw new Error("Sign in and save this project to your account before transcribing it.");
  return requestProjectAnalysis(services,workspace.org.id,clip,!!selectedRef.current,AbortSignal.any([signal,controller.current.signal]));
 },[services,workspace?.org.id]);
 async function restore(payload:VideoProject,signal:AbortSignal){
  const restored:File[]=[];let missing=0;
  for(const hash of new Set(draftMedia(payload.draft).map(c=>c.source.sha256))){try{const file=await resolve(hash,signal);if(file)restored.push(file);else missing++;}catch(error){signal.throwIfAborted();missing++;}}
  signal.throwIfAborted();if(restored.length)setRelink({id:crypto.randomUUID(),files:restored});
  if(missing)setMessage(`${missing} original file${missing===1?" needs":"s need"} restoring. Reselect the originals shown in the editor; your edit is preserved.`);
  publish();
 }
 function unsavedOriginals(){return [...usedHashes()].some(h=>!stored.current.has(h)&&!cloud.current.has(h));}
 async function guard(){
  if(editorBlockRef.current)throw new Error(editorBlockRef.current);
  if(busy||pending.current.size)throw new Error("Wait for your originals to finish saving before switching projects.");
  await sync.current?.flush();
  if(sync.current?.hasUnsavedWork||sync.current?.state==="conflict"||sync.current?.state==="offline")throw new Error("Finish syncing or recover the newer saved project before switching.");
  if(unsavedOriginals())throw new Error("Some originals are not backed up. Retry saving or reselect the missing files before switching projects.");
 }
 async function open(key:string,skipGuard=false){
  if(actionFlight.current)return;actionFlight.current=true;
  let next:DocumentSync|null=null;
  try{
   if(!skipGuard)await guard();controller.current.signal.throwIfAborted();if(!mounted.current)return;const attempt=++operation.current;setBusy(true);setMessage("");
   next=key&&services&&workspace?new DocumentSync(services,workspace.org.id,key,setState,{listingId:null}):null;
   if(next)tentative.current.add(next);
   const doc=next?await next.open():null;
   if(attempt!==operation.current||!mounted.current){next?.dispose();return;}
   let payload:VideoProject;
   if(key){if(!doc||doc.kind!=="project"||doc.listing_id!==null)throw new Error("This saved video project is unavailable.");payload=decodeProject(doc.payload);}
   else payload={schema:1,name:"Untitled video",archived:false,listingId:null,draft:newDraft(),sources:[]};
   if(skipGuard){preserveRecovery(current.current);}
   else if(key){
    // A tab may have closed before its last save. Keep that edit independently
    // before the remote editor's initial onChange replaces the routine backup.
    const previous=localStorage.getItem(`${storageScope}:${key}:backup`);
    if(previous){let cached:VideoProject|null=null;try{cached=decodeProject(JSON.parse(previous));}catch{/* Invalid browser data cannot replace the valid account project. */}if(cached&&JSON.stringify(cached)!==JSON.stringify(payload))preserveRecovery(cached);}
   }else if(current.current.draft.clips.length){preserveRecovery(current.current);}
   sync.current?.dispose();sync.current=next;selectedRef.current=key;setSelected(key);current.current=payload;setName(payload.name);setRelink(undefined);
   if(next)tentative.current.delete(next);
   setState("saved");setInitial(old=>({draft:payload.draft,conversation:payload.conversation,epoch:old.epoch+1}));await restore(payload,controller.current.signal);
  }catch(error){if(next!==sync.current)next?.dispose();if(next)tentative.current.delete(next);if(mounted.current)setMessage(error instanceof Error?error.message:"The project could not be opened.");}
  finally{if(next)tentative.current.delete(next);actionFlight.current=false;if(mounted.current)setBusy(false);}
 }
 async function recover(){
  if(!recovery||actionFlight.current)return;actionFlight.current=true;
  try{await guard();controller.current.signal.throwIfAborted();if(!mounted.current)return;setBusy(true);setMessage("");const payload=decodeProject(recovery);
   sync.current?.dispose();sync.current=null;selectedRef.current="";setSelected("");current.current=payload;setName(payload.name);setState("saved");setRelink(undefined);
   setInitial(old=>({draft:payload.draft,conversation:payload.conversation,epoch:old.epoch+1}));await restore(payload,controller.current.signal);
   setMessage("Recovered your browser edit as a local video. Save a copy to keep it in your account.");
  }catch(error){if(mounted.current)setMessage(error instanceof Error?error.message:"This browser edit could not be recovered.");}
  finally{actionFlight.current=false;if(mounted.current)setBusy(false);}
 }
 async function saveAs(){
  if(!services||!workspace||!canWrite.current||busy||actionFlight.current)return;actionFlight.current=true;
  const attempt=operation.current,signal=controller.current.signal;let next:DocumentSync|null=null;
  const fence=()=>{signal.throwIfAborted();if(!mounted.current||attempt!==operation.current)throw new Error("This project changed while saving.");};
  try{
   if(editorBlockRef.current)throw new Error(editorBlockRef.current);await Promise.all([...pending.current.values()]);await sync.current?.flush();
   fence();
   if(sync.current?.hasUnsavedWork)throw new Error("Finish syncing the current project before saving another copy.");
   const title=projectName(name||current.current.draft.title||"Untitled video"),key=projectKey(crypto.randomUUID());setBusy(true);setMessage("");
   next=new DocumentSync(services,workspace.org.id,key,setState,{listingId:null});tentative.current.add(next);await next.open();fence();
   const payload=decodeProject({...current.current,name:title,archived:false});next.queue(payload as unknown as Record<string,unknown>);await next.flush();fence();
   if(next.state!=="saved"){
    // Retain the uncertain writer and its exact key. Retrying reconciles it,
    // instead of purchasing storage or creating another project identity.
    sync.current?.dispose();sync.current=next;selectedRef.current=key;setSelected(key);current.current=payload;backup(key,payload);throw new Error("Project save is awaiting confirmation. Retry sync before creating another copy.");
   }
   sync.current?.dispose();sync.current=next;selectedRef.current=key;setSelected(key);current.current=payload;setName(title);backup(key,payload);
   for(const hash of usedHashes()){const file=files.current.get(hash)??await readProjectFile(scope,hash,controller.current.signal);if(file)await keepFile(hash,file);}
   await refreshIndex();setMessage([...usedHashes()].every(hash=>cloud.current.has(hash))?"Your project and originals are saved to your account.":"Project saved. Reselect the missing originals to finish uploading them for other devices.");
  }catch(error){if(next&&next!==sync.current)next.dispose();if(mounted.current&&!signal.aborted)setMessage(error instanceof Error?error.message:"This project could not be saved.");}
  finally{if(next)tentative.current.delete(next);actionFlight.current=false;if(mounted.current)setBusy(false);}
 }
 function rename(){if(selectedRef.current&&!canWrite.current)return;try{const title=projectName(name);current.current={...current.current,name:title};backup(selectedRef.current,current.current);if(selectedRef.current)sync.current?.queue(current.current as unknown as Record<string,unknown>);}catch(error){setMessage((error as Error).message);}}
 async function archive(){if(!canWrite.current)return;try{await guard();controller.current.signal.throwIfAborted();current.current={...current.current,archived:!current.current.archived};sync.current?.queue(current.current as unknown as Record<string,unknown>);await sync.current?.flush();await refreshIndex();publish();}catch(error){setMessage((error as Error).message);}}
 useEffect(()=>{void refreshIndex();void restore(current.current,controller.current.signal).catch(()=>{});return()=>{mounted.current=false;operation.current++;controller.current.abort();sync.current?.dispose();for(const writer of tentative.current)writer.dispose();tentative.current.clear();};},[scope]);
 const missing=[...usedHashes()].filter(hash=>selected? !cloud.current.has(hash):!stored.current.has(hash));
 const projectBlock=busy||writing?"Wait for the current project save to finish.":selected&&(state!=="saved"||missing.length)?"Finish saving your project and originals before switching accounts.":unsavedOriginals()?"Keep or save your original files before switching accounts.":null;
 projectBlockRef.current=projectBlock;const blocked=editorBlock??projectBlock;
 useEffect(()=>{props.onSwitchBlockChange?.(blocked);return()=>props.onSwitchBlockChange?.(null);},[blocked,props.onSwitchBlockChange]);
 useEffect(()=>{const warn=(event:BeforeUnloadEvent)=>{if(blocked){event.preventDefault();event.returnValue="";}};window.addEventListener("beforeunload",warn);return()=>window.removeEventListener("beforeunload",warn);},[blocked]);
 useEffect(()=>{const focus=()=>{if(document.visibilityState==="visible"){void sync.current?.checkRemote();void refreshIndex();}};window.addEventListener("focus",focus);return()=>window.removeEventListener("focus",focus);},[refreshIndex]);
 return <div className="video-projects">
  <section className="project-bar" aria-label="Video projects">
   <label>Video project<select aria-label="Open video project" value={selected} disabled={busy||writing>0} onChange={e=>void open(e.target.value)}><option value="">New local video</option>{index.filter(p=>showArchived||!p.archived||p.key===selected).map(p=><option key={p.key} value={p.key}>{p.name}{p.archived?" (archived)":""}</option>)}{selected&&!index.some(p=>p.key===selected)&&<option value={selected}>{name||"Saving project…"}</option>}</select></label>
   <label>Project name<input maxLength={80} value={name} disabled={busy||!!selected&&!writable} placeholder="Give this video a name" onChange={e=>setName(e.target.value)} onBlur={rename}/></label>
   {connected&&<button className="primary" disabled={!writable||busy||writing>0||!!editorBlock} onClick={()=>void saveAs()}>{selected?"Save a copy":"Save project to account"}</button>}
   {selected&&<button disabled={!writable||busy||writing>0} onClick={()=>void archive()}>{current.current.archived?"Unarchive":"Archive"}</button>}
   {connected&&!writable&&<p>Your workspace role can view saved projects. An owner or administrator can grant editing access.</p>}
   {!!index.some(p=>p.archived)&&<label className="project-archive-toggle"><input type="checkbox" checked={showArchived} onChange={e=>setShowArchived(e.target.checked)}/>Show archived</label>}
   <p role="status">{selected?writing?"Saving original files to your account…":state==="conflict"?"A newer project was saved on another device. Your browser copy is preserved.":state==="offline"?"Account saving is paused. Your browser copy is preserved.":state==="saving"?"Saving project…":missing.length?`Project saved; ${missing.length} original file${missing.length===1?"":"s"} still need uploading.`:"Project and originals saved to your account.":writing?"Keeping originals in this browser…":"Local video: originals stay in this browser. Save a project to use it on another device."}</p>
   {(state==="offline"||missing.length>0)&&<button disabled={busy||writing>0} onClick={()=>void retryFiles().catch(error=>setMessage(error.message))}>Retry saving</button>}
   {state==="conflict"&&<button disabled={busy} onClick={()=>void open(selected,true)}>Open newer saved version</button>}
   {recovery&&<button disabled={busy||writing>0||state==="conflict"} onClick={()=>void recover()}>Recover browser edit: {recovery.name}</button>}
   {recoveries.length>1&&<label>Browser recovery<select aria-label="Choose browser recovery" value={recoveryIndex} onChange={event=>setRecoveryIndex(Number(event.target.value))}>{recoveries.map((item,index)=><option key={index} value={index}>{item.name} — copy {recoveries.length-index}</option>)}</select></label>}
   {recovery&&<button disabled={busy} onClick={()=>{try{setRecoveries(removeProjectRecovery(localStorage,storageScope,recoveryIndex));setRecoveryIndex(0);}catch(error){setMessage((error as Error).message);}}}>Remove selected browser backup</button>}
   {listError&&<p role="alert">{listError} <button onClick={()=>void refreshIndex()}>Retry project list</button></p>}
   {message&&<p role="status">{message}</p>}
  </section>
  <VideoEditor {...props} key={initial.epoch} readOnly={props.readOnly||busy||!!selected&&!writable} initialDraft={initial.draft} initialConversation={initial.conversation} conversationStorageKey={selected?undefined:props.conversationStorageKey} onDraftChange={changed} onSourcesChange={sourcesChanged} onSwitchBlockChange={observeEditorBlock} relinkRequest={relink} resolveMusic={resolveMusic} onMusicSourceChange={musicChanged} requestMediaAnalysis={analyze} />
 </div>;
}
