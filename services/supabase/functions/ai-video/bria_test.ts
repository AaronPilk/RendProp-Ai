// Offline fixtures derived from CURRENT published Bria contracts (2026-10-02):
// https://docs.bria.ai/_bundle/video-editing.json (202 receipt/body schemas)
// https://docs.bria.ai/_bundle/status.json (identity/status/result schemas)
// https://github.com/Bria-AI/ComfyUI-BRIA-API/blob/main/nodes/video_nodes/video_mask_by_prompt_node.py
// mask_url is also used by Bria's node; the OpenAPI SDK sample uses video_url.
// These are synthetic fixtures; no live job or output host has been observed.
// Run without network/env permission: deno test --deny-net --deny-env bria_test.ts
import {
  BRIA_ERASE_ENDPOINT,
  BRIA_MASK_ENDPOINT,
  BRIA_ORIGIN,
  BriaError,
  type BriaErrorOutcome,
  type BriaMaskInput,
  type BriaRef,
  createBriaAdapter,
  readBriaRef,
} from "./bria.ts";
function ok(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(actual: unknown, expected: unknown) {
  ok(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${JSON.stringify(actual)} != ${JSON.stringify(expected)}`,
  );
}
async function refuses(
  run: () => unknown | Promise<unknown>,
  outcome: BriaErrorOutcome,
): Promise<BriaError> {
  try {
    await run();
  } catch (error) {
    ok(error instanceof BriaError, "Expected BriaError");
    equal(error.outcome, outcome);
    return error;
  }
  throw new Error("Expected refusal: " + outcome);
}
const id = "860f1a2b73f847e59f284d6f860f2ddb"; // Official status example id.
const ref: BriaRef = {
  request_id: id,
  status_url: `${BRIA_ORIGIN}/v2/status/${id}`,
};
const hosts = ["synthetic-output.bria.ai"];
const output =
  "https://synthetic-output.bria.ai/result.mp4?signature=synthetic";
const mask = "https://synthetic-output.bria.ai/mask.mp4?signature=synthetic";
const input: BriaMaskInput = {
  videoUrl:
    "https://synthetic-upload.supabase.co/video.mp4?signature=synthetic",
  durationSeconds: 2.5,
  prompt: "The photographer, reflected people, and reflected phones or cameras",
};
function harness(
  handler: (url: string, init: RequestInit) => Response | Promise<Response> =
    () => Response.json(ref, { status: 202 }),
  options: { token?: string; hosts?: string[]; timeoutMs?: number } = {},
) {
  const calls: { url: string; init: RequestInit }[] = [];
  let tokenCalls = 0;
  const adapter = createBriaAdapter({
    fetch: async (url, init) => {
      calls.push({ url, init });
      return await handler(url, init);
    },
    apiToken: () => {
      tokenCalls++;
      return options.token ?? "synthetic-not-a-credential";
    },
    outputHosts: options.hosts ?? hosts,
    timeoutMs: options.timeoutMs,
  });
  return { adapter, calls, tokenCalls: () => tokenCalls };
}
function complete(result: unknown, overrides: Record<string, unknown> = {}) {
  return Response.json({
    request_id: id,
    status: "COMPLETED",
    result,
    ...overrides,
  });
}
function mp4Bytes(): Uint8Array<ArrayBuffer> {
  return new Uint8Array([
    0,
    0,
    0,
    24,
    102,
    116,
    121,
    112,
    105,
    115,
    111,
    109,
    0,
    0,
    0,
    0,
    105,
    115,
    111,
    109,
    109,
    112,
    52,
    50,
  ]);
}
Deno.test("Bria mask and erase use exact distinct v2 endpoints and closed request bodies", async () => {
  const h = harness();
  equal(await h.adapter.submitMask(input), ref);
  equal(await h.adapter.submitErase(input, mask), ref);
  equal(h.calls.map((c) => c.url), [BRIA_MASK_ENDPOINT, BRIA_ERASE_ENDPOINT]);
  equal(JSON.parse(String(h.calls[0].init.body)), {
    video: input.videoUrl,
    prompt: input.prompt,
    auto_trim: false,
    output_container_and_codec: "mp4_h264",
  });
  equal(JSON.parse(String(h.calls[1].init.body)), {
    video: input.videoUrl,
    mask,
    preserve_audio: true,
    auto_trim: false,
    output_container_and_codec: "mp4_h264",
  });
  for (const call of h.calls) {
    equal(call.init.method, "POST");
    equal(call.init.redirect, "error");
    equal(
      new Headers(call.init.headers).get("api_token"),
      "synthetic-not-a-credential",
    );
    equal(new Headers(call.init.headers).get("authorization"), null);
    ok(call.init.signal instanceof AbortSignal);
  }
});
Deno.test("Bria readiness requires token, explicit exact hosts and a bounded timeout", async () => {
  for (
    const options of [
      { token: "" },
      { token: "secret\nheader" },
      { hosts: [] },
      { hosts: ["*.bria.ai"] },
      { hosts: ["localhost"] },
      { hosts: ["127.0.0.1"] },
      { hosts: ["cdn.bria.ai:443"] },
      { hosts: ["CDN.BRIA.AI"] },
      { timeoutMs: 0 },
      { timeoutMs: 25001 },
      { timeoutMs: NaN },
    ]
  ) {
    const h = harness(undefined, options);
    equal(h.adapter.configured(), false);
    await refuses(() => h.adapter.submitMask(input), "configuration");
    equal(h.calls.length, 0);
  }
  equal(harness().adapter.configured(), true);
  const h = createBriaAdapter({
    fetch: () => {
      throw new Error("Must not fetch");
    },
    apiToken: () => {
      throw new Error("private exception");
    },
    outputHosts: hosts,
  });
  equal(h.configured(), false);
  equal(
    (await refuses(() => h.submitMask(input), "configuration")).message,
    "Direct Bria is not configured",
  );
});
Deno.test("Bria input limits reject invalid durations before credential lookup or dispatch", async () => {
  const h = harness();
  for (
    const duration of [0, -1, 5, 5.001, NaN, Infinity, null, "2", undefined]
  ) {
    await refuses(() =>
      h.adapter.submitMask({
        ...input,
        durationSeconds: duration as number,
      }), "invalid");
    await refuses(() =>
      h.adapter.submitErase({
        ...input,
        durationSeconds: duration as number,
      }, mask), "invalid");
  }
  equal(h.tokenCalls(), 0);
  equal(h.calls.length, 0);
  for (const duration of [0.001, 4.999]) {
    await h.adapter.submitMask({ ...input, durationSeconds: duration });
    equal(JSON.parse(String(h.calls.at(-1)!.init.body)).video, input.videoUrl);
  }
});
Deno.test("Bria refuses unsafe source URLs and prompts without echoing private data", async () => {
  const h = harness();
  for (
    const url of [
      "",
      "http://public.example.com/a",
      "file:///private/a",
      "data:video/mp4;base64,AA",
      "https://localhost/a",
      "https://host.local/a",
      "https://host.internal/a",
      "https://169.254.169.254/a",
      "https://127.0.0.1/a",
      "https://[::1]/a",
      "https://2130706433/a",
      "https://0177.0.0.1/a",
      "https://0x7f000001/a",
      "https://public.example.com:8443/a",
      "https://user:secret@public.example.com/a",
      "https://public.example.com/a#secret",
      "https://public.example.com/\\a",
      " https://public.example.com/a",
      "https://public.example.com/a b",
      "https://public.example.com/a\u0000",
      `https://public.example.com/${"x".repeat(8192)}`,
    ]
  ) {
    const error = await refuses(
      () => h.adapter.submitMask({ ...input, videoUrl: url }),
      "invalid",
    );
    if (url) ok(!error.message.includes(url));
  }
  for (
    const prompt of ["", " ", "x".repeat(6001), "private\u0000prompt", null, 42]
  ) {
    await refuses(
      () => h.adapter.submitMask({ ...input, prompt: prompt as string }),
      "invalid",
    );
  }
  equal(h.tokenCalls(), 0);
  equal(h.calls.length, 0);
});
Deno.test("Bria retained refs reject all alternate hosts, paths and mismatched identity before auth", async () => {
  const h = harness();
  for (
    const url of [
      ref.status_url.replace(id, "different-id"),
      ref.status_url.replace("/status/", "/video/edit/"),
      ref.status_url + "/",
      ref.status_url + "?private=secret",
      ref.status_url + "#secret",
      ref.status_url.replace("https:", "http:"),
      ref.status_url.replace(
        "engine.prod.bria-api.com",
        "engine.prod.bria-api.com.evil.com",
      ),
      ref.status_url.replace(
        "engine.prod.bria-api.com",
        "user:secret@engine.prod.bria-api.com",
      ),
      ref.status_url.replace(
        "engine.prod.bria-api.com",
        "engine.prod.bria-api.com:443",
      ),
      ref.status_url.replace("/status/", "/status/%2e%2e/status/"),
      ref.status_url.replace(id, "%38" + id.slice(1)),
    ]
  ) {
    const candidate = { ...ref, status_url: url };
    await refuses(() => readBriaRef(candidate), "invalid");
    await refuses(() => h.adapter.poll(candidate, "mask"), "invalid");
  }
  for (
    const value of [null, [], {}, { ...ref, request_id: 123 }, {
      ...ref,
      request_id: "../secret",
    }, { ...ref, request_id: "short" }]
  ) {
    await refuses(() => readBriaRef(value), "invalid");
  }
  equal(h.tokenCalls(), 0);
  equal(h.calls.length, 0);
});
Deno.test("Bria each explicit rejection cancels body without parsing or leaking it", async () => {
  for (const status of [400, 401, 403, 404, 405, 413, 415, 422, 429]) {
    let cancelled = false;
    const h = harness(() =>
      new Response(
        new ReadableStream({
          start(c) {
            c.enqueue(new TextEncoder().encode("private-token-and-url"));
          },
          cancel() {
            cancelled = true;
          },
        }),
        { status },
      )
    );
    const error = await refuses(() => h.adapter.submitMask(input), "rejected");
    equal(error.httpStatus, status);
    ok(!error.message.includes("private"));
    equal(h.calls.length, 1);
    ok(cancelled);
  }
});
Deno.test("Bria ambiguous HTTP submissions never retry or substitute an endpoint", async () => {
  for (const status of [200, 201, 204, 301, 302, 408, 409, 500, 503]) {
    const h = harness(() => new Response(null, { status }));
    const error = await refuses(() => h.adapter.submitMask(input), "uncertain");
    equal(error.httpStatus, status);
    equal(h.calls.length, 1);
    equal(h.calls[0].url, BRIA_MASK_ENDPOINT);
  }
  const h = harness(() => {
    throw new Error("private-token or private-input-url");
  });
  const error = await refuses(
    () => h.adapter.submitErase(input, mask),
    "uncertain",
  );
  ok(!error.message.includes("private"));
  equal(h.calls.length, 1);
  equal(h.calls[0].url, BRIA_ERASE_ENDPOINT);
});
Deno.test("Bria malformed accepted receipts remain uncertain and produce exactly one POST", async () => {
  for (
    const data of [
      null,
      [],
      {},
      { ...ref, request_id: 42 },
      { ...ref, status_url: "https://evil.example.com/status" },
      { ...ref, result: { video_url: output } },
      { ...ref, error: { message: "private" } },
    ]
  ) {
    const h = harness(() => Response.json(data, { status: 202 }));
    await refuses(() => h.adapter.submitMask(input), "uncertain");
    equal(h.calls.length, 1);
  }
});
Deno.test("Bria JSON response limits apply to content length, streamed bytes, encoding and shape", async () => {
  const responses = [
    () =>
      new Response("private html", {
        status: 202,
        headers: { "content-type": "text/html" },
      }),
    () =>
      new Response("{private", {
        status: 202,
        headers: { "content-type": "application/json" },
      }),
    () =>
      new Response(JSON.stringify(ref), {
        status: 202,
        headers: {
          "content-type": "application/json",
          "content-length": "65537",
        },
      }),
    () =>
      new Response(JSON.stringify(ref), {
        status: 202,
        headers: { "content-type": "application/json", "content-length": "-1" },
      }),
    () =>
      new Response(JSON.stringify(ref).padEnd(65537, " "), {
        status: 202,
        headers: { "content-type": "application/json" },
      }),
    () =>
      new Response(new Uint8Array([0xff]), {
        status: 202,
        headers: { "content-type": "application/json" },
      }),
  ];
  for (const response of responses) {
    const h = harness(response);
    const error = await refuses(() => h.adapter.submitMask(input), "uncertain");
    ok(!error.message.includes("private"));
    equal(h.calls.length, 1);
  }
  // Positive control: the exact byte cap is accepted, not silently reduced.
  const atLimit = JSON.stringify(ref).padEnd(65536, " ");
  const h = harness(() =>
    new Response(atLimit, {
      status: 202,
      headers: {
        "content-type": "application/json",
        "content-length": "65536",
      },
    })
  );
  equal(await h.adapter.submitMask(input), ref);
});
Deno.test("Bria timeout covers stalled POST, stalled JSON and never resubmits", async () => {
  const cases = [
    () => new Promise<Response>(() => {}),
    () =>
      new Response(new ReadableStream({ start() {} }), {
        status: 202,
        headers: { "content-type": "application/json" },
      }),
  ];
  for (const handler of cases) {
    const h = harness(handler, { timeoutMs: 15 });
    await refuses(() => h.adapter.submitMask(input), "uncertain");
    equal(h.calls.length, 1);
    ok(h.calls[0].init.signal?.aborted);
  }
});
Deno.test("Bria polling resumes one retained request with GET only and preserves identity", async () => {
  const h = harness(() =>
    Response.json({ request_id: id, status: "IN_PROGRESS" })
  );
  equal(await h.adapter.poll(JSON.parse(JSON.stringify(ref)), "mask"), {
    status: "processing",
  });
  equal(h.calls.length, 1);
  equal(h.calls[0].url, ref.status_url);
  equal(h.calls[0].init.method, "GET");
  equal(h.calls[0].init.body, undefined);
  equal(h.calls[0].init.redirect, "error");
  for (const stage of ["unknown", null, "MASK"] as unknown[]) {
    await refuses(() => h.adapter.poll(ref, stage as "mask"), "invalid");
  }
  equal(h.calls.length, 1);
});
Deno.test("Bria documented mask_url and video_url forms parse without inventing other result shapes", async () => {
  for (
    const result of [{ mask_url: mask }, { video_url: mask }, {
      mask_url: mask,
      video_url: mask,
    }]
  ) {
    const h = harness(() => complete(result));
    equal(await h.adapter.poll(ref, "mask"), {
      status: "completed",
      output_url: mask,
    });
    equal(h.calls.length, 1);
    equal(h.calls[0].init.method, "GET");
  }
  equal(
    await harness(() => complete({ video_url: output })).adapter.poll(
      ref,
      "erase",
    ),
    { status: "completed", output_url: output },
  );
  for (
    const result of [
      { mask_url: mask, video_url: output },
      { video: { url: output } },
      { url: output },
      { image_url: output },
      { video_url: 123 },
    ]
  ) {
    await refuses(
      () => harness(() => complete(result)).adapter.poll(ref, "mask"),
      "status",
    );
  }
  await refuses(
    () =>
      harness(() => complete({ mask_url: mask })).adapter.poll(ref, "erase"),
    "status",
  );
});
Deno.test("Bria ERROR, UNKNOWN and defensive FAILED are safely handled job failures", async () => {
  for (const status of ["ERROR", "UNKNOWN", "FAILED", "CANCELLED"]) {
    const h = harness(() =>
      Response.json({
        request_id: id,
        status,
        error: {
          code: 500,
          message: "private token",
          details: "private signed url",
        },
      })
    );
    equal(await h.adapter.poll(ref, "erase"), {
      status: "failed",
      error: "Bria reflection processing failed",
    });
    equal(h.calls.length, 1);
  }
  const h = harness(() =>
    new Response("private expired request", { status: 404 })
  );
  equal(await h.adapter.poll(ref, "erase"), {
    status: "failed",
    error: "Bria request is unavailable",
  });
});
Deno.test("Bria status identity, contradictory states and unknown states never produce completed output", async () => {
  for (
    const data of [
      {
        request_id: "different-id",
        status: "COMPLETED",
        result: { video_url: output },
      },
      { status: "COMPLETED", result: { video_url: output } },
      { request_id: id, status: "completed", result: { video_url: output } },
      { request_id: id, status: "IN_QUEUE" },
      { request_id: id, status: "IN_PROGRESS", result: { video_url: output } },
      { request_id: id, status: "IN_PROGRESS", error: { message: "private" } },
      {
        request_id: id,
        status: "COMPLETED",
        result: { video_url: output },
        error: { message: "private" },
      },
      { request_id: id, status: "COMPLETED", result: [] },
    ]
  ) {
    const h = harness(() => Response.json(data));
    const error = await refuses(() => h.adapter.poll(ref, "erase"), "status");
    ok(!error.message.includes("private"));
    equal(h.calls.length, 1);
  }
});
Deno.test("Bria output warnings require review and never expose provider text", async () => {
  const h = harness(() =>
    complete({ video_url: output, warning: "private provider details" })
  );
  equal(await h.adapter.poll(ref, "erase"), {
    status: "failed",
    error: "Bria adjusted the requested output",
  });
  equal(
    await harness(() => complete({ video_url: output, warning: null })).adapter
      .poll(ref, "erase"),
    { status: "completed", output_url: output },
  );
});
Deno.test("Bria status transport and HTTP failures remain read-only and scrub upstream details", async () => {
  for (
    const handler of [
      () => new Response("private status token", { status: 500 }),
      () => {
        throw new Error("private status URL");
      },
      () => new Promise<Response>(() => {}),
    ]
  ) {
    const h = harness(handler, { timeoutMs: 15 });
    const error = await refuses(() => h.adapter.poll(ref, "erase"), "status");
    ok(!error.message.includes("private"));
    equal(h.calls.length, 1);
    equal(h.calls[0].init.method, "GET");
  }
});
Deno.test("Bria output exact allowlist cannot expand after configuration and blocks unsafe results", async () => {
  const mutable = [...hosts], h = harness(undefined, { hosts: mutable });
  mutable.push("attacker.example.com");
  for (
    const url of [
      "https://attacker.example.com/result.mp4",
      "https://synthetic-output.bria.ai.evil.com/result.mp4",
      "https://child.synthetic-output.bria.ai/result.mp4",
      "https://127.0.0.1/result.mp4",
      "https://169.254.169.254/result.mp4",
      "https://user:token@synthetic-output.bria.ai/result.mp4",
      "https://synthetic-output.bria.ai:8443/result.mp4",
      "https://synthetic-output.bria.ai/result.mp4#token",
      "file:///private/result.mp4",
    ]
  ) {
    await refuses(() => h.adapter.outputUrl(url), "invalid");
    await refuses(() => h.adapter.submitErase(input, url), "invalid");
    await refuses(() => h.adapter.downloadOutput(url), "invalid");
    const poller = harness(() => complete({ video_url: url }));
    await refuses(() => poller.adapter.poll(ref, "erase"), "status");
    equal(poller.calls.length, 1); // Never follows the provider output URL.
  }
  equal(h.calls.length, 0);
  equal(h.tokenCalls(), 0);
  equal(h.adapter.outputUrl(output), output);
  await refuses(
    () => h.adapter.submitErase({ ...input, videoUrl: mask }, mask),
    "invalid",
  );
});
Deno.test("Bria output download uses credential-free bounded GET and returns MP4 bytes", async () => {
  const source = mp4Bytes();
  const h = harness(() =>
    new Response(source, { headers: { "content-type": "video/mp4" } })
  );
  const result = await h.adapter.downloadOutput(output, source.length);
  equal([...new Uint8Array(result.bytes)], [...source]);
  equal(result.mime, "video/mp4");
  equal(h.tokenCalls(), 0);
  equal(h.calls.length, 1);
  equal(h.calls[0].url, output);
  equal(h.calls[0].init.method, "GET");
  equal(h.calls[0].init.redirect, "error");
  equal(new Headers(h.calls[0].init.headers).get("api_token"), null);
  equal(new Headers(h.calls[0].init.headers).get("authorization"), null);
});
Deno.test("Bria download rejects advertised/streamed oversize, redirects, HTML and non-MP4 bytes", async () => {
  const cases = [
    () =>
      new Response(mp4Bytes(), {
        headers: { "content-type": "video/mp4", "content-length": "25" },
      }),
    () =>
      new Response(new Uint8Array([...mp4Bytes(), 0]), {
        headers: { "content-type": "video/mp4" },
      }),
    () =>
      new Response("private html", {
        headers: { "content-type": "text/html" },
      }),
    () =>
      new Response(new Uint8Array(24), {
        headers: { "content-type": "video/mp4" },
      }),
    () =>
      new Response(null, {
        status: 302,
        headers: { location: "https://127.0.0.1/private" },
      }),
    () => new Response("private error", { status: 500 }),
  ];
  for (const [i, handler] of cases.entries()) {
    const h = harness(handler);
    const error = await refuses(
      () => h.adapter.downloadOutput(output, 24),
      i < 4 ? "invalid" : "status",
    );
    ok(!error.message.includes("private"));
    equal(h.calls.length, 1);
    equal(h.tokenCalls(), 0);
  }
  const h = harness();
  for (const max of [0, 11, NaN, 100 * 1024 * 1024 + 1]) {
    await refuses(() => h.adapter.downloadOutput(output, max), "invalid");
  }
  equal(h.calls.length, 0);
});
Deno.test("Bria output download deadline covers stalled fetch and stalled media streams", async () => {
  for (
    const handler of [
      () => new Promise<Response>(() => {}),
      () =>
        new Response(new ReadableStream({ start() {} }), {
          headers: { "content-type": "video/mp4" },
        }),
    ]
  ) {
    const h = harness(handler, { timeoutMs: 15 });
    await refuses(() => h.adapter.downloadOutput(output), "status");
    equal(h.calls.length, 1);
    equal(h.tokenCalls(), 0);
    ok(h.calls[0].init.signal?.aborted);
  }
});
