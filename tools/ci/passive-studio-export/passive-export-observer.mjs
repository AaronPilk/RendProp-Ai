// Test-only bounded state. No timers, workers, media consumers or clock changes.
// Playwright serializes this self-contained function into each fixture page.
export function installPassiveExportObserver() {
  const sessions = [];
  let current, requestMetadata;
  const trackIds = new WeakMap();
  let trackSequence = 0;
  const nativeHook = {installed: false, issue: null};
  const MAX_EXPORTS = 4, MAX_REQUESTS = 120;
  const safeName = error => typeof error?.name === "string" ? error.name.slice(0, 80) : typeof error;
  const frame = (value, ordinal) => ({ordinal, startSeconds: value.start,
    endSeconds: value.end, durationMilliseconds: (value.end - value.start) * 1000});
  const observer = {
    beginExport(atMilliseconds) {
      if (sessions.length >= MAX_EXPORTS) { current = undefined; return; }
      current = {ordinal: sessions.length + 1, timeOrigin: performance.timeOrigin,
        beginAtMilliseconds: atMilliseconds, requestCount: 0, requests: [], encoded: null};
      sessions.push(current);
    },
    beginRequest(metadata) {
      const previous = requestMetadata;
      requestMetadata = metadata;
      return previous;
    },
    endRequest(previous) { requestMetadata = previous; },
    beforeNativeRequest(track) {
      if (!current) return null;
      const ordinal = ++current.requestCount;
      if (ordinal > MAX_REQUESTS) return null;
      if (!trackIds.has(track)) trackIds.set(track, ++trackSequence);
      const entry = {ordinal, ...(requestMetadata ?? {phase: "unattributed"}),
        trackOrdinal: trackIds.get(track), beforeNativeAtMilliseconds: performance.now()};
      current.requests.push(entry);
      return entry;
    },
    afterNativeRequest(entry, threw, error) {
      if (!entry) return;
      entry.afterNativeAtMilliseconds = performance.now();
      entry.threw = threw;
      if (threw) entry.errorName = safeName(error);
    },
    encodedSummary(frames, frameCount, timescale) {
      if (!current) return;
      current.encoded = {observedAtMilliseconds: performance.now(), frameCount,
        timescale, first16: frames.map((value, ordinal) => frame(value, ordinal))};
    },
    encodedRefusal(index, frames, firstOrdinal, rule) {
      if (!current?.encoded || current.encoded.refusal) return;
      current.encoded.refusal = {observedAtMilliseconds: performance.now(), frameIndex: index,
        rule, neighborhood: frames.map((value, ordinal) => frame(value, firstOrdinal + ordinal))};
    },
    snapshot() {
      return {schema: "rendprop-passive-export-diagnostic-v1", limits: {exports: MAX_EXPORTS,
        requestsPerExport: MAX_REQUESTS, firstEncodedFrames: 16, refusalNeighborRadius: 4},
        nativeHook: {...nativeHook}, sessions: structuredClone(sessions), scope: "Diagnostic evidence only. Native calls, results, exceptions, quality limits and download assertions are unchanged. Observation adds bounded overhead and cannot prove CI equivalence."};
    },
  };
  Object.defineProperty(window, "rendpropPassiveExportDiagnostic", {value: observer,
    enumerable: false, configurable: false, writable: false});
  try {
    const prototype = window.CanvasCaptureMediaStreamTrack?.prototype;
    const descriptor = prototype && Object.getOwnPropertyDescriptor(prototype, "requestFrame");
    const original = descriptor?.value;
    if (typeof original !== "function") nativeHook.issue = "Native requestFrame is unavailable";
    else {
      Object.defineProperty(prototype, "requestFrame", {...descriptor, value: function(...args) {
        let entry;
        try { entry = observer.beforeNativeRequest(this); } catch {}
        try {
          const result = Reflect.apply(original, this, args);
          try { observer.afterNativeRequest(entry, false); } catch {}
          return result;
        } catch (error) {
          try { observer.afterNativeRequest(entry, true, error); } catch {}
          throw error;
        }
      }});
      nativeHook.installed = true;
    }
  } catch (error) { nativeHook.issue = safeName(error); }
}
