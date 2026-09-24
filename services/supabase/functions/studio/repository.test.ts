import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { SupabaseClient, User } from "npm:@supabase/supabase-js@2";
import {
  createStudioRepository,
  type StudioRepositoryDependencies,
} from "./repository.ts";
import { HttpError } from "../_shared/http.ts";
import { createStudioHandler, PAGE_SIZE, type PhotoRow } from "./handler.ts";

const user = "10000000-0000-4000-8000-000000000001";
const org = "20000000-0000-4000-8000-000000000002";
const listing = "30000000-0000-4000-8000-000000000003";
const req = new Request("https://fixture.invalid/studio/media");
type Result = { data: unknown; error: { message: string } | null };

function fixture() {
  const events: string[] = [];
  const queries: { table: string; operations: [string, ...unknown[]][] }[] = [];
  const results: Record<string, Result> = {
    orgs: { data: { id: org }, error: null },
    listings: { data: { id: listing, org_id: org }, error: null },
    photos: { data: [], error: null },
    capture_assets: { data: [], error: null },
    renders: { data: [], error: null },
  };
  const client = {
    rpc(_name: string, args: Record<string, string[]>) { return Promise.resolve({ data: { assets: Object.fromEntries(args.p_assets.map(id => [id, true])), renders: Object.fromEntries(args.p_renders.map(id => [id, true])), keys: Object.fromEntries(args.p_keys.map(key => [key, true])) }, error: null }); },
    from(table: string) {
      events.push(table);
      const operations: [string, ...unknown[]][] = [];
      queries.push({ table, operations });
      const query = {
        select(...args: unknown[]) {
          operations.push(["select", ...args]);
          return query;
        },
        eq(...args: unknown[]) {
          operations.push(["eq", ...args]);
          return query;
        },
        is(...args: unknown[]) {
          operations.push(["is", ...args]);
          return query;
        },
        in(...args: unknown[]) { operations.push(["in", ...args]); return query; },
        limit(...args: unknown[]) { operations.push(["limit", ...args]); return query; },
        order(...args: unknown[]) {
          operations.push(["order", ...args]);
          return query;
        },
        range(...args: unknown[]) {
          operations.push(["range", ...args]);
          return query;
        },
        abortSignal(signal: AbortSignal) {
          operations.push(["abortSignal", signal]);
          return query;
        },
        maybeSingle() {
          operations.push(["maybeSingle"]);
          return Promise.resolve(results[table]);
        },
        then<T = Result, U = never>(
          yes?: ((value: Result) => T | PromiseLike<T>) | null,
          no?: ((reason: unknown) => U | PromiseLike<U>) | null,
        ) {
          const result = results[table];
          if (!Array.isArray(result.data)) return Promise.resolve(result).then(yes, no);
          // Model PostgREST ordering/range semantics, so end-to-end adapter tests
          // fail if a persisted gallery order is never included in the query.
          const order = operations.filter(op => op[0] === "order");
          let data = [...result.data].filter(row => operations.every(op => op[0] !== "in" || (op[2] as unknown[]).includes(row[String(op[1])]))).sort((a, b) => {
            for (const [, column, options] of order) {
              const field = String(column), direction = (options as { ascending?: boolean }).ascending === false ? -1 : 1;
              if (a[field] !== b[field]) return (a[field] < b[field] ? -1 : 1) * direction;
            }
            return 0;
          });
          const limit = operations.find(op => op[0] === "limit");
          if (limit) data = data.slice(0, Number(limit[1]));
          const range = operations.find(op => op[0] === "range");
          return Promise.resolve({ ...result, data: range ? data.slice(Number(range[1]), Number(range[2]) + 1) : data }).then(yes, no);
        },
      };
      return query;
    },
  } as unknown as SupabaseClient;
  let clientCalls = 0;
  const deps: StudioRepositoryDependencies = {
    userClient(request) {
      assertEquals(request, req);
      clientCalls++;
      return client;
    },
    async getUser(request) {
      assertEquals(request, req);
      events.push("auth");
      return { id: user } as User;
    },
    async assertNotDeleting(subject) {
      assertEquals(subject, user);
      events.push("deletion");
    },
    async orgForUser(subject, requested) {
      assertEquals([subject, requested], [user, org]);
      events.push("membership");
      return org;
    },
  };
  return { deps, events, queries, results, clientCalls: () => clientCalls };
}

