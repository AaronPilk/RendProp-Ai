// Actual handler + adapter + monetary quote, with all transports replaced and
// network denied. The compact vendor answer must never become the client wire.
import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { MAX_AGENT_REEL_TOKENS, planWindows } from "./agentreel.ts";
import type { RouteStep } from "../_shared/router.ts";

Deno.env.set("SUPABASE_URL", "https://agent-reel-fixture.invalid");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "fixture-not-a-key");
Deno.env.set("SUPABASE_ANON_KEY", "fixture-not-a-key");
Deno.env.set("OPENAI_API_KEY", "fixture-not-a-key");
Deno.env.set("ANTHROPIC_API_KEY", "fixture-not-a-key");
const { textAttemptQuote } = await import("../_shared/funded-serving.ts");
let handler: (req: Request) => Promise<Response>;
const serve = Deno.serve;
Deno.serve = ((fn: typeof handler) => {
  handler = fn;
  return {};
}) as typeof Deno.serve;
try {
  await import("./index.ts");
} finally {
  Deno.serve = serve;
}
const { resetRouterCache } = await import("../_shared/router.ts");

const actor = "00000000-0000-4000-8000-000000000001";
const org = "00000000-0000-4000-8000-000000000002";
const photos = Array.from({ length: 20 }, (_, i) => ({
  id: `00000000-0000-4000-8000-${String(i + 10).padStart(12, "0")}`,
  room: i % 2 ? "Kitchen" : "Backyard",
}));
const transcript = Array.from(
  { length: 60 },
  (_, i) => ({ t: i * 3, text: "The kitchen opens onto the deck." }),
);
const windows = planWindows(transcript, 180, photos.length);
const compact = (caption = "") =>
  JSON.stringify({
    w: windows.map((w, i) => [w.window_id, `p${i + 1}`, caption]),
  });

