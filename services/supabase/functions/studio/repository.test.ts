import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { SupabaseClient, User } from "npm:@supabase/supabase-js@2.116.0";
import {
  createStudioRepository,
  type StudioRepositoryDependencies,
} from "./repository.ts";
import { HttpError } from "../_shared/http.ts";
import { admitMediaRead } from "../_shared/media-delivery-admission.ts";
import { createStudioHandler, PAGE_SIZE, type PhotoRow } from "./handler.ts";

const user = "10000000-0000-4000-8000-000000000001";
const org = "20000000-0000-4000-8000-000000000002";
const listing = "30000000-0000-4000-8000-000000000003";
const req = new Request("https://fixture.invalid/studio/media");
type Result = { data: unknown; error: { message: string } | null };

// Closed PostgREST filter/range semantics, applied to the actual adapter's
// emitted query before slicing. This catches missing pre-pagination exclusions.
function splitLogic(text:string):string[] {
 let depth=0,start=0;const parts:string[]=[];
 for(let i=0;i<text.length;i++){if(text[i]==="(")depth++;else if(text[i]===")")depth--;else if(text[i]===","&&depth===0){parts.push(text.slice(start,i));start=i+1;}}
 return [...parts,text.slice(start)];
}
function logic(row:Record<string,unknown>,term:string):boolean {
 if(term.startsWith("and(")||term.startsWith("or(")){const parts=splitLogic(term.slice(term.indexOf("(")+1,-1)).map(t=>logic(row,t));return term.startsWith("and(")?parts.every(Boolean):parts.some(Boolean);}
 const [column,...rest]=term.split(".");let expression=rest.join("."),negated=false;if(expression.startsWith("not.")){negated=true;expression=expression.slice(4);}
 const separator=expression.indexOf("."),op=expression.slice(0,separator),value=expression.slice(separator+1),actual=row[column];
 let match:boolean;if(op==="is")match=value==="null"&&actual==null;else if(op==="like")match=actual!=null&&new RegExp("^"+value.replace(/[.*+?^${}()|[\]\\]/g,"\\$&").replaceAll("%",".*").replaceAll("_",".")+"$").test(String(actual));else if(op==="eq")match=actual===value;else if(op==="neq")match=actual!=null&&actual!==value;else throw Error("Unsupported closed filter "+op);
 return negated?(actual!=null&&!match):match;
}

function fixture(fixtureRequest = req) {
  const events: string[] = [];
  const rpcNames: string[] = [];
  let publicationRows: unknown;
  const queries: { table: string; operations: [string, ...unknown[]][] }[] = [];
  const results: Record<string, Result> = {
    orgs: { data: { id: org }, error: null },
    listings: { data: { id: listing, org_id: org }, error: null },
    photos: { data: [], error: null },
    capture_assets: { data: [], error: null },
    renders: { data: [], error: null },
    media_provenance: { data: [], error: null },
  };
  const client = {
    rpc(name: string, args: Record<string, string[]>) {
      rpcNames.push(name);
      if (name !== "studio_presenter_media_visibility") return Promise.resolve({ data: null, error: { message: "permission denied for authenticated" } });
      return Promise.resolve({ data: { assets: Object.fromEntries(args.p_assets.map(id => [id, true])), renders: Object.fromEntries(args.p_renders.map(id => [id, true])), keys: Object.fromEntries(args.p_keys.map(key => [key, true])), ...(publicationRows === undefined ? {} : { photo_publications: publicationRows }) }, error: null });
    },
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
        not(...args: unknown[]) { operations.push(["not", ...args]); return query; },
        or(...args: unknown[]) { operations.push(["or", ...args]); return query; },
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
          // Exact-match filters the cover preview adds; the ordinary page never emits them.
          const exact = ["kind", "storage_key", "enhanced_key", "original_key"];
          let data = [...result.data].filter(row => operations.every(op => (op[0] !== "in" || (op[2] as unknown[]).includes(row[String(op[1])])) &&
            (op[0] !== "eq" || !exact.includes(String(op[1])) || row[String(op[1])] === op[2]) &&
            (op[0] !== "not" || logic(row,`${op[1]}.not.${op[2]}.${op[3]}`)) &&
            (op[0] !== "or" || splitLogic(String(op[1])).some(term=>logic(row,term))))).sort((a, b) => {
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
    adminClient: () => client,
    userClient(request) {
      assertEquals(request, fixtureRequest);
      clientCalls++;
      return client;
    },
    async getUser(request) {
      assertEquals(request, fixtureRequest);
      events.push("auth");
      return { id: user } as User;
    },
    async assertNotDeleting(subject) {
      assertEquals(subject, user);
      events.push("deletion");
    },
    async activeOrg(id) {
      return await client.from("orgs").select("id").eq("id",id).is("deleted_at",null).abortSignal(fixtureRequest.signal).maybeSingle() as {data:{id:string}|null;error:unknown};
    },
    async listingScope(subject, requested) {
      assertEquals([subject, requested], [user, listing]);
      events.push("listing-scope");
      return {actor_id:user,org_id:org,library_org_id:org,can_read:true};
    },
  };
  return { deps, events, queries, results, rpcNames, publicationRows: (rows: unknown) => { publicationRows = rows; }, clientCalls: () => clientCalls };
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
    "listing-scope",
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
    f.events.filter((event) => event === "listing-scope").length,
    2,
    "listing authority must never be cached across rechecks",
  );
});

