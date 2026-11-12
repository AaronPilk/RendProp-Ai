import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { bucketForKey, createStudioHandler, PAGE_SIZE } from "./handler.ts";
import type { MediaScope, PhotoRow, StudioDependencies, StudioMediaTiming } from "./handler.ts";
import { HttpError } from "../_shared/http.ts";
import { createPrivateMediaRequestSigner } from "../_shared/private-media.ts";
const org = "10000000-0000-4000-8000-000000000001",
  listing = "20000000-0000-4000-8000-000000000002",
  user = "30000000-0000-4000-8000-000000000003";
const scope: MediaScope = { userId: user, orgId: org, listingId: listing };
const key = `uploads/${org}/${listing}/photo.jpg`;
function fixture() {
  const signed: string[] = [];
  let reads = 0;
  const deps: StudioDependencies = {
    authorize: async () => scope,
    mediaVisibility: async (_scope, refs) => ({ assets: Object.fromEntries((refs.assets ?? []).map(id => [id, true])), renders: Object.fromEntries((refs.renders ?? []).map(id => [id, true])), keys: Object.fromEntries((refs.keys ?? []).map(key => [key, true])) }),
    rateLimit: async () => true,
    read: async () => {
      reads++;
      return { photos: [], assets: [], renders: [] };
    },
    sign: async (bucket, key, ttl) => {
      signed.push(`${bucket}:${key}:${ttl}`);
      return "https://objects.example/read";
    },
    assertSigningPolicyFresh: async () => {},
    now: () => Date.parse("2026-09-12T12:00:00Z"),
  };
  return { deps, signed, reads: () => reads };
}
const request = (
  query = "",
  method = "GET",
  headers: Record<string, string> = {},
) =>
  new Request(
    `https://project.supabase.co/functions/v1/studio/media?org_id=${org}&listing_id=${listing}${query}`,
    { method, headers },
  );
const photo: PhotoRow = {
  id: "40000000-0000-4000-8000-000000000004",
  listing_id: listing,
  original_key: key,
  enhanced_key: null,
  caption: "Example room",
  is_staged: true,
  sort: 0,
  created_at: "2026-09-12T00:00:00Z",
};
Deno.test("canonical linked keys only, not arbitrary object reads", () => {
  assertEquals(bucketForKey(key, scope), "uploads");
  assertEquals(
    bucketForKey(`renders/${org}/${listing}/finished.mp4`, scope),
    "renders",
  );
  for (
    const bad of [
      null,
      "",
      `uploads/${user}/${listing}/x.jpg`,
      `uploads/${org}/${user}/x.jpg`,
      `_staging/${key}`,
      `${key}?version=1`,
      `${key}/../other`,
      `uploads/${org}/${listing}/%2e%2e/x`,
      `${key}#x`,
      `${key}\\x`,
      `ai-router/${org}/result.jpg`,
    ]
  ) {
    assertEquals(bucketForKey(bad, scope), null);
  }
});
Deno.test("OPTIONS requires no authorization or media read", async () => {
  const f = fixture();
  f.deps.authorize = () => {
    throw Error("should not run");
  };
  const r = await createStudioHandler(f.deps)(request("", "OPTIONS"));
  assertEquals(r.status, 200);
  assertEquals(f.reads(), 0);
});

