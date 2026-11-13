import assert from "node:assert/strict";
import test from "node:test";
// @ts-ignore Test helpers are plain ESM.
import { testAudioOutputOption, installTestAudioOutput, verifyTestAudioOutput } from "./export-audio-output.mjs";

test("silent output is explicit, source-bound and preserves other fixture options", async () => {
  const ordinary = testAudioOutputOption(["--only-fixed"]);
  assert.equal(ordinary.audioOutput.mode, "default-device");
  assert.deepEqual(ordinary.args, ["--only-fixed"]);
  assert.match(ordinary.audioOutput.helperSha256, /^[a-f0-9]{64}$/);
  let installed = false;
  await installTestAudioOutput({ addInitScript() { installed = true; } }, ordinary.audioOutput);
  assert.equal(installed, false, "Default mode must not inject any browser script");
  const evidence = await verifyTestAudioOutput({ evaluate() { throw new Error("Default mode read browser state"); } }, ordinary.audioOutput);
  assert.equal(evidence.installed, false);
  const selected = testAudioOutputOption(["--fault=omit-readiness", "--silent-audio-output"]);
  assert.deepEqual(selected.args, ["--fault=omit-readiness"]);
  assert.equal(selected.audioOutput.mode, "silent-native-sink");
  assert.throws(() => testAudioOutputOption(["--silent-audio-output", "--silent-audio-output"]), /Duplicate/);
});

test("unsupported, uninstalled or ignored silent sinks fail closed", async () => {
  const { audioOutput } = testAudioOutputOption(["--silent-audio-output"]);
  for (const evidence of [null, { supported: false, failure: "unsupported" },
    { supported: true, installed: true, failure: "ignored" },
    { supported: true, installed: true, nativeClockGetterUnchanged: false, contexts: [] },
    { supported: true, installed: true, nativeClockGetterUnchanged: true, contexts: [{ sinkType: null, nativeTime: 0 }] }]) {
    await assert.rejects(verifyTestAudioOutput({ evaluate: async () => evidence }, audioOutput));
  }
  const native = { supported: true, installed: true, failure: null, nativeClockGetterUnchanged: true,
    contexts: [{ sinkType: "none", nativeTime: 0.25, sampleRate: 48000, state: "running" }] };
  assert.deepEqual((await verifyTestAudioOutput({ evaluate: async () => native }, audioOutput)).contexts, native.contexts);
});
