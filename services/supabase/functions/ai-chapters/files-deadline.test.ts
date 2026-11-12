import { deleteFile, generateChapters, uploadVideoFromUrl, waitForActive } from "./gemini.ts";
import { HttpError } from "../_shared/http.ts";
import { ProviderHttpError } from "../_shared/providers/common.ts";

function check(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));
const uploadArgs = () => ({ sourceUrl: "https://source.fixture.invalid/video", mimeType: "video/mp4", displayName: "synthetic", maxBytes: 300_000_000, deadlineMs: Date.now() + 35 });
const generation = { model: "fixture", fileUri: "https://files.fixture.invalid/video", mimeType: "video/mp4", prompt: "synthetic", systemInstruction: "synthetic", fps: 1 };
const uploaded = () => new Response(JSON.stringify({ file: { name: "files/synthetic", uri: generation.fileUri, sizeBytes: "4", mimeType: "video/mp4" } }));
// Structural argument variables let the exact same normal-checked tests execute against the old API, where extra deadline fields were ignored.
const upload = (args: ReturnType<typeof uploadArgs>) => uploadVideoFromUrl(args);
const generate = (args: typeof generation & { deadlineMs?: number }) => generateChapters(args);
const started = () => new Response(null, { headers: { "x-goog-upload-url": "https://upload.fixture.invalid/session" } });
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }
function source() {
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({ start(c) { c.enqueue(new Uint8Array([1,2,3,4])); }, cancel() { cancelled = true; } });
  return { response: new Response(body, { headers: { "content-length": "4" } }), cancelled: () => cancelled };
}
async function closed(run: (calls: { url: string; init?: RequestInit }[]) => Promise<void>, fetcher: (url: string, init?: RequestInit) => Promise<Response>) {
  const previous = globalThis.fetch, calls: { url: string; init?: RequestInit }[] = [];
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => { const url = input instanceof Request ? input.url : String(input); calls.push({ url, init }); return fetcher(url, init); }) as typeof fetch;
  try { await run(calls); } finally { globalThis.fetch = previous; }
}
async function rejectedBeforeRelease(operation: () => Promise<unknown>, release: () => void, beforeRelease?: () => void) {
  let settled = false, error: unknown;
  const pending = operation().then(() => { settled = true; }, e => { settled = true; error = e; });
  try {
    await sleep(90); const bounded = settled;
    beforeRelease?.(); release(); await pending;
    check(bounded, "operation waited for the externally released stalled transport/body instead of its deadline");
    check(error instanceof HttpError && error.status === 504 && error.code === "upstream", "deadline must preserve a fixed existing-style HttpError504");
    check(!(error instanceof ProviderHttpError), "Files/timeout failure must not prove paid-generation rejection");
  } finally { release(); await pending; }
}

