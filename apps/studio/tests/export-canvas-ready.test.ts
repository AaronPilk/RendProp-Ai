import assert from "node:assert/strict";
import {getEventListeners} from "node:events";
import {test} from "node:test";
import {awaitCanvasFrameReady} from "../src/editor/export-canvas-ready";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => {resolve = done;});
  return {promise, resolve};
}

function frame(width = 1920, height = 1080) {
  let closed = 0;
  return {
    value: {displayWidth: width, displayHeight: height, close: () => {closed++;}} as VideoFrame,
    get closed() {return closed;},
  };
}

function track(onRequest: () => void = () => {}) {
  let requests = 0, clones = 0, cloneStops = 0, originalStops = 0;
  const copy = {readyState: "live", stop: () => {cloneStops++;}} as MediaStreamTrack;
  return {
    value: {
      readyState: "live",
      requestFrame: () => {requests++; onRequest();},
      clone: () => {clones++; return copy;},
      stop: () => {originalStops++;},
    } as CanvasCaptureMediaStreamTrack,
    copy,
    get requests() {return requests;}, get clones() {return clones;},
    get cloneStops() {return cloneStops;}, get originalStops() {return originalStops;},
  };
}

async function withProcessor<T>(constructor: unknown, run: () => Promise<T>): Promise<T> {
  const original = Object.getOwnPropertyDescriptor(globalThis, "MediaStreamTrackProcessor");
  try {
    if (constructor === undefined) Reflect.deleteProperty(globalThis, "MediaStreamTrackProcessor");
    else Object.defineProperty(globalThis, "MediaStreamTrackProcessor", {value: constructor, configurable: true});
    return await run();
  } finally {
    if (original) Object.defineProperty(globalThis, "MediaStreamTrackProcessor", original);
    else Reflect.deleteProperty(globalThis, "MediaStreamTrackProcessor");
  }
}

test("unsupported browser leaves the original canvas source untouched and never claims readiness", async () => {
  await withProcessor(undefined, async () => {
    const source = track();
    const ready = await awaitCanvasFrameReady(source.value, 1920, 1080, new AbortController().signal, () => {}, async () => {});
    assert.equal(ready, false);
    assert.deepEqual([source.clones, source.requests, source.cloneStops, source.originalStops], [0, 0, 0, 0]);
  });
});

test("a dimension-valid source frame is observed through a clone, closed, and detached before recording", async () => {
  const first = frame();
  const read = deferred<ReadableStreamReadResult<VideoFrame>>();
  let handedTrack: MediaStreamTrack | undefined, maxBufferSize = 0, cancels = 0, releases = 0, checks = 0;
  const order: string[] = [];
  const source = track(() => {order.push("request"); read.resolve({done: false, value: first.value});});
  class Processor {
    readable = {getReader: () => {order.push("sink"); return {read: () => read.promise,
      cancel: async () => {cancels++;}, releaseLock: () => {releases++;}};}};
    constructor(init: {track: MediaStreamTrack; maxBufferSize: number}) {
      handedTrack = init.track; maxBufferSize = init.maxBufferSize;
    }
  }
  await withProcessor(Processor, async () => {
    const signal = new AbortController().signal;
    assert.equal(await awaitCanvasFrameReady(source.value, 1920, 1080, signal,
      () => {checks++;}, async () => {order.push("paint");}), true);
    assert.equal(getEventListeners(signal, "abort").length, 0);
  });
  assert.equal(handedTrack, source.copy);
  assert.equal(maxBufferSize, 1);
  assert.deepEqual(order, ["sink", "paint", "request"]);
  assert.deepEqual([source.clones, source.requests, first.closed, cancels, releases, source.cloneStops, source.originalStops],
    [1, 1, 1, 1, 1, 1, 0]);
  assert(checks >= 3);
  assert.equal(source.value.readyState, "live");
});

test("abort preserves its reason and closes a frame delivered after cancellation", async () => {
  const late = frame(), read = deferred<ReadableStreamReadResult<VideoFrame>>();
  let cancels = 0, releases = 0;
  const source = track();
  class Processor {
    readable = {getReader: () => ({read: () => read.promise,
      cancel: async () => {cancels++;}, releaseLock: () => {releases++;}})};
  }
  await withProcessor(Processor, async () => {
    const controller = new AbortController(), reason = new Error("stale export");
    const pending = awaitCanvasFrameReady(source.value, 1920, 1080, controller.signal, () => {}, async () => {});
    controller.abort(reason);
    await assert.rejects(pending, error => error === reason);
    assert.equal(getEventListeners(controller.signal, "abort").length, 0);
  });
  read.resolve({done: false, value: late.value});
  await read.promise;
  await Promise.resolve();
  assert.deepEqual([late.closed, cancels, releases, source.cloneStops, source.originalStops], [1, 1, 1, 1, 0]);
});

