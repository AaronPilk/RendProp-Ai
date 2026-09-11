// Execute the actual uploads handler with fixture-only fetch/Deno.serve.
// No sockets or real SQL/R2; PostgREST conditional updates are modeled atomically.
import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

export type Row = Record<string, unknown>;
export type ObjectBytes = {
  bytes: number;
  type: string;
  etag: string;
  body: string;
};
type Handler = (request: Request) => Promise<Response>;
let actualHandler: Handler | undefined;
export const TICKET = "uploads/fixture-org/fixture-listing/fixture-asset.mov";
export const PARTS = [{ number: 1, etag: '"AAAA"' }];
export const object = (
  body = "AAAA",
  bytes = 4,
  type = "video/quicktime",
): ObjectBytes => ({ body, bytes, type, etag: `"${body}"` });
export function latch() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => resolve = done);
  return { promise, resolve };
}

export class Fixture {
  asset: Row | null = {
    id: "fixture-asset",
    listing_id: "fixture-listing",
    storage_key: TICKET,
    bucket: "uploads",
    kind: "video",
    bytes: 4,
    uploaded: false,
    upload_aborted: false,
    upload_id: null,
    part_size: null,
    parts_total: null,
    completion_parts: null,
    content_type: "video/quicktime",
    content_type_declared: true,
    transport_version: 2,
  };
  objects = new Map<string, ObjectBytes>([[`_staging/${TICKET}`, object()]]);
  copies: string[] = [];
  copyHeaders: Headers[] = [];
  deletes: string[] = [];
  assemblies: string[] = [];
  charges: Row[] = [];
  unexpected: string[] = [];
  afterHead?: (key: string, snapshot: ObjectBytes | undefined) => Promise<void>;
  beforeCopy?: (key: string) => Promise<void>;
  beforePatch?: (patch: Row) => Promise<void>;
  beforeAssembly?: () => Promise<void>;
  loseCommitResponse = false;
  failCopy = false;
  failAbort = false;
  getCalls = 0;
  assemblyBytes = 4;
  abortedSessions = 0;
  operations = new Map<string, Row>();
  cleanup = new Set<string>();
  partReceipts: Array<{ number: number; etag: string }> | null = null;
  rpcFailures = new Set<string>();
  sessions = new Map<string, string>();
  physicalParts = new Map<number, { bytes: number; etag: string }>();
  failInitializationReply = false;

