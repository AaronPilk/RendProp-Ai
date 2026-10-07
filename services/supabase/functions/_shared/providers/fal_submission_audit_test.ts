import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { RouteStep } from "../router.ts";
import { HttpError } from "../http.ts";
import { runChain } from "./chain.ts";
import { falAdapter } from "./fal.ts";
import { ProviderError } from "./common.ts";
import {
  submitReservedVideo,
  VideoDispatchUnconfirmed,
} from "../../ai-video/cost-reservation.ts";
import { PROBES } from "../../admin/probe.ts";

const step: RouteStep = {
  route_id: "synthetic",
  task: "video.reel_clip",
  provider: "fal",
  model: "bytedance/seedance/v1/pro/fast/image-to-video",
  unit: "second",
  unit_cents: 4.8,
  capabilities: ["i2v"],
  max_latency_s: 600,
  min_plan: "pro",
  same_model_as: null,
  privacy_tier: "no_retention",
  enabled: true,
};
const input = {
  task: step.task,
  prompt: "synthetic-private-prompt",
  image_url: "https://private.invalid/input",
  seconds: 5,
};
const receipt = {
  request_id: "synthetic-job",
  status_url:
    "https://queue.fal.run/fal-ai/synthetic/requests/synthetic-job/status",
  response_url: "https://queue.fal.run/fal-ai/synthetic/requests/synthetic-job",
};
const marker = "synthetic-key-body-and-private-url-marker";
async function mocked(
  fn: () => Promise<void>,
  response: (url: string, init?: RequestInit) => Response | Promise<Response>,
) {
  const realFetch = globalThis.fetch,
    realLog = console.error,
    key = Deno.env.get("FAL_KEY");
  const logs: unknown[][] = [];
  Deno.env.set("FAL_KEY", "synthetic-key-not-a-credential");
  globalThis.fetch =
    ((url: string | URL | Request, init?: RequestInit) => {
      const target = String(url instanceof Request ? url.url : url);
      // The full edge suite can initialize the shared, cached Supabase client
      // with another fixture's synthetic URL. Telemetry is a separate HTTP
      // boundary: never feed it the provider's canned failure or count it as
      // a vendor dispatch. All networking still remains mocked.
      if (new URL(target).pathname === "/rest/v1/rpc/report_provider_outcome") {
        return Promise.resolve(Response.json(null));
      }
      return Promise.resolve(response(target, init));
    }) as typeof fetch;
  console.error = (...args: unknown[]) => {
    logs.push(args);
  };
  try {
    await fn();
    assert(!JSON.stringify(logs).includes(marker));
  } finally {
    globalThis.fetch = realFetch;
    console.error = realLog;
    key == null ? Deno.env.delete("FAL_KEY") : Deno.env.set("FAL_KEY", key);
  }
}
function deps(
  options: { releaseFails?: boolean; malformedRelease?: boolean } = {},
) {
  const calls: string[] = [];
  return {
    calls,
    rpc: (name: string, args: Record<string, unknown>) => {
      if(name==="serving_cost_reserve")return Promise.resolve({data:{reserved:true},error:null});
      if(name==="serving_cost_finish")return Promise.resolve({data:{finished:true},error:null});
      if(name==="org_has_internal_testing_grant")return Promise.resolve({data:true,error:null});
      calls.push(name);
      if(name==="app_video_cost_reserve_v2"){
        assertEquals(args.p_monthly_window_start,"2026-10-01T00:00:00.123456Z");
        assertEquals(args.p_burst_window_start,"2026-10-05T00:00:00.654321Z");
        assertEquals(args.p_listing,null);
      }
      return Promise.resolve({
        data: name === "app_video_cost_reserve_v2"
          ? { reserved: true }
          : name.endsWith("settle")
          ? { settled: true }
          : options.malformedRelease
          ? {}
          : { released: true },
        error: options.releaseFails && name.includes("release")
          ? { message: "synthetic disconnected" }
          : null,
      });
    },
    submit: (selected: RouteStep) =>
      runChain(step.task, [selected], (s) => falAdapter.submit(s, input)),
  };
}
const options = {
  actorId: "synthetic-actor",
  orgId: "synthetic-org",
  key: "synthetic-logical-tap",
  allowance:{monthlyWindowStart:"2026-10-01T00:00:00.123456Z",burstWindowStart:"2026-10-05T00:00:00.654321Z"},
  feature: "reel" as const,
  steps: [step],
  input,
  seconds: 5,
};

