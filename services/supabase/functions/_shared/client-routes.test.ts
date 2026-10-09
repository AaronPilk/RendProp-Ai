// Exercise deployed handlers with synthetic Auth/PostgREST transport only.
import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
const user = "10000000-0000-4000-8000-000000000001",
  org = "20000000-0000-4000-8000-000000000002",
  listing = "30000000-0000-4000-8000-000000000003",
  lead = "40000000-0000-4000-8000-000000000004",
  other = "50000000-0000-4000-8000-000000000005",
  requestId = "60000000-0000-4000-8000-000000000006";
for (
  const [key, value] of Object.entries({
    SUPABASE_URL: "https://client-route-fixture.invalid",
    SUPABASE_ANON_KEY: "synthetic-public",
    SUPABASE_SERVICE_ROLE_KEY: "synthetic-service",
  })
) Deno.env.set(key, value);
type Handler = (req: Request) => Promise<Response>;
let captured!: Handler;
const descriptor = Object.getOwnPropertyDescriptor(Deno, "serve")!;
Object.defineProperty(Deno, "serve", {
  configurable: true,
  writable: true,
  value: (fn: Handler) => {
    captured = fn;
    return {};
  },
});
let listings!: Handler, leads!: Handler, me!: Handler;
try {
  await import("../listings/index.ts");
  listings = captured;
  await import("../leads/index.ts");
  leads = captured;
  await import("../me/index.ts");
  me = captured;
} finally {
  Object.defineProperty(Deno, "serve", descriptor);
}
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
const contact = {
  listing_id: listing,
  org_id: org,
  enabled: true,
  public_card: { name: "Client Agent" },
  recipient_email: "private@fixture.invalid",
  hide_rendprop_branding: true,
  photo_asset_id: null,
  revision: 1,
  updated_at: "2026-10-01T00:00:00Z",
};
async function invoke(
  path: string,
  method = "GET",
  body?: unknown,
  opts: { workspace?: string; unauthenticated?: boolean; marketing?: boolean } =
    {},
) {
  const original = globalThis.fetch,
    seen: { name: string; args: Record<string, unknown> }[] = [];
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init), url = new URL(req.url);
    assertEquals(url.hostname, "client-route-fixture.invalid");
    if (url.pathname === "/auth/v1/user") {
      return reply({
        id: user,
        email: "owner@fixture.invalid",
        is_anonymous: false,
      });
    }
    if (url.pathname === "/rest/v1/deletion_requests") return reply(null);
    if (url.pathname === "/rest/v1/leads") {
      assertEquals(url.searchParams.get("org_id"), `eq.${org}`);
      return reply([{
        id: lead,
        listing_id: listing,
        org_id: org,
        name: "Buyer",
        extra: { preferred_date: "2026-10-03" },
      }]);
    }
    if (url.pathname.startsWith("/rest/v1/rpc/")) {
      const name = url.pathname.split("/").pop()!, args = await req.json();
      seen.push({ name, args });
      if (name === "workspace_directory") {
        assertEquals(args.p_user, user);
        if (args.p_preferred_org && args.p_preferred_org !== org) {
          return reply({ message: "RP403: workspace is unavailable" }, 400);
        }
        return reply({
          actor_id:user,own_org_id:org,billing_org_id:org,can_switch_agent_libraries:false,
          active_org_id: org,
          workspaces: [{
            id: org,
            name: "Photographer",
            role: opts.marketing ? "marketing" : "owner",
            access_mode:"own",library_owner_user_id:user,billing_org_id:org,
            can_read:true,can_write:!opts.marketing,can_manage_subscription:!opts.marketing,
          }],
        });
      }
      if(name === "library_access" || name === "listing_library_scope") {
        assertEquals(args,name === "library_access"?{p_actor:user,p_org:org}:{p_actor:user,p_listing:listing});
        return reply({actor_id:user,org_id:org,library_owner_user_id:user,role:opts.marketing?"marketing":"owner",access_mode:"own",can_read:true,can_write:!opts.marketing,can_manage_subscription:!opts.marketing,billing_org_id:org,team_org_id:null,...(name === "listing_library_scope"?{listing_id:listing,library_org_id:org,listing_owner_user_id:user}:{})});
      }
      if(name === "lead_library_scope") {
        assertEquals(args,{p_actor:user,p_lead:lead});
        return reply({actor_id:user,lead_id:lead,listing_id:listing,org_id:org,library_org_id:org});
      }
      if(name === "list_library_leads") {
        assertEquals(args,{p_actor:user,p_org:org,p_limit:200,p_since:null,p_status:null,p_listing:null});
        return reply([{id:lead,listing_id:listing,org_id:org,library_org_id:org,name:"Buyer",extra:{preferred_date:"2026-10-03"}}]);
      }
      if (
        name === "listing_client_contact_get" ||
        name === "listing_client_contact_put"
      ) {
        assertEquals(args.p_user, user);
        assertEquals(args.p_org, org);
        assertEquals(args.p_listing, listing);
        if (name.endsWith("put") && opts.marketing) {
          return reply({
            message: "RP403: your role does not permit editing client delivery",
          }, 400);
        }
        return reply(contact);
      }
      if (name === "set_real_estate_role") {
        assertEquals(args.p_user, user);
        return reply({ id: user, real_estate_role: args.p_role });
      }
      if (name === "client_lead_resend") {
        assertEquals(args, {
          p_user: user,
          p_org: org,
          p_lead: lead,
          p_request: requestId,
          p_expected_email: "private@fixture.invalid",
        });
        if (opts.marketing) {
          return reply({
            message: "RP403: your role does not permit editing client delivery",
          }, 400);
        }
        return reply({
          ok: true,
          delivery: {
            state: "queued",
            recipient_email: "private@fixture.invalid",
            can_resend: false,
          },
        });
      }
      if (name === "client_lead_delivery_list") {
        assertEquals(args, { p_user: user, p_org: org, p_leads: [lead] });
        return reply({
          [lead]: {
            state: "skipped",
            recipient_email: null,
            current_recipient_email: "private@fixture.invalid",
            last_attempt_at: null,
            can_resend: !opts.marketing,
          },
        });
      }
    }
    throw new Error(`Unmodeled request: ${req.method} ${url.pathname}`);
  };
  try {
    const headers: Record<string, string> = {
      "x-org-id": opts.workspace ?? org,
    };
    if (!opts.unauthenticated) {
      headers.authorization = "Bearer verified-fixture";
    }
    const result = await (path.startsWith("listings")
      ? listings
      : path.startsWith("leads")
      ? leads
      : me)(
        new Request(`https://app.fixture.invalid/${path}`, {
          method,
          headers,
          ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        }),
      );
    return { status: result.status, body: await result.json(), seen };
  } finally {
    globalThis.fetch = original;
  }
}
Deno.test("actual client contact routes use verified identity and explicit workspace", async () => {
  const get = await invoke(`listings/${listing}/client-contact`);
  assertEquals(get.status, 200);
  assertEquals(get.body.contact, contact);
  const put = await invoke(`listings/${listing}/client-contact`, "PUT", {
    expected_revision: 0,
    enabled: true,
    public_card: { name: "Client Agent" },
    recipient_email: "private@fixture.invalid",
    hide_rendprop_branding: true,
  });
  assertEquals(put.status, 200);
  assert(
    put.seen.some((r) =>
      r.name === "listing_client_contact_put" &&
      r.args.p_expected_revision === 0
    ),
  );
});
Deno.test("actual client routes reject absent auth, foreign workspace, malformed scope and marketing writes", async () => {
  for (
    const opts of [{ unauthenticated: true }, { workspace: other }, {
      workspace: "not-a-workspace",
    }]
  ) {
    const r = await invoke(
      `listings/${listing}/client-contact`,
      "GET",
      undefined,
      opts,
    );
    assert([400, 401, 403, 404].includes(r.status));
    assert(!r.seen.some((x) => x.name === "listing_client_contact_get"));
  }
  const r = await invoke(`listings/${listing}/client-contact`, "PUT", {
    expected_revision: 1,
    enabled: true,
    public_card: { name: "Client Agent" },
    recipient_email: "private@fixture.invalid",
    hide_rendprop_branding: true,
  }, { marketing: true });
  assertEquals(r.status, 403);
});
Deno.test("actual profile preference route cannot accept a forged user or permission role", async () => {
  const r = await invoke("me/profile", "PATCH", {
    real_estate_role: "photographer_videographer",
  });
  assertEquals(r.status, 200);
  assertEquals(r.body, {
    ok: true,
    user: { id: user, real_estate_role: "photographer_videographer" },
  });
  for (
    const body of [{ real_estate_role: "admin" }, {
      real_estate_role: "agent",
      user_id: other,
    }]
  ) {
    const denied = await invoke("me/profile", "PATCH", body);
    assertEquals(denied.status, 400);
    assert(!denied.seen.some((x) => x.name === "set_real_estate_role"));
  }
});
Deno.test("actual lead list and manual forwarding use selected workspace and protected current recipient", async () => {
  const get = await invoke("leads");
  assertEquals(get.status, 200);
  assertEquals(
    get.body.leads[0].client_delivery.current_recipient_email,
    "private@fixture.invalid",
  );
  assertEquals(get.body.leads[0].extra.preferred_date, "2026-10-03");
  const body = {
    request_id: requestId,
    expected_recipient_email: "private@fixture.invalid",
  };
  const send = await invoke(`leads/${lead}/send-to-client`, "POST", body);
  assertEquals(send.status, 200);
  assertEquals(send.body.delivery.state, "queued");
  const marketing = await invoke(`leads/${lead}/send-to-client`, "POST", body, {
    marketing: true,
  });
  assertEquals(marketing.status, 403);
  const foreign = await invoke(`leads/${lead}/send-to-client`, "POST", body, {
    workspace: other,
  });
  assertEquals(foreign.status, 404);
  assert(!foreign.seen.some((x) => x.name === "client_lead_resend"));
});
