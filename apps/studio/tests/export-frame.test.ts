import assert from "node:assert/strict";
import {test} from "node:test";
import {getEventListeners} from "node:events";
import {nextExportFrame} from "../src/editor/export";

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
