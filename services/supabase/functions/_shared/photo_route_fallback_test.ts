// Execute the real router + chain against a filtering PostgREST transport.
// No provider call, credentials or external request leaves this process.
import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { RouteContext, RouteStep } from "./router.ts";
Deno.env.set("SUPABASE_URL", "https://photo-router.invalid");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-only-service-role");
Deno.env.set("SUPABASE_ANON_KEY", "test-only-anon");
const { resolveRoute, resetRouterCache } = await import("./router.ts");
const { resolveChain } = await import("./providers/chain.ts");
const { HttpError } = await import("./http.ts");
const TASKS = [
  "photo.sky",
  "photo.twilight",
  "photo.lawn",
  "photo.declutter",
  "photo.stage",
  "photo.custom",
];
function row(task: string, overrides: Record<string, unknown> = {}) {
  return {
    id: `active-${task}`,
    task,
    position: 2,
    provider: "gemini",
    model: "gemini-3.1-flash-image",
    unit: "image",
    unit_cents: 6.7,
    capabilities: ["prompt-edit", "fidelity"],
    max_latency_s: 60,
    min_plan: "free",
    same_model_as: null,
    privacy_tier: "retained_30d",
    enabled: true,
    retire_after: null,
    params: null,
    note: "legacy",
    ...overrides,
  };
}
const fallback = {
  ...row("photo.sky"),
  route_id: "hardcoded-bypass",
} as RouteStep;
const context: RouteContext = {
  plan: "free",
  needs: ["prompt-edit"],
  carries_customer_media: true,
};
async function transport(
  enabled: boolean,
  rows: ReturnType<typeof row>[],
  run: (seen: URL[]) => Promise<void>,
  error: "routes" | "all" | null = null,
) {
  const original = globalThis.fetch;
  const before = JSON.stringify(rows);
  const seen: URL[] = [];
  globalThis.fetch = ((input: string | URL | Request) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    seen.push(url);
    let body: unknown;
    if (url.pathname.endsWith("/app_config")) body = { value: { enabled } };
    else if (url.pathname.endsWith("/ai_routes")) {
      if (
        error === "all" || (error === "routes" && !url.searchParams.has("note"))
      ) {
        return Promise.resolve(
          new Response(
            JSON.stringify({ message: "fixture database failure" }),
            { status: 400 },
          ),
        );
      }
      body = rows.filter((r) =>
        [...url.searchParams].every(([key, val]) =>
          !val.startsWith("eq.") ||
          String(r[key as keyof typeof r]) === val.slice(3)
        )
      ).sort((a, b) => a.position - b.position).slice(
        0,
        Number(url.searchParams.get("limit") ?? rows.length),
      );
    } else if (url.pathname.endsWith("/provider_health")) body = [];
    else throw new Error(`Unexpected request: ${url.pathname}`);
    return Promise.resolve(
      new Response(JSON.stringify(body), {
        headers: { "Content-Type": "application/json" },
      }),
    );
  }) as typeof fetch;
  resetRouterCache();
  try {
    await run(seen);
    assertEquals(
      JSON.stringify(rows),
      before,
      "route and blocked-provider fixtures remain immutable",
    );
  } finally {
    globalThis.fetch = original;
    resetRouterCache();
  }
}
for (const flag of [false, true]) {
  for (const task of TASKS) {
    Deno.test(`photo ${task} flag=${flag}: only already-active route at6.7c`, async () => {
      const rows = [
        row(task),
        row(task, {
          id: "disabled-legacy",
          position: 99,
          enabled: false,
          unit_cents: 3.9,
        }),
        row(task, {
          id: "kie",
          position: 0,
          provider: "kie",
          enabled: false,
          privacy_tier: "trains_by_default",
        }),
        row(task, {
          id: "higgsfield",
          position: -1,
          provider: "higgsfield",
          enabled: false,
          privacy_tier: "trains_by_default",
        }),
      ];
      await transport(flag, rows, async (seen) => {
        const taskContext = {
          ...context,
          needs: ["photo.stage", "photo.custom"].includes(task)
            ? ["prompt-edit", "fidelity"]
            : ["prompt-edit"],
        };
        const a = await resolveRoute(task, taskContext),
          b = await resolveChain(task, taskContext, fallback);
        assertEquals(a, b);
        assertEquals(a.length, 1);
        assertEquals(a[0].route_id, `active-${task}`);
        assertEquals(a[0].enabled, true);
        assertEquals(a[0].unit_cents, 6.7);
        for (const q of seen.filter((q) => q.pathname.endsWith("/ai_routes"))) {
          assertEquals(q.searchParams.get("enabled"), "eq.true");
          if (!flag) assertEquals(q.searchParams.get("note"), "eq.legacy");
        }
      });
    });
  }
  for (
    const mode of [
      "missing",
      "disabled-only",
      "retired",
      "plan",
      "capability",
      "privacy",
    ]
  ) {
    Deno.test(`photo flag=${flag}: ${mode} cannot bypass through constants`, async () => {
      const overrides = mode === "disabled-only"
        ? { enabled: false }
        : mode === "retired"
        ? { retire_after: "2000-01-01" }
        : mode === "plan"
        ? { min_plan: "team" }
        : mode === "capability"
        ? { capabilities: [] }
        : mode === "privacy"
        ? { privacy_tier: "trains_by_default" }
        : {};
      await transport(
        flag,
        mode === "missing" ? [] : [row("photo.sky", overrides)],
        async () => {
          assertEquals(await resolveRoute("photo.sky", context), []);
          const err = await assertRejects(
            () => resolveChain("photo.sky", context, fallback),
            HttpError,
          );
          assertEquals(err.status, 503);
        },
      );
    });
  }
  Deno.test(`photo flag=${flag}: unreadable database fails closed`, async () => {
    await transport(flag, [row("photo.sky")], async () => {
      assertEquals(await resolveRoute("photo.sky", context), []);
      await assertRejects(
        () => resolveChain("photo.sky", context, fallback),
        HttpError,
      );
    }, "all");
  });
}
Deno.test("photo flag ON: main read error recovers only enabled eligible exact fallback", async () => {
  await transport(true, [row("photo.stage")], async (seen) => {
    assertEquals(
      (await resolveChain("photo.stage", context, fallback))[0].route_id,
      "active-photo.stage",
    );
    assert(
      seen.some((q) =>
        q.searchParams.get("note") === "eq.legacy" &&
        q.searchParams.get("enabled") === "eq.true"
      ),
    );
  }, "routes");
});
Deno.test("non-photo empty route retains pre-existing hardcoded fallback behavior", async () => {
  await transport(false, [], async () => {
    assertEquals(
      await resolveChain("video.reel_clip", { plan: "free" }, fallback),
      [fallback],
    );
  });
});

