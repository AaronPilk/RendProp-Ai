import assert from "node:assert/strict";
import test from "node:test";
import {readFileSync} from "node:fs";
import {createHash} from "node:crypto";
import {fileURLToPath} from "node:url";
import {dirname, join, resolve} from "node:path";
import {startSilentStreamBootstrap} from "./silent-output-bootstrap";

const here = dirname(fileURLToPath(import.meta.url));
const sha = (file: string) => createHash("sha256")
  .update(readFileSync(file)).digest("hex");
const fake = (throwAt?: "sink" | "create" | "connect" | "start" | "stop" | "disconnect") => {
  const events: string[] = [];
  const track = {readyState: "live", stop() {
    events.push("stop-track");
    this.readyState = "ended";
  }};
  const sink = {stream: {getTracks() {return [track];}}};
  const source = {
    offset: {value: 1},
    connect(target: unknown) {
      assert.equal(target, sink);
      events.push("connect-stream-sink");
      if (throwAt === "connect") throw new Error("synthetic connect failure");
    },
    start() {
      events.push("start");
      if (throwAt === "start") throw new Error("synthetic start failure");
    },
    stop() {
      events.push("stop");
      if (throwAt === "stop") throw new Error("synthetic stop failure");
    },
    disconnect() {
      events.push("disconnect");
      if (throwAt === "disconnect") throw new Error("synthetic disconnect failure");
    },
  };
  const audio = {createMediaStreamDestination() {
    events.push("create-sink");
    if (throwAt === "sink") throw new Error("synthetic sink failure");
    return sink;
  }, createConstantSource() {
    events.push("create");
    if (throwAt === "create") throw new Error("synthetic create failure");
    return source;
  }};
  return {audio: audio as unknown as AudioContext, source, sink, track, events};
};

test("early zero connects only to the reusable stream sink and stop owns its track", () => {
  const row = fake();
  const bootstrap = startSilentStreamBootstrap(row.audio);
  assert.equal(bootstrap.sink, row.sink);
  assert.equal(row.source.offset.value, 0);
  assert.deepEqual(row.events, ["create-sink", "create", "connect-stream-sink", "start"]);
  assert.equal(bootstrap.trace.connectedToStreamSink, true);
  assert.equal(bootstrap.trace.tracksCreated, 1);
  assert.equal(bootstrap.trace.started, true);
  bootstrap.stop();
  bootstrap.stop();
  assert.deepEqual(row.events, ["create-sink", "create", "connect-stream-sink", "start",
    "stop", "disconnect", "stop-track"]);
  assert.equal(bootstrap.trace.stopCalls, 2);
  assert.equal(bootstrap.trace.liveTracksAfterStop, 0);
  assert.equal(row.track.readyState, "ended");
  assert.equal(bootstrap.trace.disconnected, true);
});

test("partial setup failures disconnect source and stop any created sink track", () => {
  for (const step of ["sink", "create", "connect", "start"] as const) {
    const row = fake(step);
    assert.throws(() => startSilentStreamBootstrap(row.audio), /synthetic/);
    assert.equal(row.events.filter(event => event === "disconnect").length,
      step === "sink" || step === "create" ? 0 : 1);
    assert.equal(row.track.readyState, step === "sink" ? "live" : "ended");
  }
});

test("stop failure still disconnects and stops track before AudioContext close", () => {
  const row = fake("stop");
  const bootstrap = startSilentStreamBootstrap(row.audio);
  assert.throws(() => bootstrap.stop(), /synthetic stop failure/);
  assert.equal(row.events.at(-1), "stop-track");
  bootstrap.stop();
  assert.equal(row.events.filter(event => event === "stop").length, 1);
  assert.equal(row.track.readyState, "ended");
});

test("disconnect failure is recorded honestly while the sink track still ends", () => {
  const row = fake("disconnect");
  const bootstrap = startSilentStreamBootstrap(row.audio);
  assert.throws(() => bootstrap.stop(), /synthetic disconnect failure/);
  assert.equal(bootstrap.trace.disconnected, false);
  assert.equal(bootstrap.trace.liveTracksAfterStop, 0);
  assert.equal(row.track.readyState, "ended");
});

test("setup and pre-capture failure paths retain owned context cleanup", () => {
  const pcm = readFileSync(join(here, "audible-pcm.ts"), "utf8");
  const exporter = readFileSync(join(here, "experimental-webcodecs-audible.ts"), "utf8");
  const begin = pcm.slice(pcm.indexOf("export function beginAudibleProofAudio"),
    pcm.indexOf("async function readyAudioClock"));
  assert(begin.indexOf("startSilentStreamBootstrap(context)") >= 0);
  assert(begin.indexOf("startSilentStreamBootstrap(context)") <
    begin.indexOf("context.resume()"));
  assert(begin.includes("closeStarted = context.close()") &&
    begin.includes("new AudioBootstrapSetupError(closeStarted, error)"),
  "A setup failure must initiate an observable context close");
  assert(exporter.includes("error.closeStarted.then") &&
    exporter.includes("new Promise<\"timed-out\">") &&
    exporter.includes("audibleProofSetupClose = result") &&
    exporter.includes("if (result !== \"closed\")"),
  "The exporter must bound and record setup close before refusing");
  assert(pcm.includes("begun.bootstrap.stop()") &&
    pcm.indexOf("begun.bootstrap.stop()") < pcm.indexOf("await closeAudio(audio)"),
  "Captured window must stop the bootstrap before closing audio");
  assert(pcm.includes("sink = begun.bootstrap.sink") &&
    !pcm.includes("sink = audio.createMediaStreamDestination()"),
  "The tap must use the early sink, without constructing another sink");
  assert(!pcm.includes("source.connect(audio.destination)"),
  "No separate hardware-output branch is allowed");
  assert(exporter.includes("begunAudio.bootstrap.stop()") &&
    exporter.indexOf("begunAudio.bootstrap.stop()") <
      exporter.lastIndexOf("audio.close()"),
  "Outer pre-capture exit must own bootstrap cleanup");
});

test("unchanged v5 worklet, fixture, and strict media oracles stay byte-identical", () => {
  const v5 = resolve(here, "../webcodecs-audible-prototype-v5");
  for (const name of ["audible-pcm-worklet.js",
    "audible-proof-fixture.ts", "audible-proof-fixture.html"])
    assert.equal(sha(join(here, name)), sha(join(v5, name)), name);
  const oracle = (file: string) => {
    const source = readFileSync(file, "utf8");
    return source.slice(source.indexOf("function pcmFloat(file)"), source.indexOf("\ntry {\n  assert(entry"));
  };
  assert.equal(oracle(join(here, "audible-proof-browser.mjs")),
    oracle(join(v5, "audible-proof-browser.mjs")));
  const browser = readFileSync(join(here, "audible-proof-browser.mjs"), "utf8");
  assert(browser.includes('"src/editor/silent-output-bootstrap.ts"') &&
    browser.includes("bootstrap.startedWallMs <= pcmTrace.startupClock.startedWallMs") &&
    browser.includes("assert.equal(refused.bootstrap?.liveTracksAfterStop, 0)"));
  const pcm = readFileSync(join(here, "audible-pcm.ts"), "utf8");
  assert(pcm.includes("const clock = new AudioStartupClock()"));
  assert(pcm.includes("const clock = new RecordingClock()"));
  assert(pcm.includes("const started = performance.now(), deadline = started + 2000"));
  assert(pcm.includes("const ARM_LEAD_FRAMES = 8192"));
  assert(pcm.includes("const CREDITS = 8"));
});
