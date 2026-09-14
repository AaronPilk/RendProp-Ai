import {
  assertEquals,
  assertRejects,
  assertStringIncludes,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  editDisclosure,
  editOutputInput,
  handleEditOutput,
  resolveEditSources,
} from "./edit-output.ts";
import { HttpError } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";
const org = "11111111-1111-4111-8111-111111111111",
  user = "22222222-2222-4222-8222-222222222222",
  listing = "33333333-3333-4333-8333-333333333333",
  output = "44444444-4444-4444-8444-444444444444",
  source = "55555555-5555-4555-8555-555555555555",
  photo = "66666666-6666-4666-8666-666666666666",
  voice = "77777777-7777-4777-8777-777777777777";
const key = (name: string) => `renders/${org}/${listing}/${name}`;
function fixture() {
  const tables: Record<string, any[]> = {
    capture_assets: [{
      id: output,
      listing_id: listing,
      kind: "video",
      bucket: "renders",
      uploaded: true,
      storage_key: key("edited-complete-operation.mp4"),
      duration_s: 10,
    }, {
      id: source,
      listing_id: listing,
      kind: "photo",
      bucket: "renders",
      uploaded: true,
      storage_key: key("kitchen.png"),
    }],
    photos: [],
    media_provenance: [],
    studio_creative_results: [],
  };
  let role = "agent", proofFailures = 0, writes = 0;
  const qualityCalls: any[] = [];
  const admin = {
    rpc: async (name: string, args: any) => {
      assertEquals(name, "assert_studio_edit_quality");
      qualityCalls.push(args);
      return { data: null, error: null };
    },
    from: (table: string) => {
      let operation = "select",
        patch: any = null,
        one = false,
        limit = Infinity;
      const filters: ((row: any) => boolean)[] = [];
      const value = (row: any, field: string) =>
        field.includes("->>")
          ? row[field.split("->>")[0]]?.[field.split("->>")[1]]
          : row[field];
      const run = () => {
        let rows = tables[table].filter((row) => filters.every((f) => f(row)));
        if (operation === "insert") {
          writes++;
          if (table === "media_provenance" && proofFailures-- > 0) {
            return {
              data: null,
              error: { code: "temporary" },
            };
          }
          if (
            tables[table].some((row) =>
              row.id === patch.id && patch.id ||
              table === "studio_creative_results" &&
                row.request_key === patch.request_key
            )
          ) return { data: null, error: { code: "23505" } };
          const row = structuredClone({
            ...patch,
            id: patch.id ?? crypto.randomUUID(),
          });
          tables[table].push(row);
          rows = [row];
        }
        if (operation === "update") {
          writes++;
          for (const row of rows) Object.assign(row, structuredClone(patch));
        }
        const data = structuredClone(rows.slice(0, limit));
        return { data: one ? data[0] ?? null : data, error: null };
      };
      const chain: any = {
        select: () => chain,
        eq: (field: string, wanted: any) => {
          filters.push((row) => value(row, field) === wanted);
          return chain;
        },
        in: (field: string, wanted: any[]) => {
          filters.push((row) => wanted.includes(value(row, field)));
          return chain;
        },
        limit: (n: number) => {
          limit = n;
          return chain;
        },
        insert: (body: any) => {
          operation = "insert";
          patch = body;
          return chain;
        },
        update: (body: any) => {
          operation = "update";
          patch = body;
          return chain;
        },
        single: () => {
          one = true;
          return Promise.resolve(run());
        },
        maybeSingle: () => {
          one = true;
          return Promise.resolve(run());
        },
        then: (resolve: any) => resolve(run()),
      };
      return chain;
    },
  };
  const context: StudioContext = {
    userId: user,
    orgId: org,
    admin: admin as any,
    db: {
      rpc: async (name: string, args: any) => {
        assertEquals(name, "org_role");
        assertEquals(args, { target: org });
        return { data: role, error: null };
      },
    } as any,
    authorizeListing: async (id) => {
      if (id !== listing) throw new HttpError(403, "Wrong property");
    },
  };
  const call = (extra: Record<string, unknown> = {}) =>
    handleEditOutput(
      new Request("https://fixture.invalid/studio/edit-output", {
        method: "POST",
        body: JSON.stringify({
          listing_id: listing,
          asset_id: output,
          source_asset_ids: [source],
          ...extra,
        }),
      }),
      context,
    );
  return {
    tables,
    context,
    call,
    qualityCalls,
    setRole: (v: string) => role = v,
    failProofOnce: () => proofFailures = 1,
    get writes() {
      return writes;
    },
  };
}
Deno.test("edit input bounds source declarations and rejects self-reference", () => {
  assertEquals(
    editOutputInput({
      listing_id: listing,
      asset_id: output,
      source_asset_ids: [source, source],
    }).sourceIds,
    [source],
  );
  for (const ids of [[], [output], Array(25).fill(source), ["missing"]]) {
    assertThrows(
      () =>
        editOutputInput({
          listing_id: listing,
          asset_id: output,
          source_asset_ids: ids,
        }),
      HttpError,
    );
  }
});
Deno.test("native photo identifiers resolve the enhanced saved capture in the same property", () => {
  const f = fixture();
  const images = [{
    id: photo,
    listing_id: listing,
    original_key: key("before.png"),
    enhanced_key: key("kitchen.png"),
  }];
  assertEquals(
    resolveEditSources([photo], f.tables.capture_assets, images, org, listing)
      .map((row) => row.id),
    [source],
  );
  assertThrows(
    () =>
      resolveEditSources([photo], f.tables.capture_assets, images, org, user),
    HttpError,
  );
});
Deno.test("ordinary edits keep a generic disclosure without inventing AI or a single unaltered original", async () => {
  const f = fixture(), response = await f.call(), body = await response.json();
  assertEquals(body.ok, true);
  assertEquals(body.asset_id, output);
  const proof = f.tables.media_provenance[0],
    result = f.tables.studio_creative_results[0];
  assertEquals(proof.altered_key, key("edited-complete-operation.mp4"));
  assertEquals(proof.original_key, null);
  assertEquals(result.metadata.has_visual_ai, false);
  assertEquals(result.metadata.final_content_verified, false);
  assertEquals(result.metadata.state, "completed");
  assertEquals(proof.disclosure, editDisclosure(false, false));
  assertEquals(f.qualityCalls, [{ p_asset: source, p_seen: [output] }]);
});
Deno.test("known AI photos and owned narration propagate disclosure while source IDs remain declarations", async () => {
  const f = fixture();
  f.tables.photos.push({
    id: photo,
    listing_id: listing,
    original_key: key("before.png"),
    enhanced_key: key("kitchen.png"),
    is_staged: true,
  });
  f.tables.media_provenance.push({
    id: crypto.randomUUID(),
    org_id: org,
    listing_id: listing,
    kind: "virtual_stage",
    altered_key: key("kitchen.png"),
    disclosure: "AI staged photo",
  });
  f.tables.studio_creative_results.push({
    id: voice,
    user_id: user,
    org_id: org,
    listing_id: listing,
    kind: "voice",
    storage_key: `ai-voice/${org}/${voice}.mp3`,
    metadata: { state: "completed" },
  });
  const response = await f.call({
      source_asset_ids: [photo],
      narration_result_id: voice,
    }),
    body = await response.json();
  assertStringIncludes(body.disclosure, "AI-altered or generated visuals");
  assertStringIncludes(body.disclosure, "AI-generated narration");
  const result = f.tables.studio_creative_results.find((row) =>
    row.kind === "video"
  )!;
  assertEquals(result.metadata.source_asset_ids, [source]);
  assertEquals(result.metadata.narration_result_id, voice);
  assertEquals(result.metadata.final_content_verified, false);
});
Deno.test("output finalization rejects read-only roles, unfinished uploads and unavailable narration before writes", async () => {
  for (
    const change of [
      (f: ReturnType<typeof fixture>) => f.setRole("marketing"),
      (f: ReturnType<typeof fixture>) =>
        f.tables.capture_assets[0].uploaded = false,
    ]
  ) {
    const f = fixture();
    change(f);
    await assertRejects(() => f.call(), HttpError);
    assertEquals(f.writes, 0);
  }
  const f = fixture();
  await assertRejects(
    () => f.call({ narration_result_id: voice }),
    HttpError,
    "completed narration",
  );
  assertEquals(f.writes, 0);
});
Deno.test("native generated sources with absent or failed QC cannot be finalized into a new edit", async () => {
  const f = fixture();
  f.tables.media_provenance.push({
    id: crypto.randomUUID(),
    org_id: org,
    listing_id: listing,
    kind: "reel",
    altered_key: key("kitchen.png"),
    qc: { verdict: "fail", publishable: false, request_id: "known-job" },
  });
  await assertRejects(() => f.call(), HttpError, "passing property accuracy");
  assertEquals(f.writes, 0);
});
Deno.test("lost finalization responses and partial disclosure writes reuse the same output record", async () => {
  const f = fixture();
  f.failProofOnce();
  await assertRejects(() => f.call(), HttpError, "disclosure still needs");
  assertEquals(f.tables.studio_creative_results.length, 1);
  assertEquals(
    f.tables.studio_creative_results[0].metadata.state,
    "finalizing",
  );
  const first = await (await f.call()).json(),
    second = await (await f.call()).json();
  assertEquals(first, second);
  assertEquals(f.tables.studio_creative_results.length, 1);
  assertEquals(f.tables.media_provenance.length, 1);
});
Deno.test("a saved output cannot be silently relabeled with a different source declaration", async () => {
  const f = fixture();
  await f.call();
  const other = "88888888-8888-4888-8888-888888888888";
  f.tables.capture_assets.push({
    ...f.tables.capture_assets[1],
    id: other,
    storage_key: key("other.png"),
  });
  await assertRejects(
    () => f.call({ source_asset_ids: [other] }),
    HttpError,
    "different source record",
  );
  assertEquals(f.tables.studio_creative_results[0].metadata.source_asset_ids, [
    source,
  ]);
});
Deno.test("the existing per-property disclosure ceiling is preserved before reserving an edit", async () => {
  const f = fixture();
  f.tables.media_provenance.push(
    ...Array.from(
      { length: 500 },
      () => ({
        id: crypto.randomUUID(),
        org_id: org,
        listing_id: listing,
        altered_key: key("unrelated.png"),
      }),
    ),
  );
  await assertRejects(() => f.call(), HttpError, "disclosure limit");
  assertEquals(f.writes, 0);
});
