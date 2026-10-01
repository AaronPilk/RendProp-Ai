// Public listings scroll independently of video. Sources attach only after an
// explicit open; closing destroys the decoder and restores the listing position.
export const LISTING_PLAYER_CSS = `
  html { scroll-behavior: auto; }
  .lp-sec, #listing-top { scroll-margin-top: var(--listing-nav-offset,88px); }
  #listing-nav { position:sticky; top:0; z-index:20; background:rgba(11,13,16,.96); border-bottom:1px solid rgba(255,255,255,.1); }
  .listing-nav-inner { max-width:1080px; margin:auto; padding:12px 22px; display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
  #listing-nav a, #listing-nav button { font:inherit; font-size:13px; color:var(--ink); text-decoration:none; border:1px solid rgba(255,255,255,.15); background:transparent; border-radius:999px; padding:10px 14px; min-height:44px; cursor:pointer; }
  #listing-nav .watch-button { background:var(--accent); border-color:var(--accent); color:white; }
  #listing-nav .listing-backtop { margin-left:auto; }
  #listing-nav #share { position:static; display:inline-flex; align-items:center; gap:6px; transform:none; }
  #overview { padding:34px 0 24px; }
  .listing-cover { margin:0 auto 18px; max-width:1036px; border-radius:20px; overflow:hidden; background:var(--card); position:relative; }
  .listing-cover img { width:100%; max-height:440px; object-fit:contain; display:block; }
  .listing-cover-empty { min-height:180px; display:grid; place-items:center; padding:24px; color:var(--ink-dim); }
  .listing-cover-actions { padding:18px; display:flex; align-items:center; gap:12px; flex-wrap:wrap; }
  .listing-cover-actions button { font:inherit; border:0; border-radius:12px; padding:14px 20px; min-height:48px; background:var(--accent); color:#fff; font-weight:700; cursor:pointer; }
  .listing-cover-actions p { font-size:14px; color:var(--ink-dim); }
  .listing-media-label { display:block; padding:0 18px 18px; color:var(--accent-3); font-size:13px; }
  #flythrough-modal { position:fixed; inset:0; margin:auto; width:min(1120px,calc(100vw - 28px)); max-width:none; max-height:calc(100dvh - 28px); padding:0; color:var(--ink); background:var(--bg); border:1px solid rgba(255,255,255,.2); border-radius:20px; overflow:auto; }
  #flythrough-modal::backdrop { background:rgba(0,0,0,.84); }
  #flythrough-modal:not([open]) { display:none; }
  #flythrough-modal .video-head { position:sticky; top:0; z-index:2; display:flex; gap:14px; justify-content:space-between; align-items:center; padding:14px 18px; background:var(--bg); }
  #flythrough-title { font-size:18px; }
  #flythrough-close, .video-action { font:inherit; cursor:pointer; min-height:44px; padding:10px 16px; border:1px solid rgba(255,255,255,.2); border-radius:12px; color:var(--ink); background:var(--card); }
  #flythrough-video { display:block; width:100%; height:auto; max-height:calc(100dvh - 210px); min-height:120px; object-fit:contain; background:#000; }
  .video-foot { padding:14px 18px 20px; display:flex; flex-wrap:wrap; align-items:center; gap:12px; }
  #flythrough-status { flex-basis:100%; font-size:14px; color:var(--ink-dim); }
  #flythrough-quality { font-size:13px; color:var(--ink-dim); }
  #flythrough-chapters { display:flex; overflow-x:auto; gap:8px; padding:0 18px 18px; }
  #flythrough-chapters button { flex-shrink:0; }
  #flythrough-chapters [aria-current=true] { border-color:var(--accent); color:var(--accent-3); }
  .video-disclosure { margin:0 18px 16px; font-size:13px; line-height:1.5; color:var(--accent-3); }
  [hidden] { display:none !important; }
  @media(max-width:600px) { .listing-nav-inner { gap:6px; padding:8px 12px; } #listing-nav a, #listing-nav button { padding:8px 10px; font-size:12px; } .listing-cover { border-radius:0; } #flythrough-modal { width:calc(100vw - 12px); max-height:calc(100dvh - 12px); border-radius:14px; } #flythrough-close { padding:8px 10px; } }
  @media(prefers-reduced-motion:reduce) { * { scroll-behavior:auto !important; } }
`;