test("abort during prepared painting closes an already delivered frame without requesting another", async () => {
  const first = frame(), painting = deferred<void>(), entered = deferred<void>();
  let cancels = 0;
  const source = track();
  class Processor {
    readable = {getReader: () => ({read: async () => ({done: false, value: first.value}),
      cancel: async () => {cancels++;}, releaseLock: () => {}})};
  }
  await withProcessor(Processor, async () => {
    const controller = new AbortController(), reason = new Error("cancel while painting");
    const pending = awaitCanvasFrameReady(source.value, 1920, 1080, controller.signal, () => {},
      async () => {entered.resolve(); await painting.promise;});
    await entered.promise;
    controller.abort(reason);
    painting.resolve();
    await assert.rejects(pending, error => error === reason);
  });
  assert.deepEqual([source.requests, first.closed, cancels, source.cloneStops, source.originalStops], [0, 1, 1, 1, 0]);
});

test("a processor rejection during a failed async paint cannot replace the paint failure", async () => {
  const source = track(), paintError = new Error("paint failed");
  class Processor {
    readable = {getReader: () => ({read: async () => {throw new Error("processor read failed");},
      cancel: async () => {}, releaseLock: () => {}})};
  }
  await withProcessor(Processor, async () => {
    await assert.rejects(awaitCanvasFrameReady(source.value, 1920, 1080,
      new AbortController().signal, () => {}, async () => {throw paintError;}), error => error === paintError);
  });
  assert.deepEqual([source.requests, source.cloneStops, source.originalStops], [0, 1, 0]);
});

test("timeout and wrong-size frames refuse before recorder admission and release only probe resources", async () => {
  const pendingRead = deferred<ReadableStreamReadResult<VideoFrame>>();
  const wrong = frame(1280, 720);
  let readResult = pendingRead.promise;
  const source = track();
  class Processor {
    readable = {getReader: () => ({read: () => readResult,
      cancel: async () => {}, releaseLock: () => {}})};
  }
  await withProcessor(Processor, async () => {
    await assert.rejects(awaitCanvasFrameReady(source.value, 1920, 1080,
      new AbortController().signal, () => {}, async () => {}, 10), /could not prepare the first video frame/);
    readResult = Promise.resolve({done: false, value: wrong.value});
    await assert.rejects(awaitCanvasFrameReady(source.value, 1920, 1080,
      new AbortController().signal, () => {}, async () => {}), /could not prepare a complete video frame/);
  });
  pendingRead.resolve({done: true, value: undefined});
  assert.equal(wrong.closed, 1);
  assert.deepEqual([source.clones, source.cloneStops, source.originalStops], [2, 2, 0]);
});

test("revision change after frame delivery refuses and closes the frame and probe", async () => {
  const first = frame();
  const source = track();
  let checks = 0, cloneStops = 0;
  class Processor {
    readable = {getReader: () => ({read: async () => ({done: false, value: first.value}),
      cancel: async () => {}, releaseLock: () => {}})};
  }
  source.copy.stop = () => {cloneStops++;};
  await withProcessor(Processor, async () => {
    await assert.rejects(awaitCanvasFrameReady(source.value, 1920, 1080, new AbortController().signal,
      () => {if (++checks === 3) throw new Error("revision changed");}, async () => {}), /revision changed/);
  });
  assert.equal(first.closed, 1);
  assert.equal(cloneStops, 1);
  assert.equal(source.originalStops, 0);
});

test("processor construction failure stops the clone without touching the original source", async () => {
  const source = track();
  class Processor {constructor() {throw new Error("processor refused");}}
  await withProcessor(Processor, async () => {
    await assert.rejects(awaitCanvasFrameReady(source.value, 1920, 1080,
      new AbortController().signal, () => {}, async () => {}), /processor refused/);
  });
  assert.deepEqual([source.clones, source.requests, source.cloneStops, source.originalStops], [1, 0, 1, 0]);
});

test("reader cancellation that never settles refuses readiness within its cleanup bound", async () => {
  const first = frame(), source = track();
  let releases = 0;
  class Processor {
    readable = {getReader: () => ({read: async () => ({done: false, value: first.value}),
      cancel: () => new Promise<void>(() => {}), releaseLock: () => {releases++;}})};
  }
  await withProcessor(Processor, async () => {
    const started = performance.now();
    await assert.rejects(awaitCanvasFrameReady(source.value, 1920, 1080,
      new AbortController().signal, () => {}, async () => {}), /did not finish cleanly/);
    assert(performance.now() - started < 1_000);
  });
  assert.deepEqual([first.closed, releases, source.cloneStops, source.originalStops], [1, 1, 1, 0]);
});
