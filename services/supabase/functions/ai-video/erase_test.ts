// Offline production handler tests: real guardrails, MP4 probe and routing;
// only auth/database/provider/storage boundaries are injected. Deno denies net.
import {
  BRIA_CONSENT,
  createEraseHandler,
  ERASE_MASK_PROMPT,
  ERASE_PROMPT,
  extractEraseJob,
  readEraseConfig,
} from "./erase.ts";
import { createBriaAdapter } from "./bria.ts";
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
    provider: "fal" | "bria" | "disabled" = "fal",
    serverConfig: Record<string, string> | null = null,
    ack = true,
    maskRate = 2,
    eraseRate = 3,
    directToken = "synthetic-direct-key",
    maskError = false,
    cancelOnAdmission = false,
    directMask = "https://outputs.example.com/mask.mp4",
    now = 1_000_000,
    submitStatus = 200,
    rejectedWithReceipt = false,
    submitThrows = false,
    statusValue = "COMPLETED",
    resultStatus = 200,
    resultURL = "https://fal.media/synthetic.mp4",
    rpcFailure = "",
    cancelDuringPersist = false,
    applied: O | null = null;
  const liabilities:unknown[]=[];
  const holds:O[]=[];
  const rpc = async (name: string, args: O) => {
    // Explicit synthetic unlimited sponsorship for legacy provider protocol
    // cases. Finite paid admission is tested independently below.
    if (name === "org_has_internal_testing_grant") return {data:true,error:null};
    if (name === "serving_cost_reserve") {holds.push(args);return {data:{reserved:true},error:null};}
    if (name === "serving_cost_finish") {liabilities.push(args.p_state);return {data:{finished:true},error:null};}
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
    if (action === "reserve" || action === "reserve_direct") {
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
        ...(action === "reserve_direct"
          ? {
            provider: "bria",
            provider_config: args.p_config,
            asset_id: args.p_asset,
            duration_s: args.p_seconds,
            stages: [{
              stage: "mask",
              state: "dispatching",
              provider_ref: null,
              admitted_at: new Date(now).toISOString(),
            }, {
              stage: "erase",
              state: "pending",
              provider_ref: null,
              admitted_at: null,
            }],
          }
          : {}),
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
    if (action === "finish_stage") {
      const j = jobs.get(args.p_job)!,
        stage = j.stages.find((s: O) => s.stage === args.p_stage);
      stage.state = args.p_state;
      stage.provider_ref ??= args.p_ref;
      stage.output_url ??= args.p_output;
      if (
        !["failed", "uncertain", "cancelled", "completed"].includes(j.state)
      ) {
        j.state = ["failed", "uncertain"].includes(args.p_state)
          ? args.p_state
          : "processing";
        if (["failed", "uncertain"].includes(args.p_state)) {
          j.allowance_refunded_at = new Date(now).toISOString();
        }
      }
      return { data: structuredClone(j), error: null };
    }
    if (action === "admit_stage") {
      const j = jobs.get(args.p_job)!;
      if (cancelOnAdmission) j.state = "cancelled";
      const stage = j.stages.find((s: O) => s.stage === "erase");
      const dispatch = j.state === "processing" && stage.state === "pending";
      if (dispatch) {
        stage.state = "dispatching";
        stage.admitted_at = new Date(now).toISOString();
      }
      equal(args.p_consent, BRIA_CONSENT);
      return { data: { job: structuredClone(j), dispatch }, error: null };
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
        url: "https://media.example.com/" + assetId + ".mp4",
        duration_s: duration,
        space_type: "real_estate",
      };
    },
    falKey: () => key,
    config: (req, actor) =>
      serverConfig
        ? readEraseConfig((name) => serverConfig?.[name], req, actor)
        : ({
          provider,
          maskUnitCostCents: maskRate,
          eraseUnitCostCents: eraseRate,
          priceVersion: "synthetic-confirmed-price",
          outputHosts: ["outputs.example.com"],
        }),
    bria: (config) =>
      createBriaAdapter({
        apiToken: () => directToken,
        outputHosts: config.output_hosts as string[],
        fetch: async (input, init) => {
          equal(init.redirect, "error");
          equal(
            new Headers(init.headers).get("api_token"),
            "synthetic-direct-key",
          );
          if (init.method === "POST") {
            const name = input.endsWith("mask_by_prompt") ? "mask" : "erase";
            events.push("direct-submit:" + name);
            bodies.push(JSON.parse(String(init.body)));
            if (submitThrows) throw Error("lost direct response");
            return Response.json({
              request_id: "synthetic-" + name,
              status_url:
                "https://engine.prod.bria-api.com/v2/status/synthetic-" + name,
            }, { status: submitStatus === 200 ? 202 : submitStatus });
          }
          events.push("direct-get");
          const name = input.endsWith("synthetic-mask") ? "mask" : "erase";
          return Response.json(
            maskError
              ? {
                request_id: "synthetic-" + name,
                status: "ERROR",
                error: "sensitive provider body",
              }
              : {
                request_id: "synthetic-" + name,
                status: "COMPLETED",
                result: name === "mask"
                  ? { mask_url: directMask }
                  : { video_url: "https://outputs.example.com/edited.mp4" },
              },
          );
        },
      }),
    now: () => now,
    fetch: async (input, init) => {
      if (
        input.startsWith("https://media.invalid/") ||
        input.startsWith("https://media.example.com/")
      ) {
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
        return Response.json(submitStatus<400||rejectedWithReceipt?ref:{error:"synthetic rejection"}, { status: submitStatus });
      }
      events.push("provider-get");
      return input.endsWith("/status")
        ? Response.json({ status: statusValue })
        : Response.json({ video: { url: resultURL } }, {
          status: resultStatus,
        });
    },
    persist: async (input, k, outputProvider, pinned) => {
      events.push("persist");
      if (cancelDuringPersist) jobs.get(id(10))!.state = "cancelled";
      equal(
        input,
        outputProvider === "bria"
          ? "https://outputs.example.com/edited.mp4"
          : "https://fal.media/synthetic.mp4",
      );
      if (outputProvider === "bria") {
        equal(pinned?.price_version, "synthetic-confirmed-price");
      }
      ok(k.includes(ctx.orgId + "/" + id(10)));
      return "https://media.invalid/output.mp4";
    },
  });
  function request(action: string, payload: O = body, method = "POST") {
    return new Request(url + "/" + action, {
      method,
      headers: {
        "content-type": "application/json",
        "idempotency-key": id(6),
        ...(ack ? { "x-rendprop-ai-consent": BRIA_CONSENT } : {}),
      },
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
    liabilities,
    holds,
    jobs,
    set: (options: O) => {
      if ("provider" in options) provider = options.provider;
      if ("serverConfig" in options) serverConfig = options.serverConfig;
      if ("ack" in options) ack = options.ack;
      if ("maskRate" in options) maskRate = options.maskRate;
      if ("eraseRate" in options) eraseRate = options.eraseRate;
      if ("directToken" in options) directToken = options.directToken;
      if ("maskError" in options) maskError = options.maskError;
      if ("cancelOnAdmission" in options) {
        cancelOnAdmission = options.cancelOnAdmission;
      }
      if ("directMask" in options) directMask = options.directMask;
      if ("duration" in options) duration = options.duration;
      if ("actualSeconds" in options) actualSeconds = options.actualSeconds;
      if ("movieSeconds" in options) movieSeconds = options.movieSeconds;
      if ("key" in options) key = options.key;
      if ("now" in options) now = options.now;
      if ("submitStatus" in options) submitStatus = options.submitStatus;
      if ("rejectedWithReceipt" in options) rejectedWithReceipt = options.rejectedWithReceipt;
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
    equal(h.liabilities[0],status<500?"rejected":"uncertain");
    ok(h.jobs.get(id(10))!.allowance_refunded_at);
  }
});
Deno.test("a rejection carrying an allocated receipt retains both shared and reflection liability",async()=>{
  const h=harness();h.set({submitStatus:400,rejectedWithReceipt:true});
  equal((await h.submit()).status,202);equal(h.jobs.get(id(10))!.state,"uncertain");
  equal(h.liabilities[0],"uncertain");
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

Deno.test("direct provider requires explicit selection, processor acknowledgement and both confirmed prices", async () => {
  equal(
    readEraseConfig((name) => name === "BRIA_API_TOKEN" ? "token" : undefined),
    { provider: "fal" },
  );
  equal(
    readEraseConfig((name) =>
      name === "VIDEO_ERASE_PROVIDER" ? "typo" : undefined
    ),
    { provider: "disabled" },
  );
  for (
    const config of [{ ack: false }, { maskRate: NaN }, { eraseRate: 0 }, {
      maskRate: Infinity,
    }, { directToken: "" }]
  ) {
    const h = harness();
    h.set({ provider: "bria", ...config });
    const quote = await h.handler(
      h.request("declutter/quote?listing_id=" + id(4), {}, "GET"),
      ctx,
      "quote",
    );
    equal((await quote.json()).available, false);
    await refuses(() => h.submit(), 503);
    ok(
      !h.events.includes("rpc:reserve_direct") &&
        !h.events.some((e) => e.startsWith("direct-submit")),
    );
  }
  const h = harness();
  h.set({ provider: "bria" });
  equal(
    (await (await h.handler(
      h.request("declutter/quote?listing_id=" + id(4), {}, "GET"),
      ctx,
      "quote",
    )).json()).unit_cost_cents,
    5,
  );
});
Deno.test("direct mask and erase each follow one durable admission; race polls never duplicate the paid erase", async () => {
  const h = harness();
  h.set({ provider: "bria" });
  const first = await (await h.submit()).json();
  ok(first.model_id.includes("/v2/video/edit/erase"));
  ok(
    h.events.indexOf("rpc:reserve_direct") <
      h.events.indexOf("direct-submit:mask"),
  );
  equal(h.bodies[0].prompt, ERASE_MASK_PROMPT);
  await Promise.all([h.status(), h.status()]);
  equal(h.events.filter((e) => e === "direct-submit:mask").length, 1);
  equal(h.events.filter((e) => e === "direct-submit:erase").length, 1);
  ok(
    h.events.indexOf("rpc:admit_stage") <
      h.events.indexOf("direct-submit:erase"),
  );
  equal(h.bodies[1].mask, "https://outputs.example.com/mask.mp4");
  equal(h.holds.map(hold => [hold.p_key,hold.p_stage,hold.p_provider,hold.p_model]),[
    [id(10),"reflection.mask","bria","/v2/video/segment/mask_by_prompt"],
    [id(10),"reflection.erase","bria","/v2/video/edit/erase"],
  ]);
  const result = await (await h.status()).json();
  equal(result.status, "completed");
  equal(result.publishable, false);
  await h.submit();
  equal(h.events.filter((e) => e.startsWith("direct-submit")).length, 2);
});
Deno.test("provider selection and price changes do not rewrite existing direct or fal jobs", async () => {
  const direct = harness();
  direct.set({ provider: "bria" });
  await direct.submit();
  direct.set({ provider: "fal", maskRate: NaN, eraseRate: 100 });
  await direct.status();
  await direct.status();
  equal(direct.events.filter((e) => e === "provider-submit").length, 0);
  equal((await (await direct.status()).json()).status, "completed");
  const fal = harness();
  await fal.submit();
  fal.set({ provider: "bria", ack: false });
  equal((await (await fal.status()).json()).status, "completed");
  equal(fal.events.filter((e) => e.startsWith("direct-submit")).length, 0);
});
Deno.test("direct uncertain POST or lost receipt cannot restart masking or admit erase", async () => {
  for (
    const failure of [{ submitThrows: true }, { rpcFailure: "finish_stage" }]
  ) {
    const h = harness();
    h.set({ provider: "bria", ...failure });
    if (failure.rpcFailure) await refuses(() => h.submit(), 503);
    else await h.submit();
    h.set({ submitThrows: false, rpcFailure: "", now: 1_121_000 });
    await h.submit();
    await h.status();
    equal(h.events.filter((e) => e === "direct-submit:mask").length, 1);
    equal(h.events.filter((e) => e === "direct-submit:erase").length, 0);
    equal(h.jobs.get(id(10))!.state, "uncertain");
  }
});
Deno.test("mask error, cancelled batch or withdrawn processor acknowledgement stops erase", async () => {
  for (
    const config of [{ maskError: true }, { cancelOnAdmission: true }, {
      ack: false,
    }]
  ) {
    const h = harness();
    h.set({ provider: "bria" });
    await h.submit();
    h.set(config);
    const result = await (await h.status()).json();
    ok(["failed", "cancelled"].includes(result.status));
    equal(h.events.filter((e) => e === "direct-submit:erase").length, 0);
    ok(!JSON.stringify(result).includes("sensitive provider body"));
  }
});
Deno.test("direct erase ambiguity keeps the original mask and does not dispatch a replacement stage", async () => {
  const h = harness();
  h.set({ provider: "bria" });
  await h.submit();
  h.set({ submitThrows: true });
  equal((await (await h.status()).json()).status, "failed");
  h.set({ submitThrows: false });
  await h.status();
  await h.submit();
  equal(h.events.filter((e) => e === "direct-submit:mask").length, 1);
  equal(h.events.filter((e) => e === "direct-submit:erase").length, 1);
});

const betaConfig = {
  VIDEO_ERASE_PROVIDER: "fal",
  BRIA_BETA_ENABLED: "true",
  BRIA_BETA_USER_IDS: ctx.userId,
  BRIA_MASK_CENTS_PER_SECOND: "2",
  BRIA_ERASE_CENTS_PER_SECOND: "3",
  BRIA_PRICE_VERSION: "synthetic-confirmed-price",
  BRIA_OUTPUT_HOSTS: "outputs.example.com",
};
Deno.test("Bria beta selection requires flag, exact actor UUID allowlist and processor acknowledgement", async () => {
  for (
    const config of [
      {},
      { BRIA_API_TOKEN: "new-token" },
      { VIDEO_ERASE_PROVIDER: "bria" },
      { ...betaConfig, BRIA_BETA_ENABLED: "false" },
      { ...betaConfig, BRIA_BETA_ENABLED: "TRUE" },
      { ...betaConfig, BRIA_BETA_USER_IDS: id(99) },
      { ...betaConfig, BRIA_BETA_USER_IDS: "*" },
      { ...betaConfig, BRIA_BETA_USER_IDS: ctx.userId + ",invalid" },
    ]
  ) {
    const h = harness();
    h.set({ serverConfig: config });
    await h.submit();
    equal(h.events.filter((e) => e === "provider-submit").length, 1);
    equal(h.events.filter((e) => e.startsWith("direct-submit")).length, 0);
  }
  const oldApp = harness();
  oldApp.set({ serverConfig: betaConfig, ack: false });
  const quote = await oldApp.handler(
    oldApp.request("declutter/quote?listing_id=" + id(4), {}, "GET"),
    ctx,
    "quote",
  );
  equal((await quote.json()).unit_cost_cents, 14);
  await oldApp.submit();
  equal(oldApp.events.filter((e) => e === "provider-submit").length, 1);
  equal(oldApp.events.filter((e) => e.startsWith("direct-submit")).length, 0);
  const otherActor = harness();
  otherActor.set({ serverConfig: betaConfig });
  await otherActor.handler(otherActor.request("declutter"), {
    ...ctx,
    userId: id(99),
  }, "submit");
  equal(otherActor.events.filter((e) => e === "provider-submit").length, 1);
  equal(
    otherActor.events.filter((e) => e.startsWith("direct-submit")).length,
    0,
  );
  const beta = harness();
  beta.set({ serverConfig: betaConfig });
  await beta.submit();
  equal(beta.events.filter((e) => e === "direct-submit:mask").length, 1);
  equal(beta.events.filter((e) => e === "provider-submit").length, 0);
});
Deno.test("eligible Bria beta actor fails closed on unknown rates or output hosts without falling back to fal", async () => {
  for (
    const config of [{ ...betaConfig, BRIA_MASK_CENTS_PER_SECOND: "" }, {
      ...betaConfig,
      BRIA_ERASE_CENTS_PER_SECOND: "unknown",
    }, { ...betaConfig, BRIA_OUTPUT_HOSTS: "" }]
  ) {
    const h = harness();
    h.set({ serverConfig: config });
    const quote = await h.handler(
      h.request("declutter/quote?listing_id=" + id(4), {}, "GET"),
      ctx,
      "quote",
    );
    equal((await quote.json()).available, false);
    await refuses(() => h.submit(), 503);
    ok(
      !h.events.includes("rpc:reserve") &&
        !h.events.includes("rpc:reserve_direct"),
    );
    equal(
      h.events.filter((e) =>
        e === "provider-submit" || e.startsWith("direct-submit")
      ).length,
      0,
    );
  }
});
Deno.test("beta flag or allowlist changes cannot reroute an already admitted direct job", async () => {
  const h = harness();
  h.set({ serverConfig: betaConfig });
  await h.submit();
  h.set({ serverConfig: {} });
  await h.status();
  await h.status();
  equal((await (await h.status()).json()).status, "completed");
  equal(h.events.filter((e) => e.startsWith("direct-submit")).length, 2);
  equal(h.events.filter((e) => e === "provider-submit").length, 0);
});
