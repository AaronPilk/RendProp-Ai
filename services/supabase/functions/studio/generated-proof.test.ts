import {
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { attachGeneratedVideoProof } from "./generated-proof.ts";
import { HttpError } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";
const org = "11111111-1111-4111-8111-111111111111",
  user = "22222222-2222-4222-8222-222222222222",
  listing = "33333333-3333-4333-8333-333333333333",
  resultId = "44444444-4444-4444-8444-444444444444",
  sourceId = "55555555-5555-4555-8555-555555555555",
  outputId = "66666666-6666-4666-8666-666666666666",
  proofId = "77777777-7777-4777-8777-777777777777";
const prefix = `renders/${org}/${listing}/`,
  key =
    `${prefix}${outputId}-complete-88888888-8888-4888-8888-888888888888.mp4`;
function fixture() {
  const row: any = {
    id: resultId,
    user_id: user,
    org_id: org,
    listing_id: listing,
    kind: "video",
    storage_key: null,
    provenance_id: proofId,
    metadata: {
      state: "processing",
      video_kind: "reel",
      source_asset_id: sourceId,
      request_id: "fixture-provider-job",
      status_url: "https://fal.media/status/fixture",
      response_url: "https://fal.media/response/fixture",
    },
  };
  const source = {
    id: sourceId,
    listing_id: listing,
    kind: "photo",
    bucket: "renders",
    uploaded: true,
    storage_key: `${prefix}original-source.png`,
  };
  const output = {
    id: outputId,
    listing_id: listing,
    kind: "video",
    bucket: "renders",
    uploaded: true,
    storage_key: key,
  };
  const proof: any = {
    id: proofId,
    org_id: org,
    listing_id: listing,
    kind: "reel",
    original_key: source.storage_key,
    altered_key: null,
    qc: null,
  };
  const tables: Record<string, any[]> = {
    capture_assets: [source, output],
    media_provenance: [proof],
    studio_creative_results: [row],
  };
  let updates = 0;
  const admin = {
    rpc: (name: string, args: Record<string, unknown>) => {
      assertEquals(name, "studio_presenter_media_visibility");
      assertEquals(args.p_listing, listing);
      assertEquals(args.p_renders, []);
      const assets = args.p_assets as string[], keys = args.p_keys as string[];
      return Promise.resolve({ error: null, data: {
        assets: Object.fromEntries(assets.map(id => [id, tables.capture_assets.some(a => a.id === id && a.uploaded)])),
        renders: {},
        keys: Object.fromEntries(keys.map(value => [value, tables.capture_assets.some(a => a.storage_key === value && a.uploaded)])),
      } });
    },
    from: (table: string) => {
      const filters: ((row: any) => boolean)[] = [];
      let patch: any;
      const field = (row: any, name: string) =>
        name.includes("->>")
          ? row[name.split("->>")[0]]?.[name.split("->>")[1]]
          : row[name];
      const run = () => {
        const rows = tables[table].filter((row) =>
          filters.every((filter) => filter(row))
        );
        if (patch) {
          updates++;
          rows.forEach((row) => Object.assign(row, structuredClone(patch)));
        }
        return { data: rows[0] ? structuredClone(rows[0]) : null, error: null };
      };
      const chain: any = {
        select: () => chain,
        eq: (name: string, value: any) => {
          filters.push((row) =>
            typeof field(row, name) === "number" && typeof value === "string"
              ? String(field(row, name)) === value
              : field(row, name) === value
          );
          return chain;
        },
        is: (name: string, value: any) => {
          filters.push((row) => (field(row, name) ?? null) === value);
          return chain;
        },
        update: (value: any) => {
          patch = value;
          return chain;
        },
        single: async () => run(),
        maybeSingle: async () => run(),
        then: (done: any) => done(run()),
      };
      return chain;
    },
  };
  const context: StudioContext = {
    userId: user,
    orgId: org,
    admin: admin as any,
    db: {
      rpc: () => {
        throw new Error(
          "Video attachment must not call the photo-only set_provenance_media RPC.",
        );
      },
    } as any,
    authorizeListing: async (id) => {
      assertEquals(id, listing);
    },
  };
  return {
    row,
    source,
    output,
    proof,
    tables,
    context,
    get updates() {
      return updates;
    },
  };
}
Deno.test("a confirmed video receipt attaches only its saved source and existing scoped provenance", async () => {
  const f = fixture();
  await attachGeneratedVideoProof(
    f.context,
    f.row,
    f.row.metadata,
    outputId,
    key,
  );
  assertEquals(f.proof.altered_key, key);
  assertEquals(f.proof.original_key, f.source.storage_key);
  assertEquals(f.proof.qc, null);
  await attachGeneratedVideoProof(
    f.context,
    f.row,
    f.row.metadata,
    outputId,
    key,
  );
  assertEquals(f.tables.media_provenance.length, 1);
});
Deno.test("generated video attachment refuses unconfirmed bytes, changed originals and unrelated proof rows", async () => {
  for (
    const change of [
      (f: ReturnType<typeof fixture>) => f.output.uploaded = false,
      (f: ReturnType<typeof fixture>) => f.proof.listing_id = org,
      (f: ReturnType<typeof fixture>) =>
        f.proof.original_key = `${prefix}different.png`,
      (f: ReturnType<typeof fixture>) => f.row.user_id = org,
    ]
  ) {
    const f = fixture();
    change(f);
    await assertRejects(
      () =>
        attachGeneratedVideoProof(
          f.context,
          f.row,
          f.row.metadata,
          outputId,
          key,
        ),
      HttpError,
    );
    assertEquals(f.updates, 0);
  }
});
Deno.test("video-status imports completed MP4 and attaches video provenance without the photo-only RPC", async () => {
  const env = {
    SUPABASE_URL: "https://fixture.supabase.co",
    CLOUDFLARE_ACCOUNT_ID: "012345678901234567890123456789ab",
    R2_ACCESS_KEY_ID: "fixture-access-key",
    R2_SECRET_ACCESS_KEY: "fixture-secret-key",
    UPLOAD_GATEWAY_ORIGIN: "https://uploads.rendprop.com",
  };
  const old = Object.fromEntries(
      Object.keys(env).map((name) => [name, Deno.env.get(name)]),
    ),
    originalFetch = globalThis.fetch;
  for (const [name, value] of Object.entries(env)) Deno.env.set(name, value);
  try {
    const { handleCreative } = await import("./creative.ts");
    const f = fixture(), calls: string[] = [];
    f.output.uploaded = false;
    globalThis.fetch = async (input, options) => {
      const requestOptions = options as {
        method?: string;
        headers?: HeadersInit;
      } | undefined;
      const url = new URL(String(input));
      calls.push(
        `${requestOptions?.method ?? "GET"} ${url.origin}${url.pathname}`,
      );
      const json = (body: unknown) =>
        new Response(JSON.stringify(body), {
          headers: { "content-type": "application/json" },
        });
      if (url.pathname === "/functions/v1/ai-video/status") {
        return json({
          status: "completed",
          video_url: "https://fal.media/fixture-result.mp4",
        });
      }
      if (url.href === "https://fal.media/fixture-result.mp4") {
        return new Response(new Uint8Array([0, 0, 0, 20, 102, 116, 121, 112]), {
          headers: { "content-type": "video/mp4" },
        });
      }
      if (url.pathname === "/functions/v1/uploads") {
        return json({
          asset_id: outputId,
          storage_key: `${prefix}${outputId}.mp4`,
          mode: "single",
          uploaded: false,
          put_url:
            `https://uploads.rendprop.com/v2/${outputId}?signature=fixture`,
        });
      }
      if (url.hostname === "uploads.rendprop.com") {
        assertEquals(
          new Headers(requestOptions?.headers).has("authorization"),
          false,
        );
        return new Response(null, { status: 200 });
      }
      if (url.pathname === `/functions/v1/uploads/${outputId}/complete`) {
        f.output.uploaded = true;
        return json({ ...f.output });
      }
      throw new Error(
        `Unexpected fixture request ${url.origin}${url.pathname}`,
      );
    };
    const response = await handleCreative(
      new Request("https://fixture.invalid/studio/video-status", {
        method: "POST",
        headers: { authorization: "Bearer fixture-user" },
        body: JSON.stringify({ result_id: resultId }),
      }),
      f.context,
    );
    const body = await response!.json();
    assertEquals(response!.status, 200);
    assertEquals(body.result.state, "completed");
    assertEquals(body.result.asset_id, outputId);
    assertEquals(body.result.qc_required, true);
    assertEquals(body.result.qc_publishable, false);
    assertEquals(f.row.storage_key, key);
    assertEquals(f.proof.altered_key, key);
    assertEquals(f.proof.original_key, f.source.storage_key);
    assertStringIncludes(body.result.url, "-complete-");
    assertEquals(calls.length, 5);
    assertEquals(JSON.stringify(body).includes("fixture-secret-key"), false);
  } finally {
    globalThis.fetch = originalFetch;
    for (const [name, value] of Object.entries(old)) {
      if (value === undefined) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  }
});
