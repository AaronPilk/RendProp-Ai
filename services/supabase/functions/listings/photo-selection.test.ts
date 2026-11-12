// Actual listing handler + closed transport. No network, customer or media bytes.
import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
const ORG = "a0200216-0000-4000-8000-000000000001",
  LISTING = "a0200216-0000-4000-8000-000000000002",
  USER = "a0200216-0000-4000-8000-000000000003",
  ASSET = "a0200216-0000-4000-8000-000000000004",
  LIBRARY = "a0200216-0000-4000-8000-000000000005",
  OTHER = "a0200216-0000-4000-8000-000000000006",
  OP = "a0200216-0000-4000-8000-000000000007";
const PHOTO=new Uint8Array([255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]);
const SHA=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",PHOTO)),n=>n.toString(16).padStart(2,"0")).join("");
const KEY = `renders/${ORG}/${LISTING}/gallery-${ASSET}.jpg`;
for (
  const [k, v] of Object.entries({
    SUPABASE_URL: "https://native-selection-fixture.invalid",
    SUPABASE_ANON_KEY: "fixture-anon",
    SUPABASE_SERVICE_ROLE_KEY: "fixture-service",
    CLOUDFLARE_ACCOUNT_ID: "fixture",
    R2_ACCESS_KEY_ID: "fixture",
    R2_SECRET_ACCESS_KEY: "fixture",
    R2_PUBLIC_BASE_URL: "https://cover.fixture.invalid",
  })
) Deno.env.set(k, v);
type Row = Record<string, unknown>;
type Handler = (req: Request) => Promise<Response>;
let handler!: Handler;
const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
try {
  Object.defineProperty(Deno, "serve", {
    configurable: true,
    writable: true,
    value: (fn: Handler) => {
      handler = fn;
      return {};
    },
  });
  await import("./index.ts");
} finally {
  Object.defineProperty(Deno, "serve", serve);
}
const intent = () => ({
  family_asset_ids: [ASSET],
  target: { asset_id: ASSET, sha256: SHA, bytes: PHOTO.length },
  expected_selection: {
    gallery_asset_ids: [] as string[],
    main_photo_key: null,
  },
  follow_family_cover: false,
  reviewed: false,
});
const body = () => ({ operation_id: OP, ...intent() });
type Options = {
  method?: string;
  abandon?: boolean;
  query?: string;
  header?: string | null;
  key?: string | null;
  readOnly?: boolean;
  missing?: boolean;
  deleting?: boolean;
  scopeChanges?: boolean;
  rpcError?: Row;
  transportLoss?: boolean;
  reply?: Row;
  operation?: Row | null;
  replayed?: boolean;
};
async function invoke(value: Row = body(), o: Options = {}) {
  const previous = globalThis.fetch, calls: { name: string; args: Row }[] = [];
  let scopeReads = 0;
  const response = (x: unknown, status = 200) =>
    new Response(JSON.stringify(x), {
      status,
      headers: { "content-type": "application/json" },
    });
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init), url = new URL(req.url);
    if(url.hostname.endsWith(".r2.cloudflarestorage.com")){
      assertEquals(req.method,"GET");assertEquals(req.headers.get("if-match"),'"fixture"');
      return new Response(PHOTO,{headers:{"content-length":String(PHOTO.length),"content-type":"image/jpeg",etag:'"fixture"'}});
    }
    assertEquals(url.hostname, "native-selection-fixture.invalid");
    if (url.pathname === "/auth/v1/user") {
      return response({ id: USER, is_anonymous: false });
    }
    if (url.pathname.endsWith("listing_library_scope")) {
      scopeReads++;
      return response({
        actor_id: USER,
        listing_id: LISTING,
        org_id: ORG,
        library_org_id: o.scopeChanges && scopeReads > 1 ? OTHER : LIBRARY,
        library_owner_user_id: USER,
        listing_owner_user_id: USER,
        role: o.readOnly ? "marketing" : "owner",
        access_mode: "own",
        can_read: !o.missing,
        can_write: !o.readOnly && !o.missing,
        can_manage_subscription: true,
        billing_org_id: LIBRARY,
        team_org_id: null,
      });
    }
    if (url.pathname.endsWith("deletion_requests")) {
      return response(o.deleting ? [{ id: OTHER }] : []);
    }
    const name = url.pathname.split("/").at(-1)!;
    if(name==="hosting_retention_state")return response({org_id:LIBRARY,policy:"preserved",protected:false,retention_ends_at:null,hosting_available:true});
    if(name==="library_media_delivery_admit")return response({admitted:true,legacy_unbudgeted:false});
    if(name==="photo_publication_target")return response({actor_id:USER,org_id:ORG,library_org_id:LIBRARY,listing_id:LISTING,target:{asset_id:ASSET,key:KEY,sha256:SHA,bytes:PHOTO.length,mime:"image/jpeg",etag:'"fixture"',operation_id:OP},publication:null});
    if(name==="photo_publication_resolve")return response(null);
    if (
      name === "native_gallery_selection_snapshot_v2" ||
      name === "native_gallery_selection_change_v2" ||
      name === "native_gallery_selection_abandon"
    ) {
      const args = await req.json();
      calls.push({ name, args });
      assertEquals(args.p_actor, USER);
      assertEquals(args.p_org, ORG);
      assertEquals(args.p_library, LIBRARY);
      assertEquals(args.p_listing, LISTING);
      if (o.transportLoss) throw new TypeError("Synthetic lost reply");
      if (o.rpcError) return response(o.rpcError, 400);
      const raw = {
        schema: 1,
        actor_id: USER,
        org_id: ORG,
        library_org_id: LIBRARY,
        listing_id: LISTING,
        gallery_asset_ids: [ASSET],
        effective_asset_ids: [ASSET],
        main_photo_key: null,
        gallery_assets: [{
          asset_id: ASSET,
          sha256: SHA,
          bytes: PHOTO.length,
          storage_key: KEY,
        }],
        operation_status:
          name !== "native_gallery_selection_snapshot_v2" || o.operation
            ? "accepted"
            : args.p_operation
            ? "not_found"
            : null,
        abandoned_operation: null,
        operation: name !== "native_gallery_selection_snapshot_v2"
          ? {
            operation_id: OP,
            request: args.p_request,
            result: { gallery_asset_ids: [ASSET], main_photo_key: null },
          }
          : o.operation ?? null,
        ...(name !== "native_gallery_selection_snapshot_v2"
          ? {
            ok: true,
            replayed: o.replayed ?? false,
            ...(name === "native_gallery_selection_abandon"
              ? { abandoned: false }
              : {}),
          }
          : {}),
        ...o.reply,
      };
      return response(raw);
    }
    throw new Error("Unmodeled request " + req.method + " " + url.pathname);
  };
  try {
    const method = o.method ?? "PATCH",
      header = o.header === undefined ? LIBRARY : o.header,
      key = o.key === undefined ? `photo-selection:${OP}` : o.key;
    const r = await handler(
      new Request(
        `https://edge.fixture.invalid/listings/${LISTING}/photo-selection${
          o.abandon ? "/abandon" : ""
        }${o.query ?? ""}`,
        {
          method,
          headers: {
            authorization: "Bearer fixture",
            ...(header ? { "x-org-id": header } : {}),
            ...(key ? { "Idempotency-Key": key } : {}),
          },
          body: method === "GET" ? undefined : JSON.stringify(value),
        },
      ),
    );
    return {
      status: r.status,
      body: await r.json(),
      cache: r.headers.get("cache-control"),
      calls,
      scopeReads,
    };
  } finally {
    globalThis.fetch = previous;
  }
}
Deno.test("actual dedicated photo choice derives physical scope and sends one exact RPC", async () => {
  const r = await invoke();
  assertEquals(r.status, 200);
  assertEquals(r.cache, "private, no-store");
  assertEquals(r.calls, [{
    name: "native_gallery_selection_change_v2",
    args: {
      p_actor: USER,
      p_org: ORG,
      p_library: LIBRARY,
      p_listing: LISTING,
      p_operation: OP,
      p_request: intent(),
    },
  }]);
  assertEquals(r.scopeReads, 2);
});
Deno.test("actual authoritative read is private and carries only requested receipt identity", async () => {
  for (const q of ["", `?operation_id=${OP.toUpperCase()}`]) {
    const r = await invoke({}, { method: "GET", query: q });
    assertEquals(r.status, 200);
    assertEquals(r.cache, "private, no-store");
    assertEquals(r.calls[0].args.p_operation, q ? OP : null);
    assertEquals(r.calls[0].name, "native_gallery_selection_snapshot_v2");
  }
});
Deno.test("actual operation replay returns current snapshot and immutable old receipt", async () => {
  const r = await invoke(body(), {
    replayed: true,
    reply: {
      gallery_asset_ids: [],
      effective_asset_ids: [],
      gallery_assets: [],
    },
  });
  assertEquals(r.status, 200);
  assertEquals(r.body.replayed, true);
  assertEquals(r.body.gallery_asset_ids, []);
  assertEquals(r.body.operation.result.gallery_asset_ids, [ASSET]);
  assertEquals(r.calls.length, 1);
});
Deno.test("actual route refuses missing or physical-only library header before RPC", async () => {
  for (const header of [null, ORG, OTHER]) {
    const r = await invoke(body(), { header });
    assert(r.status === 409 || r.status === 404);
    assertEquals(r.calls, []);
  }
});
Deno.test("actual write refuses read-only missing listing or deleting account before RPC", async () => {
  for (
    const [o, status] of [[{ readOnly: true }, 403], [{ missing: true }, 404], [
      { deleting: true },
      409,
    ]] as const
  ) {
    const r = await invoke(body(), o);
    assertEquals(r.status, status);
    assertEquals(r.calls, []);
  }
});
Deno.test("actual choice refuses unknown or forged authority provider and storage fields", async () => {
  for (
    const field of [
      "actor_id",
      "org_id",
      "library_org_id",
      "provider",
      "storage_key",
      "gallery_asset_ids",
      "negative_prompt",
      "internal",
    ]
  ) {
    const r = await invoke({ ...body(), [field]: OTHER });
    assertEquals(r.status, 400);
    assertEquals(r.calls, []);
  }
});
Deno.test("actual choice requires exact matching saved operation header", async () => {
  for (const key of [null, "photo-selection:" + OTHER, "other:" + OP]) {
    const r = await invoke(body(), { key });
    assertEquals(r.status, 409);
    assertEquals(r.calls, []);
  }
});
Deno.test("actual choice rejects malformed bounded footprint and target before RPC", async () => {
  for (
    const patch of [
      { family_asset_ids: [] },
      { family_asset_ids: [ASSET, ASSET.toUpperCase()] },
      { family_asset_ids: Array(101).fill(ASSET) },
      { target: { asset_id: OTHER, sha256: SHA, bytes: PHOTO.length } },
      { target: { asset_id: ASSET, sha256: SHA, bytes: 0 } },
      { target: { asset_id: ASSET, sha256: "z".repeat(64), bytes: PHOTO.length } },
      { target: null, reviewed: true },
      {
        expected_selection: {
          gallery_asset_ids: [],
          main_photo_key: null,
          extra: true,
        },
      },
    ]
  ) {
    const r = await invoke({ ...body(), ...patch });
    assertEquals(r.status, 400);
    assertEquals(r.calls, []);
  }
});
Deno.test("actual read refuses ambiguous query and unmatched operation receipt", async () => {
  for (
    const q of [
      "?extra=1",
      `?operation_id=${OP}&operation_id=${OP}`,
      "?operation_id=bad",
    ]
  ) {
    const r = await invoke({}, { method: "GET", query: q });
    assertEquals(r.status, 400);
    assertEquals(r.calls, []);
  }
  const r = await invoke({}, {
    method: "GET",
    query: `?operation_id=${OP}`,
    operation: { operation_id: OTHER },
  });
  assertEquals(r.status, 503);
});
Deno.test("actual CAS refusal is definite conflict and is never automatically replayed", async () => {
  const r = await invoke(body(), {
    rpcError: {
      code: "PT409",
      message: "RP409: The listing photo selection changed",
    },
  });
  assertEquals(r.status, 409);
  assertEquals(r.body.code, "gallery_selection_changed");
  assertEquals(r.calls.length, 1);
});
Deno.test("actual lost reply stays ambiguous without mutation retry", async () => {
  const r = await invoke(body(), { transportLoss: true });
  assertEquals(r.status, 503);
  assertEquals(r.calls.length, 1);
});
Deno.test("actual successful reply is refused when library mapping changes after RPC", async () => {
  const r = await invoke(body(), { scopeChanges: true });
  assertEquals(r.status, 503);
  assertEquals(r.calls.length, 1);
  assertEquals(r.scopeReads, 2);
});
Deno.test("actual malformed upstream identity membership or bytes never confirms", async () => {
  for (
    const reply of [
      { actor_id: OTHER },
      { org_id: OTHER },
      { library_org_id: OTHER },
      { listing_id: OTHER },
      { effective_asset_ids: [OTHER] },
      {
        gallery_assets: [{
          asset_id: ASSET,
          sha256: SHA,
          bytes: PHOTO.length,
          storage_key: KEY.replace(ORG, OTHER),
        }],
      },
      {
        gallery_assets: [{
          asset_id: ASSET,
          sha256: SHA,
          bytes: 0,
          storage_key: KEY,
        }],
      },
      {
        operation: {
          operation_id: OP,
          request: { ...intent(), reviewed: true },
          result: { gallery_asset_ids: [ASSET], main_photo_key: null },
        },
      },
    ]
  ) {
    const r = await invoke(body(), { reply });
    assertEquals(r.status, 503);
    assertEquals(r.calls.length, 1);
  }
});

