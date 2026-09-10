import { RenderBenchmark, assertSogEnvelope } from './benchmark.mjs';

const $ = (id) => document.getElementById(id);
const benchmark = new RenderBenchmark();
const canvas = $('scene');
let app, camera, splat, asset, loaded = null, loading = false;
let onscreenDraws = 0, totalRenderedFrames = 0, yaw = 0, pitch = 0;
let defaultPose = null, lastUi = 0, runContext = null;
const held = new Set();

function status(message) { $('status').textContent = message; }
function invalidate(reason) { benchmark.invalidate(reason); updateMeasurement(); }
function updateMeasurement() {
  const result = benchmark.result;
  if (benchmark.state === 'complete') {
    $('measurement').textContent = `${result.fps.toFixed(1)} submitted frames/s · ${result.renderedFrames} rendered frames · ${(result.elapsedMs / 1000).toFixed(2)}s. This is draw submission throughput, not GPU completion timing.`;
  } else if (benchmark.state === 'invalid') {
    $('measurement').textContent = `Invalid run: ${benchmark.reason}`;
  } else if (benchmark.active) {
    $('measurement').textContent = benchmark.state === 'warming' ? 'Warming up — move around the scene.' : `Measuring — move around. ${benchmark.intervals.length} frame intervals recorded.`;
  }
  $('measure').disabled = !loaded || loading || benchmark.active;
  $('export').disabled = !result;
}

function resetView() {
  if (!defaultPose) return;
  invalidate('View was reset during measurement');
  camera.setPosition(...defaultPose.position);
  camera.lookAt(...defaultPose.target);
  const euler = camera.getEulerAngles(); pitch = euler.x; yaw = euler.y;
}

function resize() {
  if (!app) return;
  invalidate('Canvas size or resolution changed during measurement');
  app.graphicsDevice.maxPixelRatio = $('resolution').value === 'native' ? window.devicePixelRatio : 1;
  app.resizeCanvas(window.innerWidth, window.innerHeight);
}

async function loadFile(file, synthetic = false) {
  if (loading) return;
  loading = true;
  invalidate('A new file was selected');
  loaded = null;
  $('file').disabled = true; $('reset').disabled = true;
  $('measure').disabled = true;
  status('Reading SOG on this device…');
  try {
    const bytes = await file.arrayBuffer();
    assertSogEnvelope(file.name, bytes);
    if (splat) { splat.destroy(); splat = null; }
    if (asset) { asset.unload(); app.assets.remove(asset); asset = null; }
    // SogBundleParser 2.22.1 consumes file.contents directly. The synthetic URL
    // selects its .sog decoder; no request to /local-scene-*.sog is necessary.
    const next = new pc.Asset('local-scene', 'gsplat', {
      url: `/local-scene-${Date.now()}.sog`, filename: file.name, contents: bytes
    });
    asset = next;
    await new Promise((resolve, reject) => {
      next.once('load', resolve);
      next.once('error', (error) => reject(new Error(String(error))));
      app.assets.add(next); app.assets.load(next);
    });
    const count = next.resource?.numSplats;
    if (!Number.isFinite(count) || count <= 0) throw new Error('SOG decoded without any splats');
    splat = new pc.Entity('local-scene');
    splat.addComponent('gsplat', { asset: next, unified: true });
    app.root.addChild(splat);
    const bounds = next.resource.aabb;
    const center = bounds.center;
    const radius = Math.max(bounds.halfExtents.length(), 0.5);
    defaultPose = { position: [center.x, center.y, center.z + radius * 1.5], target: [center.x, center.y, center.z] };
    camera.camera.farClip = Math.max(100, radius * 10);
    resetView();
    loaded = { name: file.name, bytes: file.size, splatCount: count, synthetic };
    $('reset').disabled = false;
    status(`${synthetic ? 'SYNTHETIC TEST — NOT A ROOM. ' : ''}${file.name}: ${count.toLocaleString()} splats, ${file.size.toLocaleString()} bytes. Drag to look, hold buttons to move.`);
  } catch (error) {
    loaded = null;
    status(`Could not load SOG: ${error.message}`);
    if (splat) { splat.destroy(); splat = null; }
    if (asset) { asset.unload(); app.assets.remove(asset); asset = null; }
  } finally {
    loading = false; $('file').disabled = false; updateMeasurement();
  }
}

