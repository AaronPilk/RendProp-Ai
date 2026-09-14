import test from "node:test";
import assert from "node:assert/strict";
import { awaitMediaOperation, waitForEvent } from "../src/editor/media.ts";

test("a blocked native media promise exits promptly on cancellation", async () => {
  const controller = new AbortController();
  const pending = awaitMediaOperation(
    new Promise<void>(() => {}),
    controller.signal,
    "Starting audio",
  );
  controller.abort(new DOMException("User cancelled export.", "AbortError"));
  await assert.rejects(pending, {
    name: "AbortError",
    message: "User cancelled export.",
  });
});

test("a blocked native media promise has a real deadline", async () => {
  await assert.rejects(
    awaitMediaOperation(
      new Promise<void>(() => {}),
      new AbortController().signal,
      "Starting video",
      5,
    ),
    /Starting video took too long/,
  );
});

test("media event waits resolve on success and fail on decode error or cancellation", async () => {
  const target = new EventTarget();
  const controller = new AbortController();
  const success = waitForEvent(target, "loadeddata", controller.signal);
  target.dispatchEvent(new Event("loadeddata"));
  await success;
  const failure = waitForEvent(target, "loadeddata", controller.signal);
  target.dispatchEvent(new Event("error"));
  await assert.rejects(failure, /could not decode/);
  const cancelled = waitForEvent(target, "loadeddata", controller.signal);
  controller.abort();
  await assert.rejects(cancelled, { name: "AbortError" });
});
