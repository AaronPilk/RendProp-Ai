/** Emitted as a lazy ES module. Only invoked after a viewer requests a room. */
export const SPATIAL_RUNTIME = String.raw`
const ENGINE_URL = 'https://cdn.jsdelivr.net/npm/playcanvas@2.22.1/build/playcanvas.min.js';
const ENGINE_SRI = 'sha384-2sYsYZfrbYhDV41s7X2ecMMRNZ8xTYBbSZcu3t9x0fpAFoqDtCQVeQtiq+mx0Fwz';
let engineLoad;
function engine() {
  if (window.pc) return window.pc.version === '2.22.1' ? Promise.resolve(window.pc) : Promise.reject(new Error('Unsupported 3D engine'));
  if (!engineLoad) engineLoad = new Promise((resolve, reject) => {
    const script = document.createElement('script');
    const timer = setTimeout(() => { script.remove(); reject(new Error('3D engine download timed out. Please retry.')); }, 15000);
    script.src = ENGINE_URL; script.integrity = ENGINE_SRI; script.crossOrigin = 'anonymous'; script.referrerPolicy = 'no-referrer';
    script.onload = () => { clearTimeout(timer); window.pc?.version === '2.22.1' ? resolve(window.pc) : reject(new Error('3D engine unavailable')); };
    script.onerror = () => { clearTimeout(timer); script.remove(); reject(new Error('3D engine download failed. Please retry.')); };
    document.head.appendChild(script);
  }).catch((error) => { engineLoad = null; throw error; });
  return engineLoad;
}
export function mountSpatial(host, options) {
  if (!/^[0-9a-f-]{36}$/i.test(options.sceneId || '')) throw new Error('Invalid scene');
  options = {...options, sceneId:options.sceneId.toLowerCase()};
  let disposed = false, app, camera, asset, splat, manifest, yaw = 0, pitch = 0, top = false;
  let drag = null, joystick = null, vector = [0, 0], ready = false, loadTimer;
  let rendered = false, stopFrameWatch = () => {};
  const lifecycle = new AbortController(), transfer = new AbortController(), held = new Set();
  const listeners = { signal: lifecycle.signal };
  host.innerHTML = '<section class="spatial-view" aria-label="3D room viewer"><style>' +
    '.spatial-view{position:fixed;inset:0;background:#0e0d14;color:#f2f0fa;z-index:10000;font:15px/1.4 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;overflow:hidden}.spatial-view *{box-sizing:border-box}.spatial-canvas{width:100%;height:100%;touch-action:none;display:block}.spatial-tools{position:absolute;top:max(12px,env(safe-area-inset-top));left:12px;right:12px;display:flex;flex-wrap:wrap;gap:8px;align-items:center}.spatial-view button{font:inherit;min-height:44px;min-width:44px;border-radius:12px;padding:10px 14px;border:1px solid #756d88;background:#231d31;color:#fff;cursor:pointer}.spatial-view button:focus-visible,.spatial-canvas:focus-visible{outline:3px solid #c7a4ff;outline-offset:2px}.spatial-view button:disabled{opacity:.5;cursor:default}.spatial-view button[aria-pressed=true]{background:#7c3aed}.spatial-rooms{display:flex;gap:8px;overflow:auto;max-width:100%;flex-basis:100%}.spatial-rooms button{white-space:nowrap}.spatial-bottom{position:absolute;left:12px;right:12px;bottom:max(14px,env(safe-area-inset-bottom));display:flex;align-items:flex-end;gap:16px}.spatial-status{background:rgba(14,13,20,.92);padding:12px;border-radius:12px;max-width:560px;margin:0}.spatial-pad{width:106px;height:106px;flex-shrink:0;border:2px solid #b997fb;border-radius:50%;position:relative;background:rgba(60,35,94,.88);touch-action:none}.spatial-thumb{position:absolute;left:32px;top:32px;width:38px;height:38px;border-radius:50%;background:#b997fb;pointer-events:none}.spatial-arrows{display:flex;flex-wrap:wrap;gap:4px;max-width:160px}.spatial-arrows button{padding:6px}.spatial-nav{display:flex;align-items:center;gap:8px}.spatial-note{font-size:12px;opacity:.9;display:block}.spatial-error{color:#ffd6db}@media(max-width:540px){.spatial-bottom{flex-wrap:wrap;gap:8px}.spatial-status{order:-1;flex-basis:100%;font-size:13px;padding:8px}.spatial-tools{gap:6px}.spatial-view button{padding:8px 10px}.spatial-nav{width:100%;justify-content:space-between}}' +
    '</style><canvas class="spatial-canvas" tabindex="0" aria-label="3D room. Drag to look; use movement controls or W A S D to walk."></canvas><div class="spatial-tools"><button type="button" data-action="close">Close 3D</button><button type="button" data-action="reset" disabled>Starting view</button><button type="button" data-action="top" aria-pressed="false" disabled>Top-down</button><div class="spatial-rooms" aria-label="Rooms"></div></div><div class="spatial-bottom"><nav class="spatial-nav" aria-label="Walk through room"><div class="spatial-pad" aria-label="Drag to move" role="img"><span class="spatial-thumb"></span></div><div class="spatial-arrows"><button type="button" data-move="forward" disabled>Forward</button><button type="button" data-move="back" disabled>Back</button><button type="button" data-move="left" disabled>Left</button><button type="button" data-move="right" disabled>Right</button></div></nav><p class="spatial-status" role="status">Loading room…</p></div></section>';
  const root = host.firstElementChild, canvas = root.querySelector('canvas'), status = root.querySelector('[role=status]');
  root.setAttribute('role', 'dialog'); root.setAttribute('aria-modal', 'true');
  const rooms = root.querySelector('.spatial-rooms'), pad = root.querySelector('.spatial-pad'), thumb = root.querySelector('.spatial-thumb');
  function say(text, error = false) { status.textContent = text; status.classList.toggle('spatial-error', error); }
  function clearMove() { held.clear(); vector = [0, 0]; joystick = drag = null; thumb.style.transform = ''; }
  function releaseGraphics() {
    stopFrameWatch();
    ready = false; clearMove();
    if (splat) { splat.destroy(); splat = null; }
    if (asset && app) { asset.unload(); app.assets.remove(asset); asset = null; }
    if (app) { app.destroy(); app = null; }
  }
  function destroy() {
    if (disposed) return;
    disposed = true; clearTimeout(loadTimer); transfer.abort(); lifecycle.abort(); observer.disconnect();
    releaseGraphics(); root.remove();
  }
  function close() {
    destroy(); if (options.onClose) options.onClose(); else host.textContent = '3D viewer closed. Return to the app to reopen it.';
  }
  root.querySelector('[data-action=close]').addEventListener('click', close, listeners);
  root.querySelector('[data-action=close]').focus({preventScroll:true});
  root.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') { event.preventDefault(); close(); return; }
    if (event.key !== 'Tab') return;
    const focusable = [...root.querySelectorAll('button:not(:disabled),canvas')], index = focusable.indexOf(document.activeElement);
    if (event.shiftKey && index <= 0) { event.preventDefault(); focusable.at(-1).focus(); }
    else if (!event.shiftKey && index === focusable.length - 1) { event.preventDefault(); focusable[0].focus(); }
  }, listeners);
  function fitTop() {
    if (!top || !camera || !manifest) return;
    const b = manifest.bounds, aspect = Math.max(.1, root.clientWidth / Math.max(1, root.clientHeight));
    camera.camera.orthoHeight = Math.max(b.max[2] - b.min[2], (b.max[0] - b.min[0]) / aspect, 1) * .55;
  }
  function resize() { if (app) { app.resizeCanvas(root.clientWidth, root.clientHeight); fitTop(); } }
  const observer = new ResizeObserver(resize); observer.observe(root);
  function position(pose) {
    if (!camera || !manifest) return;
    top = false; camera.camera.projection = window.pc.PROJECTION_PERSPECTIVE;
    root.querySelector('[data-action=top]').setAttribute('aria-pressed', 'false');
    camera.setPosition(pose.position[0], manifest.floor_y + manifest.eye_height, pose.position[2]);
    camera.lookAt(...pose.target); const euler = camera.getEulerAngles(); yaw = euler.y; pitch = Math.max(-80, Math.min(80, euler.x));
    clearMove();
  }
  function move(dx, dz, dt) {
    if (!ready || top || !camera || document.hidden) return;
    const norm = Math.max(1, Math.hypot(dx, dz)); dx /= norm; dz /= norm;
    const radians = yaw * Math.PI / 180, speed = Math.min(dt, .1) * 1.1;
    const p = camera.getPosition(), b = manifest.bounds;
    const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));
    camera.setPosition(clamp(p.x + (dx * Math.cos(radians) + dz * Math.sin(radians)) * speed, b.min[0], b.max[0]),
      manifest.floor_y + manifest.eye_height,
      clamp(p.z + (-dx * Math.sin(radians) + dz * Math.cos(radians)) * speed, b.min[2], b.max[2]));
  }
  canvas.addEventListener('pointerdown', (event) => { if (!ready || top) return; canvas.setPointerCapture(event.pointerId); drag = { id:event.pointerId, x:event.clientX, y:event.clientY }; }, listeners);
  canvas.addEventListener('pointermove', (event) => {
    if (!drag || drag.id !== event.pointerId || !ready) return;
    yaw -= (event.clientX - drag.x) * .18; pitch = Math.max(-80, Math.min(80, pitch - (event.clientY - drag.y) * .18));
    camera.setEulerAngles(pitch, yaw, 0); drag.x = event.clientX; drag.y = event.clientY;
  }, listeners);
  for (const name of ['pointerup', 'pointercancel', 'lostpointercapture']) canvas.addEventListener(name, () => { drag = null; }, listeners);
  pad.addEventListener('pointerdown', (event) => { if (!ready || top) return; event.preventDefault(); pad.setPointerCapture(event.pointerId); joystick = event.pointerId; }, listeners);
  pad.addEventListener('pointermove', (event) => {
    if (joystick !== event.pointerId || !ready || top) return;
    const rect = pad.getBoundingClientRect(); let x = (event.clientX - rect.left - rect.width / 2) / 36, z = (event.clientY - rect.top - rect.height / 2) / 36;
    const length = Math.max(1, Math.hypot(x, z)); x /= length; z /= length; vector = [x, z];
    thumb.style.transform = 'translate(' + (x * 30) + 'px,' + (z * 30) + 'px)';
  }, listeners);
  for (const name of ['pointerup', 'pointercancel', 'lostpointercapture']) pad.addEventListener(name, clearMove, listeners);
  for (const button of root.querySelectorAll('[data-move]')) {
    button.addEventListener('pointerdown', (event) => { event.preventDefault(); button.setPointerCapture(event.pointerId); held.add(button.dataset.move); }, listeners);
    for (const name of ['pointerup', 'pointercancel', 'lostpointercapture']) button.addEventListener(name, () => held.delete(button.dataset.move), listeners);
    button.addEventListener('click', (event) => { if (event.detail === 0) move(Number(button.dataset.move === 'right') - Number(button.dataset.move === 'left'), Number(button.dataset.move === 'back') - Number(button.dataset.move === 'forward'), .1); }, listeners);
  }
  const keys = { KeyW:'forward',KeyS:'back',KeyA:'left',KeyD:'right',ArrowUp:'forward',ArrowDown:'back',ArrowLeft:'left',ArrowRight:'right' };
  window.addEventListener('keydown', (event) => { if (keys[event.code] && !['INPUT','SELECT','TEXTAREA'].includes(event.target.tagName)) { event.preventDefault(); held.add(keys[event.code]); } }, listeners);
  window.addEventListener('keyup', (event) => held.delete(keys[event.code]), listeners);
  window.addEventListener('blur', clearMove, listeners);
  document.addEventListener('visibilitychange', () => { if (document.hidden) clearMove(); }, listeners);
  window.addEventListener('pagehide', destroy, listeners);
  canvas.addEventListener('webglcontextlost', (event) => { event.preventDefault(); clearTimeout(loadTimer); transfer.abort(); releaseGraphics(); say('3D graphics were interrupted. Close this room and reopen it.', true); }, listeners);
  root.querySelector('[data-action=reset]').addEventListener('click', () => position(manifest.initial_camera), listeners);
  root.querySelector('[data-action=top]').addEventListener('click', (event) => {
    if (!ready) return;
    if (top) { position(manifest.initial_camera); return; }
    clearMove(); top = true; event.currentTarget.setAttribute('aria-pressed', 'true');
    const b = manifest.bounds, width = Math.max(b.max[0] - b.min[0], b.max[2] - b.min[2], 1);
    camera.camera.projection = window.pc.PROJECTION_ORTHOGRAPHIC; camera.camera.orthoHeight = width * .7;
    camera.setPosition((b.min[0] + b.max[0]) / 2, b.max[1] + width, (b.min[2] + b.max[2]) / 2); camera.setEulerAngles(-90, 0, 0);
    fitTop();
  }, listeners);
  async function bytes(response, cap, exact) {
    if (!response.ok) throw new Error(response.status === 401 || response.status === 403 ? 'Private viewer access expired. Reopen this room from the app.' : response.status === 404 || response.status === 409 ? 'This room is not available at this revision. Reopen it from the app.' : 'Room download failed. Please retry.');
    if (!response.body) throw new Error('Room response was empty');
    const output = new Uint8Array(cap), reader = response.body.getReader(); let size = 0, empty = 0;
    try {
      while (true) {
        const part = await reader.read(); if (part.done) break;
        if (part.value.length > cap - size || (!part.value.length && ++empty > 64)) throw new Error('Room download exceeds its limit');
        if (part.value.length) empty = 0; output.set(part.value, size); size += part.value.length;
      }
      if (exact && size !== cap) throw new Error('Room download incomplete');
      return output.subarray(0, size);
    } finally { void reader.cancel().catch(() => {}); }
  }
  const headers = options.token ? {Authorization:'Bearer ' + options.token} : {};
  const base = '/s/' + options.sceneId;
  function watchFirstSceneFrame() {
    const current = app, gl = current.graphicsDevice.gl;
    let drew = false, stopped = false;
    // A loaded Asset or postrender alone can still be a clear-only frame while
    // the splat sorter warms up. Observe this scene's own context until a real
    // nonzero instanced draw reaches its canvas, then restore the native calls.
    // No readPixels, private engine counters or instrumentation on other views.
    const restore = [];
    for (const name of ['drawArraysInstanced', 'drawElementsInstanced']) {
      const original = gl[name];
      const wrapped = function(...args) {
        const canvasDraw = this.getParameter(this.DRAW_FRAMEBUFFER_BINDING) === null;
        const count = name === 'drawArraysInstanced' ? args[2] : args[1];
        const instances = name === 'drawArraysInstanced' ? args[3] : args[4];
        const result = original.apply(this, args);
        if (canvasDraw && count > 0 && instances > 0 && !this.isContextLost()) drew = true;
        return result;
      };
      gl[name] = wrapped;
      restore.push(() => { if (gl[name] === wrapped) gl[name] = original; });
    }
    stopFrameWatch = () => {
      if (stopped) return; stopped = true;
      current.off('postrender', frame); restore.forEach(undo => undo());
    };
    function frame() {
      if (!drew || disposed || !ready || transfer.signal.aborted || app !== current || gl.isContextLost()) return;
      rendered = true; stopFrameWatch(); clearTimeout(loadTimer);
      say((manifest.provenance === 'synthetic' ? 'SYNTHETIC TEST — NOT A CAPTURED ROOM. ' : '') +
        (manifest.privacy_reviewed ? 'Reviewed room. ' : 'Private preview — not published. Review privacy before sharing. ') +
        'Drag to look; move with the joystick. ' +
        (manifest.floor_source === 'roomplan' ? 'Floor follows the room scan; boundaries are capture estimates. ' : 'Height and boundaries are capture estimates. ') +
        'No collision geometry or measurement tools.');
      // Native review is bound to the bytes actually rendered, never a fetched
      // preview URL. Ordinary browsers have no bridge and continue unchanged.
      try { window.webkit?.messageHandlers?.spatialViewer?.postMessage({
        type:'spatial-ready', scene_id:manifest.scene_id, artifact_revision:manifest.artifact_revision
      }); } catch { /* A missing native receiver does not invalidate web viewing. */ }
    }
    current.on('postrender', frame);
  }
  const boot = async () => {
    loadTimer = setTimeout(() => { transfer.abort(); if (!disposed) { releaseGraphics(); say('Room loading timed out. Close and reopen to retry.', true); } }, 90000);
    const data = await bytes(await fetch(base + '/manifest', {headers,cache:'no-store',redirect:'error',signal:transfer.signal}), 65536, false);
    manifest = decodeSpatialManifest(JSON.parse(new TextDecoder('utf-8', {fatal:true}).decode(data)));
    if (manifest.scene_id !== options.sceneId || (!options.token && !manifest.privacy_reviewed)) throw new Error('This room is not published');
    say(manifest.provenance === 'synthetic' ? 'SYNTHETIC TEST — NOT A CAPTURED ROOM. Loading…' : 'Loading captured room…');
    const content = await bytes(await fetch(base + '/model?revision=' + encodeURIComponent(manifest.artifact_revision), {headers,cache:'no-store',redirect:'error',signal:transfer.signal}), manifest.bytes, true);
    const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', content))].map(x => x.toString(16).padStart(2,'0')).join('');
    if (digest !== manifest.sha256) throw new Error('Room integrity check failed. Please reopen it.');
    inspectSpatialSog(content, manifest.gaussian_count);
    const pc = await engine();
    if (disposed || transfer.signal.aborted) return;
    app = new pc.Application(canvas, {graphicsDeviceOptions:{antialias:false,alpha:false,deviceTypes:['webgl2']}});
    app.graphicsDevice.maxPixelRatio = Math.min(window.devicePixelRatio || 1, 1.5);
    app.setCanvasResolution(pc.RESOLUTION_AUTO);
    camera = new pc.Entity('spatial-camera'); camera.addComponent('camera', {clearColor:new pc.Color(.055,.05,.078), nearClip:.03, farClip:1000, fov:65}); app.root.addChild(camera);
    const next = new pc.Asset('room', 'gsplat', {url:'/verified-room.sog', filename:'room.sog', contents:content.buffer}); asset = next;
    await new Promise((resolve, reject) => {
      const abort = () => { next.off('load', success); next.off('error', failure); reject(new Error('Room loading cancelled')); };
      const success = () => { transfer.signal.removeEventListener('abort', abort); next.off('error', failure); resolve(); };
      const failure = () => { transfer.signal.removeEventListener('abort', abort); next.off('load', success); reject(new Error('Room could not be decoded on this device')); };
      transfer.signal.addEventListener('abort', abort, {once:true}); next.once('load', success); next.once('error', failure); app.assets.add(next); app.assets.load(next);
    });
    if (disposed || transfer.signal.aborted) return;
    if (next.resource?.numSplats !== manifest.gaussian_count) throw new Error('Room geometry count does not match its manifest');
    splat = new pc.Entity('room'); splat.addComponent('gsplat', {asset:next,unified:true}); app.root.addChild(splat);
    for (const room of manifest.rooms) { const button = document.createElement('button'); button.type='button'; button.textContent=room.label; button.addEventListener('click', () => position(room), listeners); rooms.appendChild(button); }
    ready = true; position(manifest.rooms.find(r => r.id === options.roomId) || manifest.initial_camera);
    for (const button of root.querySelectorAll('button')) button.disabled = false;
    app.on('update', (dt) => move(vector[0] + Number(held.has('right')) - Number(held.has('left')), vector[1] + Number(held.has('back')) - Number(held.has('forward')), dt));
    say('Opening room graphics…'); watchFirstSceneFrame(); resize(); app.start();
  };
  const loaded = boot().catch((error) => { if (!disposed) { clearTimeout(loadTimer); transfer.abort(); releaseGraphics(); say(error instanceof Error ? error.message : '3D room unavailable', true); } });
  // Read-only lifecycle diagnostics; no switch can manufacture a loaded room.
  return { destroy, loaded, snapshot:() => ({ready,rendered,disposed,top,sceneId:manifest?.scene_id,revision:manifest?.artifact_revision,provenance:manifest?.provenance,position:camera?.getPosition().toArray()}) };
}
`;