  operation(kind: string, part = 0): Row {
    const found = [...this.operations.values()].find((op) =>
      op.kind === kind && op.part === part
    );
    if (found) return found;
    const a = this.asset!,
      id = crypto.randomUUID(),
      key = String(a.storage_key),
      dot = key.lastIndexOf(".");
    const op: Row = {
      id,
      asset_id: a.id,
      kind,
      part,
      bucket: a.bucket,
      object_key: kind === "single"
        ? `_staging/${key}`
        : kind === "copy"
        ? `${key.slice(0, dot)}-complete-${id}${key.slice(dot)}`
        : key,
      upload_id: a.upload_id,
      bytes: ["init", "assemble"].includes(kind) ? 0 : a.bytes,
      expected_bytes: a.bytes,
      content_type: a.content_type,
      content_type_declared: a.content_type_declared,
      asset_kind: a.kind,
      expires_at: new Date(Date.now() + 3600000).toISOString(),
      state: kind === "init" && a.upload_id ? "stored" : "planned",
      etag: kind === "init" ? "multipart-initialized" : null,
      claim: null,
    };
    this.operations.set(id, op);
    return op;
  }
  confirmed() {
    const a = this.asset!;
    if (a.parts_total != null) {
      return (this.partReceipts ??
        Array.from(
          { length: Number(a.parts_total) },
          (_, i) => ({
            number: i + 1,
            etag: Number(a.parts_total) === 1 ? '"AAAA"' : `"part-${i + 1}"`,
          }),
        ))
        .map((p) =>
          Object.assign(this.operation("part", p.number), {
            state: "stored",
            etag: p.etag,
            claim: "fixture-dispatched",
          })
        );
    }
    return [
      Object.assign(this.operation("single"), {
        state: "stored",
        etag: '"AAAA"',
        claim: "fixture-dispatched",
      }),
    ];
  }
  async sweep() {
    return await actualHandler!(
      new Request("https://edge.invalid/uploads/sweep", {
        method: "POST",
        headers: { authorization: "Bearer fixture-service" },
      }),
    );
  }
  async rpc(name: string, args: Row): Promise<Response> {
    const json = (data: unknown, status = 200) =>
      Response.json(data, { status });
    const reject = (code: number, message: string) =>
      json({ message: `RP${code}: ${message}` }, 400);
    if (this.rpcFailures.has(name)) {
      return reject(503, "synthetic durable state unavailable");
    }
    const op = this.operations.get(String(args.p_operation));
    if (name === "reserve_upload_assets") {
      const assets = args.p_assets as Row[];
      if (
        this.asset?.idem_key && this.asset.idem_key === assets[0].idem_key &&
        !this.asset.uploaded && !this.asset.upload_aborted
      ) {
        return json([{ ...this.asset, replayed: true }]);
      }
      this.charges.push(args);
      this.asset = {
        uploaded: false,
        upload_aborted: false,
        upload_id: null,
        completion_parts: null,
        transport_version: 2,
        ...assets[0],
      };
      return json(
        assets.map((a) => ({ ...this.asset, ...a, replayed: false })),
      );
    }
    if (name === "confirmed_upload_transfers") return json(this.confirmed());
    if (name === "plan_upload_operation") {
      return json(this.operation(String(args.p_kind), Number(args.p_part)));
    }
    if (name === "claim_upload_operation") {
      if (!op) return reject(404, "operation missing");
      if (this.asset!.upload_aborted) return reject(503, "cancelled");
      if (["stored", "retained"].includes(String(op.state))) {
        return json({ ...op, dispatch: false });
      }
      if (op.state !== "planned") {
        return reject(503, "dispatch already claimed");
      }
      Object.assign(op, { state: "dispatching", claim: args.p_claim });
      return json({ ...op, dispatch: true });
    }
    if (
      name === "finish_upload_operation" || name === "recover_upload_operation"
    ) {
      if (!op) return reject(404, "operation missing");
      if (name === "finish_upload_operation" && op.claim !== args.p_claim) {
        return reject(409, "claim mismatch");
      }
      if (name === "recover_upload_operation" && this.asset!.upload_aborted) {
        return reject(409, "terminal recovery");
      }
      Object.assign(op, {
        state: name === "recover_upload_operation" ? "stored" : args.p_result,
        etag: args.p_etag,
        upload_id: args.p_upload_id ?? op.upload_id,
        content_type: args.p_content_type ?? op.content_type,
      });
      if (op.kind === "init") this.asset!.upload_id = op.upload_id;
      if (
        this.asset!.upload_aborted &&
        !["part", "assemble"].includes(String(op.kind))
      ) this.cleanup.add(String(op.id));
      return json({ ...op });
    }
    if (
      name === "settle_upload_reservation" || name === "cancel_legacy_upload"
    ) {
      const complete = args.p_complete === true,
        patch = complete ? { uploaded: true } : { upload_aborted: true };
      await this.beforePatch?.(patch);
      if (this.asset!.uploaded) {
        return complete ? json({ ...this.asset }) : reject(409, "completed");
      }
      if (this.asset!.upload_aborted) {
        return complete ? reject(409, "cancelled") : json({ ...this.asset });
      }
      if (complete) {
        if (!op || op.state !== "stored") {
          return reject(409, "stored publication receipt missing");
        }
        Object.assign(this.asset!, args.p_metadata ?? {}, patch, {
          storage_key: op.object_key,
          content_type: op.content_type,
          upload_id: null,
        });
        op.state = "retained";
      } else {
        if (name === "cancel_legacy_upload") {
          const legacy = this.operation(
            this.asset!.upload_id ? "init" : "single",
          );
          legacy.claim = "fixture-legacy";
        }
        Object.assign(this.asset!, patch, { transport_version: 2 });
      }
      for (const item of this.operations.values()) {
        if (
          complete && this.asset!.parts_total != null &&
          ["init", "part", "assemble"].includes(String(item.kind))
        ) item.state = "retained";
        if (
          item.state !== "retained" &&
          !["part", "assemble"].includes(String(item.kind))
        ) this.cleanup.add(String(item.id));
      }
      if (complete && this.loseCommitResponse) {
        this.loseCommitResponse = false;
        return json({ message: "synthetic lost commit acknowledgement" }, 503);
      }
      return json({ ...this.asset });
    }
    if (name === "upload_maintenance_batch") {
      return json({ expire: [], cleanup: [...this.cleanup] });
    }
    if (name === "claim_upload_cleanup") {
      if (!op || !this.cleanup.has(String(op.id)) || op.state === "retained") {
        return reject(409, "not cleanup eligible");
      }
      Object.assign(op, { state: "cleaning", cleanup_claim: args.p_claim });
      return json({ ...op });
    }
    if (name === "finish_upload_cleanup") {
      if (!op || op.cleanup_claim !== args.p_claim) {
        return reject(409, "cleanup claim mismatch");
      }
      op.state = args.p_deleted ? "deleted" : "uncertain";
      if (args.p_deleted) this.cleanup.delete(String(op.id));
      return json(true);
    }
    throw new Error(`Unmodeled durable RPC ${name}`);
  }

