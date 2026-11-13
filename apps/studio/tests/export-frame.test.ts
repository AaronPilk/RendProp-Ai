import assert from "node:assert/strict";
import {test} from "node:test";
import {getEventListeners} from "node:events";
import {MAX_ORIGINAL_AUDIO_LOSS_SECONDS, nextExportFrame, startBufferedVideo} from "../src/editor/export";

async function withClock(run: (clock: {
  frames: Map<number, FrameRequestCallback>;
  timers: Map<number, {callback: () => void; delay: number}>;
  advance: (time: number) => void;
}) => Promise<void>) {
  const keys = ["requestAnimationFrame", "cancelAnimationFrame", "setTimeout", "clearTimeout", "performance"] as const;
  const saved = new Map(keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  const frames = new Map<number, FrameRequestCallback>(), timers = new Map<number, {callback: () => void; delay: number}>();
  let id = 0, now = 0;
  const replacements = {
    requestAnimationFrame: (callback: FrameRequestCallback) => {frames.set(++id, callback); return id;},
    cancelAnimationFrame: (id: number) => frames.delete(id),
    setTimeout: (callback: () => void, delay: number) => {timers.set(++id, {callback, delay}); return id;},
    clearTimeout: (id: number) => timers.delete(id),
    performance: {now: () => now},
  };
  try {
    for (const key of keys) Object.defineProperty(globalThis, key, {value: replacements[key], configurable: true});
    await run({frames, timers, advance: time => {now = time;}});
  } finally {
    for (const key of keys) {
      const descriptor = saved.get(key);
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else Reflect.deleteProperty(globalThis, key);
    }
  }
}

test("export frame uses callback delivery time and cancels its deadline timer", async () => {
  await withClock(async ({frames, timers, advance}) => {
    const controller = new AbortController();
    const result = nextExportFrame(controller.signal, 500);
    assert.equal(frames.size, 1); assert.equal(timers.size, 1);
    advance(180);
    frames.values().next().value!(40); // A stale rAF timestamp must not become the export clock.
    assert.equal(await result, 180);
    assert.equal(frames.size, 0); assert.equal(timers.size, 0);
    assert.equal(getEventListeners(controller.signal, "abort").length, 0);
    controller.abort();
  });
});

test("segment deadline wins over a late frame and cancels its pending callback", async () => {
  await withClock(async ({frames, timers, advance}) => {
    const controller = new AbortController();
    const result = nextExportFrame(controller.signal, 12);
    const timer = timers.values().next().value!;
    assert.equal(timer.delay, 12);
    advance(12); timer.callback();
    assert.equal(await result, 12);
    assert.equal(frames.size, 0); assert.equal(timers.size, 0);
    assert.equal(getEventListeners(controller.signal, "abort").length, 0);
    controller.abort();
  });
});

test("cancelling a frame wait removes both scheduled operations and preserves its reason", async () => {
  await withClock(async ({frames, timers}) => {
    const controller = new AbortController(), reason = new Error("cancel this export");
    const result = nextExportFrame(controller.signal, 500);
    controller.abort(reason);
    await assert.rejects(result, error => error === reason);
    assert.equal(frames.size, 0); assert.equal(timers.size, 0);
    assert.equal(getEventListeners(controller.signal, "abort").length, 0);
  });
});

test("expired deadlines yield once and an already cancelled wait schedules nothing", async () => {
  await withClock(async ({frames, timers, advance}) => {
    const controller = new AbortController();
    const result = nextExportFrame(controller.signal, -10);
    const timer = timers.values().next().value!;
    assert.equal(timer.delay, 1);
    advance(1); timer.callback(); assert.equal(await result, 1);
    controller.abort();
    assert.throws(() => nextExportFrame(controller.signal, 1), {name: "AbortError"});
    assert.equal(frames.size, 0); assert.equal(timers.size, 0);
    assert.equal(getEventListeners(controller.signal, "abort").length, 0);
  });
});

test("the original-audio loss bound stays between media clock granularity and the 100 ms stall control", () => {
  // Two capture intervals: a measured gap this long is refused; the browser
  // test's injected 100 ms stall must always exceed it, and a 10 ms device
  // callback or official-playback-position step must never reach it.
  assert.equal(MAX_ORIGINAL_AUDIO_LOSS_SECONDS, 2 / 30);
  assert(MAX_ORIGINAL_AUDIO_LOSS_SECONDS < .1 - .03);
  assert(MAX_ORIGINAL_AUDIO_LOSS_SECONDS > .02 + .03);
});

test("a stalled animation callback cannot exceed the existing 30 fps capture interval", async () => {
  await withClock(async ({frames, timers, advance}) => {
    const controller = new AbortController();
    const result = nextExportFrame(controller.signal, 500);
    const timer = timers.values().next().value!;
    assert.equal(timer.delay, 1000 / 30);
    advance(1000 / 30); timer.callback();
    assert.equal(await result, 1000 / 30);
    assert.equal(frames.size, 0); assert.equal(timers.size, 0);
    assert.equal(getEventListeners(controller.signal, "abort").length, 0);
  });
});

function bufferedVideo(play: () => Promise<void>) {
  return Object.assign(new EventTarget(), {paused: false, seeking: false, readyState: 4, play}) as unknown as HTMLVideoElement;
}
test("native playing admits buffered capture before delayed play settlement, retaining the operation", async () => {
  await withClock(async ({timers}) => {
    const controller = new AbortController(); let resolve!: () => void, calls = 0;
    const video = bufferedVideo(() => {calls++; assert.equal(getEventListeners(video, "playing").length, 1); return new Promise<void>(done => {resolve = done;});});
    const playback = startBufferedVideo(video, controller);
    video.dispatchEvent(new Event("playing")); await playback.ready;
    assert.equal(calls, 1); assert.equal(controller.signal.aborted, false);
    assert.equal(getEventListeners(video, "playing").length, 0); assert.equal(timers.size, 1, "Original play operation retains its deadline");
    resolve(); await playback.settled; assert.equal(timers.size, 0);
  });
});
test("buffered playback retains immediate and late rejection identity after actual playing", async () => {
  await withClock(async ({timers}) => {
    for (const late of [false, true]) {
      const controller = new AbortController(), reason = new Error("native play failed"); let reject!: (error: unknown) => void;
      const video = bufferedVideo(() => new Promise<void>((_resolve, fail) => {reject = fail;}));
      const playback = startBufferedVideo(video, controller);
      if (late) {video.dispatchEvent(new Event("playing")); await playback.ready;}
      reject(reason); await assert.rejects(playback.settled, error => error === reason);
      if (!late) await assert.rejects(playback.ready, error => error === reason);
      assert.equal(controller.signal.reason, reason); assert.equal(timers.size, 0);
      assert.equal(getEventListeners(video, "playing").length, 0);
    }
  });
});
test("buffered playback cancellation and synchronous play throws clear owned listeners and deadlines", async () => {
  await withClock(async ({timers}) => {
    for (const syncThrow of [false, true]) {
      const controller = new AbortController(), reason = new Error("stop buffered startup"); let calls = 0;
      const video = bufferedVideo(() => {calls++; if (syncThrow) throw reason; return new Promise<void>(() => {});});
      const playback = startBufferedVideo(video, controller);
      if (!syncThrow) controller.abort(reason);
      await assert.rejects(playback.ready, error => error === reason); await assert.rejects(playback.settled, error => error === reason);
      assert.equal(calls, 1); assert.equal(timers.size, 0); assert.equal(getEventListeners(video, "playing").length, 0);
    }
    const cancelled = new AbortController(); cancelled.abort(); let played = false;
    assert.throws(() => startBufferedVideo(bufferedVideo(() => {played = true; return Promise.resolve();}), cancelled), {name: "AbortError"});
    assert.equal(played, false); assert.equal(timers.size, 0);
  });
});
test("actual playing cannot admit a paused, seeking or unready video", async () => {
  await withClock(async ({timers}) => {
    for (const state of [{paused: true}, {seeking: true}, {readyState: 2}]) {
      const controller = new AbortController(), video = bufferedVideo(() => new Promise<void>(() => {})); Object.assign(video, state);
      const playback = startBufferedVideo(video, controller); video.dispatchEvent(new Event("playing"));
      await assert.rejects(playback.ready, /did not begin playing/); controller.abort(); await assert.rejects(playback.settled);
      assert.equal(timers.size, 0); assert.equal(getEventListeners(video, "playing").length, 0);
    }
  });
});
test("native playing does not remove the bounded late play-settlement timeout", async () => {
  await withClock(async ({timers}) => {
    const controller = new AbortController(), video = bufferedVideo(() => new Promise<void>(() => {}));
    const playback = startBufferedVideo(video, controller); video.dispatchEvent(new Event("playing")); await playback.ready;
    assert.equal(timers.size, 1); const timer = timers.values().next().value!; assert.equal(timer.delay, 15000); timer.callback();
    await assert.rejects(playback.settled, /Starting video took too long/); assert.equal(controller.signal.aborted, true); assert.equal(timers.size, 0);
  });
});
