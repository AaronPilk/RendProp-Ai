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

function fixture() {
  const events: string[] = [];
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
          let data = [...result.data].filter(row => operations.every(op => (op[0] !== "in" || (op[2] as unknown[]).includes(row[String(op[1])])) &&
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
    async activeOrg(id) {
      return await client.from("orgs").select("id").eq("id",id).is("deleted_at",null).abortSignal(req.signal).maybeSingle() as {data:{id:string}|null;error:unknown};
    },
    async listingScope(subject, requested) {
      assertEquals([subject, requested], [user, listing]);
      events.push("listing-scope");
      return {actor_id:user,org_id:org,library_org_id:org,can_read:true};
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

Deno.test("deletion and removed membership failures prevent tenant reads", async () => {
  for (const denied of ["assertNotDeleting", "listingScope"] as const) {
    const f = fixture();
    f.deps[denied] = async () => {
      throw new HttpError(denied === "listingScope" ? 403 : 409, "Denied.");
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
  const handler = createStudioHandler({ ...repository, authorize: async () => ({ userId: user, orgId: org, listingId: listing }), rateLimit: async () => true, sign: async (_bucket, key) => `https://fixture.invalid/read/${encodeURIComponent(key)}`, now: () => 0 });
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
 const signed:string[]=[],handler=createStudioHandler({...repository,authorize:async()=>({userId:user,orgId:org,listingId:listing}),rateLimit:async()=>true,sign:async(_bucket,key)=>{signed.push(key);return'https://fixture.invalid/read/'+encodeURIComponent(key);},now:()=>0});
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