for (const status of [400, 401, 402, 403, 404, 413, 422, 429]) {
  Deno.test(`actual fal submit HTTP${status} is definitively rejected, releases once and retains sanitized status/class`, async () => {
    let posts = 0;
    const d = deps();
    await mocked(async () => {
      const error = await assertRejects(
        () => submitReservedVideo(options, d),
        HttpError,
      );
      assert(!(error instanceof VideoDispatchUnconfirmed));
      assertEquals(error.details?.provider_status, status);
      assertEquals(error.details?.dispatch_rejected, true);
      assert(!JSON.stringify(error).includes(marker));
      assert(!error.message.includes(marker));
      assertEquals(d.calls, [
        "app_video_cost_reserve_v2",
        "app_video_cost_release_rejected",
      ]);
      assertEquals(posts, 1);
    }, (url, init) => {
      if (url.startsWith("https://queue.fal.run/")) {
        assertEquals(init?.method, "POST");
        posts++;
        return Response.json({ detail: marker }, { status });
      }
      return Response.json(null);
    });
  });
}
for (const status of [408, 409, 425, 500, 503, 504]) {
  Deno.test(`actual fal submit HTTP${status} remains uncertain, never releases or submits fallback`, async () => {
    let posts = 0;
    const d = deps();
    await mocked(async () => {
      await assertRejects(
        () =>
          submitReservedVideo({
            ...options,
            steps: [step, { ...step, provider: "kie" }],
          }, d),
        VideoDispatchUnconfirmed,
      );
      assertEquals(d.calls, ["app_video_cost_reserve_v2"]);
      assertEquals(posts, 1);
    }, (url) => {
      if (url.startsWith("https://queue.fal.run/")) {
        posts++;
        return Response.json({ detail: marker }, { status });
      }
      return Response.json(null);
    });
  });
}
for (
  const body of [{}, {
    request_id: 5,
    status_url: receipt.status_url,
    response_url: receipt.response_url,
  }, { request_id: "synthetic-job" }]
) {
  Deno.test(`2xx acceptance without usable receipt remains held: ${JSON.stringify(body)}`, async () => {
    const d = deps();
    await mocked(async () => {
      await assertRejects(
        () => submitReservedVideo(options, d),
        VideoDispatchUnconfirmed,
      );
      assertEquals(d.calls, ["app_video_cost_reserve_v2"]);
    }, () => Response.json(body));
  });
}
Deno.test("4xx carrying a job receipt remains held despite the HTTP failure", async () => {
  const d = deps();
  await mocked(
    async () => {
      await assertRejects(
        () => submitReservedVideo(options, d),
        VideoDispatchUnconfirmed,
      );
      assertEquals(d.calls, ["app_video_cost_reserve_v2"]);
    },
    () =>
      Response.json({ request_id: "possibly-existing-job", detail: marker }, {
        status: 422,
      }),
  );
});
Deno.test("transport timeout remains held without fallback or allowance-release evidence", async () => {
  const d = deps();
  await mocked(async () => {
    await assertRejects(
      () => submitReservedVideo(options, d),
      VideoDispatchUnconfirmed,
    );
    assertEquals(d.calls, ["app_video_cost_reserve_v2"]);
  }, () => {
    throw new DOMException(marker, "TimeoutError");
  });
});
Deno.test("actual accepted fal receipt settles once", async () => {
  const d = deps();
  await mocked(
    async () => {
      assertEquals(
        (await submitReservedVideo(options, d)).value.id,
        receipt.request_id,
      );
      assertEquals(d.calls, [
        "app_video_cost_reserve_v2",
        "app_video_cost_settle",
      ]);
    },
    (url) =>
      url.startsWith("https://queue.fal.run/")
        ? Response.json(receipt)
        : Response.json(null),
  );
});
for (const patch of [{ releaseFails: true }, { malformedRelease: true }]) {
  Deno.test(`unconfirmed release retains hold and allowance: ${JSON.stringify(patch)}`, async () => {
    const d = deps(patch);
    await mocked(async () => {
      await assertRejects(
        () => submitReservedVideo(options, d),
        VideoDispatchUnconfirmed,
      );
      assertEquals(d.calls, [
        "app_video_cost_reserve_v2",
        "app_video_cost_release_rejected",
      ]);
    }, () => Response.json({ detail: marker }, { status: 403 }));
  });
}
for (
  const payload of [{ status: "COMPLETED", error: marker }, {
    status: "COMPLETED",
    error_type: "INTERNAL_ERROR",
  }]
) {
  Deno.test("actual fal COMPLETED with failure returns failed and skips the result GET", async () => {
    let gets = 0;
    await mocked(async () => {
      const state = await falAdapter.poll({
        id: receipt.request_id,
        provider: "fal",
        model: step.model,
        poll_url: receipt.status_url,
        submitted_at: new Date().toISOString(),
      });
      assertEquals(state.status, "failed");
      assertEquals(gets, 1);
      assert(!JSON.stringify(state).includes(marker));
    }, () => {
      gets++;
      return Response.json(payload);
    });
  });
}
for (const status of [422]) {
  Deno.test(`completed fal result HTTP${status} returns failed, not thrown poll502`, async () => {
    await mocked(
      async () => {
        const state = await falAdapter.poll({
          id: receipt.request_id,
          provider: "fal",
          model: step.model,
          poll_url: receipt.status_url,
          submitted_at: new Date().toISOString(),
        });
        assertEquals(state.status, "failed");
        assert(!JSON.stringify(state).includes(marker));
      },
      (url) =>
        url.includes("/status")
          ? Response.json({
            status: "COMPLETED",
            response_url: receipt.response_url,
          })
          : Response.json({ detail: marker }, { status }),
    );
  });
}
for (const status of [408, 429, 500, 503]) {
  Deno.test(`completed fal result HTTP${status} retains the accepted job for retrieval`, async () => {
    let resultGets = 0, posts = 0;
    await mocked(async () => {
      const ref = { id: receipt.request_id, provider: "fal", model: step.model,
        poll_url: receipt.status_url, submitted_at: new Date().toISOString() };
      const error = await assertRejects(() => falAdapter.poll(ref), ProviderError);
      assertEquals(error.status, status);
      assert(!error.message.includes(marker));
      const result = await falAdapter.poll(ref);
      assertEquals(result.status, "done");
      assertEquals(resultGets, 2);
      assertEquals(posts, 0);
    }, (url, init) => {
      if (init?.method === "POST") posts++;
      if (url.includes("/status")) return Response.json({status:"COMPLETED",response_url:receipt.response_url});
      resultGets++;
      return resultGets === 1 ? Response.json({detail:marker},{status})
        : Response.json({video:{url:"https://synthetic.invalid/retained.mp4"}});
    });
  });
}
Deno.test("actual fal catalog authentication never asserts generation is available", async () => {
  await mocked(async () => {
    const probe = PROBES.find((p) => p.key === "fal")!;
    const result = await probe.run(AbortSignal.timeout(1000));
    assertEquals(result.ok, null);
    assertEquals(result.detail?.key_authenticated, 1);
    assertEquals(result.detail?.generation_verified, 0);
  }, () => Response.json({ models: [{ id: "synthetic" }] }));
});
Deno.test("missing fal secret is an explicit before-dispatch rejection with zero HTTP calls", async () => {
  const d = deps();
  let calls = 0;
  await mocked(async () => {
    Deno.env.delete("FAL_KEY");
    const error = await assertRejects(
      () => submitReservedVideo(options, d),
      HttpError,
    );
    assert(!(error instanceof VideoDispatchUnconfirmed));
    assertEquals(error.details?.provider_status, 0);
    assertEquals(d.calls, [
      "app_video_cost_reserve_v2",
      "app_video_cost_release_rejected",
    ]);
    assertEquals(calls, 0);
  }, () => {
    calls++;
    return Response.json(null);
  });
});
Deno.test("unsupported fal input is rejected before any HTTP call", async () => {
  const d = deps();
  let calls = 0;
  await mocked(async () => {
    const error = await assertRejects(
      () =>
        submitReservedVideo({
          ...options,
          steps: [{ ...step, model: "synthetic/unsupported" }],
        }, d),
      HttpError,
    );
    assert(!(error instanceof VideoDispatchUnconfirmed));
    assertEquals(error.details?.provider_status, 0);
    assertEquals(d.calls, [
      "app_video_cost_reserve_v2",
      "app_video_cost_release_rejected",
    ]);
    assertEquals(calls, 0);
  }, () => {
    calls++;
    return Response.json(null);
  });
});
