import {
  assertEquals,
  assertRejects,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  boundedBytes,
  completedVideoKey,
  creativeId,
  downloadURL,
  handleCreative,
  renewTrustedJobReferences,
  voiceStorageKey,
} from "./creative.ts";
import { HttpError } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";
const org = "11111111-1111-4111-8111-111111111111",
  user = "22222222-2222-4222-8222-222222222222",
  listing = "33333333-3333-4333-8333-333333333333",
  id = "44444444-4444-4444-8444-444444444444";
Deno.test("video import adopts the confirmed immutable operation key and verifies its asset identity", () => {
  const promoted =
    `renders/${org}/${listing}/${id}-complete-55555555-5555-4555-8555-555555555555.mp4`;
  const scope = { orgId: org, listingId: listing, assetId: id };
  assertEquals(
    completedVideoKey({
      id,
      listing_id: listing,
      uploaded: true,
      storage_key: promoted,
    }, scope),
    promoted,
  );
  assertEquals(
    completedVideoKey(
      { asset_id: id, uploaded: true, storage_key: promoted },
      scope,
      true,
    ),
    promoted,
  );
  assertThrows(
    () =>
      completedVideoKey({
        id: user,
        listing_id: listing,
        uploaded: true,
        storage_key: promoted,
      }, scope),
    HttpError,
  );
  assertThrows(
    () =>
      completedVideoKey({
        id,
        listing_id: org,
        uploaded: true,
        storage_key: promoted,
      }, scope),
    HttpError,
  );
  assertThrows(
    () =>
      completedVideoKey({
        id,
        listing_id: listing,
        uploaded: true,
        storage_key: `renders/${user}/${listing}/${id}.mp4`,
      }, scope),
    HttpError,
  );
});
Deno.test("voice key refresh is bounded to the exact trusted R2 audio namespace", () => {
  const host = "012345678901234567890123456789ab.r2.cloudflarestorage.com";
  assertEquals(
    voiceStorageKey(
      `https://${host}/rendprop-uploads/ai-voice/${org}/${id}.mp3?X-Amz-Signature=unused`,
      org,
    ),
    `ai-voice/${org}/${id}.mp3`,
  );
  assertThrows(
    () =>
      voiceStorageKey(
        `https://${host}/rendprop-uploads/ai-voice/${user}/${id}.mp3`,
        org,
      ),
    HttpError,
  );
  assertThrows(
    () =>
      voiceStorageKey(
        `https://${host}/rendprop-uploads/ai-voice/${org}/%2e%2e/other.mp3`,
        org,
      ),
    HttpError,
  );
  assertThrows(
    () =>
      voiceStorageKey(`https://audio.invalid/ai-voice/${org}/${id}.mp3`, org),
    HttpError,
  );
});
Deno.test("generated downloads accept configured own storage or known provider results only", () => {
  assertEquals(
    downloadURL("https://v3.fal.media/files/example.mp4"),
    "https://v3.fal.media/files/example.mp4",
  );
  assertEquals(
    downloadURL(
      "https://media.example.invalid/renders/clip.mp4",
      "https://media.example.invalid/",
    ),
    "https://media.example.invalid/renders/clip.mp4",
  );
  for (
    const value of [
      "http://localhost/file",
      "https://example.invalid/file",
      "https://fal.media.example.invalid/file",
      "https://user@fal.media/file",
      "https://fal.media:444/file",
    ]
  ) assertThrows(() => downloadURL(value), HttpError);
});
Deno.test("streaming import enforces its byte ceiling without trusting content length", async () => {
  assertEquals(
    await boundedBytes(new Response(new Uint8Array([1, 2, 3])), 4),
    new Uint8Array([1, 2, 3]),
  );
  await assertRejects(
    () => boundedBytes(new Response(new Uint8Array(5)), 4),
    HttpError,
  );
  await assertRejects(
    () =>
      boundedBytes(
        new Response("", { headers: { "content-length": "1000" } }),
        4,
      ),
    HttpError,
  );
});
Deno.test("creative ids reject invalid or missing selections", () => {
  assertEquals(creativeId(id), id);
  assertThrows(() => creativeId(""), HttpError);
  assertThrows(() => creativeId("not-an-id"), HttpError);
});
function context(row: any, duplicate = false): StudioContext {
  const admin = {
    from: () => {
      let action = "read", patch: any = null;
      const chain: any = {
        insert: (value: any) => {
          action = "insert";
          patch = value;
          return chain;
        },
        update: (value: any) => {
          action = "update";
          patch = value;
          return chain;
        },
        select: () => chain,
        eq: () => chain,
        maybeSingle: async () => ({ data: row, error: null }),
        single: async () => {
          if (action === "insert" && duplicate) {
            return { data: null, error: { code: "23505" } };
          }
          if (patch) Object.assign(row, patch);
          return { data: row, error: null };
        },
        then: (resolve: (value: any) => void) => {
          if (patch) Object.assign(row, patch);
          resolve({ data: row, error: null });
        },
      };
      return chain;
    },
  };
  return {
    userId: user,
    orgId: org,
    admin: admin as any,
    db: {} as any,
    authorizeListing: async (candidate) => {
      if (candidate !== listing) throw new HttpError(403, "Wrong listing");
    },
  };
}
Deno.test("duplicate reservation is returned without dispatching another paid generation", async () => {
  const body = { listing_id: listing, kind: "reel", image_b64: "abc" };
  const bytes = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(JSON.stringify(body)),
  );
  const digest = Array.from(
    new Uint8Array(bytes),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
  const row = {
    id,
    user_id: user,
    org_id: org,
    listing_id: listing,
    kind: "video",
    metadata: { state: "submitting", digest },
    created_at: "2026-09-14T00:00:00Z",
  };
  const response = await handleCreative(
    new Request("https://test.invalid/studio/video", {
      method: "POST",
      headers: { "Idempotency-Key": "request-key-123" },
      body: JSON.stringify(body),
    }),
    context(row, true),
  );
  assertEquals(response!.status, 200);
  assertEquals((await response!.json()).result.state, "submitting");
});
Deno.test("duplicate request key cannot be reused for different creative input", async () => {
  const row = {
    id,
    user_id: user,
    org_id: org,
    listing_id: listing,
    kind: "video",
    metadata: { state: "submitting", digest: "other" },
  };
  await assertRejects(
    () =>
      handleCreative(
        new Request("https://test.invalid/studio/video", {
          method: "POST",
          headers: { "Idempotency-Key": "request-key-123" },
          body: JSON.stringify({ listing_id: listing, kind: "reel" }),
        }),
        context(row, true),
      ),
    HttpError,
    "already been used",
  );
});
Deno.test("trusted video submit hides upstream job URLs while retaining recovery reference", async () => {
  const original = globalThis.fetch, old = Deno.env.get("SUPABASE_URL");
  Deno.env.set("SUPABASE_URL", "https://project.supabase.co");
  let requests = 0;
  globalThis.fetch = async (input, init) => {
    requests++;
    assertEquals(
      String(input),
      "https://project.supabase.co/functions/v1/ai-video/reel-clip",
    );
    assertEquals(
      new Headers((init as any)?.headers).get("authorization"),
      "Bearer fixture-user",
    );
    return new Response(
      JSON.stringify({
        request_id: "provider-123",
        status_url: "https://fal.example.invalid/private-status",
        response_url: "https://fal.example.invalid/private-response",
        disclosure: "AI generated movement.",
      }),
      { headers: { "content-type": "application/json" } },
    );
  };
  try {
    const row: any = {
      id,
      user_id: user,
      org_id: org,
      listing_id: listing,
      kind: "video",
      created_at: "2026-09-14T00:00:00Z",
      metadata: {},
    };
    const response = await handleCreative(
      new Request("https://test.invalid/studio/video", {
        method: "POST",
        headers: {
          "Idempotency-Key": "request-key-123",
          authorization: "Bearer fixture-user",
        },
        body: JSON.stringify({
          listing_id: listing,
          kind: "reel",
          image_b64: "abc",
        }),
      }),
      context(row),
    );
    const output = await response!.json();
    assertEquals(response!.status, 202);
    assertEquals(requests, 1);
    assertEquals(output.result.state, "processing");
    assertEquals(output.result.request_id, "provider-123");
    assertEquals(JSON.stringify(output).includes("private-status"), false);
    assertEquals(
      row.metadata.status_url,
      "https://fal.example.invalid/private-status",
    );
  } finally {
    globalThis.fetch = original;
    if (old === undefined) Deno.env.delete("SUPABASE_URL");
    else Deno.env.set("SUPABASE_URL", old);
  }
});
Deno.test("an active import lease lets another device read progress without a duplicate transfer", async () => {
  const row = {
    id,
    user_id: user,
    org_id: org,
    listing_id: listing,
    kind: "video",
    metadata: {
      state: "importing",
      import_started: Date.now(),
      status_url: "trusted-status",
      response_url: "trusted-result",
      video_kind: "reel",
    },
  };
  const response = await handleCreative(
    new Request("https://test.invalid/studio/video-status", {
      method: "POST",
      body: JSON.stringify({ result_id: id }),
    }),
    context(row),
  );
  assertEquals(response!.status, 200);
  assertEquals((await response!.json()).result.state, "importing");
});
Deno.test("uncertain provider submission keeps its reservation so retry cannot spend again", async () => {
  const original = globalThis.fetch, old = Deno.env.get("SUPABASE_URL");
  Deno.env.set("SUPABASE_URL", "https://project.supabase.co");
  let requests = 0;
  globalThis.fetch = async () => {
    requests++;
    throw new Error("simulated lost response");
  };
  const row: any = {
    id,
    user_id: user,
    org_id: org,
    listing_id: listing,
    kind: "video",
    metadata: {},
  };
  const request = () =>
    new Request("https://test.invalid/studio/video", {
      method: "POST",
      headers: { "Idempotency-Key": "ambiguous-request" },
      body: JSON.stringify({
        listing_id: listing,
        kind: "reel",
        image_b64: "abc",
      }),
    });
  try {
    await assertRejects(
      () => handleCreative(request(), context(row)),
      Error,
      "simulated lost response",
    );
    assertEquals(row.metadata.state, "needs_review");
    const recovered = await handleCreative(request(), context(row, true));
    assertEquals((await recovered!.json()).result.state, "needs_review");
    assertEquals(requests, 1);
  } finally {
    globalThis.fetch = original;
    if (old === undefined) Deno.env.delete("SUPABASE_URL");
    else Deno.env.set("SUPABASE_URL", old);
  }
});

