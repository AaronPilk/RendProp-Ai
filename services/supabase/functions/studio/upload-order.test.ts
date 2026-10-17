// Studio media order follows upload order. The actual repository adapter and
// handler run against a closed PostgREST model (filters, ordering, ranges) so a
// missing or wrong ORDER BY changes the pages exactly as it would in production.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { SupabaseClient, User } from "npm:@supabase/supabase-js@2.116.0";
import { createStudioRepository, type StudioRepositoryDependencies } from "./repository.ts";
import { createStudioHandler, PAGE_SIZE, type PhotoRow } from "./handler.ts";

const user = "10000000-0000-4000-8000-000000000001", org = "20000000-0000-4000-8000-000000000002", listing = "30000000-0000-4000-8000-000000000003";
const req = new Request("https://fixture.invalid/studio/media");
type Row = Record<string, unknown>;
function splitLogic(text: string): string[] {
  let depth = 0, start = 0; const parts: string[] = [];
  for (let i = 0; i < text.length; i++) { if (text[i] === "(") depth++; else if (text[i] === ")") depth--; else if (text[i] === "," && depth === 0) { parts.push(text.slice(start, i)); start = i + 1; } }
  return [...parts, text.slice(start)];
}
function logic(row: Row, term: string): boolean {
  if (term.startsWith("and(") || term.startsWith("or(")) { const parts = splitLogic(term.slice(term.indexOf("(") + 1, -1)).map(t => logic(row, t)); return term.startsWith("and(") ? parts.every(Boolean) : parts.some(Boolean); }
  const [column, ...rest] = term.split("."); let expression = rest.join("."), negated = false; if (expression.startsWith("not.")) { negated = true; expression = expression.slice(4); }
  const separator = expression.indexOf("."), op = expression.slice(0, separator), value = expression.slice(separator + 1), actual = row[column!];
  let match: boolean;
  if (op === "is") match = value === "null" && actual == null;
  else if (op === "like") match = actual != null && new RegExp("^" + value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replaceAll("%", ".*").replaceAll("_", ".") + "$").test(String(actual));
  else if (op === "eq") match = actual === value; else if (op === "neq") match = actual != null && actual !== value; else throw Error("Unsupported closed filter " + op);
  return negated ? (actual != null && !match) : match;
}
function media(photos: PhotoRow[], assets: Row[]) {
  const tables: Record<string, Row[] | Row> = { photos: photos as unknown as Row[], capture_assets: assets, renders: [], media_provenance: [], orgs: { id: org }, listings: { id: listing, org_id: org } };
  const client = {
    rpc(_name: string, args: Record<string, string[]>) { return Promise.resolve({ data: { assets: Object.fromEntries(args.p_assets.map(id => [id, true])), renders: Object.fromEntries(args.p_renders.map(id => [id, true])), keys: Object.fromEntries(args.p_keys.map(key => [key, true])) }, error: null }); },
    from(table: string) {
      const operations: [string, ...unknown[]][] = [];
      const query = {
        select: (...a: unknown[]) => (operations.push(["select", ...a]), query), eq: (...a: unknown[]) => (operations.push(["eq", ...a]), query),
        is: (...a: unknown[]) => (operations.push(["is", ...a]), query), in: (...a: unknown[]) => (operations.push(["in", ...a]), query),
        not: (...a: unknown[]) => (operations.push(["not", ...a]), query), or: (...a: unknown[]) => (operations.push(["or", ...a]), query),
        limit: (...a: unknown[]) => (operations.push(["limit", ...a]), query), order: (...a: unknown[]) => (operations.push(["order", ...a]), query),
        range: (...a: unknown[]) => (operations.push(["range", ...a]), query), abortSignal: () => query,
        maybeSingle: () => Promise.resolve({ data: tables[table], error: null }),
        then<T>(yes: (value: { data: unknown; error: null }) => T) {
          const rows = tables[table];
          if (!Array.isArray(rows)) return Promise.resolve({ data: rows, error: null }).then(yes);
          const order = operations.filter(op => op[0] === "order");
          const data = rows.filter(row => operations.every(op => (op[0] !== "eq" || row[String(op[1])] === undefined || row[String(op[1])] === op[2]) &&
            (op[0] !== "in" || (op[2] as unknown[]).includes(row[String(op[1])])) && (op[0] !== "not" || logic(row, `${op[1]}.not.${op[2]}.${op[3]}`)) &&
            (op[0] !== "or" || splitLogic(String(op[1])).some(term => logic(row, term))))).sort((a, b) => {
            for (const [, column] of order) { const field = String(column); if (a[field] !== b[field]) return a[field]! < b[field]! ? -1 : 1; }
            return 0;
          });
          const range = operations.find(op => op[0] === "range");
          return Promise.resolve({ data: range ? data.slice(Number(range[1]), Number(range[2]) + 1) : data, error: null }).then(yes);
        },
      };
      return query;
    },
  } as unknown as SupabaseClient;
  const deps = {
    userClient: () => client, getUser: async () => ({ id: user }) as User, assertNotDeleting: async () => {},
    activeOrg: async () => ({ data: { id: org }, error: null }), listingScope: async () => ({ actor_id: user, org_id: org, library_org_id: org, can_read: true }),
  } as unknown as StudioRepositoryDependencies;
  const repository = createStudioRepository(req, deps);
  const handler = createStudioHandler({ ...repository, authorize: async () => ({ userId: user, orgId: org, listingId: listing }), rateLimit: async () => true, sign: async (_bucket, key) => `https://fixture.invalid/read/${encodeURIComponent(key)}`, now: () => 0 } as Parameters<typeof createStudioHandler>[0]);
  return async () => {
    const ids: string[] = []; let offset: number | null = 0;
    while (offset !== null) {
      const page = await (await handler(new Request(`https://fixture.invalid/functions/v1/studio/media?org_id=${org}&listing_id=${listing}&offset=${offset}`))).json();
      ids.push(...page.photos.map((photo: { id: string }) => photo.id)); offset = page.next_offset;
    }
    return ids;
  };
}
// Later uploads get LOWER UUIDs, so any UUID tie-break shows the wrong order.
const id = (n: number) => `40000000-0000-4000-8000-${String(9999 - n).padStart(12, "0")}`;
const at = (n: number) => new Date(Date.UTC(2026, 9, 15, 12, 0, n)).toISOString();
const key = (n: number) => `renders/${org}/${listing}/gallery-${id(n)}.jpg`;
const asset = (n: number, created = at(n)): Row => ({ id: id(n), listing_id: listing, storage_key: key(n), kind: "photo", bucket: "renders", uploaded: true, duration_s: null, created_at: created });
const row = (n: number, sort: number, created = at(n)): PhotoRow => ({ id: id(n), listing_id: listing, original_key: key(n), enhanced_key: null, caption: `IMG_${String((n % 30) + 1).padStart(4, "0")}`, is_staged: false, sort, created_at: created });
const upload = (count: number) => Array.from({ length: count }, (_, n) => n);

