// Offline request-contract tests. No permission for live network calls is needed.
import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import type { RouteStep } from "../router.ts";
import type { GenerateInput } from "./types.ts";
import { ProviderError } from "./common.ts";
import {
  createHfMotionTransferInput,
  estimateHfMotionTransfer,
  HF_MOTION_TRANSFER_MODEL,
  HF_MOTION_TRANSFER_TASK,
  hfEndpoint,
  hfInput,
  higgsfieldAdapter,
  submitHfMotionTransfer,
  readHfMotionTransferRef,
  pollHfMotionTransfer,
  cancelHfMotionTransfer,
  type HfMotionTransferInput,
} from "./higgsfield.ts";

function approved(over: Partial<HfMotionTransferInput> = {}): HfMotionTransferInput {
  return {
    performanceVideoUrl: "https://uploads.rendprop.com/performance.mp4?X-Amz-Signature=synthetic",
    performanceDurationSeconds: 12.25,
    approvedCharacterImageUrls: ["https://uploads.rendprop.com/approved-front.jpg", "https://uploads.rendprop.com/approved-side.jpg"],
    reviewedPrompt: "Keep the approved agent's identity.\nPreserve the reviewed performance.",
    ...over,
  };
}

const step: RouteStep = {
  route_id: "offline-test-only",
  task: HF_MOTION_TRANSFER_TASK,
  provider: "higgsfield",
  model: HF_MOTION_TRANSFER_MODEL,
  unit: "call",
  unit_cents: 0,
  capabilities: [],
  max_latency_s: 600,
  min_plan: "free",
  same_model_as: null,
  privacy_tier: "retained_30d",
  enabled: false,
};

async function withFetch(
  handler: (url: string, init?: RequestInit) => Response,
  run: () => Promise<void>,
) {
  const original = globalThis.fetch;
  const names = ["HIGGSFIELD_API_KEY_ID", "HIGGSFIELD_API_KEY_SECRET"];
  const previous = names.map((name) => Deno.env.get(name));
  names.forEach((name) => Deno.env.set(name, "synthetic-not-a-credential"));
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) =>
    Promise.resolve(handler(String(input instanceof Request ? input.url : input), init))) as typeof fetch;
  try {
    await run();
  } finally {
    globalThis.fetch = original;
    names.forEach((name, index) => previous[index] === undefined ? Deno.env.delete(name) : Deno.env.set(name, previous[index]!));
  }
}

Deno.test("Genjutsu uses the intentional official higgsfiled slug and rejects aliases", () => {
  assertEquals(hfEndpoint(HF_MOTION_TRANSFER_MODEL), { path: `/${HF_MOTION_TRANSFER_MODEL}`, kind: "motion_transfer" });
  for (const model of ["higgsfield/genjutsu/motion-transfer/v1.0", "genjutsu", "higgsfiled/genjutsu/object-swap/v1.0", `${HF_MOTION_TRANSFER_MODEL}/seedance`, "unknown-model"]) {
    assertThrows(() => hfEndpoint(model), ProviderError);
  }
});

