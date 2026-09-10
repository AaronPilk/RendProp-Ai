// Diagnostic of the ACTUAL route, not a replacement implementation. No socket
// is opened: Deno.serve is intercepted and every upstream response is synthetic.
// This desired-contract test currently FAILS if a delayed complete can replace
// the object after another complete has committed the asset as uploaded.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

function latch() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => resolve = done);
  return { promise, resolve };
}

Deno.test("a delayed second complete must not replace an already-completed object", async () => {
  const values: Record<string, string> = {
    SUPABASE_URL: "https://upload-fixture.invalid",
    SUPABASE_SERVICE_ROLE_KEY: "fixture-service-key-not-real",
    SUPABASE_ANON_KEY: "fixture-anon-key-not-real",
    CLOUDFLARE_ACCOUNT_ID: "fixture",
    R2_ACCESS_KEY_ID: "fixture-access-key-not-real",
    R2_SECRET_ACCESS_KEY: "fixture-secret-not-real",
  };
  const prior = new Map(Object.keys(values).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(values)) Deno.env.set(key, value);
  const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  const originalFetch = globalThis.fetch;
  let handler: ((request: Request) => Promise<Response>) | undefined;
  Object.defineProperty(Deno, "serve", {
    ...serve,
    value: (callback: (request: Request) => Promise<Response>) => {
      handler = callback;
      return {};
    },
  });
  const firstAtCAS = latch(), secondAtCopy = latch(), permitSecondCopy = latch();
  const key = "uploads/fixture-org/fixture-listing/fixture-asset.jpg";
  const asset: Record<string, unknown> = {
    id: "fixture-asset", listing_id: "fixture-listing", storage_key: key,
    bucket: "uploads", kind: "photo", bytes: 4, uploaded: false,
    upload_id: null, part_size: null, parts_total: null,
    content_type: "image/jpeg", content_type_declared: true,
  };
  let staged: string | null = "AAAA", finalObject: string | null = null;
  let copyCount = 0;
  const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
    status, headers: { "content-type": "application/json" },
  });
  const row = (request: Request, data: unknown) =>
    json(request.headers.get("accept")?.includes("vnd.pgrst.object") ? data : [data]);
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    if (url.hostname === "upload-fixture.invalid") {
      if (url.pathname === "/auth/v1/user") return json({ id: "fixture-user", aud: "authenticated" });
      if (url.pathname === "/rest/v1/memberships") return row(request, { role: "owner" });
      if (url.pathname === "/rest/v1/listings") return row(request, { org_id: "fixture-org" });
      if (url.pathname === "/rest/v1/capture_assets") {
        if (request.method === "GET") return row(request, { ...asset });
        if (request.method === "PATCH") {
          const patch = await request.json();
          if (!asset.uploaded) {
            firstAtCAS.resolve();
            await secondAtCopy.promise;
            Object.assign(asset, patch);
            return row(request, { ...asset });
          }
          return json([]);
        }
      }
    }
    if (url.hostname === "fixture.r2.cloudflarestorage.com") {
      const isStage = url.pathname.includes("/_staging/");
      if (request.method === "HEAD") {
        const bytes = isStage ? staged : finalObject;
        return new Response(null, {
          status: bytes === null ? 404 : 200,
          headers: bytes === null ? {} : {
            "content-length": "4", "content-type": "image/jpeg", etag: `"${bytes}"`,
          },
        });
      }
      if (request.method === "DELETE" && isStage) {
        staged = null;
        return new Response(null, { status: 204 });
      }
      if (request.method === "PUT" && request.headers.has("x-amz-copy-source")) {
        copyCount++;
        const selected = staged;
        assertEquals(request.headers.get("x-amz-copy-source-if-match"), `"${selected}"`);
        if (copyCount === 2) {
          secondAtCopy.resolve();
          await permitSecondCopy.promise;
        }
        // Each copy's source condition holds. The missing condition is on
        // destination publication, not the source ETag checked by R2.
        assertEquals(staged, selected);
        finalObject = selected;
        return new Response("<CopyObjectResult><ETag>fixture</ETag></CopyObjectResult>");
      }
    }
    throw new Error(`Unexpected synthetic request: ${request.method} ${url.hostname}${url.pathname}`);
  };
  const deadline = setTimeout(() => {
    firstAtCAS.resolve(); secondAtCopy.resolve(); permitSecondCopy.resolve();
  }, 5000);
  try {
    await import("../../services/supabase/functions/uploads/index.ts");
    if (!handler) throw new Error("Actual uploads route was not captured");
    const complete = () => handler!(new Request("https://edge.invalid/uploads/fixture-asset/complete", {
      method: "POST", headers: { authorization: "Bearer fixture-user-token", "content-type": "application/json" },
      body: "{}",
    }));
    const first = complete();
    await firstAtCAS.promise;
    staged = "BBBB";
    const second = complete();
    const firstResponse = await first;
    assertEquals(firstResponse.status, 200, await firstResponse.clone().text());
    assertEquals(asset.uploaded, true);
    assertEquals(finalObject, "AAAA");
    permitSecondCopy.resolve();
    const secondResponse = await second;
    assertEquals(secondResponse.status, 200, await secondResponse.clone().text());
    assertEquals(copyCount, 2);
    // Desired immutability invariant: FAIL on current code, even though both
    // source objects individually meet the ticket's byte/type checks.
    assertEquals(finalObject, "AAAA", "Final object was replaced after completion committed");
  } finally {
    clearTimeout(deadline);
    firstAtCAS.resolve(); secondAtCopy.resolve(); permitSecondCopy.resolve();
    globalThis.fetch = originalFetch;
    Object.defineProperty(Deno, "serve", serve);
    for (const [key, value] of prior) {
      if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value);
    }
  }
});