Deno.test("independent authorization reads overlap only inside their existing trust boundaries", async () => {
  const f = fixture();
  let finishDeletion!: () => void;
  let finishScope!: (scope: Awaited<ReturnType<StudioRepositoryDependencies["listingScope"]>>) => void;
  let finishOrg!: (result: Awaited<ReturnType<StudioRepositoryDependencies["activeOrg"]>>) => void;
  const deletion = new Promise<void>(resolve => finishDeletion = resolve);
  const membership = new Promise<Awaited<ReturnType<StudioRepositoryDependencies["listingScope"]>>>(resolve => finishScope = resolve);
  const workspace = new Promise<Awaited<ReturnType<StudioRepositoryDependencies["activeOrg"]>>>(resolve => finishOrg = resolve);
  f.deps.assertNotDeleting = async subject => { assertEquals(subject, user); f.events.push("deletion"); await deletion; };
  f.deps.listingScope = async (subject, requested) => {
    assertEquals([subject, requested], [user, listing]);
    f.events.push("listing-scope");
    return await membership;
  };
  f.deps.activeOrg = async id => { assertEquals(id, org); f.events.push("orgs"); return await workspace; };
  let completed = false;
  const pending = createStudioRepository(req, f.deps).authorize(req, org, listing)
    .then(value => { completed = true; return value; });
  await new Promise(resolve => setTimeout(resolve, 0));
  assertEquals(f.events, ["auth", "deletion", "listing-scope"]);
  assertEquals(f.clientCalls(), 0);
  finishDeletion();
  await new Promise(resolve => setTimeout(resolve, 0));
  assertEquals(f.events, ["auth", "deletion", "listing-scope"]);
  finishScope({ actor_id: user, org_id: org, library_org_id: org, can_read: true });
  await new Promise(resolve => setTimeout(resolve, 0));
  assertEquals(f.events, ["auth", "deletion", "listing-scope", "orgs", "listings"]);
  assertEquals(completed, false, "the RLS listing result cannot bypass the live workspace check");
  finishOrg({ data: { id: org }, error: null });
  assertEquals(await pending, { userId: user, orgId: org, listingId: listing });
});

