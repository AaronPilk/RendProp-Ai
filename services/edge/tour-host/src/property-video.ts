import { escapeAttr, escapeHtml, safeUrl } from "./html";

export interface ListingVideo {
  url: string;
  poster_url: string | null;
  duration_s: number;
  width: number;
  height: number;
  disclosure: string | null;
  /** Server projection of the immutable composition policy. Absence is not
   * evidence of branding-free media; never derive this from details/query. */
  branding_policy?: "unbranded" | null;
}

/** Only a typed server-selected, finished landscape master can be a hero.
 * Provider clips, arbitrary details URLs and portrait/social outputs cannot. */
export function listingVideo(value: unknown): ListingVideo | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const v = value as Record<string, unknown>;
  const url = typeof v.url === "string" ? safeUrl(v.url) : "";
  if (!url || !Number.isInteger(v.width) || !Number.isInteger(v.height) ||
      (v.width as number) < 1920 || (v.height as number) < 1080 ||
      (v.width as number) > 7680 || (v.height as number) > 4320 ||
      (v.width as number) * 9 !== (v.height as number) * 16 ||
      typeof v.duration_s !== "number" || !Number.isFinite(v.duration_s) || v.duration_s <= 0 || v.duration_s > 7200) return null;
  return { url, poster_url: typeof v.poster_url === "string" ? safeUrl(v.poster_url) || null : null,
    duration_s:v.duration_s,width:v.width as number,height:v.height as number,
    disclosure:typeof v.disclosure === "string" ? v.disclosure.trim().slice(0,2000) || null : null,
    branding_policy:v.branding_policy === "unbranded" ? "unbranded" : null };
}