export const LISTING_PLAYER_JS = `
(function(){
  'use strict';
  var CFG = window.__CFG__ || {};
  var listingNav = document.getElementById('listing-nav');
  function updateNavOffset(){
    if (listingNav) document.documentElement.style.setProperty('--listing-nav-offset',(Math.ceil(listingNav.getBoundingClientRect().height)+16)+'px');
  }
  updateNavOffset();
  if (listingNav && window.ResizeObserver) new ResizeObserver(updateNavOffset).observe(listingNav);
  addEventListener('resize',updateNavOffset);
  var modal = document.getElementById('flythrough-modal');
  var video = document.getElementById('flythrough-video');
  var status = document.getElementById('flythrough-status');
  var quality = document.getElementById('flythrough-quality');
  var playButton = document.getElementById('flythrough-play');
  var retryButton = document.getElementById('flythrough-retry');
  var closeButton = document.getElementById('flythrough-close');
  var generation = 0, active = false, hls = null, usingHls = false, triedFallback = false;
  var opener = null, savedBody = null, savedScroll = null, inactive = [], pendingSeek = null, lastTime = 0;
  var deadline = null, meterTimer = null, lastWatch = 0, watchMs = 0, sentWatch = 0, maxDepth = 0;
  var viewSent = false, delivered = 0, sentDelivered = 0, sessionBuffered = 0;
  function say(text){ if (status) status.textContent = text; }
  function clamp(v,a,b){ return Math.max(a,Math.min(b,v)); }
  function bufferedSeconds(){
    var total = 0;
    try { for (var i=0;i<video.buffered.length;i++) total += video.buffered.end(i)-video.buffered.start(i); } catch(e){}
    return total;
  }
  function accountBuffer(){
    if (!active) return;
    var total = bufferedSeconds();
    if (total > sessionBuffered){ delivered += total-sessionBuffered; sessionBuffered = total; }
  }
  function watchTick(){
    var now = performance.now();
    if (active && !video.paused && !video.ended && !video.seeking && video.readyState >= 2 && !document.hidden){
      if (lastWatch) watchMs += Math.min(1000,Math.max(0,now-lastWatch));
      if (video.duration > 0) maxDepth = Math.max(maxDepth,clamp(video.currentTime/video.duration,0,1));
    }
    lastWatch = now;
    accountBuffer();
  }
  function postBeacon(extra){
    if (!CFG.functionsBase || !CFG.slug || !viewSent) return;
    accountBuffer();
    var body = {watch_ms:Math.max(0,Math.round(watchMs-sentWatch)),scroll_depth:Math.round(maxDepth*1000)/1000,streamed_minutes:Math.round(Math.max(0,delivered-sentDelivered)/60*1000)/1000};
    sentWatch = watchMs; sentDelivered = delivered;
    if (CFG.unbranded) body.unbranded = true;
    if (extra) Object.keys(extra).forEach(function(k){ body[k]=extra[k]; });
    var url = CFG.functionsBase+'/beacon/'+encodeURIComponent(CFG.slug);
    if (CFG.anonKey) url += '?apikey='+encodeURIComponent(CFG.anonKey);
    var text = JSON.stringify(body);
    try { if (navigator.sendBeacon && navigator.sendBeacon(url,new Blob([text],{type:'text/plain;charset=UTF-8'}))) return; } catch(e){}
    try { fetch(url,{method:'POST',body:text,headers:{'Content-Type':'text/plain'},keepalive:true,mode:'cors',credentials:'omit'}).catch(function(){}); } catch(e){}
  }
  function destroyMedia(){
    clearTimeout(deadline); deadline = null;
    if (hls){ try { hls.destroy(); } catch(e){} hls = null; }
    video.pause(); video.removeAttribute('src'); video.load();
    usingHls = false;
  }
  function closeVideo(noFocus){
    if (!active) return;
    watchTick(); postBeacon(null);
    lastTime = Number(video.currentTime) || 0;
    active = false; ++generation; pendingSeek = null;
    clearInterval(meterTimer); meterTimer = null; lastWatch = 0;
    destroyMedia();
    if (modal.open && typeof modal.close === 'function') modal.close(); else modal.removeAttribute('open');
    inactive.forEach(function(el){ el.inert = false; }); inactive = [];
    if (savedBody){
      document.body.style.overflow=savedBody.overflow; document.body.style.position=savedBody.position;
      document.body.style.top=savedBody.top; document.body.style.width=savedBody.width;
      savedBody = null;
    }
    if (savedScroll) window.scrollTo(savedScroll.x,savedScroll.y);
    if (!noFocus && opener && opener.isConnected) opener.focus({preventScroll:true});
  }
  function play(){
    if (!active) return;
    playButton.hidden = true;
    try {
      var result = video.play(), token = generation;
      if (result && result.catch) result.catch(function(){ if (active && token === generation){ playButton.hidden=false; say('Tap Play to start the fly-through.'); } });
    } catch(e){ playButton.hidden=false; say('Tap Play to start the fly-through.'); }
  }
  function unavailable(){
    if (!active) return;
    ++generation; // invalidate queued play/HLS callbacks for this failed source
    clearTimeout(deadline); deadline = null;
    say('The video could not load. You can retry or return to the listing.');
    retryButton.hidden = false; playButton.hidden = true;
    if (hls){ try { hls.destroy(); } catch(e){} hls=null; }
    video.pause(); video.removeAttribute('src'); video.load();
  }
  function attachDirect(url){
    if (!active) return;
    video.preload='auto'; video.src=url; video.load(); play();
  }
  function attachHls(url,token){
    if (!active || token !== generation) return;
    usingHls = true;
    if (video.canPlayType('application/vnd.apple.mpegurl') || video.canPlayType('application/x-mpegURL')){ attachDirect(url); return; }
    function attach(){
      if (!active || token !== generation) return;
      if (!window.Hls || !window.Hls.isSupported()){ unavailable(); return; }
      hls = new window.Hls({maxBufferLength:30,maxMaxBufferLength:60,backBufferLength:30,capLevelToPlayerSize:false,lowLatencyMode:false,enableWorker:true});
      var instance = hls;
      instance.on(window.Hls.Events.ERROR,function(evt,data){ if (active && token===generation && data && data.fatal) unavailable(); });
      instance.loadSource(url); instance.attachMedia(video); play();
    }
    if (window.Hls){ attach(); return; }
    var script = document.createElement('script'); script.src=CFG.hlsSrc;
    if (CFG.hlsSri){ script.integrity=CFG.hlsSri; script.crossOrigin='anonymous'; }
    script.onload=attach; script.onerror=function(){ if (active && token===generation) unavailable(); };
    document.head.appendChild(script);
  }
  function startSource(){
    var token = ++generation;
    triedFallback = false; retryButton.hidden=true; playButton.hidden=true;
    say('Loading fly-through…'); quality.textContent='';
    clearTimeout(deadline);
    deadline = setTimeout(function(){ if (active && token===generation && video.readyState<2) unavailable(); },25000);
    // The R2 master is not re-encoded or resolution-capped in the browser.
    // Existing low-resolution masters still require a new owner-published render.
    if (CFG.scrubUrl) attachDirect(CFG.scrubUrl);
    else if (CFG.hlsUrl) attachHls(CFG.hlsUrl,token);
    else unavailable();
  }
  function openVideo(button,time){
    if (!modal || !video || (!CFG.scrubUrl && !CFG.hlsUrl)) return;
    pendingSeek = typeof time === 'number' && isFinite(time) ? Math.max(0,time) : lastTime;
    if (active){ seekPending(); play(); return; }
    opener = button; savedScroll = {x:scrollX,y:scrollY};
    savedBody = {overflow:document.body.style.overflow,position:document.body.style.position,top:document.body.style.top,width:document.body.style.width};
    if (typeof modal.showModal === 'function') modal.showModal(); else modal.setAttribute('open','');
    inactive = Array.prototype.filter.call(document.body.children,function(el){ return el !== modal && !el.inert; });
    inactive.forEach(function(el){ el.inert=true; });
    document.body.style.overflow='hidden'; document.body.style.position='fixed';
    document.body.style.top=-savedScroll.y+'px'; document.body.style.width='100%';
    active=true; sessionBuffered=0; lastWatch=performance.now();
    closeButton.focus({preventScroll:true});
    meterTimer=setInterval(watchTick,250);
    startSource();
  }
  function seekPending(){
    if (!active || pendingSeek===null || video.readyState<1 || !isFinite(video.duration) || video.duration<=0) return;
    try { video.currentTime=clamp(pendingSeek,0,Math.max(0,video.duration-.01)); pendingSeek=null; } catch(e){}
  }
  document.querySelectorAll('[data-open-flythrough]').forEach(function(button){ button.addEventListener('click',function(){ openVideo(button); }); });
  document.querySelectorAll('[data-seek],[data-video-seek]').forEach(function(button){
    button.addEventListener('click',function(){ var time=Number(button.getAttribute('data-video-seek') || button.getAttribute('data-seek')); openVideo(button,isFinite(time)?time:0); });
  });
  if (closeButton) closeButton.addEventListener('click',function(){ closeVideo(false); });
  if (modal){
    modal.addEventListener('cancel',function(ev){ ev.preventDefault(); closeVideo(false); });
    // close() queues an event. A visitor may reopen before that old event runs.
    modal.addEventListener('close',function(){ if (active && !modal.open) closeVideo(false); });
    modal.addEventListener('keydown',function(ev){
      if (ev.key==='Escape'){ ev.preventDefault(); closeVideo(false); }
      // Native dialogs trap focus. This also protects the non-native fallback.
      if (ev.key!=='Tab') return;
      var buttons=Array.prototype.filter.call(modal.querySelectorAll('button,video[controls],a[href],[tabindex]'),function(el){ return !el.hidden && !el.disabled && el.getClientRects().length; });
      if (!buttons.length) return;
      var first=buttons[0],last=buttons[buttons.length-1];
      if (ev.shiftKey && document.activeElement===first){ ev.preventDefault(); last.focus(); }
      else if (!ev.shiftKey && document.activeElement===last){ ev.preventDefault(); first.focus(); }
    });
  }
  if (playButton) playButton.addEventListener('click',play);
  if (retryButton) retryButton.addEventListener('click',function(){ destroyMedia(); sessionBuffered=0; startSource(); });
  if (video){
    function updateQuality(){
      if (!active) return;
      quality.textContent=(video.videoWidth && video.videoHeight ? video.videoWidth+' × '+video.videoHeight+' · ' : '')+(usingHls?'Streaming':'Published master');
    }
    video.addEventListener('loadedmetadata',function(){
      if (!active) return;
      seekPending(); updateQuality();
    });
    video.addEventListener('resize',updateQuality);
    video.addEventListener('loadeddata',function(){
      if (!active || retryButton.hidden===false || video.readyState<2) return;
      clearTimeout(deadline); deadline=null; say('Use the playback controls or choose a room below.');
    });
    video.addEventListener('playing',function(){
      if (!active) return;
      playButton.hidden=true; say('Use the playback controls or choose a room below.');
      if (!viewSent && video.readyState>=2){ viewSent=true; postBeacon({view_start:true}); }
    });
    video.addEventListener('waiting',function(){ if (active && retryButton.hidden) say('Buffering video… You can return to the listing at any time.'); });
    video.addEventListener('progress',accountBuffer);
    video.addEventListener('timeupdate',function(){
      if (!active) return;
      var activeTime=-1;
      document.querySelectorAll('[data-video-seek]').forEach(function(button){ var t=Number(button.getAttribute('data-video-seek')); if (t<=video.currentTime && t>activeTime) activeTime=t; });
      document.querySelectorAll('[data-video-seek]').forEach(function(button){ if (Number(button.getAttribute('data-video-seek'))===activeTime) button.setAttribute('aria-current','true'); else button.removeAttribute('aria-current'); });
    });
    video.addEventListener('error',function(){
      if (!active || !video.error) return;
      if (!usingHls && CFG.hlsUrl && !triedFallback){
        triedFallback=true; sessionBuffered=0; say('Opening the streaming version…'); attachHls(CFG.hlsUrl,generation); return;
      }
      unavailable();
    });
  }
  setInterval(function(){ if (active && viewSent && !document.hidden) postBeacon(null); },20000);
  document.addEventListener('visibilitychange',function(){ if (document.hidden && active){ watchTick(); video.pause(); postBeacon(null); } });
  addEventListener('pagehide',function(){ closeVideo(true); });

  // Spatial rooms remain separate media viewers; returning does not start a
  // hidden video download. The listing stays at the user's original position.
  var spatialOpen=false,spatialToken=0;
  document.querySelectorAll('[data-spatial-scene]').forEach(function(button){
    button.addEventListener('click',function(){
      if (spatialOpen) return;
      if (active) closeVideo(true);
      spatialOpen=true; var token=++spatialToken, x=scrollX,y=scrollY, overflow=document.body.style.overflow;
      document.body.style.overflow='hidden';
      var host=document.createElement('div'); document.body.appendChild(host);
      var siblings=Array.prototype.filter.call(document.body.children,function(el){ return el!==host && !el.inert; });
      siblings.forEach(function(el){ el.inert=true; });
      var instance=null;
      function close(){
        if (!spatialOpen || token!==spatialToken) return;
        if (instance) instance.destroy(); host.remove(); spatialOpen=false; ++spatialToken;
        siblings.forEach(function(el){ el.inert=false; }); document.body.style.overflow=overflow;
        window.scrollTo(x,y);
        var focus=button.closest('#flythrough-modal') ? document.getElementById('open-flythrough') : button;
        if (focus) focus.focus({preventScroll:true});
      }
      host.innerHTML='<div style="position:fixed;inset:0;z-index:10000;background:#0e0d14;color:white;padding:24px"><p role="status">Opening 3D room…</p><button type="button">Back to listing</button></div>';
      host.querySelector('button').addEventListener('click',close);
      import('/spatial-viewer.js').then(function(module){ if (spatialOpen && token===spatialToken) instance=module.mountSpatial(host,{sceneId:button.dataset.spatialScene,roomId:button.dataset.spatialRoom,onClose:close}); })
        .catch(function(){ if (spatialOpen && token===spatialToken) host.querySelector('[role=status]').textContent='3D could not load. Return to the listing and retry.'; });
    });
  });

  /*__EDITORIAL__*/
  /*__LEADFORM__*/
  /* ---- Staged disclosure toggle ---- */
  /*__APPLINK__*/
  /*__SHARE__*/
})();
`;
