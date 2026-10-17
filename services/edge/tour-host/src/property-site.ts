// The PILK single-property template's editorial layout, using only the
// published listing's data. No template sample facts, tracking tags or fonts.
export type PropertyPage = "home" | "gallery" | "location" | "contact";

export function propertyPage(value: unknown): PropertyPage {
  return value === "gallery" || value === "location" || value === "contact" ? value : "home";
}

export function propertyPageHref(slug: string, page: PropertyPage, publicBase: "/f" | "/property" = "/f", previewTheme?: import("./property-design").WebsiteTheme | null, addressPath?: string): string {
  const base = addressPath || `${publicBase}/${encodeURIComponent(slug)}`;
  const params = new URLSearchParams();
  if (page !== "home") params.set("page", page);
  if (previewTheme) params.set("preview_theme", previewTheme);
  return params.size ? `${base}?${params}` : base;
}

export const PROPERTY_SITE_CSS = `
  .property-site .property-skip-link { position:fixed; z-index:1000; top:0; left:max(8px,env(safe-area-inset-left)); transform:translateY(-200%); display:inline-flex; align-items:center; min-height:44px; max-width:calc(100vw - 32px); padding:10px 16px; border:2px solid currentColor; border-radius:4px; background:#fff; color:#17171c; font-size:14px; font-weight:700; line-height:1.4; text-decoration:underline; }
  .property-site .property-skip-link:focus { top:max(8px,env(safe-area-inset-top)); transform:none; outline:3px solid currentColor; outline-offset:3px; }
  .property-site #property-content { scroll-margin-top:var(--listing-nav-offset,9rem); }
  body.property-site { --bg:#f7f5f1; --ink:#17171c; --ink-dim:#62616b; --faint:#6a6872; --card:#fff;
    --accent-3:#6b3bb4; --accent-soft:rgba(124,58,237,.07); --grad-text:linear-gradient(#17171c,#17171c);
    line-height:1.65; background:var(--bg); }
  .property-site .lp-wrap { max-width:1200px; padding:0 40px; }
  .property-site #listing-nav { background:rgba(18,16,24,.96); color:#fff; border-color:rgba(255,255,255,.12); backdrop-filter:blur(16px); -webkit-backdrop-filter:blur(16px); }
  .property-site .listing-nav-inner { max-width:1200px; padding:14px 40px; }
  .property-site #listing-nav a,.property-site #listing-nav button { color:#fff; font-size:12px; letter-spacing:.09em; border-radius:4px; }
  .property-site #listing-nav .listing-nav-links a { border-color:transparent; }
  .property-site #listing-nav .listing-nav-links a[aria-current=page] { color:#decaff; border-bottom-color:#b794ff; }
  .property-site .listing-nav-actions .watch-button { background:transparent; border-color:#b794ff; }
  .property-site .listing-cover { max-width:1200px; margin:0 auto; border-radius:0; min-height:360px; background:#17171c; color:white; }
  .property-site .listing-cover > img { width:100%; height:clamp(400px,70vh,760px); max-height:none; object-fit:cover; }
  .property-site .listing-cover::after { content:""; position:absolute; inset:0; pointer-events:none; background:linear-gradient(0deg,rgba(10,10,14,.78),rgba(10,10,14,.08) 75%); }
  .property-site .property-hero-copy { position:absolute; z-index:1; inset:auto 0 0; padding:clamp(26px,5vw,60px); max-width:900px; }
  .property-site .property-hero-copy .lp-eyebrow { color:#e6d5ff; }
  .property-site .property-hero-title { font:400 clamp(34px,5vw,68px)/1.05 Georgia,"Times New Roman",serif; text-wrap:balance; overflow-wrap:anywhere; }
  .property-site .property-hero-price { margin-top:14px; font-size:22px; }
  .property-site .listing-cover-actions { padding:0; gap:12px; margin-top:26px; }
  .property-site .listing-cover-actions button,.property-site .property-hero-link { display:inline-flex; justify-content:center; align-items:center; min-height:48px; padding:13px 20px; border:1px solid rgba(255,255,255,.65); border-radius:4px; background:#fff; color:#221331; font-family:inherit; font-weight:600; font-size:13px; line-height:1.35; text-decoration:none; }
  .property-site .property-hero-link { color:#fff; background:transparent; }
  .property-site .listing-cover-actions p { color:rgba(255,255,255,.84); font-size:12px; flex-basis:100%; }
  .property-site .listing-media-label { padding:0; margin-top:18px; color:#f1e5ff; font-size:12px; }
  .property-site .listing-media-label a { color:inherit; text-underline-offset:3px; }
  .property-site #overview { padding:54px 0; }
  .property-site .lp-lead { background:none; }
  .property-site .lp-sec { border-color:rgba(23,23,28,.1); padding:clamp(42px,7vw,84px) 0; }
  .property-site .lp-h,.property-site .property-page-head h1 { font-family:Georgia,"Times New Roman",serif; font-weight:400; letter-spacing:-.035em; line-height:1.12; }
  .property-site .lp-h { font-size:clamp(30px,4vw,46px); }
  .property-site .lp-eyebrow { font-size:10px; letter-spacing:.2em; }
  .property-site .lp-price { color:var(--ink); background:none; -webkit-text-fill-color:currentColor; font-weight:500; }
  .property-site .lp-stats { gap:0; border-top:1px solid rgba(23,23,28,.12); border-bottom:1px solid rgba(23,23,28,.12); }
  .property-site .lp-stat { background:none; border:0; border-radius:0; padding:24px 12px; }
  .property-site .lp-stat .v { font:400 30px/1.2 Georgia,"Times New Roman",serif; }
  .property-site .lp-stat .k { font-size:10px; }
  .property-site .lp-prose p { font-size:16px; max-width:58em; }
  .property-site .lp-gal { grid-template-columns:repeat(3,minmax(0,1fr)); gap:20px; }
  .property-site .lp-gcell { aspect-ratio:auto; background:#fff; border:0; border-radius:4px; }
  .property-site .lp-gcell img { aspect-ratio:4/3; object-fit:cover; height:auto; }
  .property-site .property-photo { display:block; cursor:zoom-in; color:inherit; }
  .property-site .lp-gcell figcaption { position:static; color:var(--ink-dim); background:none; font-size:12px; padding:10px 0; font-weight:400; }
  .property-site .lp-mediadate { grid-column:1/-1; }
  .property-site .lp-btn { border-radius:4px; background:#231631; box-shadow:none; font-size:13px; letter-spacing:.04em; }
  .property-site .lp-btn:hover { box-shadow:none; }
  .property-site .lp-btn.ghost,.property-site .lp-btn-ghost { color:#4b2b72; background:none; border:1px solid #a18ab7; }
  .property-site .lp-fact,.property-site .lp-level,.property-site .disc-item,.property-site .disc-sum { border-color:rgba(23,23,28,.12); border-radius:8px; }
  .property-site .property-page-head { background:#17131f; color:white; padding:56px 0; }
  .property-site .property-page-head .lp-eyebrow { color:#d4baff; }
  .property-site .property-page-head h1 { font-size:clamp(36px,5vw,60px); }
  .property-site .property-page-head p { margin-top:14px; color:#d1cdd8; overflow-wrap:anywhere; }
  .property-site .property-location-card { display:grid; grid-template-columns:1.4fr 1fr; border:1px solid rgba(23,23,28,.12); border-radius:8px; overflow:hidden; margin-top:28px; background:white; }
  .property-site .property-location-copy { padding:30px; }
  .property-site .property-location-copy address { font:400 26px/1.4 Georgia,"Times New Roman",serif; overflow-wrap:anywhere; }
  .property-site .property-location-visual { min-height:230px; display:grid; place-items:center; padding:30px; background-color:#eee9f1; background-image:linear-gradient(45deg,transparent 48%,rgba(112,91,134,.08) 49%,rgba(112,91,134,.08) 51%,transparent 52%),linear-gradient(-45deg,transparent 48%,rgba(112,91,134,.08) 49%,rgba(112,91,134,.08) 51%,transparent 52%); background-size:42px 42px; }
  .property-site .property-location-visual span { display:grid; place-items:center; width:62px; height:62px; background:#6b3bb4; color:#fff; border-radius:50%; font-size:30px; }
  .property-site .property-nearby-list { list-style:none; display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:14px; margin-top:24px; }
  .property-site .property-nearby-list li { padding:20px; border:1px solid rgba(23,23,28,.12); background:#fff; border-radius:6px; }
  .property-site .property-nearby-list a { display:block; color:#38224e; font-weight:600; overflow-wrap:anywhere; }
  .property-site .property-nearby-list span { display:block; color:var(--ink-dim); font-size:12px; margin-top:8px; }
  .property-site #endcard { padding:60px 0; }
  .property-site #endcard .panel { max-width:1120px; padding:32px; border:1px solid rgba(23,23,28,.12); background:#fff; border-radius:8px; }
  .property-site .panel h2 { font:400 30px/1.2 Georgia,"Times New Roman",serif; margin-top:20px; }
  .property-site .agent { border-bottom:1px solid rgba(23,23,28,.1); padding-bottom:24px; margin-bottom:24px; }
  .property-site .agent .avatar { width:72px; height:72px; background:#eee9f1; }
  .property-site .agent .who .nm { font-size:20px; }
  .property-site .agent .who .bk { font-size:13px; }
  .property-site .agent .who .bk a { display:inline-flex; align-items:center; min-height:44px; min-width:44px; }
  .property-site .field input,.property-site .field textarea { background:#faf9f7; color:#17171c; border-color:#cfcbd3; border-radius:4px; font-size:16px; }
  .property-site .field .err { color:#9d2020; }
  .property-site .formmsg { color:#862020; background:#fff0f0; }
  .property-site .privacy,.property-site .privacy a,.property-site .disclosure { color:#62616b; }
  .property-site .cta { background:#231631; border-radius:4px; }
  .property-site .lp-foot { border-color:rgba(23,23,28,.12); }
  .property-site .lp-partner { border-color:rgba(23,23,28,.12); border-radius:8px; }
  .property-site #flythrough-modal { --bg:#111018; --ink:#f2f3f5; --ink-dim:#c0bdc7; --card:#24212c; --accent-3:#d4baff; }
  .property-site #flythrough-modal button { line-height:1.3; }
  .property-site #property-photo-modal { position:fixed; inset:0; margin:auto; width:min(1280px,calc(100vw - 24px)); max-width:none; max-height:calc(100dvh - 24px); padding:16px; border:1px solid #55515b; border-radius:10px; background:#111018; color:#fff; }
  .property-site #property-photo-modal::backdrop { background:rgba(0,0,0,.86); }
  .property-site #property-photo-modal:not([open]) { display:none; }
  .property-site .property-photo-head { display:flex; justify-content:space-between; align-items:center; gap:12px; }
  .property-site #property-photo-close { min-height:44px; padding:10px 16px; background:#24212c; color:#fff; border:1px solid #655d70; border-radius:4px; cursor:pointer; }
  .property-site #property-photo-full { display:block; width:100%; height:auto; max-height:calc(100dvh - 220px); object-fit:contain; margin:14px 0 8px; touch-action:pan-y pinch-zoom; }
  .property-site #property-photo-modal[aria-busy=true] #property-photo-full { opacity:.35; }
  .property-site #property-photo-status { min-height:1.5em; margin:0 0 8px; color:#d1cdd8; font-size:13px; }
  .property-site .property-photo-nav { display:flex; align-items:center; justify-content:space-between; gap:12px; margin-bottom:10px; }
  .property-site .property-photo-nav[hidden] { display:none; }
  .property-site .property-photo-nav button { min-height:44px; min-width:44px; padding:10px 16px; background:#24212c; color:#fff; border:1px solid #655d70; border-radius:4px; font:inherit; font-size:14px; cursor:pointer; }
  .property-site .property-photo-nav button:disabled { opacity:.4; cursor:default; }
  .property-site #property-photo-count { color:#d1cdd8; font-size:13px; font-variant-numeric:tabular-nums; }
  .property-site #property-photo-modal a { color:#d4baff; }
  .property-site #property-photo-modal .property-photo-all { display:inline-block; margin-right:18px; }
  /* WCAG AA text contrast on the shared contact card, form and attribution. */
  .property-site .agent .avatar { color:var(--accent-3); }
  .property-site .agent .social a { color:var(--accent-3); display:inline-flex; align-items:center; justify-content:center; min-height:44px; min-width:44px; }
  .property-site .field .lbl .opt { opacity:1; }
  .property-site .lp-fine a { color:var(--accent-3); }
  .property-site .property-location-visual svg { display:block; width:30px; height:30px; }
  .property-site #listing-nav .nav-short { display:none; }
  .property-site a:focus-visible,.property-site button:focus-visible { outline:3px solid #a878e8; outline-offset:4px; }
  @media(min-width:760px) { .property-site #leadform { display:grid; grid-template-columns:1fr 1fr; column-gap:22px; } .property-site #leadform > h2,.property-site #leadform > .sub,.property-site #leadform > .privacy,.property-site #leadform > .formmsg,.property-site #leadform > button,.property-site #leadform > .cf-turnstile { grid-column:1/-1; } }
  @media(max-width:759px) { .property-site .lp-wrap { padding:0 22px; } .property-site .lp-gal,.property-site .property-nearby-list { grid-template-columns:repeat(2,minmax(0,1fr)); gap:12px; } .property-site .property-location-card { grid-template-columns:1fr; } .property-site .property-location-visual { min-height:150px; } .property-site #endcard { padding:36px 16px; } .property-site #endcard .panel { padding:22px; } }
  @media(max-width:600px) { .property-site #listing-nav .nav-full { position:absolute; width:1px; height:1px; overflow:hidden; clip:rect(0 0 0 0); clip-path:inset(50%); white-space:nowrap; } .property-site #listing-nav .nav-short { display:inline; } .property-site #listing-nav .property-primary-play,.property-site #listing-nav .walkthrough-secondary { padding-left:4px; padding-right:4px; } .property-site .listing-nav-inner { padding:8px 12px; gap:6px; } .property-site #listing-nav a,.property-site #listing-nav button { font-size:12px; letter-spacing:0; } .property-site .listing-cover > img { height:580px; max-height:80svh; min-height:430px; } .property-site .property-hero-copy { padding:26px 22px; } .property-site .property-hero-title { font-size:36px; } }
`;

