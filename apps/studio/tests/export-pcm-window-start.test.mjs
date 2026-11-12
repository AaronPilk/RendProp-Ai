import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {runInNewContext} from "node:vm";
import {test} from "node:test";

const source = readFileSync(new URL("../src/editor/export-pcm-worklet.js", import.meta.url), "utf8");
function processor(initialIndex, initialBase) {
  const messages = [];
  let Registered;
  class FakeProcessor {
    constructor() {
      this.port = {onmessage: null, postMessage: row => messages.push(row)};
    }
  }
  const sandbox = {AudioWorkletProcessor: FakeProcessor, currentFrame: 0,
    sampleRate: 48000, registerProcessor: (_name, type) => {Registered = type;}};
  runInNewContext(source, sandbox, {filename: "export-pcm-worklet.js"});
  return {worklet: new Registered({processorOptions: {initialIndex, initialBase}}),
    messages, sandbox};
}

test("a lazy worklet starts from the canonical plan index and global AAC frame", () => {
  const {worklet, messages, sandbox} = processor(1, 24000);
  worklet.port.onmessage({data: {type: "arm", windowIndex: 1,
    outputBase: 24000, frameCount: 128}});
  assert.equal(messages[0]?.type, "armed");
  assert.equal(messages[0]?.windowIndex, 1);
  assert.equal(messages[0]?.outputBase, 24000);
  sandbox.currentFrame = messages[0].startFrame;
  const stereo = [new Float32Array(128), new Float32Array(128)];
  worklet.process([stereo], [stereo]);
  sandbox.currentFrame += 128;
  worklet.process([stereo], [stereo]);
  assert.deepEqual(messages.map(row => row.type), ["armed", "chunk", "done"]);
  assert.equal(messages[1].windowIndex, 1);
  assert.equal(messages[1].outputBase, 24000);
  assert.equal(messages[1].startFrame, 0);
  assert.equal(messages[1].frameCount, 128);
  assert.equal(messages[2].nextOutputBase, 24128);
  worklet.port.onmessage({data: {type: "recycle", buffer: messages[1].buffer}});
  worklet.port.onmessage({data: {type: "arm", windowIndex: 2,
    outputBase: 24128, frameCount: 128}});
  assert.equal(messages.at(-1)?.type, "armed");
  assert.equal(messages.at(-1)?.windowIndex, 2);
});

test("a lazy worklet rejects a stale global index or base before PCM", () => {
  const {worklet, messages} = processor(1, 24000);
  worklet.port.onmessage({data: {type: "arm", windowIndex: 0,
    outputBase: 0, frameCount: 128}});
  assert.equal(messages.at(-1)?.type, "fault");
  assert.equal(messages.at(-1)?.code, "invalid-window-rearm");
});