Deno.test("Files source fetch headers have one absolute deadline and late-body cleanup", async () => {
  const gate = deferred<Response>(), src = source();
  await closed(async calls => {
    await rejectedBeforeRelease(() => upload(uploadArgs()), () => gate.resolve(src.response));
    await sleep(0); check(src.cancelled(), "late source response body was not cancelled");
    check(calls.length === 1 && calls[0].init?.signal?.aborted, "no upload may follow source timeout");
  }, async () => gate.promise);
});
Deno.test("Files resumable start stalled fetch aborts and promptly cancels source", async () => {
  const gate = deferred<Response>(), src = source();
  await closed(async calls => {
    await rejectedBeforeRelease(() => upload(uploadArgs()), () => gate.resolve(started()), () => { check(src.cancelled(), "source remained open during start timeout"); });
    check(calls.length === 2 && calls.every(c => c.init?.signal?.aborted), "a timed-out start must not reach upload");
  }, async url => url.includes("source.fixture") ? src.response : url.includes("upload.fixture") ? uploaded() : gate.promise);
});
Deno.test("Files stalled error response body expires and cancels both readers", async () => {
  const src = source(), gate = deferred<void>(); let bodyCancelled = false;
  const body = new ReadableStream<Uint8Array>({ start(c) { void gate.promise.then(() => { try { c.close(); } catch { /* already cancelled */ } }); }, cancel() { bodyCancelled = true; } });
  await closed(async () => {
    await rejectedBeforeRelease(() => upload(uploadArgs()), () => gate.resolve(), () => { check(src.cancelled() && bodyCancelled, "stalled error body/source not cancelled at timeout"); });
  }, async url => url.includes("source.fixture") ? src.response : new Response(body, { status: 503 }));
});
Deno.test("Files stalled source streaming is deadline-bound without buffering video", async () => {
  const gate = deferred<void>(); let cancelled = false, receivedStream = false;
  const body = new ReadableStream<Uint8Array>({ start(c) { void gate.promise.then(() => { try { c.enqueue(new Uint8Array([1,2,3,4])); c.close(); } catch { /* cancelled */ } }); }, cancel() { cancelled = true; } });
  await closed(async calls => {
    await rejectedBeforeRelease(() => upload(uploadArgs()), () => gate.resolve(), () => { check(cancelled, "stalled storage reader was not cancelled promptly"); });
    check(receivedStream && calls.length === 3, "upload must remain exactly one streaming POST");
  }, async (url, init) => {
    if (url.includes("source.fixture")) return new Response(body, { headers: { "content-length": "4" } });
    if (!url.includes("upload.fixture")) return started();
    receivedStream = init?.body instanceof ReadableStream;
    const reader = (init!.body as ReadableStream<Uint8Array>).getReader();
    try { while (!(await reader.read()).done) { /* no media aggregation */ } } finally { reader.releaseLock(); }
    return uploaded();
  });
});
Deno.test("Files upload stalled fetch is bounded and source is cancelled", async () => {
  const src = source(), gate = deferred<Response>();
  await closed(async () => {
    await rejectedBeforeRelease(() => upload(uploadArgs()), () => gate.resolve(uploaded()), () => { check(src.cancelled(), "source stayed locked during upload timeout"); });
  }, async url => url.includes("source.fixture") ? src.response : url.includes("upload.fixture") ? gate.promise : started());
});
Deno.test("Files upload response-body deadline cancels reader and source", async () => {
  const src = source(), gate = deferred<void>(); let cancelled = false;
  const body = new ReadableStream<Uint8Array>({ start(c) { void gate.promise.then(() => { try { c.enqueue(new TextEncoder().encode('{"file":{"name":"files/synthetic","uri":"https://files.fixture.invalid/video"}}')); c.close(); } catch { /* cancelled */ } }); }, cancel() { cancelled = true; } });
  await closed(async () => {
    await rejectedBeforeRelease(() => upload(uploadArgs()), () => gate.resolve(), () => { check(cancelled && src.cancelled(), "upload response/source not cancelled before release"); });
  }, async url => url.includes("source.fixture") ? src.response : url.includes("upload.fixture") ? new Response(body) : started());
});
Deno.test("Files malformed upload receipt promptly cancels still-open source", async () => {
  const src = source(); let failure: unknown;
  await closed(async () => {
    try { await upload({ ...uploadArgs(), deadlineMs: Date.now() + 1000 }); } catch (e) { failure = e; }
    check(failure instanceof HttpError && failure.status === 502 && !(failure instanceof ProviderHttpError), "malformed Files response must remain non-paid fixed refusal");
    check(src.cancelled(), "parse failure left source unowned");
  }, async url => url.includes("source.fixture") ? src.response : url.includes("upload.fixture") ? new Response("malformed") : started());
});
for (const stage of ["headers", "body"] as const) Deno.test(`Files poll ${stage} deadline cancels without another GET`, async () => {
  const gate = deferred<Response>(), bodyGate = deferred<void>(); let cancelled = false;
  const body = new ReadableStream<Uint8Array>({ start(c) { void bodyGate.promise.then(() => { try { c.enqueue(new TextEncoder().encode('{"state":"ACTIVE"}')); c.close(); } catch { /* cancelled */ } }); }, cancel() { cancelled = true; } });
  await closed(async calls => {
    await rejectedBeforeRelease(() => waitForActive("files/synthetic", Date.now() + 35), () => { if (stage === "headers") gate.resolve(new Response(body)); bodyGate.resolve(); });
    await sleep(0); check(cancelled && calls.length === 1 && calls[0].init?.signal?.aborted, "poll deadline did not close owned response/no-more-GET fence");
  }, async () => stage === "headers" ? gate.promise : new Response(body));
});
Deno.test("Files PROCESSING cadence cannot sleep beyond whole poll deadline", async () => {
  await closed(async calls => {
    await rejectedBeforeRelease(() => waitForActive("files/synthetic", Date.now() + 35), () => {});
    check(calls.length === 1, "expired polling cannot make another GET");
  }, async () => new Response('{"state":"PROCESSING"}'));
});
Deno.test("Files DELETE never extends caller final deadline or retries", async () => {
  const gate = deferred<Response>(), erase = deleteFile as (name: string, deadlineMs?: number) => Promise<void>;
  await closed(async calls => {
    let done = false; const pending = erase("files/synthetic", Date.now() + 35).then(() => { done = true; });
    try { await sleep(90); const prompt = done; gate.resolve(new Response(null, { status: 204 })); await pending; check(prompt, "DELETE extended caller final deadline"); check(calls.length === 1 && calls[0].init?.signal?.aborted, "DELETE must be one bounded attempt"); }
    finally { gate.resolve(new Response(null, { status: 204 })); await pending; }
  }, async () => gate.promise);
});
Deno.test("Files DELETE does not await a stuck body cancellation", async () => {
  const gate = deferred<void>(); let cancelled = false;
  const body = new ReadableStream({ cancel() { cancelled = true; return gate.promise; } });
  await closed(async () => {
    let done = false; const pending = deleteFile("files/synthetic").then(() => { done = true; });
    try { await sleep(30); const prompt = done; gate.resolve(); await pending; check(prompt && cancelled, "best-effort DELETE blocked on body cancel promise"); }
    finally { gate.resolve(); await pending; }
  }, async () => new Response(body));
});
Deno.test("Files HTTP rejection never becomes definitive paid generation evidence", async () => {
  await closed(async () => {
    let failure: unknown; try { await waitForActive("files/synthetic", Date.now() + 1000); } catch (e) { failure = e; }
    check(failure instanceof HttpError && failure.status === 502 && !(failure instanceof ProviderHttpError), "Files403 must stay a plain HttpError");
  }, async () => new Response('{"error":{"code":403}}', { status: 403 }));
});
Deno.test("generateContent typed definitive HTTP evidence is unchanged", async () => {
  await closed(async () => {
    let failure: unknown; try { await generate(generation); } catch (e) { failure = e; }
    check(failure instanceof ProviderHttpError && failure.status === 502 && failure.providerFailure.dispatch_rejected, "only actual model rejection retains typed definitive evidence");
  }, async () => new Response('{"error":{"code":403}}', { status: 403 }));
});
Deno.test("generateContent respects remaining caller budget without paid retry evidence", async () => {
  const gate = deferred<Response>();
  await closed(async calls => {
    await rejectedBeforeRelease(() => generate({ ...generation, deadlineMs: Date.now() + 35 }), () => gate.resolve(new Response('{"candidates":[]}')));
    check(calls.length === 1, "timeout must not automatically resubmit the paid model");
  }, async () => gate.promise);
});
Deno.test("expired caller budget starts no Files or generation request", async () => {
  await closed(async calls => {
    for (const run of [() => upload({ ...uploadArgs(), deadlineMs: Date.now() - 1 }), () => waitForActive("files/synthetic", Date.now() - 1), () => generate({ ...generation, deadlineMs: Date.now() - 1 })]) {
      let failure: unknown; try { await run(); } catch (e) { failure = e; }
      check(failure instanceof HttpError && failure.status === 504 && !(failure instanceof ProviderHttpError), "expired budget did not fail before dispatch");
    }
    check(calls.length === 0, "expired budget reached a request");
  }, async () => { throw new Error("unexpected fetch"); });
});

