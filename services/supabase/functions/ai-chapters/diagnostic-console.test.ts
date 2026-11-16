import { deleteFile, generateChapters, uploadVideoFromUrl, waitForActive, buildGenerateBody } from "./gemini.ts";
import { HttpError } from "../_shared/http.ts";

const HOSTILE = "diagnostic-fixture-public-marker customer@example.invalid https://media.fixture.invalid/private?cap=never-real files/customer-private-handle /private/customer.mov";
const FILE = "files/customer-private-handle";
const generate = { model: "fixture-model", fileUri: "https://files.fixture.invalid/owned", mimeType: "video/mp4", systemInstruction: "fixture-system", prompt: "fixture-prompt", fps: 1 };
function check(value: unknown, reason: string): asserts value { if (!value) throw new Error(reason); }
function equal(actual: unknown, expected: unknown, reason: string) { check(JSON.stringify(actual) === JSON.stringify(expected), reason); }
function src() { return new Response(new Uint8Array([1, 2, 3, 4]), { headers: { "content-length": "4" } }); }
function start() { return new Response("", { headers: { "x-goog-upload-url": "https://upload.fixture.invalid/session" } }); }
function uploaded() { return new Response(JSON.stringify({ file: { name: FILE, uri: generate.fileUri, mimeType: "video/mp4", sizeBytes: "4" } })); }

type Step = Response | Error;
async function closed(steps: Step[], run: () => Promise<void>) {
  const fetchBefore = globalThis.fetch;
  const methods = ["log", "info", "warn", "error", "debug", "trace", "dir", "table", "assert"] as const;
  const original = methods.map(method => [method, Object.getOwnPropertyDescriptor(console, method)!] as const);
  const logs: { method: string; args: unknown[] }[] = [], requests: { url: string; init?: RequestInit }[] = [];
  for (const method of methods) Object.defineProperty(console, method, { configurable: true, writable: true, value: (...args: unknown[]) => { logs.push({ method, args }); } });
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    requests.push({ url: input instanceof Request ? input.url : String(input), init });
    check(steps.length > 0, "Unexpected additional fetch");
    const next = steps.shift()!;
    return next instanceof Error ? Promise.reject(next) : Promise.resolve(next);
  }) as typeof fetch;
  try { await run(); check(steps.length === 0, "Every expected fetch was consumed"); return { logs, requests }; }
  finally { globalThis.fetch = fetchBefore; for (const [method, descriptor] of original) Object.defineProperty(console, method, descriptor); }
}
async function fixedError(run: () => Promise<unknown>, phase: string, status: number) {
  let failure: unknown;
  try { await run(); } catch (error) { failure = error; }
  check(failure instanceof HttpError, "Actual helper must preserve HttpError");
  equal([failure.status, failure.code, failure.message], [502, "upstream", `The video model could not be reached (${phase} returned ${status}). Try again in a moment.`], "Fixed client status/code/message unchanged");
}
function safe(logs: { method: string; args: unknown[] }[], phase: string, status: number | null, errorName?: string) {
  check(logs.length === 1 && logs[0]!.method === "error" && logs[0]!.args.length === 1, "One closed console event must survive");
  const serialized = JSON.stringify(logs);
  for (const forbidden of [HOSTILE, "diagnostic-fixture-public-marker", "customer@example.invalid", "media.fixture.invalid", FILE, "/private/customer.mov", "never-real"])
    check(!serialized.includes(forbidden), "Provider data reached console arguments");
  check(typeof logs[0]!.args[0] === "string", "Console event is serialized JSON");
  equal(JSON.parse(logs[0]!.args[0] as string), { event: "ai_chapters_provider_failure", phase, http_status: status, ...(errorName ? { error_name: errorName } : {}) }, "Exact closed event/phase/status must survive");
}

