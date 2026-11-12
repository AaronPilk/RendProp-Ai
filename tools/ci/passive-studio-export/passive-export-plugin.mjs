import assert from "node:assert/strict";

function exact(code, from, to, label) {
  assert.equal(code.split(from).length, 2, `Diagnostic anchor changed: ${label}`);
  return code.replace(from, to);
}
const begin = '  const { media, format, signal, currentDraft, onProgress } = options;';
const helper = `
// Injected into a diagnostic build only; never saved to shipping source.
function rpDiagnosticRequestFrame(metadata: {phase: string; clipIndex: number; localSeconds: number; timelineSeconds: number}, invoke: () => unknown): unknown {
  const observer = (globalThis as any).rendpropPassiveExportDiagnostic;
  let previous: unknown;
  try { previous = observer?.beginRequest(metadata); } catch {}
  try { return invoke(); }
  finally { try { observer?.endRequest(previous); } catch {} }
}
`;

export function instrumentExportSource(original) {
  let code = exact(original, begin,
    '  try { (globalThis as any).rendpropPassiveExportDiagnostic?.beginExport(performance.now()); } catch {}\n' + begin,
    'export entry');
  const first = '        captureCadence.capture(performance.now(), 0);\n        track?.requestFrame?.();\n      } else {';
  code = exact(code, first,
    '        captureCadence.capture(performance.now(), 0);\n        rpDiagnosticRequestFrame({phase: "initial", clipIndex: index, localSeconds: 0, timelineSeconds: elapsedBefore}, () => track?.requestFrame?.());\n      } else {',
    'initial native request');
  const resumed = '        captureCadence.capture(performance.now(), 0);\n        track?.requestFrame?.();\n      }\n      // Start recording';
  code = exact(code, resumed,
    '        captureCadence.capture(performance.now(), 0);\n        rpDiagnosticRequestFrame({phase: "resume", clipIndex: index, localSeconds: 0, timelineSeconds: elapsedBefore}, () => track?.requestFrame?.());\n      }\n      // Start recording',
    'resumed native request');
  const painted = '          (stream!.getVideoTracks()[0] as CanvasCaptureMediaStreamTrack | undefined)?.requestFrame?.();';
  code = exact(code, painted,
    '          rpDiagnosticRequestFrame({phase: "paint", clipIndex: index, localSeconds: elapsed, timelineSeconds: elapsedBefore + elapsed}, () => (stream!.getVideoTracks()[0] as CanvasCaptureMediaStreamTrack | undefined)?.requestFrame?.());',
    'paint native request');
  return code + helper;
}

export function instrumentCadenceSource(original) {
  const sorted = '  frames.sort((a, b) => a.start - b.start);';
  let code = exact(original, sorted, sorted + '\n  try { (globalThis as any).rendpropPassiveExportDiagnostic?.encodedSummary(frames.slice(0, 16), frames.length, track?.timescale ?? null); } catch {}',
    'encoded sample sort');
  const statements = [
    ['sample-duration', 'throw skippedFrames("sample-duration", index, frames.length, duration * 1000,\n        MAX_ENCODED_GAP_SECONDS * 1000, "milliseconds");'],
    ['start-gap', 'throw skippedFrames("start-gap", index, frames.length, startGap * 1000,\n        MAX_ENCODED_GAP_SECONDS * 1000, "milliseconds");'],
    ['density', 'throw skippedFrames("density", index, frames.length, index - windowStart + 1,\n        MIN_FRAMES_PER_WINDOW, "frames-per-500ms");'],
  ];
  for (const [rule, statement] of statements) {
    // The existing if predicate and exact thrown Error expression remain.
    const evidence = `try { (globalThis as any).rendpropPassiveExportDiagnostic?.encodedRefusal(index, frames.slice(Math.max(0, index - 4), index + 5), Math.max(0, index - 4), ${JSON.stringify(rule)}); } catch {}`;
    code = exact(code, statement, `{ ${evidence}\n      ${statement}\n      }`, rule);
  }
  return code;
}

export const passiveExportDiagnosticPlugin = {
  name: "rendprop-passive-export-diagnostics-only", enforce: "pre",
  transform(code, id) {
    if (id.endsWith('/src/editor/export.ts')) return instrumentExportSource(code);
    if (id.endsWith('/src/editor/mp4-cadence.ts')) return instrumentCadenceSource(code);
  },
};