  multipart(bytes = 4) {
    this.asset = {
      ...this.asset,
      bytes,
      upload_id: "fixture-upload",
      parts_total: 1,
      part_size: bytes,
    };
    this.objects.clear();
    this.assemblyBytes = bytes; // metadata-only 12 GiB fixture, not allocated
    this.operation("init").claim = "fixture-init-dispatched";
  }
  async request(action: string, body: Row = {}) {
    const path = action === "ticket"
      ? "uploads"
      : action === "batch"
      ? "uploads/batch"
      : action === "sweep"
      ? "uploads/sweep"
      : `uploads/fixture-asset/${action}`;
    return await actualHandler!(
      new Request(`https://edge.invalid/${path}`, {
        method: "POST",
        headers: {
          authorization: "Bearer fixture-token",
          "content-type": "application/json",
          "idempotency-key": "fixture-ticket-unique",
        },
        body: JSON.stringify(body),
      }),
    );
  }
  async ok(action = "complete", body: Row = {}): Promise<Row> {
    const response = await this.request(action, body);
    assertEquals(response.status, 200, await response.clone().text());
    return await response.json();
  }
  fetch = async (
    input: RequestInfo | URL,
    init?: RequestInit,
  ): Promise<Response> => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    const json = (data: unknown, status = 200) =>
      new Response(JSON.stringify(data), {
        status,
        headers: { "content-type": "application/json" },
      });
    const row = (data: unknown) =>
      json(
        request.headers.get("accept")?.includes("vnd.pgrst.object")
          ? data
          : [data],
      );
    if (url.hostname === "upload-fixture.invalid") {
      if (url.pathname === "/auth/v1/user") {
        return json({ id: "fixture-user", aud: "authenticated" });
      }
      if (url.pathname === "/rest/v1/memberships") {
        return row({ role: "owner" });
      }
      if (url.pathname === "/rest/v1/listings") {
        return row({ id: "fixture-listing", org_id: "fixture-org" });
      }
      if (url.pathname === "/rest/v1/deletion_requests") return json([]);
      if (url.pathname === "/rest/v1/upload_operations" && request.method === "GET") {
        return json([...this.operations.values()].filter((op) => op.asset_id === this.asset?.id &&
          op.kind === "part" && op.state === "stored").map((op) => ({ part: op.part, etag: op.etag })));
      }
      if (
        url.pathname.startsWith("/rest/v1/rpc/") &&
        !url.pathname.endsWith("bump_rate") &&
        !url.pathname.endsWith("refund_rate")
      ) {
        return await this.rpc(
          url.pathname.split("/").pop()!,
          await request.json(),
        );
      }
      if (
        url.pathname === "/rest/v1/rpc/bump_rate" ||
        url.pathname === "/rest/v1/rpc/refund_rate"
      ) {
        this.charges.push(await request.json());
        return json(true);
      }
      if (url.pathname === "/rest/v1/capture_assets") {
        if (request.method === "GET") {
          this.getCalls++;
          return this.asset ? row(structuredClone(this.asset)) : json([]);
        }
        if (request.method === "POST") {
          this.asset = {
            upload_aborted: false,
            completion_parts: null,
            ...await request.json(),
          };
          return row(structuredClone(this.asset));
        }
        if (request.method === "PATCH") {
          const patch: Row = await request.json();
          await this.beforePatch?.(patch);
          // Evaluate at the atomic UPDATE, after any deliberately blocked wait.
          const matches = this.asset &&
            [...url.searchParams].every(([key, value]) => {
              if (key === "select") return true;
              if (value === "is.null") return this.asset![key] == null;
              if (value.startsWith("eq.")) {
                return String(this.asset![key]) === value.slice(3);
              }
              throw new Error(`Unsupported fixture predicate ${key}=${value}`);
            });
          if (!matches) return json([]);
          Object.assign(this.asset!, patch);
          if (patch.uploaded === true && this.loseCommitResponse) {
            this.loseCommitResponse = false;
            return json(
              { message: "synthetic lost commit acknowledgement" },
              503,
            );
          }
          return row(structuredClone(this.asset));
        }
      }
    }
    if (url.hostname === "fixture.r2.cloudflarestorage.com") {
      const key = decodeURIComponent(
        url.pathname.split("/").slice(2).join("/"),
      );
      if (request.method === "POST" && url.searchParams.has("uploads")) {
        this.sessions.set(key, "fixture-new-upload");
        return new Response(
          this.failInitializationReply
            ? "<synthetic-lost-reply/>"
            : "<InitiateMultipartUploadResult><UploadId>fixture-new-upload</UploadId></InitiateMultipartUploadResult>",
        );
      }
      if (request.method === "GET" && url.searchParams.has("uploads")) {
        const prefix = url.searchParams.get("prefix")!,
          id = this.sessions.get(prefix);
        return new Response(
          `<ListMultipartUploadsResult><IsTruncated>false</IsTruncated>${
            id
              ? `<Upload><Key>${prefix}</Key><UploadId>${id}</UploadId></Upload>`
              : ""
          }</ListMultipartUploadsResult>`,
        );
      }
      if (request.method === "GET" && url.searchParams.has("uploadId")) {
        const number = Number(url.searchParams.get("part-number-marker")) + 1,
          part = this.physicalParts.get(number);
        return new Response(
          `<ListPartsResult>${
            part
              ? `<Part><PartNumber>${number}</PartNumber><Size>${part.bytes}</Size><ETag>${part.etag}</ETag></Part>`
              : ""
          }</ListPartsResult>`,
        );
      }
      if (request.method === "HEAD") {
        const snapshot = this.objects.get(key);
        await this.afterHead?.(key, snapshot);
        return new Response(null, {
          status: snapshot ? 200 : 404,
          headers: snapshot
            ? {
              "content-length": String(snapshot.bytes),
              "content-type": snapshot.type,
              etag: snapshot.etag,
            }
            : {},
        });
      }
      if (
        request.method === "PUT" && request.headers.has("x-amz-copy-source")
      ) {
        this.copies.push(key);
        this.copyHeaders.push(new Headers(request.headers));
        const source = decodeURIComponent(
          request.headers.get("x-amz-copy-source")!.split("/").slice(2).join(
            "/",
          ),
        );
        const selected = this.objects.get(source);
        if (
          !selected ||
          selected.etag !== request.headers.get("x-amz-copy-source-if-match")
        ) return new Response(null, { status: 412 });
        await this.beforeCopy?.(key);
        if (this.failCopy) {
          return new Response("<Error>synthetic</Error>", { status: 400 });
        }
        // Model documented CopyObject metadata behavior, not just body identity.
        // COPY (the default) inherits metadata from the selected source; REPLACE
        // uses request metadata even when identical bytes have the same ETag.
        const type =
          request.headers.get("x-amz-metadata-directive") === "REPLACE"
            ? request.headers.get("content-type") ?? "application/octet-stream"
            : selected.type;
        this.objects.set(key, { ...selected, type });
        return new Response(
          "<CopyObjectResult><ETag>fixture</ETag></CopyObjectResult>",
        );
      }
      if (request.method === "POST" && url.searchParams.has("uploadId")) {
        const body = await request.text();
        this.assemblies.push(body);
        await this.beforeAssembly?.();
        this.objects.set(
          key,
          object(body.includes("BBBB") ? "BBBB" : "AAAA", this.assemblyBytes),
        );
        return new Response(
          "<CompleteMultipartUploadResult><ETag>fixture</ETag></CompleteMultipartUploadResult>",
        );
      }
      if (request.method === "DELETE") {
        if (url.searchParams.has("uploadId")) {
          this.abortedSessions++;
          if (this.failAbort) {
            return new Response("synthetic abort failure", { status: 400 });
          }
        } else {
          this.deletes.push(key);
          this.objects.delete(key);
        }
        return new Response(null, { status: 204 });
      }
    }
    const message =
      `Unexpected fixture request: ${request.method} ${url.hostname}${url.pathname}`;
    this.unexpected.push(message);
    throw new Error(message);
  };
}

