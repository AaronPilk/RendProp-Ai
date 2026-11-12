import assert from "node:assert/strict";
import test from "node:test";
import {silenceInWindows, summarizeRecordingSilence, summarizeRenderGaps} from "./native-trace-observer.mjs";

const alignment = {available: true, traceMarkerUs: 1_000_000, pageWallBeforeMs: 5_000, uncertaintyMs: 0.5};
// RequestRender every 10 ms from page 5000 ms; optional hole and early stop.
function renderSpans({untilMs, holeFromMs, holeToMs}: {untilMs: number; holeFromMs?: number; holeToMs?: number}) {
  const spans = [];
  for (let pageMs = 5_000; pageMs < untilMs; pageMs += 10) {
    if (holeFromMs !== undefined && holeToMs !== undefined && pageMs > holeFromMs && pageMs < holeToMs) continue;
    spans.push({name: "AudioDestination::RequestRender", pid: 1, tid: 2, startUs: 1_000_000 + (pageMs - 5_000) * 1000, durationUs: 100});
  }
  return spans;
}
const device = (windows: Array<[number, number]>, refusals: number[] = []) => ({id: 2, clockRefusals: refusals.map(atMs => ({atMs})),
  trace: {capturedAtMs: 9_000, events: windows.flatMap(([from, to]) => [{kind: "recorder.event.start", atMs: from}, {kind: "recorder.call.stop", atMs: to}])}});

test("a render callback that stops and never returns is reported as trailing silence", () => {
  const facts = {renderGapSummary: summarizeRenderGaps(renderSpans({untilMs: 6_000}), alignment)};
  const thread = facts.renderGapSummary.threads[0];
  assert.equal(thread.longestGapMs < 33, true, "no pair of consecutive spans shows the stop");
  const result = summarizeRecordingSilence(facts, device([[5_500, 6_120]], [6_119]));
  assert.equal(result.render.windows[0].longestSilence.kind, "trailing");
  assert.ok(Math.abs(result.render.windows[0].longestSilenceMs - 129.9) < 0.2);
  assert.deepEqual(result.refusalsAtMs, [6_119]);
});

test("a stop that recovers is reported between spans, and only inside the window it overlaps", () => {
  const facts = {renderGapSummary: summarizeRenderGaps(renderSpans({untilMs: 8_000, holeFromMs: 6_000, holeToMs: 6_080}), alignment)};
  const [inside, outside] = summarizeRecordingSilence(facts, device([[5_900, 6_500], [7_000, 7_500]])).render.windows;
  assert.equal(inside.longestSilence.kind, "between-spans");
  assert.ok(Math.abs(inside.longestSilenceMs - 79.9) < 0.2);
  assert.ok(outside.longestSilenceMs < 33);
});

test("a window that opens before the first span counts the leading edge; unaligned traces claim nothing", () => {
  const facts = {renderGapSummary: summarizeRenderGaps(renderSpans({untilMs: 6_000}), alignment)};
  const [leading] = summarizeRecordingSilence(facts, device([[4_900, 5_500]])).render.windows;
  assert.equal(leading.longestSilence.kind, "leading");
  assert.ok(Math.abs(leading.longestSilenceMs - 100) < 0.2);
  const unaligned = summarizeRenderGaps(renderSpans({untilMs: 6_000}), {available: false});
  assert.deepEqual(silenceInWindows(unaligned.threads[0].edgesAndGaps, [{fromMs: 1, toMs: 2}]), [{fromMs: 1, toMs: 2, available: false}]);
});