Deno.test("media timing records fixed phases and status without tenant or object identities", async () => {
  const f = fixture(), samples: StudioMediaTiming[] = [];
  f.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
  f.deps.observeTiming = sample => samples.push(sample);
  const response = await createStudioHandler(f.deps)(request());
  assertEquals(response.status, 200);
  assertEquals(samples.length, 1);
  const timing = samples[0];
  assertEquals(timing.event, "studio_media_timing");
  assertEquals(timing.status, 200);
  assertEquals(timing.sign_calls, 1);
  assertEquals(timing.photo_count, 1);
  assertEquals(timing.video_count, 0);
  assertEquals(timing.unavailable_count, 0);
  for (const phase of ["total_ms", "authorize_initial_ms", "rate_limit_ms", "read_ms", "visibility_initial_ms", "signing_ms", "authorize_final_ms", "visibility_final_ms", "signing_policy_final_ms"] as const) {
    assert(Number.isSafeInteger(timing[phase]) && timing[phase]! >= 0);
  }
  assert(!JSON.stringify(timing).includes(org));
  assert(!JSON.stringify(timing).includes(listing));
  assert(!JSON.stringify(timing).includes(key));

  const denied = fixture(), errors: StudioMediaTiming[] = [];
  denied.deps.authorize = async () => { throw new HttpError(403, "Not a member."); };
  denied.deps.observeTiming = sample => errors.push(sample);
  assertEquals((await createStudioHandler(denied.deps)(request())).status, 403);
  assertEquals(errors.length, 1);
  assertEquals(errors[0].status, 403);
  assertEquals(errors[0].sign_calls, undefined);
  assert(Number.isSafeInteger(errors[0].authorize_initial_ms));
});
Deno.test("a mid-request transport-policy switch or failed final lookup discards every signed Studio URL", async () => {
  const prior = Deno.env.get("PRIVATE_MEDIA_DELIVERY");
  Deno.env.set("PRIVATE_MEDIA_DELIVERY", "off");
  try {
    for (const final of [true, new Error("policy unavailable")]) {
      const f = fixture();
      f.deps.read = async () => ({ photos: [photo, { ...photo, id: "50000000-0000-4000-8000-000000000005", original_key: `uploads/${org}/${listing}/second.jpg` }], assets: [], renders: [] });
      let checks = 0, signs = 0;
      const order: string[] = [];
      f.deps.authorize = async () => { order.push("authorize"); return scope; };
      const visibility = f.deps.mediaVisibility;
      f.deps.mediaVisibility = (authorized, refs) => { order.push("visibility"); return visibility(authorized, refs); };
      const signer = createPrivateMediaRequestSigner(org, {
        gatewayRequired: async () => { order.push("policy"); checks++; if (checks === 1) return false; if (final instanceof Error) throw final; return final; },
        directSign: async () => { signs++; return "https://fixture.invalid/private-object"; },
      });
      f.deps.sign = (bucket, objectKey, seconds, authorized) => signer.sign({ actor: authorized.userId, org: authorized.orgId, listing: authorized.listingId, bucket, key: objectKey }, seconds);
      f.deps.assertSigningPolicyFresh = () => signer.assertFresh();
      const response = await createStudioHandler(f.deps)(request());
      const body = await response.text();
      assertEquals(response.status, 503);
      assertEquals(checks, 2);
      assertEquals(signs, 2);
      assertEquals(order, ["authorize", "visibility", "policy", "authorize", "visibility", "policy"]);
      assert(!body.includes("fixture.invalid") && !body.includes("photos"));
    }
  } finally {
    prior === undefined ? Deno.env.delete("PRIVATE_MEDIA_DELIVERY") : Deno.env.set("PRIVATE_MEDIA_DELIVERY", prior);
  }
});

Deno.test("revoked gallery links are filtered before signing", async () => {
  const f = fixture();
  f.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
  f.deps.mediaVisibility = async () => ({ assets: {}, renders: {}, keys: { [key]: false } });
  const response = await createStudioHandler(f.deps)(request());
  assertEquals(response.status, 200); assertEquals(f.signed, []);
  assertEquals((await response.json()).photos, []);
});