for (const phase of ["files:start", "files:upload", "files:get", "generateContent"] as const) {
  Deno.test(`actual ${phase} malicious response body stays out of every console argument`, async () => {
    const response = new Response(HOSTILE, { status: 503 });
    const steps = phase === "files:start" ? [src(), response] : phase === "files:upload" ? [src(), start(), response] : [response];
    const result = await closed(steps, async () => {
      await fixedError(() => phase === "files:get" ? waitForActive(FILE, Date.now() + 1000) : phase === "generateContent" ? generateChapters(generate) : uploadVideoFromUrl({ sourceUrl: "https://source.fixture.invalid/owned", mimeType: "video/mp4", displayName: "fixture", maxBytes: 4 }), phase, 503);
    });
    safe(result.logs, phase, 503);
  });
}
Deno.test("actual delete HTTP refusal keeps file handle out of every console argument", async () => {
  const result = await closed([new Response(HOSTILE, { status: 403 })], async () => { await deleteFile(FILE); });
  equal([result.requests[0]!.url, result.requests[0]!.init?.method], [`https://generativelanguage.googleapis.com/v1beta/${FILE}`, "DELETE"], "Original exact deletion request preserved");
  safe(result.logs, "files:delete", 403);
});
Deno.test("actual delete transport refusal keeps key body URL and file handle out of every console argument", async () => {
  const result = await closed([new TypeError(HOSTILE)], async () => { await deleteFile(FILE); });
  safe(result.logs, "files:delete", null, "TypeError");
});
for (const phase of ["files:upload", "generateContent"] as const) {
  Deno.test(`actual ${phase} malformed successful response preserves fixed client refusal and status`, async () => {
    const steps = phase === "files:upload" ? [src(), start(), new Response(HOSTILE)] : [new Response(HOSTILE)];
    const result = await closed(steps, async () => { await fixedError(() => phase === "generateContent" ? generateChapters(generate) : uploadVideoFromUrl({ sourceUrl: "https://source.fixture.invalid/owned", mimeType: "video/mp4", displayName: "fixture", maxBytes: 4 }), phase, 200); });
    safe(result.logs, phase, 200);
  });
}
Deno.test("actual successful upload preserves source stream metadata and provider receipt", async () => {
  const result = await closed([src(), start(), uploaded()], async () => {
    equal(await uploadVideoFromUrl({ sourceUrl: "https://source.fixture.invalid/owned", mimeType: "video/mp4", displayName: "fixture", maxBytes: 4 }), { name: FILE, uri: generate.fileUri, mimeType: "video/mp4", sizeBytes: 4 }, "Actual upload receipt unchanged");
  });
  check(result.requests[2]!.init?.body instanceof ReadableStream, "Original streamed upload body retained");
  equal(result.logs, [], "No success diagnostic added");
});
Deno.test("actual successful active status remains unchanged", async () => {
  const result = await closed([new Response(JSON.stringify({ name: FILE, state: "ACTIVE" }))], async () => { await waitForActive(FILE, Date.now() + 1000); });
  equal(result.logs, [], "No success diagnostic added");
});
Deno.test("actual successful generation preserves request and raw result token evidence", async () => {
  const result = await closed([new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: "{\"chapters\":[]}" }] }, finishReason: "STOP" }], usageMetadata: { promptTokenCount: 3, candidatesTokenCount: 4 } }))], async () => {
    equal(await generateChapters(generate), { text: "{\"chapters\":[]}", promptTokens: 3, outputTokens: 4, finishReason: "STOP" }, "Actual generated result unchanged");
  });
  equal(JSON.parse(result.requests[0]!.init!.body as string), buildGenerateBody(generate), "Exact existing provider request body retained");
  equal(result.logs, [], "No success diagnostic added");
});
Deno.test("actual successful delete remains best effort without logs", async () => {
  const result = await closed([new Response(null, { status: 204 })], async () => { await deleteFile(FILE); });
  equal(result.logs, [], "Successful deletion remains silent");
});