async function execute(
  options: {
    provider?: "openai" | "anthropic";
    cap?: number;
    raw?: string;
    firstRaw?: string;
    incomplete?: boolean;
  } = {},
) {
  const provider = options.provider ?? "openai";
  const cap = options.cap ?? 700;
  const step: RouteStep = {
    route_id: "synthetic-agent-reel",
    task: "copy.agent_reel",
    provider,
    model: provider === "openai" ? "gpt-6-astra" : "claude-sonnet-5",
    unit: "call",
    unit_cents: 3.7,
    capabilities: ["text", "compliant"],
    max_latency_s: 60,
    min_plan: "pro",
    same_model_as: null,
    privacy_tier: "retained_30d",
    enabled: true,
    ...{ params: { effort: "low", max_output_tokens: cap } },
  };
  const requests: Record<string, unknown>[] = [];
  const holds: Record<string, unknown>[] = [];
  const finishes: Record<string, unknown>[] = [];
  const ledger: Record<string, unknown>[] = [];
  const original = globalThis.fetch;
  resetRouterCache();
  globalThis.fetch =
    (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      const rawBody = typeof init?.body === "string"
        ? init.body
        : input instanceof Request
        ? await input.clone().text()
        : "";
      const args = rawBody ? JSON.parse(rawBody) : {};
      if (
        url.hostname === "api.openai.com" ||
        url.hostname === "api.anthropic.com"
      ) {
        assertEquals(
          url.href,
          provider === "openai"
            ? "https://api.openai.com/v1/responses"
            : "https://api.anthropic.com/v1/messages",
        );
        assert(
          holds.length === requests.length + 1,
          "every real adapter POST must follow its own funded reservation",
        );
        requests.push(args);
        const text = requests.length === 1 && options.firstRaw !== undefined ? options.firstRaw : options.raw ?? compact();
        return Response.json(
          provider === "openai"
            ? {
              status: options.incomplete ? "incomplete" : "completed",
              incomplete_details: options.incomplete
                ? { reason: "max_output_tokens" }
                : null,
              output_text: text,
            }
            : { content: [{ type: "text", text }], stop_reason: "end_turn" },
        );
      }
      assertEquals(
        url.hostname,
        "agent-reel-fixture.invalid",
        "no unmocked provider or backend can leave the process",
      );
      if (url.pathname === "/auth/v1/user") {
        return Response.json({ id: actor, is_anonymous: false });
      }
      const name = url.pathname.split("/").at(-1)!;
      if (url.pathname.includes("/rpc/")) {
        if (name === "workspace_directory") {
          assertEquals(args.p_user, actor);
          assertEquals(args.p_preferred_org, org);
          return Response.json({actor_id:actor,active_org_id:org,own_org_id:org,billing_org_id:org,
            can_switch_agent_libraries:false,workspaces:[{id:org,name:"Agent reel fixture",role:"owner",
              access_mode:"own",library_owner_user_id:actor,billing_org_id:org,can_read:true,can_write:true}]});
        }
        if (name === "library_access") {
          assertEquals(args,{p_actor:actor,p_org:org});
          return Response.json({actor_id:actor,org_id:org,library_owner_user_id:actor,role:"owner",
            access_mode:"own",can_read:true,can_write:true,can_manage_subscription:true,billing_org_id:org,team_org_id:null});
        }
        if (name === "org_entitlement") {
          return Response.json({
            plan: "pro",
            renders_per_month: 10,
            photo_edits_per_month: 200,
            reels_per_month: 12,
            aerials_per_month: 4,
            topaz_per_month: 0,
            seats: 1,
            cogs_ceiling_cents: 2400,
            price_cents: 9900,
          });
        }
        if (name === "bump_rate") return Response.json(true);
        if (name === "serving_operation_begin") {
          return Response.json({ begun: true });
        }
        if (name === "serving_cost_reserve") {
          holds.push(args);
          return Response.json({ reserved: true });
        }
        if (name === "serving_cost_finish") {
          finishes.push(args);
          return Response.json({ finished: true });
        }
        if (
          [
            "report_provider_outcome",
            "serving_operation_complete",
            "serving_operation_no_dispatch",
          ].includes(name)
        ) return Response.json({ saved: true });
        throw new Error(`Unexpected synthetic RPC ${name}`);
      }
      if (name === "memberships") {
        return Response.json({ org_id: org, role: "owner" });
      }
      if (name === "app_config") {
        return Response.json({ value: { enabled: true } });
      }
      if (name === "plan_routing_policy") {
        return Response.json([{ plan: "pro", policy: "best" }]);
      }
      if (name === "provider_health") return Response.json([]);
      if (name === "ai_routes") {
        return Response.json([{
          ...step,
          id: step.route_id,
          position: 1,
          params: { effort: "low", max_output_tokens: cap },
          retire_after: null,
        }]);
      }
      if (name === "cost_ledger") { ledger.push(args); return new Response(null, { status: 201 }); }
      throw new Error(`Unexpected synthetic table ${name}`);
    }) as typeof fetch;
  try {
    const response = await handler(
      new Request("https://fixture.invalid/ai-copy/agent-reel", {
        method: "POST",
        headers: {
          Authorization: "Bearer fixture-user",
          "X-Org-Id": org,
          "Idempotency-Key": "fixture-reel-request",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          subject: "listing",
          clip_seconds: 180,
          photos,
          transcript,
          facts: {},
          tone: "punchy",
        }),
      }),
    );
    return {
      response,
      body: await response.json(),
      requests,
      holds,
      finishes,
      ledger,
      step,
    };
  } finally {
    globalThis.fetch = original;
    resetRouterCache();
  }
}