Deno.test("library never releases a URL when lineage is revoked during signing", async () => {
  const f = fixture(); let calls = 0;
  f.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
  f.deps.mediaVisibility = async () => ({ assets: {}, renders: {}, keys: { [key]: ++calls === 1 } });
  const response = await createStudioHandler(f.deps)(request());
  assertEquals(response.status, 404); assertEquals(f.signed.length, 1);
  assert(!(await response.text()).includes("objects.example"));
});
Deno.test("signing uses four concurrent calls, preserves row order, and completes before the final fence", async () => {
  const f = fixture();
  const photos = Array.from({ length: 10 }, (_, index) => ({
    ...photo,
    id: `photo-${index}`,
    original_key: `uploads/${org}/${listing}/${index}.jpg`,
  }));
  const assetId = "50000000-0000-4000-8000-000000000005";
  const renderId = "60000000-0000-4000-8000-000000000006";
  f.deps.read = async () => ({
    photos,
    assets: [{ id: assetId, listing_id: listing, storage_key: `uploads/${org}/${listing}/asset.mp4`, kind: "video", bucket: "uploads", uploaded: true, duration_s: 12, created_at: photo.created_at }],
    renders: [{ id: renderId, listing_id: listing, video_key: `renders/${org}/${listing}/render.mp4`, duration_s: 14, created_at: photo.created_at }],
  });
  let active = 0, peak = 0, finished = 0, visibilityCalls = 0;
  f.deps.sign = async (_bucket, objectKey) => {
    active++;
    peak = Math.max(peak, active);
    const index = Number(objectKey.split("/").at(-1)?.replace(".jpg", ""));
    await new Promise(resolve => setTimeout(resolve, Number.isNaN(index) ? 1 : 1 + (9 - index) % 4 * 3));
    active--;
    finished++;
    return `https://objects.example/${objectKey.split("/").at(-1)}`;
  };
  f.deps.mediaVisibility = async (_scope, refs) => {
    visibilityCalls++;
    if (visibilityCalls === 2) {
      assertEquals(active, 0);
      assertEquals(finished, 12);
      assertEquals(refs.assets, [assetId]);
      assertEquals(refs.renders, [renderId]);
      assertEquals(refs.keys?.length, 12);
    }
    return {
      assets: Object.fromEntries((refs.assets ?? []).map(id => [id, true])),
      renders: Object.fromEntries((refs.renders ?? []).map(id => [id, true])),
      keys: Object.fromEntries((refs.keys ?? []).map(key => [key, true])),
    };
  };
  const response = await createStudioHandler(f.deps)(request());
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(peak, 4);
  assertEquals(visibilityCalls, 2);
  assertEquals(body.photos.map((row: { id: string }) => row.id), photos.map(row => row.id));
  assertEquals(body.videos.map((row: { id: string }) => row.id), [assetId, renderId]);
  assertEquals(body.photos.map((row: { url: string }) => row.url), photos.map((_, index) => `https://objects.example/${index}.jpg`));
});
Deno.test("an unavailable selected photo does not sign its separate original", async () => {
  const f = fixture();
  const enhanced = `renders/${org}/${listing}/enhanced.jpg`;
  f.deps.read = async () => ({ photos: [{ ...photo, enhanced_key: enhanced }], assets: [], renders: [] });
  f.deps.sign = async (_bucket, objectKey) => {
    f.signed.push(objectKey);
    return "";
  };
  const response = await createStudioHandler(f.deps)(request());
  assertEquals(response.status, 200);
  assertEquals((await response.json()).photos, []);
  assertEquals(f.signed, [enhanced]);
});
Deno.test("one failed signature drains in-flight calls and rejects the entire page", async () => {
  const f = fixture();
  const photos = Array.from({ length: 6 }, (_, index) => ({
    ...photo,
    id: `photo-${index}`,
    original_key: `uploads/${org}/${listing}/${index}.jpg`,
  }));
  f.deps.read = () => Promise.resolve({ photos, assets: [], renders: [] });
  let active = 0, started = 0, visibilityCalls = 0;
  f.deps.mediaVisibility = (_scope, refs) => {
    visibilityCalls++;
    return Promise.resolve({
      assets: {},
      renders: {},
      keys: Object.fromEntries((refs.keys ?? []).map(key => [key, true])),
    });
  };
  f.deps.sign = async (_bucket, objectKey) => {
    active++;
    started++;
    if (objectKey.endsWith("/0.jpg")) {
      await Promise.resolve();
      active--;
      throw Error("private signing credential");
    }
    await new Promise(resolve => setTimeout(resolve, 5));
    active--;
    return "https://objects.example/read";
  };
  const response = await createStudioHandler(f.deps)(request());
  assertEquals(response.status, 503);
  assertEquals(active, 0);
  assertEquals(started, 4);
  assertEquals(visibilityCalls, 1);
  assert(!(await response.text()).includes("objects.example"));
});
Deno.test("POST cannot mutate anything", async () => {
  const f = fixture();
  assertEquals(
    (await createStudioHandler(f.deps)(request("", "POST"))).status,
    405,
  );
  assertEquals(f.reads(), 0);
});
Deno.test("unknown route is 404", async () => {
  const f = fixture();
  assertEquals(
    (
      await createStudioHandler(f.deps)(
        new Request("https://project.supabase.co/functions/v1/studio/anything"),
      )
    ).status,
    404,
  );
});
Deno.test("unauthenticated request cannot read or sign", async () => {
  const f = fixture();
  f.deps.authorize = async () => {
    throw new HttpError(401, "Sign in required.");
  };
  assertEquals((await createStudioHandler(f.deps)(request())).status, 401);
  assertEquals(f.reads(), 0);
  assertEquals(f.signed, []);
});
Deno.test("unjoined workspace cannot read or sign", async () => {
  const f = fixture();
  f.deps.authorize = async () => {
    throw new HttpError(403, "Not a member.");
  };
  assertEquals((await createStudioHandler(f.deps)(request())).status, 403);
  assertEquals(f.reads(), 0);
});
Deno.test("authorization result must match both selectors", async () => {
  for (const changed of [{ orgId: user }, { listingId: user }]) {
    const f = fixture();
    f.deps.authorize = async () => ({ ...scope, ...changed });
    assertEquals((await createStudioHandler(f.deps)(request())).status, 403);
    assertEquals(f.reads(), 0);
  }
});
Deno.test("conflicting selector fails before auth or read", async () => {
  const f = fixture();
  assertEquals(
    (
      await createStudioHandler(f.deps)(
        request("", "GET", { "x-org-id": user }),
      )
    ).status,
    400,
  );
  assertEquals(f.reads(), 0);
});
Deno.test("malformed offsets are rejected, not coerced", async () => {
  for (const raw of ["-1", "1", "NaN", "1e2", "50.5", "10050"]) {
    const f = fixture();
    assertEquals(
      (await createStudioHandler(f.deps)(request(`&offset=${raw}`))).status,
      400,
    );
    assertEquals(f.reads(), 0);
  }
});
Deno.test("rate cap prevents DB/media expansion", async () => {
  const f = fixture();
  f.deps.rateLimit = async () => false;
  assertEquals((await createStudioHandler(f.deps)(request())).status, 429);
  assertEquals(f.reads(), 0);
});
Deno.test("returns literal contract, short lifetime, no cache", async () => {
  const f = fixture();
  f.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
  const response = await createStudioHandler(f.deps)(request());
  assertEquals(response.status, 200);
  assertEquals(response.headers.get("cache-control"), "private, no-store");
  const body = await response.json();
  assertEquals(body.photos, [
    {
      id: photo.id,
      listing_id: listing,
      url: "https://objects.example/read",
      expires_at: "2026-09-12T12:10:00.000Z",
      caption: "Example room",
      is_staged: true,
      is_altered: true,
      original_url: "https://objects.example/read",
      edit_kind: null,
      original_verified: false,
      sort: 0,
    },
  ]);
  assertEquals(body.next_offset, null);
  assertEquals(f.signed, [`uploads:${key}:600`]);
  assert(!JSON.stringify(body).includes(key));
});
Deno.test("the three final checks overlap, are all drained, and fail in membership, access, policy order", async () => {
  const gate = () => { let open!: () => void; const wait = new Promise<void>(resolve => open = resolve); return { open, wait }; };
  const f = fixture(), authorizeGate = gate();
  f.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
  const started: string[] = [];
  let authorizations = 0, visibilities = 0;
  f.deps.authorize = async () => { if (++authorizations === 2) { started.push("authorize"); await authorizeGate.wait; } return scope; };
  const visibility = f.deps.mediaVisibility;
  f.deps.mediaVisibility = (authorized, refs) => { if (++visibilities === 2) started.push("visibility"); return visibility(authorized, refs); };
  f.deps.assertSigningPolicyFresh = async () => { started.push("policy"); };
  const pending = createStudioHandler(f.deps)(request());
  await new Promise(resolve => setTimeout(resolve, 5));
  // Membership is still being rechecked, yet the other two checks have begun.
  assertEquals(started, ["authorize", "visibility", "policy"]);
  authorizeGate.open();
  assertEquals((await pending).status, 200);

  // Every combination of failing checks: nothing is released, and the reported
  // failure is the first in the old sequential order.
  for (const failing of [["authorize", "visibility", "policy"], ["visibility", "policy"], ["authorize", "policy"], ["policy"], ["authorize"], ["visibility"]]) {
    const g = fixture(); let auth = 0, seen = 0, drained = 0;
    g.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
    g.deps.authorize = async () => { if (++auth === 2) { await new Promise(resolve => setTimeout(resolve, 3)); drained++; if (failing.includes("authorize")) throw new HttpError(403, "Access changed."); } return scope; };
    g.deps.mediaVisibility = async (_scope, refs) => { const final = ++seen === 2; if (final) drained++; return { assets: {}, renders: {}, keys: Object.fromEntries((refs.keys ?? []).map(key => [key, !(final && failing.includes("visibility"))])) }; };
    g.deps.assertSigningPolicyFresh = async () => { await new Promise(resolve => setTimeout(resolve, 1)); drained++; if (failing.includes("policy")) throw new HttpError(503, "Media gateway activation pending."); };
    const response = await createStudioHandler(g.deps)(request());
    assertEquals(response.status, failing.includes("authorize") ? 403 : failing.includes("visibility") ? 404 : 503);
    assertEquals(drained, 3, "no final check may be left running after the reply");
    assert(!(await response.text()).includes("objects.example"));
  }
});
Deno.test("a short first page signs only what was asked for and never pages", async () => {
  const f = fixture(), previews: unknown[] = [];
  const photos = Array.from({ length: 3 }, (_, index) => ({ ...photo, id: `photo-${index}`, original_key: `uploads/${org}/${listing}/${index}.jpg` }));
  f.deps.read = async (...args) => { previews.push(args.length === 2 ? "ordinary" : args[2]); return { photos: photos.slice(0, args[2] ? args[2].limit + 1 : 3), assets: [], renders: [] }; };
  const one = await createStudioHandler(f.deps)(request("&limit=1&cover=1"));
  assertEquals(one.status, 200);
  const body = await one.json();
  assertEquals(body.photos.map((row: { id: string }) => row.id), ["photo-0"]);
  assertEquals(body.next_offset, null); assertEquals(body.has_more, true);
  assertEquals(f.signed.length, 1);
  const two = await (await createStudioHandler(f.deps)(request("&limit=2"))).json();
  assertEquals(two.photos.length, 2); assertEquals(two.has_more, true); assertEquals(two.next_offset, null);
  // The ordinary page, and an explicit limit of 50, read exactly as before.
  for (const query of ["", "&limit=50"]) {
    const full = await (await createStudioHandler(f.deps)(request(query))).json();
    assertEquals(full.photos.length, 3); assertEquals(full.next_offset, null); assertEquals(full.has_more, undefined);
  }
  assertEquals(previews, [{ limit: 1, cover: true }, { limit: 2, cover: false }, "ordinary", "ordinary"]);
  // More rows than the preview asked for is a broken query, not a longer page.
  const broken = fixture();
  broken.deps.read = async () => ({ photos, assets: [], renders: [] });
  assertEquals((await createStudioHandler(broken.deps)(request("&limit=1"))).status, 500);
  assertEquals(broken.signed, []);
});
Deno.test("malformed preview sizes and a preview at a later offset are rejected before auth or read", async () => {
  for (const query of ["&limit=0", "&limit=51", "&limit=1.5", "&limit=abc", "&limit=", "&limit=01", "&cover=0", "&cover=true", "&limit=1&offset=50", "&cover=1&offset=50"]) {
    const f = fixture();
    f.deps.authorize = () => { throw Error("should not run"); };
    assertEquals((await createStudioHandler(f.deps)(request(query))).status, 400, query);
    assertEquals(f.reads(), 0);
  }
});
Deno.test(
  "unsigned references and pending captures never become URLs",
  async () => {
    const f = fixture();
    f.deps.read = async () => ({
      photos: [
        { ...photo, original_key: `uploads/${user}/${listing}/other.jpg` },
      ],
      assets: [
        {
          id: "a",
          listing_id: listing,
          storage_key: key,
          bucket: "uploads",
          uploaded: false,
          kind: "photo",
          duration_s: null,
          created_at: photo.created_at,
        },
      ],
      renders: [],
    });
    const body = await (await createStudioHandler(f.deps)(request())).json();
    assertEquals(body.photos, []);
    assertEquals(body.unavailable_count, 1);
    assertEquals(f.signed, []);
  },
);
Deno.test("row from another listing fails whole response", async () => {
  const f = fixture();
  f.deps.read = async () => ({
    photos: [{ ...photo, listing_id: user }],
    assets: [],
    renders: [],
  });
  const response = await createStudioHandler(f.deps)(request());
  assertEquals(response.status, 500);
  assertEquals(f.signed, []);
});
Deno.test("uploaded video requires bucket agreement", async () => {
  const f = fixture();
  f.deps.read = async () => ({
    photos: [],
    assets: [
      {
        id: user,
        listing_id: listing,
        storage_key: key,
        bucket: "renders",
        uploaded: true,
        kind: "video",
        duration_s: 30,
        created_at: photo.created_at,
      },
    ],
    renders: [],
  });
  const body = await (await createStudioHandler(f.deps)(request())).json();
  assertEquals(body.videos, []);
  assertEquals(f.signed, []);
});
Deno.test(
  "stored render and photo deduplicate identical object keys",
  async () => {
    const f = fixture();
    const visibilityKeys: string[][] = [];
    f.deps.mediaVisibility = (_scope, refs) => {
      visibilityKeys.push([...(refs.keys ?? [])]);
      return Promise.resolve({
        assets: Object.fromEntries((refs.assets ?? []).map(id => [id, true])),
        renders: Object.fromEntries((refs.renders ?? []).map(id => [id, true])),
        keys: Object.fromEntries((refs.keys ?? []).map(key => [key, true])),
      });
    };
    f.deps.read = async () => ({
      photos: [photo],
      assets: [
        {
          id: user,
          listing_id: listing,
          storage_key: key,
          bucket: "uploads",
          uploaded: true,
          kind: "photo",
          duration_s: null,
          created_at: photo.created_at,
        },
      ],
      renders: [
        {
          id: listing,
          listing_id: listing,
          video_key: `renders/${org}/${listing}/export.mp4`,
          duration_s: 12,
          created_at: photo.created_at,
        },
      ],
    });
    const body = await (await createStudioHandler(f.deps)(request())).json();
    assertEquals(body.photos.length, 1);
    assertEquals(body.videos.length, 1);
    assertEquals(f.signed.length, 2);
    assertEquals(visibilityKeys.length, 2);
    assertEquals(visibilityKeys[1], [key, `renders/${org}/${listing}/export.mp4`]);
  },
);
Deno.test(
  "pagination signs at most50 of each kind, reports next offset",
  async () => {
    const f = fixture();
    f.deps.read = async (_scope, offset) => {
      assertEquals(offset, 50);
      return {
        photos: Array.from({ length: 51 }, (_, i) => ({
          ...photo,
          id: `p${i}`,
          original_key: `uploads/${org}/${listing}/${i}.jpg`,
        })),
        assets: [],
        renders: [],
      };
    };
    const body = await (
      await createStudioHandler(f.deps)(request("&offset=50"))
    ).json();
    assertEquals(body.photos.length, PAGE_SIZE);
    assertEquals(body.next_offset, 100);
    assertEquals(f.signed.length, 50);
  },
);
Deno.test(
  "partial database errors cannot look like empty success",
  async () => {
    const f = fixture();
    f.deps.read = async () => {
      throw Error("sensitive database internals");
    };
    const response = await createStudioHandler(f.deps)(request());
    assertEquals(response.status, 503);
    assert(!(await response.text()).includes("sensitive"));
  },
);
Deno.test(
  "signing failure returns generic error, never capabilities or credentials",
  async () => {
    const f = fixture();
    f.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
    f.deps.sign = async () => {
      throw Error("secret signed url");
    };
    const response = await createStudioHandler(f.deps)(request());
    assertEquals(response.status, 503);
    assert(!(await response.text()).includes("secret"));
  },
);