Deno.test("published Studio photo uses authenticated visibility and service-only delivery admission", async () => {
  const mediaRequest = new Request(`https://fixture.invalid/functions/v1/studio/media?org_id=${org}&listing_id=${listing}`);
  const f = fixture(mediaRequest);
  const source = "40000000-0000-4000-8000-000000000004";
  const output = "50000000-0000-4000-8000-000000000005";
  const publication = "60000000-0000-4000-8000-000000000006";
  const original = `renders/${org}/${listing}/original-${source}.jpg`;
  const altered = `renders/${org}/${listing}/gallery-${output}.jpg`;
  const evidence = `ai-router/${org}/photo-evidence/${source}/${output}/`;
  const objects = [original, altered, `${evidence}input.jpg`, `${evidence}candidate.jpg`]
    .map(key => ({ key, bucket: "renders", bytes: 100, mime: "image/jpeg", etag: '"exact"' }));
  f.publicationRows([{ publication_id: publication, org_id: org, listing_id: listing,
    assets: [source, output], keys: [original, altered], objects }]);
  f.results.photos.data = [{ id: output, listing_id: listing, original_key: original,
    enhanced_key: altered, caption: "Published", is_staged: true, sort: 0,
    created_at: "2026-10-20T00:00:00Z" }];
  const serviceRPCs: string[] = [];
  f.deps.adminClient = () => ({ rpc: async (name: string, args: Record<string, unknown>) => {
    serviceRPCs.push(name);
    assertEquals(name, "media_delivery_admit");
    assertEquals(args, { p_org: org, p_bytes: 0, p_required: false });
    return { data: { admitted: true, legacy_unbudgeted: false }, error: null };
  } }) as unknown as SupabaseClient;
  f.deps.publicationHeadIO = {
    head: async object => ({ exists: true, bytes: object.bytes, contentType: object.mime, etag: object.etag }),
    admit: (db, billingOrg) => admitMediaRead(db, billingOrg, 0, false),
  };
  const signed: string[] = [];
  const handler = createStudioHandler({ ...createStudioRepository(mediaRequest, f.deps),
    rateLimit: async () => true,
    sign: async (_bucket, key) => { signed.push(key); return `https://fixture.invalid/${encodeURIComponent(key)}`; },
    assertSigningPolicyFresh: async () => {},
    now: () => 0,
  });
  const response = await handler(mediaRequest);
  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(body.photos.map((photo: { id: string }) => photo.id), [output]);
  assertEquals(body.photos[0].original_verified, false);
  assertEquals(signed, [altered, original]);
  assertEquals(serviceRPCs.length, 8); // Four exact objects at each visibility fence.
  assertEquals(f.rpcNames, Array(4).fill("studio_presenter_media_visibility"));
  assertEquals(f.events.filter(event => event === "listing-scope").length, 2);
});

Deno.test("deletion and removed membership failures prevent reads, signing, and data responses", async () => {
  for (const denied of ["assertNotDeleting", "listingScope"] as const) {
    const mediaRequest = new Request(`https://fixture.invalid/functions/v1/studio/media?org_id=${org}&listing_id=${listing}`);
    const f = fixture(mediaRequest);
    f.deps[denied] = async () => {
      throw new HttpError(denied === "listingScope" ? 403 : 409, "Denied.");
    };
    let reads = 0, signs = 0;
    const handler = createStudioHandler({ ...createStudioRepository(mediaRequest, f.deps),
      rateLimit: async () => true,
      read: async () => { reads++; return { photos: [], assets: [], renders: [] }; },
      sign: async () => { signs++; return "https://fixture.invalid/signed"; },
      assertSigningPolicyFresh: async () => {},
      now: () => 0,
    });
    const response = await handler(mediaRequest);
    assertEquals(response.status, denied === "listingScope" ? 403 : 409);
    assert(!(await response.text()).includes("photos"));
    assertEquals(reads, 0);
    assertEquals(signs, 0);
    assertEquals(f.clientCalls(), 0);
    assertEquals(f.queries, []);
  }
});

Deno.test("deleted org or listing and inconsistent rows never release data or signed URLs", async () => {
  for (
    const [table, result, status] of [
      ["orgs", { data: null, error: null }, 404],
      ["listings", { data: null, error: null }, 404],
      ["listings", { data: { id: listing, org_id: user }, error: null }, 503],
      ["orgs", { data: { id: user }, error: null }, 503],
      ["orgs", { data: null, error: { message: "internal" } }, 503],
    ] as [string, Result, number][]
  ) {
    const mediaRequest = new Request(`https://fixture.invalid/functions/v1/studio/media?org_id=${org}&listing_id=${listing}`);
    const f = fixture(mediaRequest);
    f.results[table] = result;
    let reads = 0, signs = 0;
    const handler = createStudioHandler({ ...createStudioRepository(mediaRequest, f.deps),
      rateLimit: async () => true,
      read: async () => { reads++; return { photos: [], assets: [], renders: [] }; },
      sign: async () => { signs++; return "https://fixture.invalid/signed"; },
      assertSigningPolicyFresh: async () => {},
      now: () => 0,
    });
    const response = await handler(mediaRequest);
    assertEquals(response.status, status);
    assert(!(await response.text()).includes("photos"));
    assertEquals(reads, 0);
    assertEquals(signs, 0);
    assertEquals(f.events, ["auth", "deletion", "listing-scope", "orgs", "listings"]);
  }
});

