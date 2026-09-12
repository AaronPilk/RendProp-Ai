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
          return Promise.resolve(results[table]).then(yes, no);
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
    assertEquals(query.operations.find((op) => op[0] === "order"), [
      "order",
      "id",
      { ascending: true },
    ]);
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