Deno.test("rechecks live membership and deletion after reading and signing", async () => {
  for (const status of [403, 409]) {
    const f = fixture();
    let checks = 0;
    f.deps.authorize = async () => {
      if (++checks === 2) throw new HttpError(status, "Access changed.");
      return scope;
    };
    f.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
    const response = await createStudioHandler(f.deps)(request());
    assertEquals(checks, 2);
    assertEquals(response.status, status);
    assertEquals(response.headers.get("cache-control"), "private, no-store");
    assert(!(await response.text()).includes("https://objects.example/read"));
  }
});
Deno.test("deletion already in progress stops before rate limit, read or signing", async () => {
  const f = fixture();
  f.deps.authorize = async () => {
    throw new HttpError(409, "Account deletion pending.");
  };
  f.deps.rateLimit = () => {
    throw Error("must not run");
  };
  assertEquals((await createStudioHandler(f.deps)(request())).status, 409);
  assertEquals(f.reads(), 0);
  assertEquals(f.signed.length, 0);
});
Deno.test("valid row followed by foreign lookahead fails before any signing", async () => {
  const f = fixture();
  f.deps.read = async () => ({
    photos: [photo, { ...photo, listing_id: user }],
    assets: [],
    renders: [],
  });
  assertEquals((await createStudioHandler(f.deps)(request())).status, 500);
  assertEquals(f.signed.length, 0);
});
Deno.test("oversized query result and paging-limit lookahead are explicit failures", async () => {
  for (const [count, offset, status] of [[52, 0, 500], [51, 10000, 422]]) {
    const f = fixture();
    f.deps.read = async () => ({
      photos: Array(count).fill(photo),
      assets: [],
      renders: [],
    });
    assertEquals(
      (await createStudioHandler(f.deps)(request(`&offset=${offset}`))).status,
      status,
    );
    assertEquals(f.signed.length, 0);
  }
});
Deno.test("two pages consume each source's lookahead exactly once", async () => {
  const f = fixture();
  const photos = Array.from(
    { length: 52 },
    (_, i) => ({ ...photo, id: `photo${i}`, original_key: `${key}-${i}` }),
  );
  f.deps.read = async (_scope, offset) => ({
    photos: photos.slice(offset, offset + PAGE_SIZE + 1),
    assets: [],
    renders: [],
  });
  const first = await (await createStudioHandler(f.deps)(request())).json();
  const second = await (await createStudioHandler(f.deps)(
    request(`&offset=${first.next_offset}`),
  )).json();
  assertEquals(first.photos.length, 50);
  assertEquals(second.photos.length, 2);
  assertEquals(second.next_offset, null);
  assertEquals(
    new Set([...first.photos, ...second.photos].map((p) => p.id)).size,
    52,
  );
});
Deno.test("does not return capabilities whose declared lifetime elapsed during signing", async () => {
  const f = fixture();
  f.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
  const now = f.deps.now();
  f.deps.sign = async () => {
    f.deps.now = () => now + 600_000;
    return "https://objects.example/read";
  };
  assertEquals((await createStudioHandler(f.deps)(request())).status, 503);
});

Deno.test("oversized writable captions fail before signing any media capability", async () => {
  const f = fixture();
  f.deps.read = async () => ({ photos: [{ ...photo, caption: "x".repeat(4097) }], assets: [], renders: [] });
  const response = await createStudioHandler(f.deps)(request());
  assertEquals(response.status, 422);
  assertEquals(f.signed, []);
  assert(!JSON.stringify(await response.json()).includes("x".repeat(100)));
});
