import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
import { selectedLookupBatch } from "./selected-batch.ts";

type Row = Record<string, unknown>;
type Response = { data: Row[] | null; count: number | null; error: unknown };
type Call = {
  table: string;
  eq: Record<string, unknown>;
  included: Record<string, string[]>;
  limit: number;
};
const actor = "11111111-1111-4111-8111-111111111111";
const listing = "22222222-2222-4222-8222-222222222222";
const ids = Array.from(
  { length: 38 },
  (_, i) => `aaaaaaaa-aaaa-4aaa-8aaa-${String(i + 1).padStart(12, "0")}`,
);
const keys = ids.map((id) => `renders/${listing}/${id}.jpg`);
const selected = ids.map((id, i) => ({ asset: { id, storage_key: keys[i] } }));
const stamp = (second: number) =>
  `2026-11-11T19:00:${String(second).padStart(2, "0")}Z`;
const provenance = (
  i: number,
  second: number,
  id = `provenance-${i}-${second}`,
): Row => ({
  id,
  listing_id: listing,
  altered_key: keys[i],
  kind: "photo_edit",
  created_at: stamp(second),
});
const prepared = (
  i: number,
  second: number,
  id = `prepared-${i}-${second}`,
  version = `asset:${ids[i]}`,
): Row => ({
  id,
  actor_id: actor,
  listing_id: listing,
  original_asset_id: ids[i],
  version_id: version,
  state: "ready",
  created_at: stamp(second),
});

function fixture(
  provenanceRows: Row[],
  preparedRows: Row[],
  override?: (table: string, response: Response) => Response,
): { db: SupabaseClient; calls: Call[] } {
  const calls: Call[] = [];
  const tables: Record<string, Row[]> = {
    media_provenance: provenanceRows,
    property_video_preparations: preparedRows,
  };
  class Query {
    readonly eqFilters: Record<string, unknown> = {};
    readonly inFilters: Record<string, string[]> = {};
    rowLimit = 0;
    constructor(readonly table: string) {}
    select(_columns: string, options: { count: string }) {
      assertEquals(options.count, "exact");
      return this;
    }
    eq(column: string, value: unknown) {
      this.eqFilters[column] = value;
      return this;
    }
    in(column: string, values: string[]) {
      this.inFilters[column] = values;
      return this;
    }
    order(column: string, options: { ascending: boolean }) {
      assertEquals(column, "created_at");
      assertEquals(options.ascending, false);
      return this;
    }
    limit(value: number) {
      this.rowLimit = value;
      return this;
    }
    then(resolve: (response: Response) => unknown) {
      calls.push({
        table: this.table,
        eq: { ...this.eqFilters },
        included: { ...this.inFilters },
        limit: this.rowLimit,
      });
      const filtered = tables[this.table].filter((row) =>
        Object.entries(this.eqFilters).every(([key, value]) =>
          row[key] === value
        ) &&
        Object.entries(this.inFilters).every(([key, values]) =>
          values.includes(String(row[key]))
        )
      );
      filtered.sort((a, b) =>
        Date.parse(String(b.created_at)) - Date.parse(String(a.created_at))
      );
      const response: Response = {
        data: filtered.slice(0, this.rowLimit),
        count: filtered.length,
        error: null,
      };
      return Promise.resolve(
        resolve(override?.(this.table, response) ?? response),
      );
    }
  }
  return {
    db: {
      from: (table: string) => new Query(table),
    } as unknown as SupabaseClient,
    calls,
  };
}

Deno.test("38 selected assets use bounded scoped bulk reads and retain latest exact rows", async () => {
  const f = fixture([provenance(0, 1), provenance(0, 2), provenance(17, 3)], [
    prepared(0, 1),
    prepared(0, 2),
    prepared(37, 3),
  ]);
  const result = await selectedLookupBatch(f.db, actor, listing, selected);
  assertEquals(f.calls.length, 4);
  assertEquals(result.provenance.size, 38);
  assertEquals(result.prepared.size, 38);
  assertEquals(result.provenance.get(keys[0]), "provenance-0-2");
  assertEquals(result.provenance.get(keys[17]), "provenance-17-3");
  assertEquals(result.prepared.get(ids[0]), "prepared-0-2");
  assertEquals(result.prepared.get(ids[37]), "prepared-37-3");
  assertEquals(result.prepared.get(ids[17]), null);
  for (const call of f.calls) {
    assertEquals(call.limit, 500);
    const values = call.included[
      call.table === "media_provenance" ? "altered_key" : "original_asset_id"
    ];
    assert(values.length <= 20);
    const encodedValues = call.table === "media_provenance"
      ? values
      : [...values, ...call.included.version_id];
    assert(
      encodedValues.reduce(
        (total, value) =>
          total + new URLSearchParams({ v: value }).toString().length - 2 + 16,
        0,
      ) <= 4096,
    );
    assert(
      call.table === "media_provenance"
        ? call.eq.listing_id === listing && call.included.kind.length === 3
        : call.eq.actor_id === actor && call.eq.listing_id === listing &&
          call.eq.state === "ready" &&
          call.included.version_id.length === values.length,
    );
  }
});

