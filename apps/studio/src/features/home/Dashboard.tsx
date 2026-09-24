import {useEffect,useRef,useState} from "react";
import type { Listing, Workspace } from "../../data";
import Icon from "../../icons";
import {AI_FEATURES,FEATURES,featureFor,homeWords,listingStatus,type Feature,type FeatureId} from "./features";

export function FeatureCards({features,onOpen}: {features:readonly Feature[];onOpen:(id:FeatureId)=>void}) {
  return <div className="app-feature-grid">{features.map(feature=><button className={`app-feature-card feature-${feature.id}`} key={feature.id} onClick={()=>onOpen(feature.id)}>
    <span className="app-feature-top"><Icon name={feature.icon} size={27}/>{feature.ai&&<span className="app-ai-pill">AI</span>}</span>
    <strong>{feature.title}</strong><span>{feature.description}</span>
  </button>)}</div>;
}
export function PropertyPreview({listing}:{listing:Listing}) {
  const [failed,setFailed]=useState(false);
  const key=listing.mainPhotoKey;
  const safe=key?.startsWith(`renders/${listing.orgId}/${listing.id}/`)&&!key.includes("..")&&!/[?#\\]/.test(key);
  useEffect(()=>setFailed(false),[key]);
  return <div className="app-property-image">{safe&&!failed?<img src={`https://pub-70303ef2ff484a179c03ff19b26aa63d.r2.dev/${key!.split("/").map(encodeURIComponent).join("/")}`} alt="" loading="lazy" referrerPolicy="no-referrer" onError={()=>setFailed(true)}/>:<Icon name="home" size={36}/>}<span className={`app-property-status status-${listing.status}`}>{listingStatus(listing.status,listing.soldAt)}</span></div>;
}
type Props={workspace:Workspace|null;listings:Listing[];selectedId?:string;busy:boolean;spatialAvailable:boolean;onSelect:(id:string)=>void;onFeature:(id:FeatureId,listingId?:string)=>void;onCreate:()=>void;onStartCreating:()=>void;onProperties:()=>void;onLeads:()=>void;onPlanner:()=>void;onConnect:()=>void;onLibrary:()=>void;};
export default function Dashboard(props:Props) {
  const {workspace,listings}=props,words=homeWords(workspace?.org.spaceType??"real_estate");
  const active=listings.filter(l=>!l.soldAt),current=active.find(l=>l.id===props.selectedId);
  return <div className="app-dashboard">
    <section className="app-home-hero">
      <div><span className="app-brand-kicker">RENDPROP</span><h1>Your next video starts here.</h1><p>Describe the video you want, add your photos or clips, and make it your own.</p></div>
      <div className="app-hero-action"><button onClick={props.onStartCreating}><Icon name="film" size={20}/>Create a video<Icon name="arrow" size={18}/></button><span>Start with files on this device or media from your phone.</span></div>
    </section>
    <section aria-label={words.collection}>
      <div className="app-section-heading"><div><h2>{words.collection}</h2><p>Pick up where you left off on your phone.</p></div><button onClick={props.onCreate}><Icon name="plus" size={18}/>Add a {words.noun}</button></div>
      {props.busy&&!workspace?<p role="status">Opening your {words.plural}…</p>:!workspace?<div className="app-empty-property"><Icon name="phone" size={30}/><h3>Your phone and desktop, together</h3><p>Sign in once to see your {words.plural}, uploaded photos and videos here.</p><button className="primary" onClick={props.onConnect}>Connect my account</button></div>:!active.length?<div className="app-empty-property"><Icon name="home" size={32}/><h3>Start with a {words.noun}</h3><p>Add it here or in the app. Everything you make stays with that {words.noun}.</p><button className="primary" onClick={props.onCreate}>Add your first {words.noun}</button></div>:<div className="app-property-grid">{active.slice(0,4).map(listing=><button key={listing.id} className="app-property-card" onClick={()=>props.onFeature("photos",listing.id)}><PropertyPreview listing={listing}/><span className="app-property-info"><strong>{listing.address||listing.tagline||`Untitled ${words.noun}`}</strong><span>{[listing.beds!=null?`${listing.beds} beds`:null,listing.baths!=null?`${listing.baths} baths`:null,listing.sqft!=null?`${listing.sqft.toLocaleString()} sq ft`:null].filter(Boolean).join(" · ")||"Open photos, videos and tools"}</span><span>Open {words.noun}<Icon name="arrow" size={16}/></span></span></button>)}</div>}
      {!!listings.length&&<button className="text-button" onClick={props.onProperties}>View all {words.plural}{listings.some(l=>l.soldAt)?" & sold properties":""}<Icon name="arrow" size={16}/></button>}
    </section>
    <details className="app-all-tools"><summary><Icon name="sparkles" size={20}/><span>All tools<small>Photo edits, tours, scripts, AI video and more</small></span></summary><div>
    <section aria-label="Make something">
      <div className="app-section-heading"><div><h2>Make something</h2><p>Everything you make is saved to one {words.noun}.</p></div>{workspace&&active.length>0&&<label className="app-selected-property">Working on<select aria-label="Home for creation tools" value={current?.id??""} onChange={e=>props.onSelect(e.target.value)}><option value="">Choose a {words.noun}</option>{active.map(l=><option key={l.id} value={l.id}>{l.address||l.tagline||`Untitled ${words.noun}`}</option>)}</select></label>}</div>
      <FeatureCards features={FEATURES.filter(f=>f.id!=="spatial"||props.spatialAvailable)} onOpen={id=>props.onFeature(id,current?.id)}/>
    </section>
    <section aria-label="More AI tools"><div className="app-section-heading"><div><h2>A little help from AI</h2><p>Write the story, add a voice, or bring a photo to life.</p></div></div><FeatureCards features={AI_FEATURES} onOpen={id=>props.onFeature(id,current?.id)}/></section>
    </div></details>
    <button className="app-leads-banner" onClick={props.onLeads}><Icon name="person" size={30}/><span><strong>{workspace?`${workspace.usage.leadsNew} new ${workspace.usage.leadsNew===1?"lead":"leads"}`:"Your leads, in one place"}</strong><span>Every tour has a lead form. Follow up here or on your phone.</span></span><Icon name="arrow"/></button>
    <section className="app-handoff-guide" aria-label="From your phone to Studio"><div className="app-section-heading"><div><h2>Phone → Studio → ready to share</h2><p>One account keeps it all together.</p></div><button onClick={props.onPlanner}><Icon name="calendar" size={18}/>Plan a post</button></div><ol><li><span>1</span><div><strong>Capture on your phone</strong><p>Take photos or video in Rendprop and finish the upload.</p></div></li><li><span>2</span><div><strong>Open the same {words.noun} here</strong><p>Choose its photos and clips. Build a reel, edit photos or add a voice.</p></div></li><li><span>3</span><div><strong>Save and share</strong><p>Your saved media stays with the {words.noun}. Download a reel or share its tour.</p></div></li></ol><details><summary>Can’t see something from your phone?</summary><p>Use the same Apple account and workspace on both devices. Check that the upload has finished in the app, then refresh Studio. To continue a phone reel setup, tap <strong>Save setup</strong> in the app and <strong>Load phone reel setup</strong> in Studio.</p><button onClick={props.onLibrary}>Open my photos & videos</button></details></section>
  </div>;
}

export function FeatureGate({feature,listings,spaceType,onChoose,onCancel,onCreate}:{feature:FeatureId;listings:Listing[];spaceType:string;onChoose:(id:string)=>void;onCancel:()=>void;onCreate:()=>void}) {
  const dialog=useRef<HTMLDialogElement>(null),words=homeWords(spaceType);
  useEffect(()=>{const previous=document.activeElement;dialog.current?.showModal();return()=>{dialog.current?.close();if(previous instanceof HTMLElement&&previous.isConnected)previous.focus();};},[]);
  return <dialog ref={dialog} className="app-feature-gate" onCancel={e=>{e.preventDefault();onCancel();}} aria-labelledby="feature-gate-title"><div className="app-section-heading"><h2 id="feature-gate-title">Which {words.noun} is this for?</h2><button aria-label="Close home picker" onClick={onCancel}>✕</button></div><p>{featureFor(feature).title} keeps everything with the {words.noun} you choose.</p><div className="app-gate-list">{listings.filter(l=>!l.soldAt).map(l=><button key={l.id} onClick={()=>onChoose(l.id)}><Icon name="home"/><span>{l.address||l.tagline||`Untitled ${words.noun}`}</span><Icon name="arrow" size={18}/></button>)}</div><button onClick={onCreate}><Icon name="plus" size={18}/>Add a new {words.noun}</button></dialog>;
}