const retained = { request_id: "91000000-0000-4000-8000-000000000001", status_url: "https://api.higgsfield.ai/requests/91000000-0000-4000-8000-000000000001/status", cancel_url: "https://api.higgsfield.ai/requests/91000000-0000-4000-8000-000000000001/cancel" };
Deno.test("dedicated Genjutsu submit retains exact refs even when the job already started", async () => {
  await withFetch((_url, init) => { assertEquals(init?.redirect, "error"); return Response.json({ ...retained, status: "in_progress" }); }, async () => {
    assertEquals(await submitHfMotionTransfer(createHfMotionTransferInput(approved())), retained);
  });
});
Deno.test("retained Genjutsu refs reject redirects, custom origins, identity mismatches and altered paths before credentials", async () => {
  let calls = 0;
  await withFetch(() => { calls++; return Response.json({}); }, async () => {
    for (const replacement of ["https://api.higgsfield.ai.evil.com/requests/x/status", retained.status_url + "?next=https://evil.com", retained.status_url.replace("/status", "/cancel"), retained.status_url.replace("000000000001", "000000000002"), retained.status_url.replace("https:", "http:"), retained.status_url.replace("api.higgsfield.ai", "user:password@api.higgsfield.ai")]) {
      assertThrows(() => readHfMotionTransferRef({ ...retained, status_url: replacement }), ProviderError);
      await assertRejects(() => pollHfMotionTransfer({ ...retained, status_url: replacement }), ProviderError);
    }
  });
  assertEquals(calls, 0);
});
Deno.test("dedicated Genjutsu status requires retained identity and known state", async () => {
  for (const data of [{ request_id: crypto.randomUUID(), status: "queued" }, { request_id: retained.request_id, status: "maybe" }, { request_id: retained.request_id, status: "completed", video: { url: "file:///tmp/private.mp4" } }]) {
    await withFetch(() => Response.json(data), async () => { await assertRejects(() => pollHfMotionTransfer(retained), ProviderError); });
  }
  await withFetch(() => Response.json({ request_id: retained.request_id, status: "completed", video: { url: "https://output.rendprop.com/result.mp4" } }), async () => {
    assertEquals(await pollHfMotionTransfer(retained), { status: "completed", video_url: "https://output.rendprop.com/result.mp4" });
  });
});
Deno.test("dedicated Genjutsu cancel handles empty202 and already-started400 without JSON or retry", async () => {
  for (const [status, expected] of [[202, "accepted"], [400, "already_started"]] as const) {
    let calls = 0;
    await withFetch((url, init) => { calls++; assertEquals(url, retained.cancel_url); assertEquals(init?.method, "POST"); assertEquals(init?.redirect, "error"); return new Response(null, { status }); }, async () => { assertEquals(await cancelHfMotionTransfer(retained), expected); });
    assertEquals(calls, 1);
  }
});
Deno.test("dedicated Genjutsu submit never retries an ambiguous transport or malformed acceptance", async () => {
  for (const fail of [true, false]) {
    let calls = 0;
    await withFetch(() => { calls++; if (fail) throw new Error("simulated connection lost"); return Response.json({ status: "queued" }); }, async () => { await assertRejects(() => submitHfMotionTransfer(createHfMotionTransferInput(approved()))); });
    assertEquals(calls, 1);
  }
});
Deno.test("dedicated Genjutsu response body is bounded without logging private response content", async () => {
  await withFetch(() => new Response("X".repeat(65 * 1024)), async () => { await assertRejects(() => pollHfMotionTransfer(retained), ProviderError, "exceeds"); });
  await withFetch(() => new Response("https://private.rendprop.com?secret=example", { status: 500 }), async () => {
    const error = await assertRejects(() => pollHfMotionTransfer(retained), ProviderError); assertEquals(error.message, "higgsfield HTTP 500");
  });
});

Deno.test("Genjutsu body is the exact closed schema with ordered references and verbatim prompt", async () => {
  const source = approved();
  const body = await hfInput(step, createHfMotionTransferInput(source));
  assertEquals(body, {
    prompt: source.reviewedPrompt,
    video_url: source.performanceVideoUrl,
    image_urls: source.approvedCharacterImageUrls,
    resolution: "720p",
  });
  for (const forbidden of ["enhance_prompt", "duration", "seconds", "aspect_ratio", "extra", "image_url"]) {
    assert(!(forbidden in body));
  }
  assertEquals((await hfInput(step, createHfMotionTransferInput(approved({ resolution: "480p", reviewedPrompt: "" })))).resolution, "480p");
});

Deno.test("Genjutsu accepts exact duration boundaries and fractional measured seconds without clamping", () => {
  for (const seconds of [4, 4.001, 29.999, 30]) {
    assertEquals(createHfMotionTransferInput(approved({ performanceDurationSeconds: seconds })).seconds, seconds);
  }
  for (const seconds of [3.999, 30.001, -1, 0, NaN, Infinity, "12", null, undefined]) {
    assertThrows(() => createHfMotionTransferInput(approved({ performanceDurationSeconds: seconds as number })), ProviderError);
  }
});