Deno.test("phone-uploaded source photos follow two upload batches across media pages, not UUID order", async () => {
  // 30 photos, then a second batch of 26 whose names restart at IMG_0001.
  assertEquals(await media([], upload(56).map(n => asset(n)))(), upload(56).map(id));
});

Deno.test("gallery photos: legacy ties follow attach time, appended uploads and a saved edit stay underneath", async () => {
  // 30 legacy rows from the old attach (sort 0), 25 later uploads appended by the new attach (sort 1..25).
  const rows = upload(55).map(n => row(n, n < 30 ? 0 : n - 29));
  const read = media(rows, rows.map((r, n) => asset(n, r.created_at)));
  assertEquals(await read(), upload(55).map(id), "upload order across 55 gallery photos and two media pages");
  // A saved edit is attached later at the next position; a capture alias never duplicates it.
  rows.push(row(55, 26)); assertEquals(await media(rows, rows.map((r, n) => asset(n, r.created_at)))(), upload(56).map(id));
});

Deno.test("an explicit reorder still wins, and identical upload times break ties the same way every time", async () => {
  const rows = upload(PAGE_SIZE + 5).map(n => row(n, PAGE_SIZE + 4 - n)); // reversed by an explicit reorder
  assertEquals(await media(rows, [])(), upload(PAGE_SIZE + 5).map(id).reverse());
  const tied = upload(4).map(n => asset(n, at(0)));
  const first = await media([], tied)(), second = await media([], [...tied].reverse())();
  assertEquals(first, second); assertEquals(first, [...first].sort());
});
