#!/usr/bin/env node
// Native workerd + local R2 binding test. All outbound HTTP is intercepted;
// no account, provider credentials, remote bucket or package install is used.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { createHash, createHmac, randomUUID } from "node:crypto";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
assert.equal(
  process.argv[2],
  "--modules",
  "Supply an already installed node_modules directory",
);
const fault = process.argv[4] === "--inject-fault" &&
  process.argv[5] === "redirect-error";
assert.ok(
  process.argv.length === 4 || process.argv.length === 6 && fault,
  "Unexpected arguments",
);
const modules = resolve(process.argv[3]);
const require = createRequire(import.meta.url);
const { Miniflare, convertV4MiniflareOptions, Log, LogLevel } = require(
  join(modules, "miniflare"),
);
const { build } = require(join(modules, "esbuild"));
const out = await mkdtemp("/tmp/rendprop-gateway-native-");
const receipt = {
  accepted: false,
  tests: 0,
  failed: 0,
  skipped: 0,
  evidence: out,
  negativeControl: fault ? "redirect-error" : null,
  scope:
    "actual Worker adapter + workerd FixedLengthStream + local R2; synthetic intercepted SQL, no remote storage",
};
const versions = await Promise.all(
  ["miniflare", "workerd", "esbuild"].map(
    async (name) => [
      name,
      JSON.parse(await readFile(join(modules, name, "package.json"), "utf8"))
        .version,
    ],
  ),
);
receipt.versions = Object.fromEntries(versions);
const origin = "https://upload-fixture.invalid",
  stateOrigin = "https://state-fixture.invalid";
const secret = "synthetic-gateway-capability-key-not-production",
  service = "synthetic-state-service-key-not-production";
const operations = new Map();
let dispatches = 0, unexpected = 0;
const rpc = async (request) => {
  const url = new URL(request.url);
  assert.equal(
    url.origin,
    stateOrigin,
    "All outbound requests must remain fixture-local",
  );
  assert.equal(request.headers.get("authorization"), `Bearer ${service}`);
  const args = await request.json(), op = operations.get(args.p_operation);
  const json = (data, status = 200) => Response.json(data, { status });
  if (!op) return json({ message: "RP404: synthetic operation missing" }, 400);
  if (url.pathname === "/rest/v1/rpc/claim_upload_operation") {
    if (op.state === "stored") return json({ ...op, dispatch: false });
    if (op.state !== "planned") {
      return json({ message: "RP503: already dispatched" }, 400);
    }
    op.state = "dispatching";
    op.claim = args.p_claim;
    dispatches++;
    return json({ ...op, dispatch: true });
  }
  if (url.pathname === "/rest/v1/rpc/finish_upload_operation") {
    assert.equal(args.p_claim, op.claim);
    op.state = args.p_result;
    op.etag = args.p_etag;
    op.content_type = args.p_content_type ?? op.content_type;
    return json({ ...op });
  }
  unexpected++;
  throw new Error("Unexpected fixture RPC");
};
const bundled = await build({
  entryPoints: [join(root, "services/edge/upload-gateway/index.ts")],
  bundle: true,
  write: false,
  format: "esm",
  platform: "browser",
  target: "es2022",
  logLevel: "silent",
  plugins: fault
    ? [{
      name: "deliberately-broken-native-redirect",
      setup(api) {
        api.onLoad({ filter: /upload-gateway\/rpc\.ts$/ }, async (args) => {
          const text = await readFile(args.path, "utf8");
          assert.equal(
            text.split('redirect: "manual"').length,
            2,
            "Negative-control anchor changed",
          );
          return {
            contents: text.replace('redirect: "manual"', 'redirect: "error"'),
            loader: "ts",
          };
        });
      },
    }]
    : [],
});
receipt.bundleSHA256 = createHash("sha256").update(bundled.outputFiles[0].text)
  .digest("hex");
