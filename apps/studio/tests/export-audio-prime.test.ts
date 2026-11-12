import assert from "node:assert/strict";
import {getEventListeners} from "node:events";
import test from "node:test";
import {primeExportAudioSource} from "../src/editor/export-audio-prime";

class PrimedVideo extends EventTarget {
  duration = 4;
  readyState = 2;
  playbackRate = 2;
  playCalls = 0;
  pauseCalls = 0;
  advance = true;
  onPlay?: () => void;
  private position = 0;
  private timer?: ReturnType<typeof setInterval>;
  get currentTime() {return this.position;}
  set currentTime(target: number) {
    this.position = target;
    queueMicrotask(() => this.dispatchEvent(new Event("seeked")));
  }
  play(): Promise<void> {
    this.playCalls++;
    this.onPlay?.();
    if (this.advance)
      this.timer = setInterval(() => {this.position += .04;}, 5);
    // Delivery remains pending even while the real media clock advances.
    return new Promise(() => {});
  }
  pause(): void {
    this.pauseCalls++;
    if (this.timer) clearInterval(this.timer);
  }
}

test("prime observes real progress, then pauses and restores the exact trim without waiting for play promise", async () => {
  const fake = new PrimedVideo();
  const signal = new AbortController().signal;
  await primeExportAudioSource(fake as unknown as HTMLVideoElement,
    .5, 2.5, 2, signal, () => {});
  assert.equal(fake.playCalls, 1);
  assert.equal(fake.pauseCalls, 1);
  assert.equal(fake.currentTime, .5);
  assert.equal(getEventListeners(signal, "abort").length, 0);
  assert.equal(getEventListeners(fake, "seeked").length, 0);
});

test("prime checks current identity after its asynchronous seek before any source play", async () => {
  const fake = new PrimedVideo();
  const changed = new Error("edit changed during seek");
  let checks = 0;
  await assert.rejects(primeExportAudioSource(fake as unknown as HTMLVideoElement,
    .5, 2.5, 2, new AbortController().signal, () => {
      if (++checks === 2) throw changed;
    }), error => error === changed);
  assert.equal(fake.playCalls, 0);
});

test("prime refuses a synchronous play call that consumes the whole precontent deadline", async () => {
  const fake = new PrimedVideo();
  fake.advance = false;
  let now = 0;
  fake.onPlay = () => {now = 2001; fake.currentTime += .2;};
  const saved = Object.getOwnPropertyDescriptor(globalThis, "performance");
  Object.defineProperty(globalThis, "performance", {
    configurable: true, value: {now: () => now},
  });
  try {
    await assert.rejects(primeExportAudioSource(fake as unknown as HTMLVideoElement,
      .5, 2.5, 2, new AbortController().signal, () => {}),
    /did not advance before export/);
  } finally {
    if (saved) Object.defineProperty(globalThis, "performance", saved);
    else Reflect.deleteProperty(globalThis, "performance");
  }
  assert.equal(fake.playCalls, 1);
  assert.equal(fake.pauseCalls, 1);
});

test("prime aborts a stalled real media clock and stops its element", async () => {
  const fake = new PrimedVideo();
  fake.advance = false;
  const controller = new AbortController();
  const reason = new Error("edit changed");
  const pending = primeExportAudioSource(fake as unknown as HTMLVideoElement,
    .5, 2.5, 2, controller.signal, () => {});
  setTimeout(() => controller.abort(reason), 10);
  await assert.rejects(pending, error => error === reason);
  assert.equal(fake.playCalls, 1);
  assert.equal(fake.pauseCalls, 1);
  assert.equal(getEventListeners(controller.signal, "abort").length, 0);
});