/** Premium hero caption: the film's running time, never its pixel dimensions. */
export function filmLabel(video: ListingVideo): string {
  const seconds = Math.round(video.duration_s);
  if (!Number.isFinite(seconds) || seconds <= 0) return "Property film";
  return `Property film · ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/** `film` is the premium (paid design) presentation: full-bleed poster, one
 * discreet play control, a running-time caption and a status region that only
 * speaks while the film is loading. Classic markup and copy are unchanged. */
export function listingVideoStage(video: ListingVideo, fallbackPoster: string, address: string, film = false): string {
  const poster = video.poster_url || fallbackPoster;
  if (film) return `<div class="property-video-stage property-film">
    ${poster ? `<img class="property-film-backdrop" src="${escapeAttr(poster)}" alt="" aria-hidden="true" decoding="async">` : ""}
    <video id="property-video" preload="none" playsinline${poster ? ` poster="${escapeAttr(poster)}"` : ""} aria-label="Property film for ${escapeAttr(address)}"></video>
    <button type="button" id="property-video-play" class="property-video-play" aria-controls="property-video"><span class="property-film-play-mark" aria-hidden="true"></span><span class="property-film-play-text">Play the film</span></button>
    <p class="property-film-label">${escapeHtml(filmLabel(video))}</p>
    <p id="property-video-status" role="status" aria-live="polite"></p>
    <noscript><a class="property-video-download" href="${escapeAttr(video.url)}" target="_blank" rel="noopener">Open the property film</a></noscript>
  </div>`;
  return `<div class="property-video-stage">
    <video id="property-video" preload="none" playsinline${poster ? ` poster="${escapeAttr(poster)}"` : ""} aria-label="Property video for ${escapeAttr(address)}"></video>
    <button type="button" id="property-video-play" class="property-video-play" aria-controls="property-video">Play property video <span aria-hidden="true">▶</span></button>
    <p id="property-video-status" role="status" aria-live="polite">${escapeHtml(video.width + " × " + video.height)} · Select Play to load the video.</p>
    <noscript><a class="property-video-download" href="${escapeAttr(video.url)}" target="_blank" rel="noopener">Open property video</a></noscript>
  </div>`;
}

export const PROPERTY_VIDEO_CSS = `
  .property-site .listing-cover.property-video-hero { min-height:0; background:var(--bg); color:var(--ink); }
  .property-site .listing-cover.property-video-hero::after { display:none; }
  .property-video-stage { position:relative; width:100%; aspect-ratio:16/9; background:#111; color:white; overflow:hidden; }
  .property-video-stage video { display:block; width:100%; height:100%; object-fit:contain; }
  .property-video-play { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); min-height:56px; padding:15px 24px; border:1px solid rgba(255,255,255,.7); border-radius:40px; background:rgba(12,12,16,.88); color:white; font-family:inherit; font-size:15px; font-weight:600; line-height:1.4; cursor:pointer; box-shadow:0 6px 24px rgba(0,0,0,.25); }
  .property-video-play[hidden] { display:none; }
  .property-video-play span { margin-left:10px; }
  .property-video-play:focus-visible { outline:3px solid white; outline-offset:5px; }
  .property-video-stage #property-video-status { position:absolute; left:14px; right:14px; bottom:12px; width:fit-content; max-width:calc(100% - 28px); margin:0; padding:6px 10px; background:rgba(12,12,16,.86); border-radius:4px; font-size:12px; pointer-events:none; }
  .property-video-stage.is-playing #property-video-status { bottom:auto; top:12px; }
  .property-video-download { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); color:white; background:#16131e; padding:16px; border:1px solid white; }
  .property-site .property-video-hero .property-hero-copy { position:static; max-width:none; color:var(--ink); padding:clamp(24px,4vw,48px); }
  .property-site .property-video-hero .property-hero-copy .lp-eyebrow { color:var(--accent-3); }
  .property-site .property-video-hero .listing-cover-actions { margin-top:22px; }
  .property-site .property-video-hero .listing-cover-actions p { color:var(--ink-dim); }
  .property-site .property-video-hero .listing-cover-actions button,.property-site .property-video-hero .property-hero-link { color:var(--ink); background:transparent; border-color:var(--ink-dim); }
  .property-site .property-video-hero .listing-media-label { display:block; color:var(--ink-dim); line-height:1.6; }
  @media(max-width:600px) { .property-video-play { min-height:48px; padding:12px 16px; font-size:13px; } .property-video-stage #property-video-status { font-size:10px; left:8px; bottom:6px; padding:4px 7px; } }

  /* Premium film hero. The poster fills the frame edge to edge (a soft cover
     of the same still sits behind the complete, uncropped poster and film),
     the play control is a single quiet mark, the caption is the running time,
     and the status region speaks only while the film is loading. Motion is
     opacity/transform only and off under prefers-reduced-motion. */
  .property-video-stage.property-film { background:#0e100f; isolation:isolate; }
  .property-video-stage.property-film .property-film-backdrop { position:absolute; inset:-6%; width:112%; height:112%; object-fit:cover; filter:blur(26px) saturate(1.1) brightness(.72); pointer-events:none; z-index:0; }
  .property-video-stage.property-film > video { position:relative; z-index:1; }
  .property-video-stage.property-film .property-video-play { z-index:2; display:flex; flex-direction:column; align-items:center; gap:14px; min-height:0; padding:0; border:0; border-radius:0; background:transparent; box-shadow:none; color:#fff; font-size:12px; font-weight:500; letter-spacing:.14em; text-transform:uppercase; text-shadow:0 1px 10px rgba(0,0,0,.55); }
  .property-video-stage.property-film .property-video-play[hidden] { display:none; }
  .property-video-stage.property-film .property-film-play-mark { display:grid; place-items:center; width:72px; height:72px; border-radius:50%; border:1px solid rgba(255,255,255,.6); background:rgba(14,16,15,.38); box-shadow:0 12px 36px rgba(0,0,0,.32),inset 0 1px rgba(255,255,255,.28); }
  .property-video-stage.property-film .property-film-play-mark::after { content:""; width:0; height:0; margin-left:5px; border-style:solid; border-width:10px 0 10px 17px; border-color:transparent transparent transparent #fff; }
  .property-video-stage.property-film .property-video-play:focus-visible { outline:3px solid white; outline-offset:10px; border-radius:8px; }
  .property-video-stage.property-film .property-film-label { position:absolute; left:20px; bottom:18px; z-index:2; margin:0; font:500 11px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; letter-spacing:.16em; text-transform:uppercase; color:rgba(255,255,255,.9); text-shadow:0 1px 10px rgba(0,0,0,.6); pointer-events:none; }
  .property-video-stage.property-film #property-video-status { left:50%; right:auto; top:calc(50% + 68px); bottom:auto; width:max-content; max-width:calc(100% - 40px); transform:translateX(-50%); z-index:2; padding:7px 14px; border:1px solid rgba(255,255,255,.18); border-radius:999px; background:rgba(14,16,15,.62); font-size:11px; letter-spacing:.06em; }
  .property-video-stage.property-film #property-video-status:empty { display:none; }
  .property-video-stage.property-film.is-playing #property-video-status { top:14px; bottom:auto; }
  .property-video-stage.property-film.is-playing .property-film-label { display:none; }
  @supports ((backdrop-filter:blur(14px)) or (-webkit-backdrop-filter:blur(14px))) {
    .property-video-stage.property-film .property-film-play-mark,.property-video-stage.property-film #property-video-status { backdrop-filter:blur(14px) saturate(1.2); -webkit-backdrop-filter:blur(14px) saturate(1.2); }
  }
  @media(hover:hover) and (pointer:fine) and (prefers-reduced-motion:no-preference) {
    .property-video-stage.property-film .property-film-play-mark { transition:transform .28s cubic-bezier(.2,.7,.2,1),background-color .28s ease; }
    .property-video-stage.property-film .property-video-play:hover .property-film-play-mark { transform:scale(1.06); background:rgba(14,16,15,.5); }
  }
  @media(prefers-reduced-motion:no-preference) {
    .property-video-stage.property-film { animation:property-film-arrive .6s ease-out both; }
    .property-video-stage.property-film > video { animation:property-film-settle 1.6s cubic-bezier(.2,.7,.2,1) both; }
    .property-video-stage.property-film .property-video-play,.property-video-stage.property-film .property-film-label { animation:property-film-arrive .5s ease-out .3s both; }
  }
  @keyframes property-film-arrive { from { opacity:0; } to { opacity:1; } }
  @keyframes property-film-settle { from { transform:scale(1.035); } to { transform:none; } }
  @media(prefers-reduced-motion:reduce) { .property-video-stage.property-film,.property-video-stage.property-film > video,.property-video-stage.property-film .property-video-play,.property-video-stage.property-film .property-film-label,.property-video-stage.property-film .property-film-play-mark { animation:none; transition:none; } }
  @media(max-width:600px) {
    .property-video-stage.property-film .property-video-play { min-height:0; padding:0; font-size:11px; gap:10px; }
    .property-video-stage.property-film .property-film-play-mark { width:60px; height:60px; }
    .property-video-stage.property-film .property-film-label { left:14px; bottom:12px; font-size:10px; }
    .property-video-stage.property-film #property-video-status { left:50%; bottom:auto; top:calc(50% + 56px); padding:5px 11px; font-size:10px; }
  }
`;

/** The master is attached only on an explicit Play tap. Native video controls
 * handle normal playback/sound; leaving the page unloads its decoder and bytes. */
export const PROPERTY_VIDEO_JS = `
(function(){
  var CFG=window.__CFG__||{}, spec=CFG.listingVideo;
  var video=document.getElementById('property-video'), button=document.getElementById('property-video-play'), status=document.getElementById('property-video-status');
  if (!video || !button || !status || !spec || !spec.url) return;
  var stage=video.parentElement, attached=false, failed=false, viewed=false, playing=false, last=0, watchMs=0, sentWatch=0, maxDepth=0, buffered=0, delivered=0, sentDelivered=0, generation=0, deadline=null;
  // Premium film hero: the status region speaks only while loading and the
  // quiet play mark is restored as markup; Classic copy is unchanged.
  var film=!!CFG.filmHero, idle=film?button.innerHTML:null;
  function measure(){
    var now=performance.now();
    if(playing && !document.hidden && !video.paused && !video.ended && !video.seeking && video.readyState>=2){if(last)watchMs+=Math.min(1000,Math.max(0,now-last));if(video.duration>0)maxDepth=Math.max(maxDepth,Math.min(1,video.currentTime/video.duration));}
    last=now;
    var seconds=0;try{for(var i=0;i<video.buffered.length;i++)seconds+=Math.max(0,video.buffered.end(i)-video.buffered.start(i));}catch(e){}
    if(seconds>buffered){delivered+=seconds-buffered;buffered=seconds;}
  }
  function beacon(extra){
    if(CFG.preview || !viewed || !CFG.functionsBase || !CFG.slug)return;
    measure();var data={watch_ms:Math.round(Math.max(0,watchMs-sentWatch)),scroll_depth:Math.round(maxDepth*1000)/1000,streamed_minutes:Math.round(Math.max(0,delivered-sentDelivered)/60*1000)/1000};
    sentWatch=watchMs;sentDelivered=delivered;if(CFG.unbranded)data.unbranded=true;if(extra)Object.keys(extra).forEach(function(k){data[k]=extra[k];});
    var url=CFG.functionsBase+'/beacon/'+encodeURIComponent(CFG.slug);if(CFG.anonKey)url+='?apikey='+encodeURIComponent(CFG.anonKey);var body=JSON.stringify(data);
    try{if(navigator.sendBeacon && navigator.sendBeacon(url,new Blob([body],{type:'text/plain;charset=UTF-8'})))return;}catch(e){}
    try{fetch(url,{method:'POST',body:body,headers:{'Content-Type':'text/plain'},keepalive:true,mode:'cors',credentials:'omit'}).catch(function(){});}catch(e){}
  }
  function failure(){clearTimeout(deadline);playing=false;failed=true;video.pause();attached=false;video.removeAttribute('src');video.preload='none';video.load();button.hidden=false;button.textContent=film?'Retry the film':'Retry property video';status.textContent=film?'The film could not load. Retry, or continue to the gallery.':'The video could not load. Retry, or continue to the gallery.';stage.classList.remove('is-playing');}
  function playPropertyVideo(){
    var bounds=stage.getBoundingClientRect && stage.getBoundingClientRect();
    if(bounds && (bounds.bottom<0 || bounds.top>innerHeight) && stage.scrollIntoView)stage.scrollIntoView({block:'center',behavior:'auto'});
    var token=++generation;
    if(failed){video.removeAttribute('src');video.load();attached=false;failed=false;}
    if(!attached){video.src=spec.url;attached=true;video.controls=true;video.preload='auto';buffered=0;video.load();}
    status.textContent=film?'Loading the film…':'Loading property video…';button.hidden=true;
    clearTimeout(deadline);deadline=setTimeout(function(){if(token===generation && video.readyState<2)failure();},25000);
    try{var result=video.play();if(result && result.catch)result.catch(function(){if(token===generation)failure();});}catch(e){if(token===generation)failure();}
  }
  button.addEventListener('click',playPropertyVideo);
  var navPlay=document.getElementById('property-video-nav-play');
  if(navPlay)navPlay.addEventListener('click',playPropertyVideo);
  video.addEventListener('playing',function(){clearTimeout(deadline);playing=true;failed=false;last=performance.now();stage.classList.add('is-playing');status.textContent=film?'':'Property video · '+spec.width+' × '+spec.height;if(!viewed){viewed=true;beacon({view_start:true});}});
  video.addEventListener('pause',function(){measure();playing=false;beacon();});
  video.addEventListener('ended',function(){measure();playing=false;beacon();});
  video.addEventListener('error',function(){if(attached)failure();});
  video.addEventListener('timeupdate',measure);video.addEventListener('progress',measure);
  document.addEventListener('visibilitychange',function(){measure();if(document.hidden){video.pause();beacon();}});
  document.addEventListener('property:walkthrough-open',function(){video.pause();});
  addEventListener('pagehide',function(){measure();beacon();playing=false;generation++;clearTimeout(deadline);video.pause();video.removeAttribute('src');video.preload='none';video.load();attached=false;failed=false;button.hidden=false;if(film)button.innerHTML=idle;else button.textContent='Play property video ▶';stage.classList.remove('is-playing');status.textContent=film?'':'Select Play to load the property video.';});
})();
`;