function setupDrawCounter(gl) {
  if (!(gl instanceof WebGL2RenderingContext)) throw new Error('This spike requires WebGL 2');
  // Count nonempty instanced draws submitted to the actual canvas. The scene
  // contains only the SOG; sorting/offscreen passes and clear-only RAF frames
  // cannot satisfy this condition. This does NOT claim completed GPU work.
  for (const [name, countIndex, instanceIndex] of [
    ['drawArraysInstanced', 2, 3], ['drawElementsInstanced', 1, 4]
  ]) {
    const original = gl[name].bind(gl);
    gl[name] = (...args) => {
      const onscreen = args[countIndex] > 0 && args[instanceIndex] > 0 && gl.getParameter(gl.DRAW_FRAMEBUFFER_BINDING) === null;
      original(...args);
      if (onscreen) onscreenDraws++;
    };
  }
  const multi = gl.getExtension('WEBGL_multi_draw');
  if (multi) {
    // Some browsers batch the same instanced splat draws through this extension.
    // Preserve that path; disabling it would change the measured workload.
    for (const [name, countsIndex, countsOffsetIndex, instancesIndex, instancesOffsetIndex, drawsIndex] of [
      ['multiDrawArraysInstancedWEBGL', 3, 4, 5, 6, 7],
      ['multiDrawElementsInstancedWEBGL', 1, 2, 6, 7, 8]
    ]) {
      const original = multi[name].bind(multi);
      multi[name] = (...args) => {
        let nonempty = false;
        for (let i = 0; i < args[drawsIndex]; i++) {
          if (args[countsIndex][args[countsOffsetIndex] + i] > 0 && args[instancesIndex][args[instancesOffsetIndex] + i] > 0) { nonempty = true; break; }
        }
        const onscreen = nonempty && gl.getParameter(gl.DRAW_FRAMEBUFFER_BINDING) === null;
        original(...args);
        if (onscreen) onscreenDraws++;
      };
    }
  }
}

function setupControls() {
  let drag = null;
  canvas.addEventListener('pointerdown', (e) => { canvas.setPointerCapture(e.pointerId); drag = { id: e.pointerId, x: e.clientX, y: e.clientY }; });
  canvas.addEventListener('pointermove', (e) => {
    if (!drag || drag.id !== e.pointerId || !loaded) return;
    yaw -= (e.clientX - drag.x) * .18;
    pitch = Math.max(-85, Math.min(85, pitch - (e.clientY - drag.y) * .18));
    camera.setEulerAngles(pitch, yaw, 0);
    drag = { id: e.pointerId, x: e.clientX, y: e.clientY };
  });
  const endDrag = () => { drag = null; };
  canvas.addEventListener('pointerup', endDrag); canvas.addEventListener('pointercancel', endDrag);
  for (const button of document.querySelectorAll('[data-move]')) {
    button.addEventListener('pointerdown', (e) => { e.preventDefault(); button.setPointerCapture(e.pointerId); held.add(button.dataset.move); });
    const release = () => held.delete(button.dataset.move);
    for (const event of ['pointerup', 'pointercancel', 'lostpointercapture']) button.addEventListener(event, release);
  }
  const keys = { KeyW: 'forward', KeyS: 'back', KeyA: 'left', KeyD: 'right', KeyQ: 'down', KeyE: 'up' };
  window.addEventListener('keydown', (e) => {
    if (['INPUT', 'SELECT'].includes(e.target.tagName)) return;
    if (keys[e.code]) { e.preventDefault(); held.add(keys[e.code]); }
  });
  window.addEventListener('keyup', (e) => held.delete(keys[e.code]));
  window.addEventListener('blur', () => { held.clear(); endDrag(); invalidate('Page lost focus'); });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { held.clear(); endDrag(); invalidate('Page was hidden'); }
  });
  app.on('update', (dt) => {
    benchmark.tick(performance.now(), !document.hidden);
    if (loaded && !document.hidden) {
      const step = Math.min(dt, .1);
      const dx = Number(held.has('right')) - Number(held.has('left'));
      const dz = Number(held.has('back')) - Number(held.has('forward'));
      const dy = Number(held.has('up')) - Number(held.has('down'));
      camera.translateLocal(dx * step, dy * step, dz * step);
    }
    if (performance.now() - lastUi > 250) { updateMeasurement(); lastUi = performance.now(); }
  });
}