Deno.test("actual unselect receipt must prove family absence while preserving other effects", async () => {
  const remove = { ...body(), target: null };
  const bad = await invoke(remove);
  assertEquals(bad.status, 503);
  const good = await invoke(remove, {
    reply: {
      gallery_asset_ids: [],
      effective_asset_ids: [],
      gallery_assets: [],
      operation: {
        operation_id: OP,
        request: { ...intent(), target: null },
        result: { gallery_asset_ids: [], main_photo_key: null },
      },
    },
  });
  assertEquals(good.status, 200);
  assertEquals(good.calls.length, 1);
});

Deno.test("optional false cover field preserves the exact five-key legacy intent", async () => {
  const r = await invoke({ ...body(), promote_cover: false });
  assertEquals(r.status, 200);
  assertEquals(r.calls[0].args.p_request, intent());
});
Deno.test("explicit star accepts only cover-only receipt and retains raw null gallery", async () => {
  for (const gallery of [[ASSET], null]) {
    const choice = {
      ...body(),
      expected_selection: { gallery_asset_ids: gallery, main_photo_key: null },
      promote_cover: true,
    };
    const { operation_id: _, ...request } = choice;
    const r = await invoke(choice, {
      reply: {
        gallery_asset_ids: gallery,
        main_photo_key: KEY,
        operation: {
          operation_id: OP,
          request,
          result: { gallery_asset_ids: gallery, main_photo_key: KEY },
        },
      },
    });
    assertEquals(r.status, 200);
    assertEquals(r.calls[0].args.p_request, request);
    for (const mutated of [[], [ASSET, OTHER]]) {
      const bad = await invoke(choice, {
        reply: {
          operation: {
            operation_id: OP,
            request,
            result: { gallery_asset_ids: mutated, main_photo_key: KEY },
          },
        },
      });
      assertEquals(bad.status, 503);
    }
  }
});
Deno.test("star cannot smuggle unknown fields or removal/follow intent", async () => {
  for (
    const patch of [
      { promote_cover: "true" },
      { promote_cover: null },
      { promote_cover: true, target: null },
      { promote_cover: true, follow_family_cover: true },
      { promote_cover: true, cover_key: KEY },
    ]
  ) {
    const r = await invoke({ ...body(), ...patch });
    assertEquals(r.status, 400);
    assertEquals(r.calls, []);
  }
});
Deno.test("explicit abandon uses one scoped RPC and accepted legacy receipt wins unchanged", async () => {
  const r = await invoke(body(), { method: "POST", abandon: true });
  assertEquals(r.status, 200);
  assertEquals(r.body.abandoned, false);
  assertEquals(r.body.operation_status, "accepted");
  assertEquals(r.calls.length, 1);
  assertEquals(r.calls[0].name, "native_gallery_selection_abandon");
  assertEquals(r.body.operation, {
    operation_id: OP,
    request: intent(),
    result: { gallery_asset_ids: [ASSET], main_photo_key: null },
  });
});
const abandonedReply = () => ({
  operation_status: "abandoned",
  operation: null,
  abandoned: true,
  abandoned_operation: { operation_id: OP, request: intent() },
});
Deno.test("abandon acknowledgement proves exact frozen request while returning current state", async () => {
  const r = await invoke(body(), {
    method: "POST",
    abandon: true,
    reply: {
      ...abandonedReply(),
      gallery_asset_ids: [],
      effective_asset_ids: [],
      gallery_assets: [],
    },
  });
  assertEquals(r.status, 200);
  assertEquals(r.body.gallery_asset_ids, []);
  assertEquals(r.body.abandoned, true);
  for (
    const reply of [
      { ...abandonedReply(), abandoned: false },
      {
        ...abandonedReply(),
        abandoned_operation: { operation_id: OTHER, request: intent() },
      },
      {
        ...abandonedReply(),
        abandoned_operation: {
          operation_id: OP,
          request: { ...intent(), reviewed: true },
        },
      },
      { ...abandonedReply(), operation_status: undefined },
      {
        ...abandonedReply(),
        operation: {
          operation_id: OP,
          request: intent(),
          result: { gallery_asset_ids: [], main_photo_key: null },
        },
      },
    ]
  ) {
    const bad = await invoke(body(), { method: "POST", abandon: true, reply });
    assertEquals(bad.status, 503);
    assertEquals(bad.calls.length, 1);
  }
  const patch = await invoke(body(), { reply: abandonedReply() });
  assertEquals(patch.status, 503);
});
Deno.test("status GET distinguishes absence from tombstone and missing status stays unconfirmed", async () => {
  const absent = await invoke({}, {
    method: "GET",
    query: `?operation_id=${OP}`,
  });
  assertEquals(absent.status, 200);
  assertEquals(absent.body.operation_status, "not_found");
  const abandoned = await invoke({}, {
    method: "GET",
    query: `?operation_id=${OP}`,
    reply: abandonedReply(),
  });
  assertEquals(abandoned.status, 200);
  const missing = await invoke({}, {
    method: "GET",
    query: `?operation_id=${OP}`,
    reply: { operation_status: undefined },
  });
  assertEquals(missing.status, 503);
  const wrong = await invoke({}, {
    method: "GET",
    query: `?operation_id=${OP}`,
    reply: {
      ...abandonedReply(),
      abandoned_operation: { operation_id: OTHER, request: intent() },
    },
  });
  assertEquals(wrong.status, 503);
});
Deno.test("abandon lost reply never retries and mapping change refuses confirmation", async () => {
  const lost = await invoke(body(), {
    method: "POST",
    abandon: true,
    transportLoss: true,
  });
  assertEquals(lost.status, 503);
  assertEquals(lost.calls.length, 1);
  const drift = await invoke(body(), {
    method: "POST",
    abandon: true,
    scopeChanges: true,
  });
  assertEquals(drift.status, 503);
  assertEquals(drift.calls.length, 1);
  for (
    const o of [{ method: "POST" }, { method: "PATCH", abandon: true }, {
      method: "GET",
      abandon: true,
    }]
  ) {
    const r = await invoke(body(), o);
    assertEquals(r.status, 405);
    assertEquals(r.calls, []);
  }
});
