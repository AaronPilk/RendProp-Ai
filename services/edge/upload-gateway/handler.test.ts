import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  GatewayDependencies,
  GatewayOperation,
  handleUpload,
} from "./handler.ts";
import {
  TransportError,
  uploadCapability,
} from "../../supabase/functions/uploads/gateway_contract.ts";

const ID = "00000000-0000-4000-8000-000000000037",
  ASSET = "00000000-0000-4000-8000-000000000038";
const ORIGIN = "https://upload-fixture.invalid",
  SECRET = "synthetic-upload-capability-fixture-not-real";
class Fixture implements GatewayDependencies {
  origin = ORIGIN;
  allowedOrigin = ORIGIN;
  secret = SECRET;
  now = () => 1000;
  state = "planned";
  claims = 0;
  writes = 0;
  bytes = 0;
  commits = 0;
  spent = 0;
  finishCalls: string[] = [];
  failClaim = false;
  failFinish = false;
  failWrite = false;
  beforeWrite?: () => Promise<void>;
  op: GatewayOperation = {
    id: ID,
    asset_id: ASSET,
    kind: "single",
    bucket: "uploads",
    object_key: "_staging/uploads/fixture.mov",
    upload_id: null,
    part: 0,
    bytes: 4,
    content_type: "video/quicktime",
    content_type_declared: true,
    asset_kind: "video",
    dispatch: true,
    etag: null,
  };
  async claim() {
    this.claims++;
    if (this.failClaim) throw new Error("synthetic unavailable SQL");
    if (this.state === "stored") {
      return { ...this.op, dispatch: false, etag: '"fixture"' };
    }
    if (this.state !== "planned") {
      throw new TransportError(503, "Already claimed");
    }
    this.state = "dispatching";
    this.spent += this.op.bytes;
    return { ...this.op };
  }
  async finish(_id: string, _claim: string, result: string) {
    this.finishCalls.push(result);
    if (this.failFinish) throw new Error("synthetic lost SQL response");
    this.state = result;
  }
  fixedStream() {
    return new TransformStream<Uint8Array, Uint8Array>();
  }
  async write(_op: GatewayOperation, body: ReadableStream<Uint8Array>) {
    this.writes++;
    const reader = body.getReader();
    try {
      await this.beforeWrite?.();
      if (this.failWrite) throw new Error("synthetic R2 unavailable");
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        this.bytes += next.value.length;
        // An intentionally aggressive sink commits as soon as it has exactly N,
        // before EOF. Even this sink must never commit an invalid body's prefix.
        if (this.bytes === 4) this.commits++;
      }
      return '"fixture"';
    } finally {
      await reader.cancel().catch(() => {});
      reader.releaseLock();
    }
  }
  async request(
    chunks: number[],
    headers: Record<string, string> = { "content-type": "video/quicktime" },
  ) {
    const body = new ReadableStream<Uint8Array>({
      start(c) {
        for (const n of chunks) c.enqueue(new Uint8Array(n));
        c.close();
      },
    });
    return new Request(await uploadCapability(ORIGIN, SECRET, ID, 2000), {
      method: "PUT",
      headers,
      body,
    });
  }
}
for (const chunks of [[4], [1, 3], [1, 1, 1, 1]]) {
  Deno.test(`gateway exact upload ${chunks}`, async () => {
    const f = new Fixture(),
      response = await handleUpload(await f.request(chunks), f);
    assertEquals(response.status, 200);
    assertEquals(response.headers.get("etag"), '"fixture"');
    assertEquals([f.writes, f.bytes, f.commits, f.spent], [1, 4, 1, 4]);
    assertEquals(f.state, "stored");
  });
}
for (const chunks of [[5], [4, 1], [3, 2], [3], []]) {
  Deno.test(`gateway rejects invalid body without committing prefix ${chunks}`, async () => {
    const f = new Fixture(),
      response = await handleUpload(await f.request(chunks), f);
    assert([400, 413].includes(response.status));
    assertEquals(f.commits, 0);
    assert(f.bytes < 4);
    assertEquals(
      f.spent,
      4,
      "Uncertain external work is never refunded by the HTTP handler",
    );
    assertEquals((await handleUpload(await f.request([4]), f)).status, 503);
    assertEquals(f.writes, 1);
  });
}
Deno.test("gateway replay returns receipt without forwarding replacement bytes", async () => {
  const f = new Fixture();
  assertEquals((await handleUpload(await f.request([4]), f)).status, 200);
  assertEquals((await handleUpload(await f.request([64]), f)).status, 200);
  assertEquals([f.writes, f.commits, f.spent], [1, 1, 4]);
});
Deno.test("gateway concurrent calls dispatch once", async () => {
  const f = new Fixture();
  let release!: () => void;
  const gate = new Promise<void>((done) => release = done);
  f.beforeWrite = () => gate;
  const requests = await Promise.all(
    Array.from({ length: 8 }, () => f.request([4])),
  );
  const pending = Promise.all(requests.map((r) => handleUpload(r, f)));
  const deadline = Date.now() + 1000;
  try {
    while (f.claims < 8 && Date.now() < deadline) {
      await new Promise((done) => setTimeout(done, 0));
    }
    assertEquals(f.claims, 8);
  } finally {
    release();
  }
  const responses = await pending;
  assertEquals(responses.filter((r) => r.status === 200).length, 1);
  assertEquals(responses.filter((r) => r.status === 503).length, 7);
  assertEquals([f.writes, f.spent], [1, 4]);
});
for (const failure of ["failClaim", "failFinish", "failWrite"] as const) {
  Deno.test(`gateway ${failure} fails closed`, async () => {
    const f = new Fixture();
    f[failure] = true;
    assertEquals((await handleUpload(await f.request([4]), f)).status, 503);
    assertEquals((await handleUpload(await f.request([4]), f)).status, 503);
    assertEquals(f.writes, failure === "failClaim" ? 0 : 1);
    assertEquals(f.spent, failure === "failClaim" ? 0 : 4);
  });
}
Deno.test("gateway invalid configuration or signature reaches no state or storage service", async () => {
  for (const mode of ["origin", "secret", "signature"]) {
    const f = new Fixture();
    let request = await f.request([4]);
    if (mode === "origin") f.allowedOrigin = "https://different.invalid";
    if (mode === "secret") f.secret = "";
    if (mode === "signature") {
      const url = new URL(request.url);
      url.searchParams.set("signature", "0".repeat(64));
      request = new Request(url, request);
    }
    assert((await handleUpload(request, f)).status >= 400);
    assertEquals([f.claims, f.writes, f.spent], [0, 0, 0]);
  }
});
Deno.test("gateway bounds Content-Length and rejects compressed/mismatched media before storage", async () => {
  const cases: Record<string, string>[] = [
    { "content-length": "67108865" },
    { "content-length": "5" },
    { "content-encoding": "gzip" },
    { "content-type": "text/html" },
  ];
  for (const headers of cases) {
    const f = new Fixture(),
      response = await handleUpload(await f.request([4], headers), f);
    assert([400, 413].includes(response.status));
    assertEquals(f.writes, 0);
  }
});