const options = convertV4MiniflareOptions({
  name: "upload-fixture",
  script: bundled.outputFiles[0].text,
  modules: true,
  compatibilityDate: "2026-09-10",
  host: "127.0.0.1",
  port: 0,
  cf: false,
  logRequests: false,
  log: new Log(LogLevel.WARN),
  telemetry: { enabled: false },
  isolatedResourcePersistencePath: join(out, "storage"),
  resourceTmpPath: join(out, "runtime"),
  r2Buckets: ["UPLOADS", "RENDERS"],
  outboundService: rpc,
  bindings: {
    UPLOAD_GATEWAY_ORIGIN: origin,
    UPLOAD_GATEWAY_ALLOWED_ORIGIN: origin,
    UPLOAD_CAPABILITY_SECRET: secret,
    SUPABASE_ORIGIN: stateOrigin,
    SUPABASE_ALLOWED_ORIGIN: stateOrigin,
    SUPABASE_SERVICE_ROLE_KEY: service,
  },
});
let runtime;
function operation(kind = "single", uploadId = null) {
  const id = randomUUID(),
    op = {
      id,
      asset_id: randomUUID(),
      kind,
      part: kind === "part" ? 1 : 0,
      bucket: "uploads",
      object_key: kind === "single"
        ? `_staging/uploads/fixture/${id}.mov`
        : `uploads/fixture/${id}.mov`,
      upload_id: uploadId,
      bytes: 4,
      expected_bytes: 4,
      content_type: "video/quicktime",
      content_type_declared: true,
      asset_kind: "video",
      state: "planned",
      etag: null,
    };
  operations.set(id, op);
  return op;
}
function url(op) {
  const expiry = Math.floor(Date.now() / 1000) + 600;
  const signature = createHmac("sha256", secret).update(
    `rendprop-upload-v2\nPUT\n${op.id}\n${expiry}`,
  ).digest("hex");
  return `${origin}/v2/${op.id}?expires=${expiry}&signature=${signature}`;
}
async function put(op, chunks) {
  const body = new ReadableStream({
    start(c) {
      for (const chunk of chunks) c.enqueue(new TextEncoder().encode(chunk));
      c.close();
    },
  });
  return await runtime.dispatchFetch(url(op), {
    method: "PUT",
    headers: { "content-type": "video/quicktime" },
    body,
    duplex: "half",
  });
}
async function bounded(name, run, milliseconds = 15000) {
  let timer;
  try {
    return await Promise.race([
      run(),
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`${name} exceeded ${milliseconds}ms`)),
          milliseconds,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
async function test(name, run) {
  await bounded(name, run);
  receipt.tests++;
  console.log("PASS:", name);
}
console.log("EVIDENCE:", out);
try {
  runtime = new Miniflare(options);
  await bounded("native runtime startup", () => runtime.ready, 20000);
  const bucket = await runtime.getR2Bucket("UPLOADS");
  await test("exact single body uses native FixedLengthStream and R2.put", async () => {
    const op = operation(), response = await put(op, ["A", "AAA"]);
    assert.equal(response.status, 200, await response.text());
    assert.equal((await bucket.get(op.object_key)).size, 4);
    assert.equal(await (await bucket.get(op.object_key)).text(), "AAAA");
    assert.equal(op.state, "stored");
    assert.equal(
      response.headers.get("etag"),
      (await bucket.head(op.object_key)).httpEtag,
    );
  });
  for (const chunks of [["AAAA", "B"], ["AAA"]]) {
    await test(`invalid ${chunks.join(",")} body leaves no native R2 object`, async () => {
      const op = operation(), response = await put(op, chunks);
      assert.ok([400, 413].includes(response.status), await response.text());
      assert.equal(await bucket.head(op.object_key), null);
      assert.equal(op.state, "rejected");
    });
  }
  await test("native replay cannot overwrite stored bytes", async () => {
    const op = operation();
    assert.equal((await put(op, ["AAAA"])).status, 200);
    const before = dispatches;
    assert.equal((await put(op, ["BBBB"])).status, 200);
    assert.equal(dispatches, before);
    assert.equal(await (await bucket.get(op.object_key)).text(), "AAAA");
  });
  await test("native multipart uploadPart yields an assembly-compatible ETag", async () => {
    const op = operation("part");
    const session = await bucket.createMultipartUpload(op.object_key, {
      httpMetadata: { contentType: op.content_type },
    });
    op.upload_id = session.uploadId;
    const response = await put(op, ["AAAA"]);
    assert.equal(response.status, 200, await response.text());
    const etag = response.headers.get("etag");
    assert.ok(etag);
    assert.equal(op.etag, etag);
    await session.complete([{
      partNumber: 1,
      etag: etag.replace(/^"|"$/g, ""),
    }]);
    assert.equal(await (await bucket.get(op.object_key)).text(), "AAAA");
  });
  await test("oversized native multipart body cannot leave a valid first-part prefix", async () => {
    const op = operation("part");
    const session = await bucket.createMultipartUpload(op.object_key);
    op.upload_id = session.uploadId;
    const response = await put(op, ["AAAA", "B"]);
    assert.ok([400, 413].includes(response.status), await response.text());
    assert.equal(op.state, "rejected");
    assert.equal(op.etag, null);
    assert.equal(await bucket.head(op.object_key), null);
    await assert.rejects(() =>
      session.complete([{ partNumber: 1, etag: "not-a-stored-part" }])
    );
  });
  assert.equal(unexpected, 0);
  assert.equal(receipt.tests, 6);
  receipt.accepted = true;
} catch (error) {
  receipt.failed++;
  receipt.operationStates = [...operations.values()].map((op) => ({
    state: op.state,
    kind: op.kind,
  }));
  receipt.dispatches = dispatches;
  throw error;
} finally {
  try {
    if (runtime) {
      await bounded("native runtime disposal", () => runtime.dispose(), 10000);
    }
  } catch (error) {
    receipt.accepted = false;
    receipt.failed++;
    throw error;
  } finally {
    await writeFile(
      join(out, "receipt.json"),
      JSON.stringify(receipt, null, 2) + "\n",
    );
  }
}
console.log(
  "PASS: 6 native runtime scenarios, 0 failures, 0 skips; no remote requests",
);