async function main() {
  // Deferred classic bundle and module scripts may become ready in different
  // orders, so initialization begins only after the document has loaded both.
  if (document.readyState !== 'complete') await new Promise((resolve) => window.addEventListener('load', resolve, { once: true }));
  if (!window.pc || pc.version !== '2.22.1') throw new Error('Expected pinned PlayCanvas 2.22.1');
  app = new pc.Application(canvas, { graphicsDeviceOptions: { antialias: false, alpha: false, deviceTypes: ['webgl2'] } });
  app.setCanvasFillMode(pc.FILLMODE_FILL_WINDOW);
  app.setCanvasResolution(pc.RESOLUTION_AUTO);
  camera = new pc.Entity('camera');
  camera.addComponent('camera', { clearColor: new pc.Color(.04, .05, .07), nearClip: .01, farClip: 100, fov: 65 });
  app.root.addChild(camera);
  setupDrawCounter(app.graphicsDevice.gl);
  app.on('prerender', () => { onscreenDraws = 0; });
  app.on('postrender', () => {
    if (loaded && onscreenDraws > 0) totalRenderedFrames++;
    benchmark.rendered(performance.now(), { visible: !document.hidden, onscreenDraws, splatCount: loaded?.splatCount ?? 0 });
  });
  canvas.addEventListener('webglcontextlost', () => { invalidate('Graphics context lost'); loaded = null; status('Graphics context lost. Reload the page.'); });
  setupControls(); resize(); app.start();
  window.addEventListener('resize', resize);
  $('resolution').addEventListener('change', resize);
  $('file').addEventListener('change', () => { if ($('file').files[0]) loadFile($('file').files[0]); });
  $('reset').addEventListener('click', resetView);
  $('measure').addEventListener('click', () => {
    try {
      benchmark.start({ ready: Boolean(loaded), visible: !document.hidden, deviceLabel: $('device').value }, performance.now());
      runContext = {
        startedAt: new Date().toISOString(), engine: 'PlayCanvas 2.22.1',
        userAgent: navigator.userAgent, physicalPhoneOperatorConfirmed: $('phone').checked,
        asset: { ...loaded }, canvasPixels: [canvas.width, canvas.height],
        cssPixels: [canvas.clientWidth, canvas.clientHeight], devicePixelRatio: window.devicePixelRatio,
        renderPixelRatio: app.graphicsDevice.maxPixelRatio,
        initialCamera: { position: camera.getPosition().toArray(), rotation: camera.getRotation().toArray() },
        measurement: 'Nonempty instanced WebGL 2 draw submissions to onscreen framebuffer; one per PlayCanvas postrender. Not GPU completion or display presentation timing.',
        navigation: 'Manual touch or keyboard movement; paths are not standardized'
      };
      updateMeasurement();
    } catch (error) { $('measurement').textContent = error.message; }
  });
  $('export').addEventListener('click', () => {
    if (!benchmark.result) return;
    const report = { schema: 'rendprop.spatial-phase-a.browser-benchmark.v1', ...runContext, ...benchmark.result };
    const url = URL.createObjectURL(new Blob([JSON.stringify(report, null, 2)], { type: 'application/json' }));
    const a = document.createElement('a'); a.href = url; a.download = 'spatial-benchmark.json'; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  // Read-only diagnostics help browser verification prove a nonempty draw. They
  // cannot force ready/complete or manufacture a measurement.
  window.spatialSpike = { snapshot: () => structuredClone({ loaded, totalRenderedFrames, benchmarkState: benchmark.state, result: benchmark.result, cameraPosition: camera.getPosition().toArray() }) };
  if (new URLSearchParams(location.search).get('fixture') === '1') {
    $('fixture').hidden = false;
    $('fixture').addEventListener('click', async () => {
      try {
        const response = await fetch('/fixture.sog');
        if (!response.ok) throw new Error('Start server with --fixture pointing to SYNTHETIC-NOT-A-ROOM.sog');
        await loadFile(new File([await response.arrayBuffer()], 'SYNTHETIC-NOT-A-ROOM.sog'), true);
      } catch (error) { status(error.message); }
    });
  }
  status('Ready. Choose a local bundled SOG file.');
}
main().catch((error) => { status(`Viewer unavailable: ${error.message}`); $('file').disabled = true; });