// Load gallery photos near the viewport rather than the browser's much wider
// native lazy-load window. Anchors/lightbox still use the exact published master,
// and noscript markup preserves photos when JavaScript is unavailable.
export const PROPERTY_SITE_JS = `
  var propertyThumbs=document.querySelectorAll('img[data-property-src]');
  function loadPropertyThumb(image){
    var source=image.getAttribute('data-property-src');
    if (!source) return;
    // A thumbnail service outage must not hide the published photo. Retry only
    // the exact master already admitted for this link; never loop on failure.
    image.addEventListener('error',function(){
      var link=image.closest('[data-property-photo]');
      if(link && image.src!==link.href) image.src=link.href;
    },{once:true});
    image.loading='eager'; image.src=source; image.removeAttribute('data-property-src');
  }
  if (typeof IntersectionObserver==='function'){
    var propertyPhotoObserver=new IntersectionObserver(function(entries){
      entries.forEach(function(entry){if(entry.isIntersecting){loadPropertyThumb(entry.target);propertyPhotoObserver.unobserve(entry.target);}});
    },{rootMargin:'160px 0px'});
    propertyThumbs.forEach(function(image){propertyPhotoObserver.observe(image);});
  }else{propertyThumbs.forEach(loadPropertyThumb);}
  // One full-size viewer for the photos on this page: previous/next buttons,
  // arrow keys and a horizontal swipe move through the exact published files.
  // Only the photo being viewed is requested; closing unloads it.
  var photoModal=document.getElementById('property-photo-modal');
  var photoFull=document.getElementById('property-photo-full');
  var photoStatus=document.getElementById('property-photo-status');
  var photoCount=document.getElementById('property-photo-count');
  var photoPrev=document.getElementById('property-photo-prev'), photoNext=document.getElementById('property-photo-next');
  var photoNav=null, photoLinks=[], photoIndex=-1, swipeStart=null;
  function photoMessage(text){if(photoStatus)photoStatus.textContent=text;}
  function showPropertyPhoto(index){
    if (index<0 || index>=photoLinks.length) return;
    photoIndex=index; var link=photoLinks[index], thumb=link.querySelector('img');
    photoFull.alt=thumb ? thumb.alt : '';
    document.getElementById('property-photo-title').textContent=photoFull.alt || 'Property photo';
    if (photoCount) photoCount.textContent=(index+1)+' of '+photoLinks.length;
    if (photoNav) photoNav.hidden=photoLinks.length<2;
    if (photoPrev) photoPrev.disabled=index===0;
    if (photoNext) photoNext.disabled=index===photoLinks.length-1;
    photoModal.setAttribute('aria-busy','true'); photoMessage('Loading the full-size photo…');
    photoFull.src=link.href;
  }
  function closePropertyPhoto(){
    if (!photoModal || !photoModal.open) return;
    var opener=photoLinks[photoIndex];
    photoModal.close(); photoFull.removeAttribute('src'); photoModal.removeAttribute('aria-busy'); photoMessage('');
    if (opener && opener.isConnected) opener.focus({preventScroll:true});
    photoIndex=-1;
  }
  function stepPropertyPhoto(delta){
    var target=photoIndex+delta;
    if (target<0 || target>=photoLinks.length) return;
    showPropertyPhoto(target);
    var focusTarget=delta<0 ? photoPrev : photoNext;
    if (focusTarget && focusTarget.disabled) (delta<0 ? photoNext : photoPrev).focus();
  }
  if (photoModal && typeof photoModal.showModal==='function'){
    photoNav=photoModal.querySelector('.property-photo-nav');
    photoLinks=Array.prototype.slice.call(document.querySelectorAll('[data-property-photo]'));
    photoLinks.forEach(function(link,index){
      link.addEventListener('click',function(event){
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        event.preventDefault(); showPropertyPhoto(index);
        photoModal.showModal(); document.getElementById('property-photo-close').focus();
      });
    });
    photoFull.addEventListener('load',function(){
      if (photoIndex<0 || photoFull.src!==photoLinks[photoIndex].href) return;
      photoModal.removeAttribute('aria-busy'); photoMessage('');
    });
    photoFull.addEventListener('error',function(){
      if (photoIndex<0 || !photoFull.getAttribute('src') || photoFull.src!==photoLinks[photoIndex].href) return;
      photoModal.removeAttribute('aria-busy'); photoMessage('This photo could not load. Check your connection, then choose it again.');
    });
    if (photoPrev) photoPrev.addEventListener('click',function(){stepPropertyPhoto(-1);});
    if (photoNext) photoNext.addEventListener('click',function(){stepPropertyPhoto(1);});
    photoModal.addEventListener('keydown',function(event){
      if (event.key==='ArrowLeft'){event.preventDefault();stepPropertyPhoto(-1);}
      else if (event.key==='ArrowRight'){event.preventDefault();stepPropertyPhoto(1);}
    });
    photoFull.addEventListener('pointerdown',function(event){
      swipeStart=event.pointerType==='mouse' ? null : {x:event.clientX,y:event.clientY,id:event.pointerId};
    });
    photoFull.addEventListener('pointerup',function(event){
      var start=swipeStart; swipeStart=null;
      if (!start || start.id!==event.pointerId) return;
      var dx=event.clientX-start.x, dy=event.clientY-start.y;
      if (Math.abs(dx)>=48 && Math.abs(dx)>Math.abs(dy)*1.5) stepPropertyPhoto(dx<0 ? 1 : -1);
    });
    photoFull.addEventListener('pointercancel',function(){swipeStart=null;});
    document.getElementById('property-photo-close').addEventListener('click',closePropertyPhoto);
    photoModal.addEventListener('cancel',function(event){event.preventDefault();closePropertyPhoto();});
    photoModal.addEventListener('close',function(){if(!photoModal.open)photoFull.removeAttribute('src');});
  }
`;

