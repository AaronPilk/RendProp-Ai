// Exercise the deployed tours handler at the Worker-to-Edge boundary. The
// PostgREST transport is doubled; no real object or provider is requested.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

// Supabase's client captures its base URL at module evaluation. Install the
// closed fixture environment before importing the actual deployed handler.
const names = ["SUPABASE_URL", "SUPABASE_ANON_KEY", "SUPABASE_SERVICE_ROLE_KEY",
  "MEDIA_GATEWAY_SECRET", "PRIVATE_MEDIA_DELIVERY"] as const;
const prior = names.map(name => Deno.env.get(name));
for (const [name, value] of Object.entries({
  SUPABASE_URL: "https://private-large.fixture.invalid",
  SUPABASE_ANON_KEY: "public-fixture",
  SUPABASE_SERVICE_ROLE_KEY: "service-fixture",
  MEDIA_GATEWAY_SECRET: "d".repeat(64),
  PRIVATE_MEDIA_DELIVERY: "gateway-v1",
})) Deno.env.set(name, value);
const { privateMediaUrl } = await import("../_shared/private-media.ts");
const { REGISTERED_BACKGROUND_BYTES } = await import("../_shared/background-media-delivery.ts");

const actor = "10000000-0000-4000-8000-000000000001";
const org = "20000000-0000-4000-8000-000000000002";
const listing = "30000000-0000-4000-8000-000000000003";
const asset = "40000000-0000-4000-8000-000000000004";
const job = "50000000-0000-4000-8000-000000000005";
const key = `renders/${org}/${listing}/background/${job}/${actor}/master.mp4`;
const size = 350 * 1024 * 1024;

let handler!: (request: Request) => Promise<Response>;
const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
Object.defineProperty(Deno, "serve", { configurable: true, writable: true,
  value: (fn: typeof handler) => { handler = fn; return {}; } });
try { await import("./index.ts"); }
finally { Object.defineProperty(Deno, "serve", serve); }

Deno.test("private gateway admits a registered 350 MiB master and refuses unregistered or over-limit bytes", async () => {
  const previousFetch = globalThis.fetch;
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  let selectedKey = key;
  try {
    const reply = (value: unknown) => Response.json(value);
    globalThis.fetch = async (input, init) => {
      const request = new Request(input, init), url = new URL(request.url);
      assertEquals(url.hostname, "private-large.fixture.invalid");
      const path = url.pathname;
      if (path.startsWith("/rest/v1/rpc/")) {
        const name = path.split("/").at(-1)!;
        const args = await request.json() as Record<string, unknown>;
        calls.push({ name, args });
        if (name === "library_media_delivery_admit") {
          assertEquals(args, { p_actor: actor, p_org: org, p_bytes: 0, p_required: true });
          return reply({ admitted: true, legacy_unbudgeted: false });
        }
        if (name === "listing_library_scope") return reply({
          actor_id: actor, listing_id: listing, org_id: org, library_org_id: org,
          library_owner_user_id: actor, listing_owner_user_id: actor,
          billing_org_id: org, team_org_id: null, role: "owner", access_mode: "own",
          can_read: true, can_write: true, can_manage_subscription: true,
        });
        if (name === "hosting_retention_state") return reply({
          org_id: org, policy: "preserved", protected: false,
          retention_ends_at: null, hosting_available: true,
        });
        if (name === "studio_presenter_media_visibility") return reply({
          assets: {}, renders: {},
          keys: Object.fromEntries((args.p_keys as string[]).map(value => [value, true])),
        });
        if (name === "background_video_delivery") return reply({
          kind: "registered_background_video", asset_id: asset, bytes: size,
          sha256: "b".repeat(64), max_object_bytes: REGISTERED_BACKGROUND_BYTES,
        });
      }
      const table = path.split("/").at(-1);
      if (table === "profiles") return reply({ id: actor });
      if (table === "deletion_requests") return reply([]);
      if (table === "listings") return reply({ id: listing, org_id: org, deleted_at: null });
      if (table === "private_ai_outputs") return reply(null);
      if (table === "capture_assets") return reply({
        id: asset, listing_id: listing, bucket: "renders",
        storage_key: selectedKey, uploaded: true,
      });
      throw new Error(`Unexpected fixture request: ${path}`);
    };
    const make = async (bytes: number, objectKey = key) => {
      selectedKey = objectKey;
      const url = await privateMediaUrl({ actor, org, listing, bucket: "renders", key: objectKey });
      const cap = new URL(url).pathname.slice("/private-media/".length);
      const response = await handler(new Request("https://private-large.fixture.invalid/tours/private-media", {
        method: "POST",
        headers: { "X-Rendprop-Media-Gateway": "d".repeat(64), "Content-Type": "application/json" },
        body: JSON.stringify({ cap, bytes }),
      }));
      return { status: response.status, body: await response.json() };
    };

    const registered = await make(size);
    assertEquals(registered.status, 200, JSON.stringify(calls));
    assertEquals(registered.body.objects, { [key]: "renders" });
    assertEquals(registered.body.object_limits[key], {
      kind: "registered_background_video", asset_id: asset, bytes: size,
      sha256: "b".repeat(64), max_object_bytes: REGISTERED_BACKGROUND_BYTES,
    });
    assertEquals(calls.filter(call => call.name === "background_video_delivery")
      .map(call => call.args.p_bytes), [size]);
    assertEquals(calls[0].name, "library_media_delivery_admit");

    const beforeOrdinary = calls.length;
    const ordinary = await make(size, `renders/${org}/${listing}/ordinary.mp4`);
    assertEquals(ordinary.status, 403);
    assert(!JSON.stringify(ordinary.body).includes("ordinary.mp4"));
    assertEquals(calls.slice(beforeOrdinary).filter(call => call.name === "background_video_delivery").length, 0);

    const beforeOversize = calls.length;
    const oversize = await make(REGISTERED_BACKGROUND_BYTES + 1);
    assertEquals(oversize.status, 400);
    assertEquals(calls.length, beforeOversize);
  } finally {
    globalThis.fetch = previousFetch;
    for (const [index, name] of names.entries()) {
      const value = prior[index];
      if (value === undefined) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  }
});