Deno.test("real adapter checks Auth, deletion, membership, live org then scoped live listing", async () => {
  const f = fixture();
  const repository = createStudioRepository(req, f.deps);
  assertEquals(await repository.authorize(req, org, listing), {
    userId: user,
    orgId: org,
    listingId: listing,
  });
  assertEquals(f.events, [
    "auth",
    "deletion",
    "membership",
    "orgs",
    "listings",
  ]);
  assertEquals(f.clientCalls(), 1);
  assertEquals(f.queries[0].operations, [
    ["select", "id"],
    ["eq", "id", org],
    ["is", "deleted_at", null],
    ["abortSignal", req.signal],
    ["maybeSingle"],
  ]);
  assertEquals(f.queries[1].operations, [
    ["select", "id,org_id"],
    ["eq", "id", listing],
    ["eq", "org_id", org],
    ["is", "deleted_at", null],
    ["abortSignal", req.signal],
    ["maybeSingle"],
  ]);
  await repository.authorize(req, org, listing);
  assertEquals(
    f.events.filter((event) => event === "membership").length,
    2,
    "membership must never be cached across rechecks",
  );
});

Deno.test("deletion and removed membership failures prevent tenant reads", async () => {
  for (const denied of ["assertNotDeleting", "orgForUser"] as const) {
    const f = fixture();
    f.deps[denied] = async () => {
      throw new HttpError(denied === "orgForUser" ? 403 : 409, "Denied.");
    };
    await assertRejects(
      () => createStudioRepository(req, f.deps).authorize(req, org, listing),
      HttpError,
    );
    assertEquals(f.clientCalls(), 0);
    assertEquals(f.queries, []);
  }
});

Deno.test("deleted org or listing and inconsistent rows never authorize", async () => {
  for (
    const [table, result] of [
      ["orgs", { data: null, error: null }],
      ["listings", { data: null, error: null }],
      ["listings", { data: { id: listing, org_id: user }, error: null }],
      ["orgs", { data: { id: user }, error: null }],
      ["orgs", { data: null, error: { message: "internal" } }],
    ] as [string, Result][]
  ) {
    const f = fixture();
    f.results[table] = result;
    await assertRejects(
      () => createStudioRepository(req, f.deps).authorize(req, org, listing),
      HttpError,
    );
    if (table === "orgs" && !result.data) {
      assert(!f.events.includes("listings"));
    }
  }
});

Deno.test("all three real RLS media queries use same listing, inclusive lookahead and deterministic order", async () => {
  const f = fixture();
  const repository = createStudioRepository(req, f.deps);
  await repository.read({ userId: user, orgId: org, listingId: listing }, 50);
  assertEquals(f.clientCalls(), 1);
  assertEquals(f.queries.map((query) => query.table), [
    "photos",
    "capture_assets",
    "renders",
  ]);
  for (const query of f.queries) {
    assert(
      query.operations.some((op) =>
        op[0] === "eq" && op[1] === "listing_id" && op[2] === listing
      ),
    );
    assert(
      query.operations.some((op) =>
        op[0] === "abortSignal" && op[1] === req.signal
      ),
    );
    assertEquals(query.operations.filter((op) => op[0] === "order"), query.table === "photos"
      ? [["order", "sort", { ascending: true }], ["order", "id", { ascending: true }]]
      : [["order", "id", { ascending: true }]]);
    assertEquals(query.operations.find((op) => op[0] === "range"), [
      "range",
      50,
      100,
    ]);
  }
  assert(
    f.queries[1].operations.some((op) =>
      op[0] === "eq" && op[1] === "uploaded" && op[2] === true
    ),
  );
});

