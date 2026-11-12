import assert from "node:assert/strict";
import {getEventListeners} from "node:events";
import test from "node:test";
import {seekExportFrame} from "../src/editor/export-frame-seek";

class FakeVideo extends EventTarget {
  duration = 4;
  readyState = 2;
  seeks = 0;
  reportedOffset = 0;
  throwOnSeek = false;
  private position = 0;
  get currentTime() {return this.position + this.reportedOffset;}
  set currentTime(target: number) {
    this.seeks++;
    if (this.throwOnSeek) throw new Error("setter refused seek");
    this.position = target;
    queueMicrotask(() => this.dispatchEvent(new Event("seeked")));
  }
}

test("export seeks each distinct 120 fps source position at quarter speed", async () => {
  const fake = new FakeVideo();
  const video = fake as unknown as HTMLVideoElement;
  const signal = new AbortController().signal;
  await seekExportFrame(video, 0, signal);
  await seekExportFrame(video, 1 / 120, signal);
  await seekExportFrame(video, 2 / 120, signal);
  assert.equal(fake.seeks, 2);
  assert.equal(fake.currentTime, 2 / 120);
  await seekExportFrame(video, 2 / 120, signal);
  assert.equal(fake.seeks, 2);
  assert.equal(getEventListeners(fake, "seeked").length, 0);
  assert.equal(getEventListeners(signal, "abort").length, 0);
});

test("export refuses an inaccurate completed seek and a synchronous setter failure", async () => {
  const fake = new FakeVideo();
  const controller = new AbortController();
  const video = fake as unknown as HTMLVideoElement;
  fake.reportedOffset = .01;
  await assert.rejects(seekExportFrame(video, 1 / 120, controller.signal),
    /decoder missed an export frame/);
  assert.equal(getEventListeners(fake, "seeked").length, 0);
  fake.reportedOffset = 0;
  fake.throwOnSeek = true;
  await assert.rejects(seekExportFrame(video, 1 / 60, controller.signal),
    /setter refused seek/);
  assert.equal(getEventListeners(fake, "seeked").length, 0);
  assert.equal(getEventListeners(controller.signal, "abort").length, 0);
});