Deno.test("actual agent-reel handler preserves full12-window client wire and funds Astra700 despite visible500", async () => {
  assertEquals(MAX_AGENT_REEL_TOKENS, 500);
  const result = await execute();
  assertEquals(result.response.status, 200);
  assertEquals(result.requests.length, 1);
  const sent = result.requests[0];
  assertEquals(sent.max_output_tokens, 700);
  assertEquals(sent.reasoning, { effort: "low" });
  const turn = (sent.input as { content: { text: string }[] }[])[0].content[0]
    .text;
  assert(
    !photos.some((p) => turn.includes(p.id)),
    "model sees aliases, never UUIDs",
  );
  const [system, content] = turn.split("\n\n---\n\n");
  const quote = textAttemptQuote(result.step, system, content, 500)!;
  assertEquals(quote, textAttemptQuote(result.step, system, content, 700));
  assertEquals(
    result.holds[0].p_hold_cents,
    Math.ceil(quote.cents * 10000) / 10000,
  );
  assertEquals(
    result.body.cutaways.map((c: { photo_id: string }) => c.photo_id),
    photos.slice(0, 12).map((p) => p.id),
  );
  assertEquals(
    result.body.cutaways.map((
      c: { window_id: string; start: number; end: number },
    ) => [c.window_id, c.start, c.end]),
    windows.map((w) => [w.window_id, w.start, w.end]),
  );
  assertEquals(Object.keys(result.body).sort(), [
    "clip_seconds",
    "covered_seconds",
    "cutaways",
    "face_seconds",
    "model",
    "subject",
  ]);
  assertEquals(result.finishes[0].p_state, "succeeded");
});

Deno.test("actual configured Anthropic fallback900 is quoted and dispatched at900, never caller500", async () => {
  const result = await execute({ provider: "anthropic", cap: 900 });
  assertEquals(result.response.status, 200);
  assertEquals(result.requests[0].max_tokens, 900);
  const system = result.requests[0].system as string;
  const turn =
    (result.requests[0].messages as { content: { text: string }[] }[])[0]
      .content[0].text;
  const quote = textAttemptQuote(result.step, system, turn, 500)!;
  assertEquals(quote, textAttemptQuote(result.step, system, turn, 700));
  assertEquals(
    result.holds[0].p_hold_cents,
    Math.ceil(quote.cents * 10000) / 10000,
  );
});

Deno.test("actual incomplete Astra envelope containing valid compact JSON returns no edit", async () => {
  const result = await execute({ incomplete: true });
  assertEquals(result.response.status, 502);
  assertEquals(result.requests.length, 1);
  assertEquals(result.body.cutaways, undefined);
  assertEquals(result.finishes[0].p_state, "uncertain");
});

for (
  const raw of [
    compact().slice(0, -1),
    compact() + " ".repeat(501),
    JSON.stringify({ w: [["w1", "p1", ""]] }),
    compact().replace('"p1"', '"p01"'),
  ]
) {
  Deno.test(`actual malformed or oversized complete answer is refused (${raw.length})`, async () => {
    const result = await execute({ raw });
    assertEquals(result.response.status, 502);
    assertEquals(result.body.cutaways, undefined);
    assertEquals(
      result.requests.length,
      2,
      "existing bounded copy retry remains two, not an unbounded loop",
    );
    assertEquals(result.holds.length, 2);
  });
}

Deno.test("actual compact captions still pass through the output fair-housing refusal", async () => {
  const result = await execute({ raw: compact("PERFECT FOR FAMILIES") });
  assertEquals(result.response.status, 502);
  assertEquals(result.body.cutaways, undefined);
  assertEquals(result.requests.length, 2);
});

Deno.test("actual retry ledgers every billed call under its own stage, so both holds settle", async () => {
  const result = await execute({ firstRaw: "{}" });
  assertEquals(result.response.status, 200);
  assertEquals(result.holds.map(hold => hold.p_stage), ["copy.agent_reel:initial:0", "copy.agent_reel:retry:0"]);
  assertEquals(result.ledger.length, 2, "the discarded first answer was billed too; its hold must not stay held forever");
  result.ledger.forEach((row, i) => {
    const meta = row.meta as Record<string, unknown>;
    assertEquals(meta.stage, result.holds[i].p_stage);
    assertEquals(meta.request_key, result.holds[i].p_key);
    assertEquals(row.provider, result.holds[i].p_provider);
    assertEquals(row.model, result.holds[i].p_model);
  });
});

Deno.test("actual refused copy still ledgers both billed attempts", async () => {
  const result = await execute({ raw: compact("PERFECT FOR FAMILIES") });
  assertEquals(result.response.status, 502);
  assertEquals(result.holds.length, 2);
  assertEquals(result.ledger.map(row => (row.meta as Record<string, unknown>).stage), result.holds.map(hold => hold.p_stage));
});
