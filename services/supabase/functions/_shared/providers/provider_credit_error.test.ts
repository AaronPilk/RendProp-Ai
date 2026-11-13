import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { classifyStatus, fetchJson, ProviderError } from "./common.ts";
import { classifyKie } from "./kie.ts";
import { asHttpError } from "./chain.ts";

Deno.test("provider 402 cannot be reported as invalid customer media or an upgrade requirement", async () => {
  assertEquals(classifyStatus(402), "upstream");
  assertEquals(classifyKie(402), "upstream");
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => Response.json({ error: "empty vendor balance", token: "private-fixture-token" }, { status: 402 });
  try {
    const error = await assertRejects(() => fetchJson("fal", "https://queue.fal.run/fixture", { method: "POST" }, 1000), ProviderError);
    assertEquals(error.error_class, "upstream");
    assertEquals(error.dispatch_rejected, true);
    const response = asHttpError(error);
    assertEquals(response.status, 502); assertEquals(response.code, "upstream");
    assertEquals(response.message.includes("private-fixture-token"), false);
    // A receipt still makes dispatch uncertain even when the status says 402.
    globalThis.fetch = async () => Response.json({ request_id: "accepted-fixture" }, { status: 402 });
    const ambiguous = await assertRejects(() => fetchJson("fal", "https://queue.fal.run/fixture", { method: "POST" }, 1000), ProviderError);
    assertEquals(ambiguous.dispatch_rejected, false);
  } finally { globalThis.fetch = originalFetch; }
});