// Reuse the existing closed handler fixture text, retaining its actual request
// handler and funded-serving calls. Only synthetic provider doubles observe args.
Deno.test("actual chapter caller shares105s work and caps cleanup inside110s", async () => {
  let text = await Deno.readTextFile(new URL("./failure-recovery.test.ts", import.meta.url));
  text = text.slice(0, text.indexOf("const request ="))
    .replace("async function fixture(", "export async function fixture(")
    .replace("const uploadVideoFromUrl=async()=>{state.uploads++;", "const uploadVideoFromUrl=async(args:any)=>{(state as any).uploadDeadline=args.deadlineMs;(state as any).maxBytes=args.maxBytes;state.uploads++;")
    .replace("const waitForActive=async()=>{},deleteFile=async()=>{state.deletions++;};", "const waitForActive=async(_name:string,deadline:number)=>{(state as any).activeDeadline=deadline;},deleteFile=async(_name:string,deadline:number)=>{(state as any).deleteDeadline=deadline;state.deletions++;};")
    .replace("const generateChapters=async()=>{state.generations++;", "const generateChapters=async(args:any)=>{(state as any).generationDeadline=args.deadlineMs;state.generations++;");
  // Preserve fixture import.meta.url-relative imports and source reads.
  text = text.replaceAll("import.meta.url", JSON.stringify(new URL("./failure-recovery.test.ts", import.meta.url).href));
  const module = await import("data:application/typescript;base64," + btoa(String.fromCharCode(...new TextEncoder().encode(text))));
  const before = Date.now(), f = await module.fixture("none");
  const response = await f.handler(new Request("https://fixture.invalid/ai-chapters", { method: "POST", headers: { "content-type": "application/json", "idempotency-key": crypto.randomUUID() }, body: JSON.stringify({ listing_id: "synthetic-listing", asset_id: "synthetic-asset" }) }));
  const after = Date.now(); check(response.status === 200, "actual closed handler failed");
  check(f.state.uploadDeadline >= before + 105000 && f.state.uploadDeadline <= after + 105000, "upload lost105s absolute work budget");
  check(f.state.activeDeadline === f.state.uploadDeadline && f.state.generationDeadline === f.state.uploadDeadline, "poll/generation did not share original absolute deadline");
  check(f.state.deleteDeadline <= f.state.uploadDeadline + 5000 && f.state.deleteDeadline <= after + 5000, "DELETE extends original110s final deadline");
  check(f.state.maxBytes === 300000000 && f.state.attempts === 1 && f.state.generations === 1 && f.state.deletions === 1, "real300MB or paid-call/cleanup cardinality changed");
});