export async function fixture(run: (f: Fixture) => Promise<void>) {
  const f = new Fixture();
  const values: Record<string, string> = {
    SUPABASE_URL: "https://upload-fixture.invalid",
    SUPABASE_SERVICE_ROLE_KEY: "fixture-service",
    SUPABASE_ANON_KEY: "fixture-anon",
    CLOUDFLARE_ACCOUNT_ID: "fixture",
    R2_ACCESS_KEY_ID: "fixture-key",
    R2_SECRET_ACCESS_KEY: "fixture-secret",
  };
  Object.assign(values, {
    UPLOAD_GATEWAY_ORIGIN: "https://upload-gateway-fixture.invalid",
    UPLOAD_GATEWAY_ALLOWED_ORIGIN: "https://upload-gateway-fixture.invalid",
    UPLOAD_CAPABILITY_SECRET:
      "synthetic-upload-capability-fixture-not-a-real-secret",
  });
  const prior = new Map(
    Object.keys(values).map((key) => [key, Deno.env.get(key)]),
  );
  for (const [key, value] of Object.entries(values)) Deno.env.set(key, value);
  const oldFetch = globalThis.fetch,
    serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    globalThis.fetch = f.fetch;
    // The original can be an accessor (lazy-loaded Deno.serve). A replacement
    // data descriptor must not inherit get/set; restore the exact original below.
    Object.defineProperty(Deno, "serve", {
      configurable: serve.configurable,
      enumerable: serve.enumerable,
      writable: true,
      value: (handler: Handler) => {
        actualHandler = handler;
        return {};
      },
    });
    await import("../../services/supabase/functions/uploads/index.ts");
    assert(actualHandler, "Actual route was not captured");
    await Promise.race([
      run(f),
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error("Fixture interleaving exceeded 5 seconds")),
          5000,
        );
      }),
    ]);
    assertEquals(f.unexpected, []);
  } finally {
    clearTimeout(timer);
    globalThis.fetch = oldFetch;
    Object.defineProperty(Deno, "serve", serve);
    for (const [key, value] of prior) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
}
