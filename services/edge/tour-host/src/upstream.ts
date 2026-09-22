import type { Env } from "./types";

// Operational safety budgets, not provider limits or a promised response SLA.
// Tours contain metadata/URLs (gallery and disclosures are each capped at 40
// upstream), not media bytes. Portfolio cardinality/freeform text is not fully
// bounded upstream: over-cap payloads must fail explicitly, never be truncated.
const UPSTREAM_TIMEOUT_MS = 8_000;
const UPSTREAM_JSON_BYTES = 4 * 1024 * 1024;
const MAX_EMPTY_CHUNKS = 64;

type UpstreamJSON =
  | { kind: "ok"; value: unknown }
  | { kind: "not-found" }
  | { kind: "error"; status: 502 | 503 };

const unavailable: UpstreamJSON = { kind: "error", status: 503 };
const malformed: UpstreamJSON = { kind: "error", status: 502 };

/** One deadline covers headers AND the decoded response stream. No retries,
 * raw upstream error messages, response bodies or credentials escape to callers. */
export async function fetchUpstreamJSON(path: string, env: Env): Promise<UpstreamJSON> {
  const controller = new AbortController();
  let response: Response | undefined;
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  const cancelBody = () => {
    // Cancellation itself is not allowed to hold the public request open.
    // Abort stops the real fetch; this also closes independent/custom streams.
    if (reader) void reader.cancel().catch(() => {});
    else if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {});
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<UpstreamJSON>((resolve) => {
    timer = setTimeout(() => {
      controller.abort();
      cancelBody();
      resolve(unavailable);
    }, UPSTREAM_TIMEOUT_MS);
  });

  const read = async (): Promise<UpstreamJSON> => {
    const key = env.SUPABASE_ANON_KEY || "";
    const base = String(env.SUPABASE_FUNCTIONS_URL || "").replace(/\/+$/, "");
    response = await fetch(`${base}${path}`, {
      method: "GET",
      headers: { apikey: key, Authorization: `Bearer ${key}`, Accept: "application/json" },
      signal: controller.signal,
      // The fixed API route should not redirect. Never forward its auth headers
      // to a Location selected by a bad upstream response.
      redirect: "manual",
      // Publication state must remain fresh; HTML also bypasses customer caches.
      cf: { cacheTtl: 0, cacheEverything: false },
    });
    // A nonconforming fetch may resolve after its abort. Do not read late data.
    if (controller.signal.aborted) { cancelBody(); return unavailable; }
    if (response.status === 404) return { kind: "not-found" };
    if (response.status === 429 || response.status >= 500) return unavailable;
    if (!response.ok || !response.body) return malformed;

    reader = response.body.getReader();
    // Grow one bounded buffer, not a list of chunks: millions of tiny chunks
    // must not allocate millions of retained objects. Count bytes after runtime
    // content decoding; Content-Length may describe compressed bytes or lie.
    let buffer = new Uint8Array(0);
    let size = 0;
    let emptyChunks = 0;
    while (true) {
      const part = await reader.read();
      if (controller.signal.aborted) return unavailable;
      if (part.done) break;
      if (!(part.value instanceof Uint8Array) || part.value.byteLength > UPSTREAM_JSON_BYTES - size) return malformed;
      // A byte cap cannot stop an endlessly empty, immediately-ready stream;
      // those microtasks can starve timers. Bound consecutive no-progress reads.
      if (part.value.byteLength === 0) {
        if (++emptyChunks > MAX_EMPTY_CHUNKS) return malformed;
        continue;
      }
      emptyChunks = 0;
      const next = size + part.value.byteLength;
      if (next > buffer.byteLength) {
        const grown = new Uint8Array(Math.min(UPSTREAM_JSON_BYTES, Math.max(next, buffer.byteLength * 2, 16 * 1024)));
        grown.set(buffer.subarray(0, size));
        buffer = grown;
      }
      buffer.set(part.value, size);
      size = next;
    }
    try {
      const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(buffer.subarray(0, size));
      return { kind: "ok", value: JSON.parse(text) };
    } catch {
      return malformed;
    }
  };

  try {
    return await Promise.race([read(), deadline]);
  } catch {
    return unavailable; // network/stream failure, not evidence of a missing tour
  } finally {
    if (timer !== undefined) clearTimeout(timer);
    controller.abort();
    cancelBody();
  }
}