let photoHandler: ((req: Request) => Promise<Response>) | undefined;
async function actualPhotoHandler() {
  if (photoHandler) return photoHandler;
  Deno.env.set("GEMINI_API_KEY", "fixture-only-not-a-provider-key");
  const descriptor = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  Object.defineProperty(Deno, "serve", {
    configurable: true,
    value: (handler: typeof photoHandler) => {
      photoHandler = handler;
    },
  });
  try {
    await import("../ai-photo/index.ts");
  } finally {
    Object.defineProperty(Deno, "serve", descriptor);
  }
  assert(photoHandler);
  return photoHandler;
}
for (const flag of [false, true]) {
  for (const edit of ["sky", "constructor", "__proto__", "unknown"]) {
    Deno.test(`actual ai-photo flag=${flag} edit=${edit}: invalid input never charges; missing authorization refunds`, async () => {
      const handler = await actualPhotoHandler();
      const original = globalThis.fetch,
        seen: string[] = [],
        charges: string[] = [],
        refunds: string[] = [];
      const unexpected: string[] = [];
      globalThis.fetch =
        (async (input: string | URL | Request, init?: RequestInit) => {
          const url = new URL(
            input instanceof Request ? input.url : String(input),
          );
          const body = init?.body ? JSON.parse(String(init.body)) : {};
          seen.push(url.pathname);
          let answer: unknown;
          if (url.pathname.endsWith("/auth/v1/user")) {
            answer = { id: "fixture-user", aud: "authenticated" };
          } else if (url.pathname.endsWith("/rpc/active_org_for_user")) {
            answer = "fixture-org";
          } else if (url.pathname.endsWith("/memberships")) {
            answer = { role: "owner" };
          } else if (url.pathname.endsWith("/rpc/org_entitlement")) {
            answer = {
              plan: "pro",
              renders_per_month: 20,
              photo_edits_per_month: 100,
              reels_per_month: 20,
              aerials_per_month: 5,
              topaz_per_month: 1,
              seats: 1,
              cogs_ceiling_cents: 2000,
              price_cents: 7900,
            };
          } else if (url.pathname.endsWith("/rpc/bump_rate")) {
            charges.push(body.p_key);
            answer = true;
          } else if (url.pathname.endsWith("/rpc/refund_rate")) {
            refunds.push(body.p_key);
            answer = true;
          } else if (url.pathname.endsWith("/app_config")) {
            answer = { value: { enabled: flag } };
          } else if (url.pathname.endsWith("/ai_routes")) answer = [];
          else {
            unexpected.push(url.href);
            throw new Error(`Unexpected external boundary ${url.pathname}`);
          }
          return new Response(JSON.stringify(answer), {
            headers: { "Content-Type": "application/json" },
          });
        }) as typeof fetch;
      resetRouterCache();
      try {
        const result = await handler(
          new Request("https://photo-router.invalid/functions/v1/ai-photo", {
            method: "POST",
            headers: {
              "Authorization": "Bearer fixture-user-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              edit,
              image_b64: "c3ludGhldGlj",
              mime: "image/jpeg",
            }),
          }),
        );
        assertEquals(result.status, edit === "sky" ? 503 : 400);
        assertEquals(
          (await result.json()).code,
          edit === "sky" ? "upstream" : "validation",
        );
        assertEquals(
          charges.sort(),
          edit === "sky"
            ? ["aiphoto:fixture-org", "aiphotomo:fixture-org"]
            : [],
        );
        assertEquals(refunds.sort(), charges);
        assertEquals(
          unexpected,
          [],
          "no provider, cost ledger or provenance call occurs",
        );
        assertEquals(seen.includes("/rest/v1/ai_routes"), edit === "sky");
      } finally {
        globalThis.fetch = original;
        resetRouterCache();
      }
    });
  }
}

for (const flag of [false, true]) {
  for (
    const task of ["photo.constructor", "photo.__proto__", "photo.future_tool"]
  ) {
    for (const disabledOnly of [false, true]) {
      Deno.test(`photo namespace ${task} flag=${flag} disabledOnly=${disabledOnly}: no constants bypass`, async () => {
        await transport(
          flag,
          disabledOnly ? [row(task, { enabled: false })] : [],
          async () => {
            assertEquals(await resolveRoute(task, context), []);
            const e = await assertRejects(
              () => resolveChain(task, context, fallback),
              HttpError,
            );
            assertEquals(e.status, 503);
          },
        );
      });
    }
  }
}