Deno.test("real repository and media merge preserve saved gallery order over capture aliases and retain distinct originals", async () => {
  const f = fixture(), repository = createStudioRepository(req, f.deps);
  const id = (n: number) => `40000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
  const key = (name: string, bucket = "renders") => `${bucket}/${org}/${listing}/${name}.jpg`;
  const gallery: PhotoRow[] = [1, 2, 3].map(n => ({ id: id(n), listing_id: listing, original_key: key(`photo-${n}`), enhanced_key: null, caption: `Photo ${n}`, is_staged: false, sort: n - 1, created_at: "2026-09-14T00:00:00Z" }));
  gallery[1] = { ...gallery[1], original_key: key("untouched", "uploads"), enhanced_key: key("photo-2"), is_staged: true };
  f.results.photos.data = gallery;
  f.results.capture_assets.data = [
    ...[1, 2, 3].map(n => ({ id: id(n + 10), listing_id: listing, storage_key: key(`photo-${n}`), kind: "photo", bucket: "renders", uploaded: true, duration_s: null, created_at: "2026-09-14T00:00:00Z" })),
    { id: id(20), listing_id: listing, storage_key: key("untouched", "uploads"), kind: "photo", bucket: "uploads", uploaded: true, duration_s: null, created_at: "2026-09-14T00:00:00Z" },
  ];
  const handler = createStudioHandler({ ...repository, authorize: async () => ({ userId: user, orgId: org, listingId: listing }), rateLimit: async () => true, sign: async (_bucket, key) => `https://fixture.invalid/read/${encodeURIComponent(key)}`, now: () => 0 });
  const request = () => new Request(`https://fixture.invalid/functions/v1/studio/media?org_id=${org}&listing_id=${listing}`);
  const before = await (await handler(request())).json();
  assertEquals(before.photos.map((photo: { id: string }) => photo.id), [id(1), id(2), id(3), id(20)]);
  // This is the same persisted sort update the atomic gallery RPC performs.
  f.results.photos.data = gallery.map(row => ({ ...row, sort: 2 - row.sort }));
  const response = await handler(request()); assertEquals(response.status, 200);
  const after = await response.json();
  assertEquals(after.photos.map((photo: { id: string }) => photo.id), [id(3), id(2), id(1), id(20)]);
  assertEquals(after.photos.map((photo: { sort: number }) => photo.sort), [0, 1, 2, 0]);
  assertEquals(after.photos[1].caption, "Photo 2");
  assertEquals(after.photos[1].is_staged, true);
  assertEquals(after.photos[1].original_url, after.photos[3].url);
  assertEquals(after.photos[3].is_altered, false);
  assertEquals(after.next_offset, null);
});

Deno.test("saved gallery sort determines page boundaries without cross-page capture aliases", async () => {
  const f = fixture(), repository = createStudioRepository(req, f.deps);
  const id = (n: number) => `50000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
  const count = PAGE_SIZE + 3;
  f.results.photos.data = Array.from({ length: count }, (_, n) => ({ id: id(n), listing_id: listing, original_key: `renders/${org}/${listing}/${n}.jpg`, enhanced_key: null, caption: null, is_staged: false, sort: n < 3 ? 1 : 0, created_at: "2026-09-14T00:00:00Z" })).reverse();
  f.results.capture_assets.data = Array.from({ length: count }, (_, n) => ({ id: id(n + 100), listing_id: listing, storage_key: `renders/${org}/${listing}/${n}.jpg`, kind: "photo", bucket: "renders", uploaded: true, duration_s: null, created_at: "2026-09-14T00:00:00Z" }));
  const handler = createStudioHandler({ ...repository, authorize: async () => ({ userId: user, orgId: org, listingId: listing }), rateLimit: async () => true, sign: async () => "https://fixture.invalid/read", now: () => 0 });
  const request = (offset: number) => new Request(`https://fixture.invalid/functions/v1/studio/media?org_id=${org}&listing_id=${listing}&offset=${offset}`);
  const first = await (await handler(request(0))).json();
  const second = await (await handler(request(first.next_offset))).json();
  assertEquals(first.photos.map((photo: { id: string }) => photo.id), Array.from({ length: PAGE_SIZE }, (_, n) => id(n + 3)));
  assertEquals(second.photos.map((photo: { id: string }) => photo.id), [id(0), id(1), id(2)]);
  assertEquals(first.next_offset, PAGE_SIZE); assertEquals(second.next_offset, null);
});

Deno.test("a null or failed source is not converted to an empty successful library", async () => {
  for (const table of ["photos", "capture_assets", "renders"]) {
    for (const error of [null, { message: "internal" }]) {
      const f = fixture();
      f.results[table] = { data: null, error };
      await assertRejects(
        () =>
          createStudioRepository(req, f.deps).read({
            userId: user,
            orgId: org,
            listingId: listing,
          }, 0),
        HttpError,
      );
    }
  }
});