Deno.test("Genjutsu refuses missing references, excessive references, unsupported resolution and prompt fields", () => {
  for (const refs of [[], new Array(1), Array.from({ length: 9 }, (_, i) => `https://uploads.rendprop.com/${i}.jpg`), null, "https://uploads.rendprop.com/a.jpg"]) {
    assertThrows(() => createHfMotionTransferInput(approved({ approvedCharacterImageUrls: refs as string[] })), ProviderError);
  }
  assertEquals(createHfMotionTransferInput(approved({ approvedCharacterImageUrls: Array.from({ length: 8 }, (_, i) => `https://uploads.rendprop.com/${i}.jpg`) })).task, HF_MOTION_TRANSFER_TASK);
  for (const resolution of ["1080p", "4k", "720P", 720, null]) {
    assertThrows(() => createHfMotionTransferInput(approved({ resolution: resolution as "720p" })), ProviderError);
  }
  for (const prompt of ["a".repeat(10_001), undefined, null, 42]) {
    assertThrows(() => createHfMotionTransferInput(approved({ reviewedPrompt: prompt as string })), ProviderError);
  }
  assertEquals(createHfMotionTransferInput(approved({ reviewedPrompt: "🎥".repeat(10_000) })).prompt, "🎥".repeat(10_000));
  for (const extra of [{ enhance_prompt: true }, { aspect_ratio: "9:16" }, { duration: 5 }, { extra: {} }]) {
    assertThrows(() => createHfMotionTransferInput({ ...approved(), ...extra } as HfMotionTransferInput), ProviderError);
  }
});

Deno.test("Genjutsu rejects unsafe media URL shapes without exposing the supplied URL in errors", () => {
  for (const url of [
    "", "http://uploads.rendprop.com/a.mp4", "file:///tmp/a.mp4", "data:video/mp4;base64,AAAA", "javascript:alert(1)",
    "https://localhost/a", "https://host.local/a", "https://127.0.0.1/a", "https://[::1]/a", "https://169.254.169.254/a",
    "https://2130706433/a", "https://example.com:8443/a", "https://user:secret@example.com/a", "https://example.com/a#secret",
    "https://example.com/\\a", " https://example.com/a", "https://example.com/a b", "https://example.com/a\u0000", `https://example.com/${"a".repeat(2083)}`,
  ]) {
    for (const data of [approved({ performanceVideoUrl: url }), approved({ approvedCharacterImageUrls: [url] })]) {
      const error = assertThrows(() => createHfMotionTransferInput(data), ProviderError);
      if (url) assert(!error.message.includes(url));
    }
  }
  const same = "https://uploads.rendprop.com/source";
  assertThrows(() => createHfMotionTransferInput(approved({ performanceVideoUrl: same, approvedCharacterImageUrls: [same] })), ProviderError);
});

Deno.test("Genjutsu rejects raw generic inputs and serialized or cloned brands before any network call", async () => {
  const branded = createHfMotionTransferInput(approved());
  const untrusted: GenerateInput[] = [
    { task: HF_MOTION_TRANSFER_TASK, video_url: approved().performanceVideoUrl, extra: { image_urls: approved().approvedCharacterImageUrls, approved: true } },
    { ...branded }, JSON.parse(JSON.stringify(branded)),
  ];
  let calls = 0;
  await withFetch(() => { calls++; throw new Error("Unexpected network call"); }, async () => {
    for (const input of untrusted) {
      await assertRejects(() => hfInput(step, input), ProviderError);
      await assertRejects(() => higgsfieldAdapter.submit(step, input), ProviderError);
      await assertRejects(() => estimateHfMotionTransfer(input), ProviderError);
    }
    await assertRejects(() => hfInput({ ...step, task: "video.reel_clip" }, branded), ProviderError);
  });
  assertEquals(calls, 0);
});

Deno.test("Genjutsu approval snapshot survives caller and returned-body mutation", async () => {
  const refs = ["https://uploads.rendprop.com/approved.jpg"];
  const source = approved({ approvedCharacterImageUrls: refs });
  const input = createHfMotionTransferInput(source);
  source.reviewedPrompt = "Unreviewed replacement";
  refs[0] = "https://uploads.rendprop.com/unapproved.jpg";
  const body = await hfInput(step, input);
  assertEquals(body.prompt, approved().reviewedPrompt);
  assertEquals(body.image_urls, ["https://uploads.rendprop.com/approved.jpg"]);
  (body.image_urls as string[])[0] = "https://uploads.rendprop.com/mutated.jpg";
  assertEquals((await hfInput(step, input)).image_urls, ["https://uploads.rendprop.com/approved.jpg"]);
  assert(Object.isFrozen(input));
});

