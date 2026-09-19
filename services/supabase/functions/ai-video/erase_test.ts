// Offline production handler tests: real guardrails, MP4 probe and routing;
// only auth/database/provider/storage boundaries are injected. Deno denies net.
import { createEraseHandler, ERASE_PROMPT, extractEraseJob } from "./erase.ts";
import { HttpError } from "../_shared/http.ts";
import { movieDuration, probeMP4Duration } from "./mp4duration.ts";
const id = (n: number) =>
  `ee000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const ctx = { orgId: id(1), userId: id(2) };
const body = {
  asset_id: id(3),
  listing_id: id(4),
  batch_id: id(5),
  purpose: "reflection_removal",
  prompt: "the photographer and people reflected in mirrors or windows",
};
const ref = {
  request_id: "synthetic-provider-1",
  status_url: "https://queue.fal.run/bria/requests/synthetic-provider-1/status",
  response_url: "https://queue.fal.run/bria/requests/synthetic-provider-1",
};
const url = "https://project.invalid/functions/v1/ai-video";
function ok(v: unknown, m = "assertion failed"): asserts v {
  if (!v) throw new Error(m);
}
function equal(a: unknown, b: unknown) {
  ok(
    JSON.stringify(a) === JSON.stringify(b),
    `${JSON.stringify(a)} != ${JSON.stringify(b)}`,
  );
}
async function refuses(fn: () => Promise<unknown>, code: number) {
  try {
    await fn();
  } catch (e) {
    ok(e instanceof HttpError);
    equal(e.status, code);
    return;
  }
  throw new Error("Expected rejection " + code);
}
function box(kind: string, bytes: Uint8Array) {
  const a = new Uint8Array(bytes.length + 8), v = new DataView(a.buffer);
  v.setUint32(0, a.length);
  a.set(new TextEncoder().encode(kind), 4);
  a.set(bytes, 8);
  return a;
}
function concat(...parts: Uint8Array[]) {
  const a = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    a.set(p, offset);
    offset += p.length;
  }
  return a;
}
function mp4(seconds = 2, version = 0) {
  const b = new Uint8Array(version ? 32 : 24), v = new DataView(b.buffer);
  v.setUint8(0, version);
  v.setUint32(version ? 20 : 12, 1000);
  if (version) v.setBigUint64(24, BigInt(Math.round(seconds * 1000)));
  else v.setUint32(16, seconds * 1000);
  const tkhd = new Uint8Array(24);
  new DataView(tkhd.buffer).setUint32(20, seconds * 1000);
  const hdlr = new Uint8Array(12);
  hdlr.set(new TextEncoder().encode("vide"), 8);
  const stts = new Uint8Array(16), t = new DataView(stts.buffer);
  t.setUint32(4, 1);
  t.setUint32(8, 1);
  t.setUint32(12, seconds * 1000);
  const stsz = new Uint8Array(12), z = new DataView(stsz.buffer);
  z.setUint32(4, 8);
  z.setUint32(8, 1);
  const mdia = box(
    "mdia",
    concat(
      box("mdhd", b),
      box("hdlr", hdlr),
      box("minf", box("stbl", concat(box("stts", stts), box("stsz", stsz)))),
    ),
  );
  return box(
    "moov",
    concat(box("mvhd", b), box("trak", concat(box("tkhd", tkhd), mdia))),
  );
}
function harness() {
  type O = Record<string, any>;
  const jobs = new Map<string, O>(),
    receipts = new Map<string, O>(),
    events: string[] = [],
    bodies: O[] = [];
  let duration: number | null = 2,
    actualSeconds = 2,
    movieSeconds: number | null = null,
    key = "synthetic-not-key",
    now = 1_000_000,
    submitStatus = 200,
    submitThrows = false,
    statusValue = "COMPLETED",
    resultStatus = 200,
    resultURL = "https://fal.media/synthetic.mp4",
    rpcFailure = "",
    cancelDuringPersist = false,
    applied: O | null = null;
  const rpc = async (name: string, args: O) => {
    const action = name.replace("video_erase_", "");
    events.push("rpc:" + action);
    if (rpcFailure === action) {
      return {
        data: null,
        error: {
          message: "Synthetic database outage; internal URL must not escape",
        },
      };
    }
    if (action === "existing") {
      return { data: { job: receipts.get(args.p_idem) ?? null }, error: null };
    }
    if (action === "quote") {
      return {
        data: {
          available: true,
          remaining_clips: 4,
          max_clip_seconds: 4.8,
          max_batch_cents: 240,
          unit_cost_cents: 14,
          remaining_cost_cents: 240,
        },
        error: null,
      };
    }
    if (action === "reserve") {
      if (receipts.has(args.p_idem)) {
        return {
          data: { dispatch: false, job: receipts.get(args.p_idem) },
          error: null,
        };
      }
      const j = {
        id: id(10),
        batch_id: args.p_batch,
        state: "dispatching",
        created_at: new Date(now).toISOString(),
        provider_ref: null,
        allowance_refunded_at: null,
      };
      jobs.set(j.id, j);
      receipts.set(args.p_idem, j);
      return { data: { dispatch: true, job: { ...j } }, error: null };
    }
    if (action === "get") {
      return jobs.has(args.p_job)
        ? { data: { ...jobs.get(args.p_job) }, error: null }
        : { data: null, error: { message: "RP404: Reflection job not found" } };
    }
    if (action === "finish") {
      const j = jobs.get(args.p_job)!;
      if (
        !["failed", "uncertain", "cancelled", "completed"].includes(j.state)
      ) j.state = args.p_state;
      if (args.p_ref) j.provider_ref = args.p_ref;
      if (["failed", "uncertain", "cancelled"].includes(j.state)) {
        j.allowance_refunded_at ??= new Date(now).toISOString();
      }
      if (j.state === "completed") {
        j.output_url = args.p_url;
        j.output_key = args.p_key;
      }
      j.error = args.p_error;
      return { data: { ...j }, error: null };
    }
    if (action === "cancel") {
      for (const j of jobs.values()) {
        j.state = "cancelled";
        j.allowance_refunded_at = new Date(now).toISOString();
      }
      return {
        data: {
          status: "cancelled",
          batch_id: args.p_batch ?? id(5),
          cancelled_clips: jobs.size,
        },
        error: null,
      };
    }
    if (action === "apply") {
      if (applied) return { data: applied, error: null };
      if (args.p_validate_only) return { data: { ready: true }, error: null };
      applied = {
        disclosure: "Synthetic truthful video disclosure",
        provenance: { id: id(15), recorded: true },
      };
      return { data: applied, error: null };
    }
    throw new Error("Unrecognized RPC " + action);
  };
  const handler = createEraseHandler({
    rpc,
    resolveAsset: async (assetId) => {
      events.push("resolve:" + assetId);
      return {
        listing_id: id(4),
        kind: "video",
        url: "https://media.invalid/" + assetId + ".mp4",
        duration_s: duration,
        space_type: "real_estate",
      };
    },
    falKey: () => key,
    now: () => now,
    fetch: async (input, init) => {
      if (input.startsWith("https://media.invalid/")) {
        events.push("media-probe");
        const bytes = mp4(actualSeconds);
        if (movieSeconds !== null) {
          new DataView(bytes.buffer).setUint32(32, movieSeconds * 1000);
        }
        const match = /bytes=(\d+)-(\d+)/.exec(
          new Headers(init.headers).get("range") ?? "",
        );
        ok(match);
        const first = Number(match[1]), last = Number(match[2]);
        return new Response(bytes.slice(first, last + 1), {
          status: 206,
          headers: {
            "content-range": `bytes ${first}-${last}/${bytes.length}`,
          },
        });
      }
      ok(input.startsWith("https://queue.fal.run/"));
      equal(init.redirect, "error");
      equal(
        new Headers(init.headers).get("authorization"),
        "Key synthetic-not-key",
      );
      if (init.method === "POST") {
        events.push("provider-submit");
        bodies.push(JSON.parse(String(init.body)));
        if (submitThrows) throw new Error("lost response");
        return Response.json(ref, { status: submitStatus });
      }
      events.push("provider-get");
      return input.endsWith("/status")
        ? Response.json({ status: statusValue })
        : Response.json({ video: { url: resultURL } }, {
          status: resultStatus,
        });
    },
    persist: async (input, k) => {
      events.push("persist");
      if (cancelDuringPersist) jobs.get(id(10))!.state = "cancelled";
      equal(input, "https://fal.media/synthetic.mp4");
      ok(k.includes(ctx.orgId + "/" + id(10)));
      return "https://media.invalid/output.mp4";
    },
  });
  function request(action: string, payload: O = body, method = "POST") {
    return new Request(url + "/" + action, {
      method,
      headers: { "content-type": "application/json", "idempotency-key": id(6) },
      ...(method === "POST" ? { body: JSON.stringify(payload) } : {}),
    });
  }
  const submit = (payload: O = body) =>
    handler(request("declutter", payload), ctx, "submit");
  const status = () =>
    handler(request("status?erase_job=" + id(10), {}, "GET"), ctx, "status");
  return {
    handler,
    request,
    submit,
    status,
    events,
    bodies,
    jobs,
    set: (options: O) => {
      if ("duration" in options) duration = options.duration;
      if ("actualSeconds" in options) actualSeconds = options.actualSeconds;
      if ("movieSeconds" in options) movieSeconds = options.movieSeconds;
      if ("key" in options) key = options.key;
      if ("now" in options) now = options.now;
      if ("submitStatus" in options) submitStatus = options.submitStatus;
      if ("submitThrows" in options) submitThrows = options.submitThrows;
      if ("statusValue" in options) statusValue = options.statusValue;
      if ("resultStatus" in options) resultStatus = options.resultStatus;
      if ("resultURL" in options) resultURL = options.resultURL;
      if ("rpcFailure" in options) rpcFailure = options.rpcFailure;
      if ("cancelDuringPersist" in options) {
        cancelDuringPersist = options.cancelDuringPersist;
      }
    },
  };
}
Deno.test("duration probes v0/v1 and fails malformed/fragmented MP4 before billing", async () => {
  equal(movieDuration(mp4(4.8)), 4.8);
  equal(movieDuration(mp4(2, 1)), 2);
  const forged = mp4(10);
  new DataView(forged.buffer).setUint32(8 + 8 + 16, 3000);
  await refuses(async () => movieDuration(forged), 400);
  await refuses(async () => movieDuration(mp4(0)), 400);
  await refuses(async () => movieDuration(new Uint8Array(8)), 400);
  const movie = mp4(2),
    frag = box("mvex", new Uint8Array(8)),
    children = new Uint8Array(movie.length - 8 + frag.length);
  children.set(movie.slice(8));
  children.set(frag, movie.length - 8);
  await refuses(async () => movieDuration(box("moov", children)), 400);
  await refuses(
    () =>
      probeMP4Duration(
        "https://media.invalid/video",
        async () => new Response("unexpected full body", { status: 200 }),
      ),
    409,
  );
});
Deno.test("preflight metadata, actual duration, listing and prompt rejects consume no reservation/provider", async () => {
  for (const duration of [0, -1, 5, NaN, Infinity, null]) {
    const h = harness();
    h.set({ duration });
    await refuses(() => h.submit(), duration === null ? 409 : 400);
    ok(
      !h.events.includes("rpc:reserve") &&
        !h.events.includes("provider-submit"),
    );
  }
  const padded = harness();
  padded.set({ duration: 4.95, actualSeconds: 5.1, movieSeconds: 4.95 });
  await refuses(() => padded.submit(), 400);
  ok(!padded.events.includes("rpc:reserve"));
  for (const actualSeconds of [5, 3]) {
    const h = harness();
    h.set({ actualSeconds });
    await refuses(() => h.submit(), 400);
    ok(!h.events.includes("rpc:reserve"));
  }
  for (
    const patch of [{ listing_id: id(8) }, { purpose: "anything" }, {
      asset_id: "not-uuid",
    }, { prompt: "Add a family in the living room" }]
  ) {
    const h = harness();
    await refuses(() => h.submit({ ...body, ...patch }), 400);
    ok(!h.events.includes("rpc:reserve"));
  }
});
Deno.test("key missing is preflight and quote unavailable; database outage hides internals", async () => {
  const h = harness();
  h.set({ key: "" });
  await refuses(() => h.submit(), 503);
  ok(!h.events.includes("rpc:reserve"));
  const quote = await h.handler(
    h.request("declutter/quote?listing_id=" + id(4), {}, "GET"),
    ctx,
    "quote",
  );
  equal((await quote.json()).available, false);
  h.set({ rpcFailure: "quote" });
  try {
    await h.handler(
      h.request("declutter/quote?listing_id=" + id(4), {}, "GET"),
      ctx,
      "quote",
    );
  } catch (e) {
    ok(e instanceof HttpError);
    equal(e.status, 503);
    ok(!e.message.includes("internal URL"));
    return;
  }
  throw Error("Expected failure");
});
Deno.test("real handler submits one canonical guarded provider request; idempotent retry performs no media fetch", async () => {
  const h = harness(), first = await h.submit();
  equal(first.status, 202);
  const data = await first.json();
  equal(data.request_id, id(10));
  equal(data.provenance.recorded, false);
  equal(extractEraseJob(new Request(data.status_url)), id(10));
  equal(h.bodies[0].auto_trim, false);
  equal(h.bodies[0].preserve_audio, true);
  equal(h.bodies[0].prompt, ERASE_PROMPT);
  ok(
    ERASE_PROMPT.includes("Do not add or alter people") &&
      ERASE_PROMPT.includes("cracks, stains"),
  );
  h.events.length = 0;
  const again = await h.submit();
  equal(await again.json(), data);
  equal(h.events, ["rpc:existing"]);
});
Deno.test("submit ambiguity returns original receipt and refund without automatic provider retry", async () => {
  const h = harness();
  h.set({ submitThrows: true });
  equal((await h.submit()).status, 202);
  equal(h.jobs.get(id(10))!.state, "uncertain");
  const state = await (await h.status()).json();
  equal(state.status, "failed");
  equal(state.allowance_refunded, true);
  await h.submit();
  equal(h.events.filter((x) => x === "provider-submit").length, 1);
});
Deno.test("definitive rejection fails/refunds; HTTP5xx remains ambiguous", async () => {
  for (const status of [400, 401, 403, 422, 429, 500, 503]) {
    const h = harness();
    h.set({ submitStatus: status });
    equal((await h.submit()).status, 202);
    equal(h.jobs.get(id(10))!.state, status < 500 ? "failed" : "uncertain");
    ok(h.jobs.get(id(10))!.allowance_refunded_at);
  }
});
Deno.test("lost database receipt never redispatches; stale unpollable claim refunds", async () => {
  const h = harness();
  h.set({ rpcFailure: "finish" });
  await refuses(() => h.submit(), 503);
  h.set({ rpcFailure: "", now: 1_121_000 });
  await h.submit();
  equal(h.events.filter((x) => x === "provider-submit").length, 1);
  const s = await (await h.status()).json();
  equal(s.status, "failed");
  equal(s.allowance_refunded, true);
});
Deno.test("status completes only after persisted output and records no public acceptance", async () => {
  const h = harness();
  await h.submit();
  const s = await (await h.status()).json();
  equal(s.status, "completed");
  equal(s.publishable, false);
  ok(h.events.indexOf("persist") < h.events.lastIndexOf("rpc:finish"));
  equal(h.events.filter((x) => x === "rpc:apply").length, 0);
});
Deno.test("provider failure, invalid output and timeout refund without persistence", async () => {
  for (
    const config of [{ statusValue: "FAILED" }, { resultStatus: 500 }, {
      resultURL: "https://localhost/secret",
    }, { now: 3_000_001 }]
  ) {
    const h = harness();
    await h.submit();
    h.set(config);
    const s = await (await h.status()).json();
    equal(s.status, "failed");
    equal(s.allowance_refunded, true);
    ok(!h.events.includes("persist"));
  }
});
Deno.test("cancellation during download cannot resurrect accepted video", async () => {
  const h = harness();
  await h.submit();
  h.set({ cancelDuringPersist: true });
  equal((await (await h.status()).json()).status, "cancelled");
});
Deno.test("status links are scoped to own endpoint and malformed IDs fail closed", async () => {
  equal(
    extractEraseJob(new Request(url + "/status?erase_job=" + id(10))),
    id(10),
  );
  equal(
    extractEraseJob(
      new Request(
        url + "/status?status_url=" +
          encodeURIComponent(url + "/status?erase_job=" + id(10)),
      ),
    ),
    id(10),
  );
  await refuses(
    async () =>
      extractEraseJob(
        new Request(
          url + "/status?status_url=" +
            encodeURIComponent(
              "https://other.invalid/ai-video/status?erase_job=" + id(10),
            ),
        ),
      ),
    400,
  );
  await refuses(
    async () => extractEraseJob(new Request(url + "/status?erase_job=bad")),
    400,
  );
  equal(
    extractEraseJob(
      new Request(
        url + "/status?status_url=" + encodeURIComponent(ref.status_url),
      ),
    ),
    null,
  );
});
Deno.test("cancel tombstone delegates exact actor; empty or double addresses rejected", async () => {
  const h = harness();
  for (const b of [{}, { batch_id: id(5), request_id: id(10) }]) {
    await refuses(
      () => h.handler(h.request("declutter/cancel", b), ctx, "cancel"),
      400,
    );
  }
  equal(
    (await (await h.handler(
      h.request("declutter/cancel", { batch_id: id(5) }),
      ctx,
      "cancel",
    )).json()).status,
    "cancelled",
  );
  equal(h.events, ["rpc:cancel"]);
});
Deno.test("apply checks real full durations, explicit receipt is idempotent and no provider call", async () => {
  const h = harness();
  h.set({ duration: 10, actualSeconds: 10 });
  const b = {
    batch_id: id(5),
    original_asset_id: id(20),
    altered_asset_id: id(21),
  };
  const first =
    await (await h.handler(h.request("declutter/apply", b), ctx, "apply"))
      .json();
  ok(first.provenance.recorded);
  h.events.length = 0;
  equal(
    await (await h.handler(h.request("declutter/apply", b), ctx, "apply"))
      .json(),
    first,
  );
  equal(h.events, ["rpc:apply"]);
  const tooLong = harness();
  tooLong.set({ duration: 601, actualSeconds: 601 });
  await refuses(
    () => tooLong.handler(tooLong.request("declutter/apply", b), ctx, "apply"),
    400,
  );
  equal(tooLong.events.filter((x) => x === "rpc:apply").length, 1);
});