Deno.test("authorization keeps deletion and workspace error precedence when concurrent reads disagree", async () => {
  const first = fixture();
  first.deps.assertNotDeleting = async () => { throw new HttpError(409, "Deletion pending."); };
  first.deps.listingScope = async () => { throw new HttpError(403, "Membership removed."); };
  const denied = await assertRejects(() => createStudioRepository(req, first.deps).authorize(req, org, listing), HttpError);
  assertEquals((denied as HttpError).status, 409);
  assertEquals(first.queries, []);

  const second = fixture();
  second.results.orgs = { data: null, error: null };
  second.results.listings = { data: null, error: { message: "RLS unavailable" } };
  const missing = await assertRejects(() => createStudioRepository(req, second.deps).authorize(req, org, listing), HttpError);
  assertEquals((missing as HttpError).status, 404);
  assertEquals(second.events, ["auth", "deletion", "listing-scope", "orgs", "listings"]);
});

Deno.test("every final authorization guard discards a signed page when access changes", async () => {
  for (const withdrawn of ["deletion", "membership", "workspace", "listing"] as const) {
    const mediaRequest = new Request(`https://fixture.invalid/functions/v1/studio/media?org_id=${org}&listing_id=${listing}`);
    const f = fixture(mediaRequest);
    const photoKey = `uploads/${org}/${listing}/room.jpg`;
    f.results.photos.data = [{ id: "40000000-0000-4000-8000-000000000004", listing_id: listing,
      original_key: photoKey, enhanced_key: null, caption: null, is_staged: false, sort: 0,
      created_at: "2026-10-20T00:00:00Z" }];
    const originalDeletion = f.deps.assertNotDeleting;
    const originalScope = f.deps.listingScope;
    const originalOrg = f.deps.activeOrg;
    let signs = 0;
    f.deps.assertNotDeleting = async id => {
      await originalDeletion(id);
      if (withdrawn === "deletion" && signs) throw new HttpError(409, "Deletion pending.");
    };
    f.deps.listingScope = async (id, requested) => {
      const scope = await originalScope(id, requested);
      return withdrawn === "membership" && signs ? { ...scope, can_read: false } : scope;
    };
    f.deps.activeOrg = async id => {
      if (withdrawn === "workspace" && signs) return { data: null, error: null };
      return await originalOrg(id);
    };
    const handler = createStudioHandler({ ...createStudioRepository(mediaRequest, f.deps),
      rateLimit: async () => true,
      sign: async () => {
        signs++;
        if (withdrawn === "listing") f.results.listings = { data: null, error: null };
        return "https://fixture.invalid/signed-private-media";
      },
      assertSigningPolicyFresh: async () => {},
      now: () => 0,
    });
    const response = await handler(mediaRequest);
    assertEquals(response.status, withdrawn === "deletion" ? 409 : withdrawn === "membership" ? 403 : 404);
    assertEquals(signs, 1);
    const body = await response.text();
    assert(!body.includes("signed-private-media") && !body.includes("photos"));
    assertEquals(f.events.filter(event => event === "auth").length, 2);
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
      ? [["order", "sort", { ascending: true }], ["order", "created_at", { ascending: true }], ["order", "id", { ascending: true }]]
      : query.table === "capture_assets" ? [["order", "created_at", { ascending: true }], ["order", "id", { ascending: true }]]
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
  const handler = createStudioHandler({ ...repository, authorize: async () => ({ userId: user, orgId: org, listingId: listing }), rateLimit: async () => true, sign: async (_bucket, key) => `https://fixture.invalid/read/${encodeURIComponent(key)}`, assertSigningPolicyFresh: async () => {}, now: () => 0 });
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

Deno.test("a cover preview reads photos only and puts the listing's chosen cover first", async () => {
  const f = fixture(), repository = createStudioRepository(req, f.deps);
  const id = (n: number) => `45000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
  const key = (name: string, bucket = "uploads") => `${bucket}/${org}/${listing}/${name}.jpg`;
  const scope = { userId: user, orgId: org, listingId: listing };
  const asset = (n: number, name: string, kind = "photo") => ({ id: id(n), listing_id: listing, storage_key: kind === "photo" ? key(name) : `uploads/${org}/${listing}/${name}.mp4`, kind, bucket: "uploads", uploaded: true, duration_s: kind === "photo" ? null : 9, created_at: `2026-09-14T00:00:0${n % 10}Z` });
  // The walkthrough video was uploaded first; the chosen cover is the fourth photo.
  f.results.capture_assets.data = [asset(10, "walkthrough", "video"), asset(11, "one"), asset(12, "two"), asset(13, "three"), asset(14, "four")];
  f.results.renders.data = [{ id: id(30), listing_id: listing, video_key: `renders/${org}/${listing}/tour.mp4`, duration_s: 20, created_at: "2026-09-14T00:00:00Z" }];
  f.results.listings.data = { id: listing, org_id: org, main_photo_key: key("four") };
  const rows = await repository.read(scope, 0, { limit: 1, cover: true });
  assertEquals(rows.renders, []);
  assertEquals(rows.assets.map(row => row.id), [id(14), id(11)]);
  assert(!f.queries.some(query => query.table === "renders"), "a cover preview never reads videos");
  const page = f.queries.find(query => query.table === "capture_assets")!;
  assert(page.operations.some(op => op[0] === "eq" && op[1] === "kind" && op[2] === "photo"));
  assertEquals(page.operations.find(op => op[0] === "range"), ["range", 0, 1]);
  const chosen = f.queries.find(query => query.table === "listings")!;
  assert(chosen.operations.some(op => op[0] === "eq" && op[1] === "id" && op[2] === listing) && chosen.operations.some(op => op[0] === "eq" && op[1] === "org_id" && op[2] === org));
  for (const query of f.queries.filter(query => query.table !== "listings")) assert(query.operations.some(op => op[0] === "eq" && op[1] === "listing_id" && op[2] === listing));

  // End to end: one signed link, the cover, not the first upload and not a video.
  const signed: string[] = [];
  const handler = createStudioHandler({ ...repository, authorize: async () => scope, rateLimit: async () => true, sign: async (_bucket, signedKey) => { signed.push(signedKey); return `https://fixture.invalid/read/${encodeURIComponent(signedKey)}`; }, assertSigningPolicyFresh: async () => {}, now: () => 0 });
  const request = (query: string) => new Request(`https://fixture.invalid/functions/v1/studio/media?org_id=${org}&listing_id=${listing}${query}`);
  const cover = await (await handler(request("&limit=1&cover=1"))).json();
  assertEquals(cover.photos.map((photo: { id: string }) => photo.id), [id(14)]);
  assertEquals(cover.videos, []);
  assertEquals(cover.next_offset, null); assertEquals(cover.has_more, true);
  assertEquals(signed, [key("four")]);

  // A gallery row showing the cover file wins over its capture alias, wherever it sorts.
  f.results.photos.data = [
    { id: id(1), listing_id: listing, original_key: key("one"), enhanced_key: null, caption: "First", is_staged: false, sort: 0, created_at: "2026-09-14T00:00:00Z" },
    { id: id(2), listing_id: listing, original_key: key("four"), enhanced_key: `renders/${org}/${listing}/four-staged.jpg`, caption: "Staged", is_staged: true, sort: 1, created_at: "2026-09-14T00:00:00Z" },
    { id: id(3), listing_id: listing, original_key: key("four"), enhanced_key: null, caption: "Cover", is_staged: false, sort: 2, created_at: "2026-09-14T00:00:00Z" },
  ];
  const gallery = await (await handler(request("&limit=1&cover=1"))).json();
  assertEquals(gallery.photos.map((photo: { id: string }) => photo.id), [id(3)]);
  assertEquals(gallery.photos[0].caption, "Cover");

  // No chosen cover: the first gallery photo, exactly what a full page lists first.
  f.results.listings.data = { id: listing, org_id: org, main_photo_key: null };
  const fallback = await (await handler(request("&limit=1&cover=1"))).json();
  const full = await (await handler(request(""))).json();
  assertEquals(fallback.photos[0].id, id(1)); assertEquals(full.photos[0].id, id(1));
  assertEquals(full.has_more, undefined);

  // A failed cover lookup is an error, never an empty or wrong card.
  f.results.listings = { data: null, error: { message: "internal" } };
  assertEquals((await handler(request("&limit=1&cover=1"))).status, 503);
});

Deno.test("an ordinary page still emits exactly the three original queries", async () => {
  const f = fixture();
  await createStudioRepository(req, f.deps).read({ userId: user, orgId: org, listingId: listing }, 0);
  assertEquals(f.queries.map(query => query.table), ["photos", "capture_assets", "renders"]);
  assert(!f.queries.some(query => query.operations.some(op => op[0] === "eq" && op[1] === "kind")));
  for (const query of f.queries) assertEquals(query.operations.find(op => op[0] === "range"), ["range", 0, PAGE_SIZE]);
});

Deno.test("saved gallery sort determines page boundaries without cross-page capture aliases", async () => {
  const f = fixture(), repository = createStudioRepository(req, f.deps);
  const id = (n: number) => `50000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
  const count = PAGE_SIZE + 3;
  f.results.photos.data = Array.from({ length: count }, (_, n) => ({ id: id(n), listing_id: listing, original_key: `renders/${org}/${listing}/${n}.jpg`, enhanced_key: null, caption: null, is_staged: false, sort: n < 3 ? 1 : 0, created_at: "2026-09-14T00:00:00Z" })).reverse();
  f.results.capture_assets.data = Array.from({ length: count }, (_, n) => ({ id: id(n + 100), listing_id: listing, storage_key: `renders/${org}/${listing}/${n}.jpg`, kind: "photo", bucket: "renders", uploaded: true, duration_s: null, created_at: "2026-09-14T00:00:00Z" }));
  const handler = createStudioHandler({ ...repository, authorize: async () => ({ userId: user, orgId: org, listingId: listing }), rateLimit: async () => true, sign: async () => "https://fixture.invalid/read", assertSigningPolicyFresh: async () => {}, now: () => 0 });
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

Deno.test("client headshots never consume property media page slots", async () => {
  const f = fixture();
  const id = (n: number) => `40000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
  f.results.capture_assets.data = [
    ...Array.from({ length: 60 }, (_, i) => ({ id: id(i), listing_id: listing, kind: "photo", uploaded: true, bucket: "renders", storage_key: `renders/${org}/${listing}/contact-${id(i)}.jpg` })),
    { id: id(100), listing_id: listing, kind: "photo", uploaded: true, bucket: "renders", storage_key: `renders/${org}/${listing}/gallery-${id(100)}.jpg` },
  ];
  const data = await createStudioRepository(req, f.deps).read({ userId: user, orgId: org, listingId: listing }, 0);
  assertEquals(data.assets.map(row => row.id), [id(100)]);
});

Deno.test("selected-key provenance projection classifies saved results and refuses caption inference/conflicting legacy proofs", async () => {
  const f = fixture(), repository = createStudioRepository(req, f.deps);
  const original = `uploads/${org}/${listing}/original.jpg`, altered = `renders/${org}/${listing}/result.jpg`;
  f.results.photos.data = [{ id: user, listing_id: listing, original_key: original, enhanced_key: altered, caption: "Decluttered · misleading editable caption", is_staged: true, sort: 0, created_at: "2026-10-14T00:00:00Z" }];
  f.results.media_provenance.data = [{ org_id: org, listing_id: listing, altered_key: altered, original_key: original, kind: "virtual_stage", edit: "stage", qc: { publishable: true } }];
  const handler = createStudioHandler({ ...repository, authorize: async () => ({ userId: user, orgId: org, listingId: listing }), rateLimit: async () => true, sign: async (_bucket, key) => `https://fixture.invalid/read/${encodeURIComponent(key)}`, assertSigningPolicyFresh: async () => {}, now: () => 0 });
  const request = () => new Request(`https://fixture.invalid/functions/v1/studio/media?org_id=${org}&listing_id=${listing}`);
  const body = await (await handler(request())).json();
  assertEquals(body.photos[0].edit_kind, "stage"); assertEquals(body.photos[0].original_verified, true);
  const query = f.queries.find(query => query.table === "media_provenance")!;
  assert(query.operations.some(op => op[0] === "eq" && op[1] === "org_id" && op[2] === org));
  assert(query.operations.some(op => op[0] === "eq" && op[1] === "listing_id" && op[2] === listing));
  assertEquals(query.operations.find(op => op[0] === "in"), ["in", "altered_key", [altered]]);
  assertEquals(query.operations.find(op => op[0] === "limit"), ["limit", 205]);
  const stage = (f.results.media_provenance.data as Record<string, unknown>[])[0];
  f.results.media_provenance.data = [stage, { ...stage, kind: "declutter", edit: "declutter" }, stage];
  const conflicting = await (await handler(request())).json();
  assertEquals(conflicting.photos[0].edit_kind, null); assertEquals(conflicting.photos[0].original_verified, false);
  f.results.media_provenance.data = [{ ...stage, qc: { publishable: false } }];
  assertEquals((await (await handler(request())).json()).photos[0].edit_kind, null);
  f.results.media_provenance.data = [];
  assertEquals((await (await handler(request())).json()).photos[0].edit_kind, null);
  f.results.media_provenance.data = [{ ...stage, org_id: user }];
  assertEquals((await handler(request())).status, 503);
});

Deno.test("video working JPEGs and generated posters never become photos; untouched originals and saved gallery photos remain", async () => {
 const f=fixture(),repository=createStudioRepository(req,f.deps),id=(n:number)=>`50000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
 const keys=[`uploads/${org}/${listing}/prepared-video/${id(10)}/${id(11)}.jpg`,`renders/${org}/${listing}/background/${id(12)}/${id(13)}/first-clip.jpg`,`uploads/${org}/${listing}/${id(14)}.jpg`,`renders/${org}/${listing}/gallery-${id(15)}.jpg`];
 f.results.capture_assets.data=keys.map((storage_key,n)=>({id:id(n),listing_id:listing,storage_key,kind:'photo',bucket:n===0||n===2?'uploads':'renders',uploaded:true,duration_s:null,created_at:'2026-10-15T00:00:00Z'}));
 const signed:string[]=[],handler=createStudioHandler({...repository,authorize:async()=>({userId:user,orgId:org,listingId:listing}),rateLimit:async()=>true,sign:async(_bucket,key)=>{signed.push(key);return'https://fixture.invalid/read/'+encodeURIComponent(key);},assertSigningPolicyFresh:async()=>{},now:()=>0});
 const response=await handler(new Request(`https://fixture.invalid/studio/media?org_id=${org}&listing_id=${listing}`)),body=await response.json();assertEquals(response.status,200);assertEquals(body.photos.map((p:{id:string})=>p.id),[id(2),id(3)]);assertEquals(signed,keys.slice(2));assertEquals(body.next_offset,null);assert(!JSON.stringify(body).includes('prepared-video')&&!JSON.stringify(body).includes('first-clip'));
});

Deno.test("internal video photo rows are excluded before range/lookahead without dropping normal masters or saved history",async()=>{
 const f=fixture(),repo=createStudioRepository(req,f.deps),id=(n:number)=>`51000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
 const prepared=`uploads/${org}/${listing}/prepared-video/${id(900)}/${id(901)}.jpg`,poster=`renders/${org}/${listing}/background/${id(902)}/${id(903)}/first-clip.jpg`;
 f.results.capture_assets.data=[...Array.from({length:60},(_,n)=>({id:id(n),listing_id:listing,kind:'photo',uploaded:true,bucket:'uploads',storage_key:prepared})),...Array.from({length:51},(_,n)=>({id:id(100+n),listing_id:listing,kind:'photo',uploaded:true,bucket:'uploads',storage_key:`uploads/${org}/${listing}/original-${n}.jpg`}))];
 f.results.photos.data=[...Array.from({length:60},(_,n)=>({id:id(n),listing_id:listing,enhanced_key:n%2?poster:null,original_key:n%2?null:prepared,sort:n})),...Array.from({length:51},(_,n)=>({id:id(100+n),listing_id:listing,enhanced_key:n%3===0?null:n%3===1?'':`renders/${org}/${listing}/saved-edit-${n}.jpg`,original_key:`uploads/${org}/${listing}/original-${n}.jpg`,sort:100+n}))];
 const page=await repo.read({userId:user,orgId:org,listingId:listing},0);assertEquals(page.assets.length,51);assertEquals(page.photos.length,51);assertEquals(page.assets[0].id,id(100));assertEquals(page.photos[0].id,id(100));
 const next=await repo.read({userId:user,orgId:org,listingId:listing},50);assertEquals(next.assets.map(row=>row.id),[id(150)]);assertEquals(next.photos.map(row=>row.id),[id(150)]);
 for(const query of f.queries.filter(q=>(q.table==='photos'||q.table==='capture_assets')&&q.operations.some(op=>op[0]==='range'))){const before=query.operations.slice(0,query.operations.findIndex(op=>op[0]==='range'));assert(before.some(op=>op[0]===(query.table==='photos'?'or':'not')));}
});