export const NEARBY_PLACES_JS = `
(function(){
  var panel=document.getElementById('property-nearby');
  if (!panel) return;
  var status=document.getElementById('property-nearby-status'), list=document.getElementById('property-nearby-list');
  var controller=new AbortController(), deadline=setTimeout(function(){controller.abort();},9000);
  addEventListener('pagehide',function(){controller.abort();},{once:true});
  function unavailable(){status.textContent='Nearby places are unavailable right now. Open the map above to explore the area.';}
  fetch(panel.getAttribute('data-endpoint'),{credentials:'omit',cache:'no-store',signal:controller.signal})
    .then(function(response){if(!response.ok)throw new Error('unavailable');return response.json();})
    .then(function(result){
      if (!panel.isConnected || controller.signal.aborted) return;
      if (!result || ['available','empty'].indexOf(result.status)<0 || !Array.isArray(result.places)){unavailable();return;}
      var places=result.places.slice(0,12).filter(function(place){
        if (!place || typeof place.name!=='string' || !place.name.trim() || ['Restaurant','Cafe','Shop'].indexOf(place.category)<0 || !Number.isFinite(place.distance_m) || place.distance_m<0 || place.distance_m>5000) return false;
        try {var url=new URL(place.source_url), parts=url.pathname.split('/');return url.origin==='https://www.openstreetmap.org' && !url.search && !url.hash && parts.length===3 && ['node','way','relation'].indexOf(parts[1])>=0 && /^[0-9]+$/.test(parts[2]);}catch(error){return false;}
      });
      if (!places.length){status.textContent='No nearby places are listed in the available map data. Open the map above to explore the area.';return;}
      places.forEach(function(place){
        var item=document.createElement('li'), link=document.createElement('a'), note=document.createElement('span');
        link.href=place.source_url; link.target='_blank'; link.rel='noopener nofollow'; link.textContent=place.name;
        note.textContent=place.category+' · approximately '+(place.distance_m/1609.344).toFixed(1)+' mi away';
        item.appendChild(link);item.appendChild(note);list.appendChild(item);
      });
      list.hidden=false;status.textContent='Restaurants, cafés and shops listed in OpenStreetMap. Confirm current details before visiting.';
    }).catch(function(){if(panel.isConnected)unavailable();}).finally(function(){clearTimeout(deadline);});
})();
`;