Deno.test("private saved job references renew after expiry only for their signed owner", async () => {
  const { encodeJobToken, verifyJobToken } = await import(
    "../_shared/providers/jobtoken.ts"
  );
  const previousSecret = Deno.env.get("JOB_TOKEN_SIGNING_SECRET"),
    clock = Date.now;
  Deno.env.set(
    "JOB_TOKEN_SIGNING_SECRET",
    "isolated-test-job-signing-secret-with-32-bytes",
  );
  try {
    Date.now = () => clock() - 3 * 3600_000;
    let token: string;
    try {
      token = await encodeJobToken({
        p: "fal",
        m: "fixture-model",
        i: "fixture-job",
        t: new Date().toISOString(),
        k: "video.reel",
      }, { orgId: org, userId: user });
    } finally {
      Date.now = clock;
    }
    const oldURL =
      `https://project.supabase.co/functions/v1/ai-video/status?job=${token}`;
    assertEquals(
      await verifyJobToken(token, { orgId: org, userId: user }),
      null,
    );
    const refs = await renewTrustedJobReferences(oldURL, oldURL, {
      orgId: org,
      userId: user,
    });
    const next = new URL(refs.status_url).searchParams.get("job")!;
    assertEquals(
      (await verifyJobToken(next, { orgId: org, userId: user }))?.i,
      "fixture-job",
    );
    await assertRejects(
      () =>
        renewTrustedJobReferences(oldURL, oldURL, {
          orgId: org,
          userId: listing,
        }),
      HttpError,
    );
  } finally {
    Date.now = clock;
    if (previousSecret === undefined) {
      Deno.env.delete("JOB_TOKEN_SIGNING_SECRET");
    } else Deno.env.set("JOB_TOKEN_SIGNING_SECRET", previousSecret);
  }
});