Deno.test("unusual or oversized keys retain exact per-item lookup path", async () => {
  const f = fixture([], []);
  const unusual = [{ asset: { id: ids[0], storage_key: "renders/a,(b).jpg" } }];
  const oversized = [{ asset: { id: ids[1], storage_key: "a".repeat(5000) } }];
  const result = await selectedLookupBatch(f.db, actor, listing, [
    ...unusual,
    ...oversized,
  ]);
  assertEquals(result.provenance.size, 0);
  assertEquals(result.prepared.size, 2);
  assertEquals(
    f.calls.filter((call) => call.table === "media_provenance").length,
    0,
  );
});

Deno.test("prepared cross pairs are excluded before latest selection", async () => {
  const f = fixture([], [
    prepared(0, 10, "wrong-pair", `asset:${ids[1]}`),
    prepared(0, 5, "exact-pair"),
  ]);
  const result = await selectedLookupBatch(f.db, actor, listing, selected);
  assertEquals(result.prepared.get(ids[0]), "exact-pair");
  assertEquals(result.prepared.get(ids[1]), null);
});

Deno.test("incomplete, oversized, and failed bulk responses retain per-item fallback", async () => {
  for (
    const mode of ["unknown_count", "truncated", "overflow", "error"] as const
  ) {
    const f = fixture(
      [provenance(0, 1)],
      [],
      (table, response) =>
        table !== "media_provenance" ? response : {
          ...response,
          count: mode === "unknown_count"
            ? null
            : mode === "truncated"
            ? 2
            : mode === "overflow"
            ? 501
            : response.count,
          error: mode === "error" ? new Error("read failed") : null,
        },
    );
    const result = await selectedLookupBatch(
      f.db,
      actor,
      listing,
      selected.slice(0, 1),
    );
    assertEquals(result.provenance.has(keys[0]), false, mode);
    assertEquals(result.prepared.get(ids[0]), null);
  }
});

Deno.test("latest timestamp tie falls back only for ambiguous key", async () => {
  const f = fixture([
    provenance(0, 7, "first"),
    provenance(0, 7, "second"),
    provenance(1, 4, "unambiguous"),
  ], []);
  const result = await selectedLookupBatch(
    f.db,
    actor,
    listing,
    selected.slice(0, 2),
  );
  assertEquals(result.provenance.has(keys[0]), false);
  assertEquals(result.provenance.get(keys[1]), "unambiguous");
});

Deno.test("unexpected cross-scope row makes entire affected batch fall back", async () => {
  const f = fixture(
    [provenance(0, 1)],
    [],
    (table, response) =>
      table === "media_provenance"
        ? {
          ...response,
          data: [{ ...provenance(0, 1), listing_id: "other-org-listing" }],
        }
        : response,
  );
  const result = await selectedLookupBatch(
    f.db,
    actor,
    listing,
    selected.slice(0, 2),
  );
  assertEquals(result.provenance.size, 0);
});

Deno.test("duplicate catalogue positions make one bulk key without losing selected position count", async () => {
  const f = fixture([provenance(0, 1)], [prepared(0, 1)]);
  const repeated = [selected[0], selected[0], selected[0]];
  const result = await selectedLookupBatch(f.db, actor, listing, repeated);
  assertEquals(repeated.length, 3);
  assertEquals(result.provenance.size, 1);
  assertEquals(result.prepared.size, 1);
  assertEquals(f.calls.length, 2);
  assertEquals(f.calls[0].included.altered_key.length, 1);
  assertEquals(f.calls[1].included.original_asset_id.length, 1);
});
