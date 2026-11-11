import type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
import { mapCatalogueRows } from "./catalogue-map.ts";

type Selected = { asset: { id?: unknown; storage_key?: unknown } };
type Task = { kind: "provenance" | "prepared"; values: string[] };
type Lookup = {
  provenance: Map<string, string | null>;
  prepared: Map<string, string | null>;
};
const ROW_LIMIT = 500;
const MAX_VALUES_PER_QUERY = 20;
const MAX_ENCODED_VALUES = 4096;
const safeKey = /^[A-Za-z0-9/_\-.]+$/;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const provenanceKinds = ["photo_edit", "virtual_stage", "declutter"];
const encodedCost = (value: string) =>
  new URLSearchParams({ v: value }).toString().length - 2 + 16;

/** Keep each PostgREST URL small. An oversized single value uses the original
 * per-row lookup. Values are deduplicated, while catalogue positions are not. */
function chunks(
  values: readonly string[],
  cost: (value: string) => number,
): string[][] {
  const result: string[][] = [];
  let chunk: string[] = [], size = 0;
  for (const value of new Set(values)) {
    let next: number;
    try {
      next = cost(value);
    } catch {
      continue;
    }
    if (next > MAX_ENCODED_VALUES) continue;
    if (
      chunk.length &&
      (chunk.length >= MAX_VALUES_PER_QUERY || size + next > MAX_ENCODED_VALUES)
    ) {
      result.push(chunk);
      chunk = [];
      size = 0;
    }
    chunk.push(value);
    size += next;
  }
  if (chunk.length) result.push(chunk);
  return result;
}

/** A complete bounded result can answer empty and latest-row lookups. A tied
 * latest timestamp uses the original per-row query instead of choosing a new
 * tie-breaker. Every uncertain result leaves its keys absent for fallback. */
function completeLatest(
  values: readonly string[],
  response: { data: unknown; error: unknown; count: number | null },
  keyFor: (row: Record<string, unknown>) => string | null,
  allowed: (row: Record<string, unknown>) => boolean,
  irrelevant?: (row: Record<string, unknown>) => boolean,
): Map<string, string | null> {
  const result = new Map<string, string | null>();
  if (
    response.error || !Array.isArray(response.data) ||
    typeof response.count !== "number" ||
    !Number.isSafeInteger(response.count) || response.count < 0 ||
    response.count !== response.data.length || response.data.length > ROW_LIMIT
  ) return result;
  const wanted = new Set(values),
    latest = new Map<string, { id: string; created_at: string }>();
  const tied = new Set<string>();
  for (const value of response.data) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return new Map();
    }
    const row = value as Record<string, unknown>, key = keyFor(row);
    if (
      !allowed(row) || typeof row.id !== "string" ||
      typeof row.created_at !== "string" ||
      !Number.isFinite(Date.parse(row.created_at))
    ) return new Map();
    // Two .in() predicates for prepared asset and version IDs admit cross
    // pairs. Exclude those before selecting each asset's latest valid row.
    if (irrelevant?.(row)) continue;
    if (key === null || !wanted.has(key)) return new Map();
    const previous = latest.get(key);
    if (!previous) latest.set(key, { id: row.id, created_at: row.created_at });
    else if (previous.created_at === row.created_at) tied.add(key);
  }
  for (const key of values) {
    if (!tied.has(key)) result.set(key, latest.get(key)?.id ?? null);
  }
  return result;
}

/** A batch is an optimization only. Failed, truncated, or ambiguous reads keep
 * no cached answer and selectedSources executes its existing per-row query. */
export async function selectedLookupBatch(
  db: SupabaseClient,
  actor: string,
  listing: string,
  selected: readonly Selected[],
): Promise<Lookup> {
  const keys = selected.map(({ asset }) => asset.storage_key).filter((
    key,
  ): key is string => typeof key === "string" && safeKey.test(key));
  const ids = selected.map(({ asset }) => asset.id).filter((id): id is string =>
    typeof id === "string" && uuid.test(id)
  );
  const tasks: Task[] = [
    ...chunks(keys, encodedCost).map(
      (values) => ({ kind: "provenance" as const, values }),
    ),
    ...chunks(
      ids,
      (id) => encodedCost(id) + encodedCost("asset:" + id),
    )
      .map((values) => ({ kind: "prepared" as const, values })),
  ];
  const answers = await mapCatalogueRows(tasks, async (task) => {
    try {
      if (task.kind === "provenance") {
        const response = await db.from("media_provenance")
          .select("id,listing_id,altered_key,kind,created_at", {
            count: "exact",
          })
          .eq("listing_id", listing).in("altered_key", task.values).in(
            "kind",
            provenanceKinds,
          )
          .order("created_at", { ascending: false }).limit(ROW_LIMIT);
        return {
          kind: task.kind,
          rows: completeLatest(
            task.values,
            response,
            (row) =>
              typeof row.altered_key === "string" ? row.altered_key : null,
            (row) =>
              row.listing_id === listing &&
              provenanceKinds.includes(String(row.kind)),
          ),
        };
      }
      const versions = task.values.map((id) => "asset:" + id);
      const response = await db.from("property_video_preparations")
        .select(
          "id,actor_id,listing_id,original_asset_id,version_id,state,created_at",
          { count: "exact" },
        )
        .eq("actor_id", actor).eq("listing_id", listing).eq("state", "ready")
        .in("original_asset_id", task.values).in("version_id", versions)
        .order("created_at", { ascending: false }).limit(ROW_LIMIT);
      return {
        kind: task.kind,
        rows: completeLatest(
          task.values,
          response,
          (row) =>
            typeof row.original_asset_id === "string" &&
              row.version_id === "asset:" + row.original_asset_id
              ? row.original_asset_id
              : null,
          (row) =>
            row.actor_id === actor && row.listing_id === listing &&
            row.state === "ready" &&
            typeof row.original_asset_id === "string" &&
            task.values.includes(row.original_asset_id) &&
            typeof row.version_id === "string" &&
            versions.includes(row.version_id),
          (row) => row.version_id !== "asset:" + row.original_asset_id,
        ),
      };
    } catch {
      return { kind: task.kind, rows: new Map<string, string | null>() };
    }
  });
  const result: Lookup = { provenance: new Map(), prepared: new Map() };
  for (const answer of answers) {
    for (const [key, id] of answer.rows) result[answer.kind].set(key, id);
  }
  return result;
}