Deno.test("Genjutsu estimate and submit send identical bodies to their distinct exact endpoints", async () => {
  const input = createHfMotionTransferInput(approved());
  const bodies: unknown[] = [];
  const urls: string[] = [];
  await withFetch((url, init) => {
    urls.push(url);
    assertEquals(init?.method, "POST");
    assertEquals((init?.headers as Record<string, string>).Authorization, "Key synthetic-not-a-credential:synthetic-not-a-credential");
    assert(init?.signal instanceof AbortSignal);
    bodies.push(JSON.parse(String(init?.body)));
    return new Response(JSON.stringify(url.includes("/estimate/") ? { credits: "7.125", usd: "0.094" } : {
      status: "queued", request_id: "synthetic-request", status_url: "https://api.higgsfield.ai/requests/synthetic-request/status",
    }));
  }, async () => {
    assertEquals(await estimateHfMotionTransfer(input), { credits: "7.125", usd: "0.094", ceilingCents: 10 });
    const ref = await higgsfieldAdapter.submit(step, input);
    assertEquals(ref.id, "synthetic-request");
    assertEquals(ref.model, HF_MOTION_TRANSFER_MODEL);
  });
  assertEquals(urls, [`https://api.higgsfield.ai/estimate/${HF_MOTION_TRANSFER_MODEL}`, `https://api.higgsfield.ai/${HF_MOTION_TRANSFER_MODEL}`]);
  assertEquals(bodies[0], bodies[1]);
});

Deno.test("Genjutsu quote rounds USD up exactly and refuses malformed or unbounded amounts", async () => {
  const input = createHfMotionTransferInput(approved());
  for (const [usd, expected] of [["0", 0], ["0.000000001", 1], ["0.10", 10], ["1.001", 101], ["9999.99", 999999]] as const) {
    await withFetch(() => new Response(JSON.stringify({ credits: "1", usd })), async () => {
      assertEquals((await estimateHfMotionTransfer(input)).ceilingCents, expected);
    });
  }
  for (const invalid of [0.1, -1, null, undefined, "NaN", "Infinity", "1e3", "-0.01", " 0.1", "00.1", "0.1234567891", "1000000000"]) {
    for (const data of [{ credits: "1", usd: invalid }, { credits: invalid, usd: "0.1" }]) {
      await withFetch(() => new Response(JSON.stringify(data)), async () => {
        await assertRejects(() => estimateHfMotionTransfer(input), ProviderError);
      });
    }
  }
  await withFetch(() => new Response(JSON.stringify({ credits: "1", usd: "10000.01" })), async () => {
    await assertRejects(() => estimateHfMotionTransfer(input), ProviderError);
  });
});

Deno.test("Genjutsu submission does not repeat POST after ambiguous timeout", async () => {
  let calls = 0;
  await withFetch(() => {
    calls++;
    throw new DOMException("synthetic timeout", "TimeoutError");
  }, async () => {
    const error = await assertRejects(() => higgsfieldAdapter.submit(step, createHfMotionTransferInput(approved())), ProviderError);
    assertEquals(error.error_class, "timeout");
  });
  assertEquals(calls, 1);
});

Deno.test("Genjutsu completed video and moderation use existing lifecycle without substitution", async () => {
  const ref = { provider: "higgsfield", model: HF_MOTION_TRANSFER_MODEL, id: "test", poll_url: "https://api.higgsfield.ai/requests/test/status", submitted_at: "2026-09-24T00:00:00Z" };
  await withFetch(() => new Response(JSON.stringify({ status: "completed", video: { url: "https://cdn.higgsfield.ai/result.mp4" } })), async () => {
    const state = await higgsfieldAdapter.poll(ref);
    assertEquals(state.status, "done");
    if (state.status === "done") assertEquals(state.result_url, "https://cdn.higgsfield.ai/result.mp4");
  });
  await withFetch(() => new Response(JSON.stringify({ status: "nsfw" })), async () => {
    const state = await higgsfieldAdapter.poll(ref);
    assertEquals(state.status, "failed");
    if (state.status === "failed") assertEquals(state.error_class, "nsfw");
  });
});
