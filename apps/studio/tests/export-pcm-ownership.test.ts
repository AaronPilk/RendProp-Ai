import assert from "node:assert/strict";
import test from "node:test";
import {sendOwnedPCMBlock} from "../src/editor/export-pcm-ownership";

test("offline PCM accepts the returned buffer after real transfer detaches its sender", async () => {
  const block = new Float32Array(2 * 1024);
  block[0] = .25;
  let received: ArrayBuffer | undefined;
  await sendOwnedPCMBlock({
    async addAudio(buffer, startFrame, frameCount) {
      assert.equal(startFrame, 24816);
      assert.equal(frameCount, 448);
      received = structuredClone(buffer, {transfer: [buffer]});
      assert.equal(buffer.byteLength, 0);
      assert.equal(new Float32Array(received)[0], .25);
      return received;
    },
  }, block.buffer, 24816, 448);
  assert.equal(block.byteLength, 0);
  assert.equal(received?.byteLength, 8192);
});

test("offline PCM refuses a wrong-size return after transfer", async () => {
  const block = new Float32Array(2 * 1024);
  await assert.rejects(sendOwnedPCMBlock({
    async addAudio(buffer) {
      structuredClone(buffer, {transfer: [buffer]});
      return new ArrayBuffer(4096);
    },
  }, block.buffer, 0, 1024), /did not return its buffer/);
  assert.equal(block.byteLength, 0);
});
