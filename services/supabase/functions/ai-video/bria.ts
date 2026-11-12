// Direct Bria v2 contract, verified against the official OpenAPI on 2026-10-02:
// https://docs.bria.ai/_bundle/video-editing.json
// https://docs.bria.ai/_bundle/status.json
// This transport never reserves budget, retries a POST, polls in a loop, or
// switches providers. The caller must commit a receipt before EACH paid stage.
export const BRIA_ORIGIN = "https://engine.prod.bria-api.com";
export const BRIA_MASK_ENDPOINT = BRIA_ORIGIN +
  "/v2/video/segment/mask_by_prompt";
export const BRIA_ERASE_ENDPOINT = BRIA_ORIGIN + "/v2/video/edit/erase";
export const BRIA_MAX_CLIP_SECONDS = 5;
const MAX_JSON_BYTES = 64 * 1024;
const MAX_URL_LENGTH = 8192;
const MAX_TIMEOUT_MS = 25000;
const MAX_OUTPUT_BYTES = 100 * 1024 * 1024;
type Obj = Record<string, unknown>;
export type BriaStage = "mask" | "erase";
export type BriaRef = { request_id: string; status_url: string };
export type BriaPoll =
  | { status: "processing" }
  | { status: "completed"; output_url: string }
  | { status: "failed"; error: string };
export type BriaErrorOutcome =
  | "invalid"
  | "configuration"
  | "rejected"
  | "uncertain"
  | "status";
export class BriaError extends Error {
  constructor(
    public readonly outcome: BriaErrorOutcome,
    message: string,
    public readonly httpStatus?: number,
  ) {
    super(message);
    this.name = "BriaError";
  }
}
export interface BriaVideoInput {
  videoUrl: string;
  // Must come from the application's bounded media probe, never user metadata.
  durationSeconds: number;
}
export interface BriaMaskInput extends BriaVideoInput {
  prompt: string;
}
export interface BriaDeps {
  fetch(input: string, init: RequestInit): Promise<Response>;
  apiToken(): string;
  // Exact hosts verified for this account. No wildcard/default guessed CDN.
  outputHosts: readonly string[];
  timeoutMs?: number;
}
function invalid(message: string): never {
  throw new BriaError("invalid", message);
}
function object(value: unknown): Obj {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    invalid("Invalid Bria response object");
  }
  return value as Obj;
}
function publicHost(host: string): boolean {
  // URLs must use public DNS names; reject all literal IPs, local names and
  // DNS names whose final component is numeric (including alternate IPv4).
  return host.length <= 253 && host.includes(".") &&
    /^[a-z0-9]+(?:[a-z0-9.-]*[a-z0-9])?$/.test(host) &&
    host.split(".").every((label) =>
      label.length > 0 && label.length <= 63 && !label.startsWith("-") &&
      !label.endsWith("-")
    ) && !/\d$/.test(host.split(".").at(-1)!) &&
    !/(?:^|\.)(?:localhost|local|internal|lan|home|invalid)$/.test(host);
}
function hasControl(value: string, allowLayout = false): boolean {
  for (const char of value) {
    const code = char.charCodeAt(0);
    if (code === 127) return true;
    if (code < 32 && !(allowLayout && [9, 10, 13].includes(code))) return true;
  }
  return false;
}
function httpsUrl(value: unknown): URL {
  if (
    typeof value !== "string" || value.length === 0 ||
    value.length > MAX_URL_LENGTH || /[\s\\]/.test(value) || hasControl(value)
  ) invalid("Invalid Bria media URL");
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    invalid("Invalid Bria media URL");
  }
  if (
    url.protocol !== "https:" || url.username || url.password || url.hash ||
    url.port || !publicHost(url.hostname)
  ) invalid("Invalid Bria media URL");
  return url;
}
function requestId(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{6,200}$/.test(value)) {
    invalid("Invalid Bria request id");
  }
  return value;
}
export function readBriaRef(value: unknown): BriaRef {
  const data = object(value), id = requestId(data.request_id);
  const url = httpsUrl(data.status_url);
  const canonical = `${BRIA_ORIGIN}/v2/status/${id}`;
  if (url.href !== canonical || data.status_url !== canonical) {
    invalid("Invalid Bria status reference");
  }
  return { request_id: id, status_url: canonical };
}
function video(input: BriaVideoInput): string {
  const data = object(input);
  if (
    typeof data.durationSeconds !== "number" ||
    !Number.isFinite(data.durationSeconds) || data.durationSeconds <= 0 ||
    data.durationSeconds >= BRIA_MAX_CLIP_SECONDS
  ) {
    invalid(
      "Reflection clips must have a measured duration under five seconds",
    );
  }
  return httpsUrl(data.videoUrl).href;
}
async function discard(response: Response): Promise<void> {
  // Cancellation must not mask a rejection or expose the response body.
  try {
    await response.body?.cancel();
  } catch { /* no private body/error details */ }
}
async function readJson(response: Response, signal: AbortSignal): Promise<Obj> {
  const type = response.headers.get("content-type")?.split(";")[0].trim();
  if (type !== "application/json") {
    invalid("Invalid Bria response content type");
  }
  const length = response.headers.get("content-length");
  if (
    length !== null &&
    (!/^\d+$/.test(length) || Number(length) > MAX_JSON_BYTES)
  ) invalid("Bria response exceeds its size limit");
  if (!response.body) invalid("Empty Bria response");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  const abort = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", abort, { once: true });
  try {
    while (true) {
      signal.throwIfAborted();
      const chunk = await reader.read();
      signal.throwIfAborted();
      if (chunk.done) break;
      bytes += chunk.value.byteLength;
      if (bytes > MAX_JSON_BYTES) {
        invalid("Bria response exceeds its size limit");
      }
      chunks.push(chunk.value);
    }
    const all = new Uint8Array(bytes);
    let offset = 0;
    for (const chunk of chunks) {
      all.set(chunk, offset);
      offset += chunk.length;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(
        new TextDecoder("utf-8", { fatal: true }).decode(all),
      );
    } catch {
      invalid("Invalid Bria response JSON");
    }
    return object(parsed);
  } finally {
    signal.removeEventListener("abort", abort);
    void reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
export function createBriaAdapter(deps: BriaDeps) {
  const timeoutMs = deps.timeoutMs ?? MAX_TIMEOUT_MS;
  const validTimeout = Number.isInteger(timeoutMs) && timeoutMs > 0 &&
    timeoutMs <= MAX_TIMEOUT_MS;
  // Copy the trusted configuration so caller mutation cannot expand the hosts.
  const hosts = new Set<string>();
  const validHosts = Array.isArray(deps.outputHosts) &&
    deps.outputHosts.length > 0 && deps.outputHosts.length <= 16 &&
    deps.outputHosts.every((host) => {
      if (typeof host !== "string" || !publicHost(host)) return false;
      hosts.add(host);
      return true;
    });
  function token(): string {
    let value: unknown;
    try {
      value = deps.apiToken();
    } catch {
      value = null;
    }
    if (
      !validTimeout || !validHosts || typeof value !== "string" ||
      value.length === 0 || value.length > 4096 || /\s/.test(value) ||
      hasControl(value)
    ) {
      throw new BriaError("configuration", "Direct Bria is not configured");
    }
    return value;
  }
  function outputUrl(value: unknown): string {
    const url = httpsUrl(value);
    if (!validHosts || !hosts.has(url.hostname)) {
      invalid("Untrusted Bria output host");
    }
    return url.href;
  }
  async function request<T>(
    url: string,
    method: "GET" | "POST",
    parse: (response: Response, signal: AbortSignal) => Promise<T>,
    body?: Obj,
  ): Promise<T> {
    const apiToken = token();
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        reject(
          new BriaError(
            method === "POST" ? "uncertain" : "status",
            method === "POST"
              ? "Bria submission could not be confirmed; do not resubmit"
              : "Bria status is temporarily unavailable",
          ),
        );
      }, timeoutMs);
    });
    try {
      return await Promise.race([
        (async () => {
          const response = await deps.fetch(url, {
            method,
            redirect: "error",
            signal: controller.signal,
            headers: {
              api_token: apiToken,
              "content-type": "application/json",
              accept: "application/json",
            },
            ...(body ? { body: JSON.stringify(body) } : {}),
          });
          // An injected/buggy fetch may settle after our timeout. Stop parsing.
          if (controller.signal.aborted) {
            void discard(response);
            throw new Error("aborted");
          }
          try {
            return await parse(response, controller.signal);
          } finally {
            void discard(response);
          }
        })(),
        timeout,
      ]);
    } catch (error) {
      if (
        error instanceof BriaError &&
        (error.outcome === "rejected" || error.outcome === "uncertain" ||
          error.outcome === "status")
      ) throw error;
      // Never echo a fetch error, response body, token, prompt or signed URL.
      throw new BriaError(
        method === "POST" ? "uncertain" : "status",
        method === "POST"
          ? "Bria submission could not be confirmed; do not resubmit"
          : "Bria status returned no usable response",
      );
    } finally {
      clearTimeout(timer);
      controller.abort();
    }
  }
  async function submit(url: string, body: Obj): Promise<BriaRef> {
    return await request(url, "POST", async (response, signal) => {
      if (
        [400, 401, 403, 404, 405, 413, 415, 422, 429].includes(response.status)
      ) {
        throw new BriaError(
          "rejected",
          "Bria rejected this clip before accepting a job",
          response.status,
        );
      }
      if (response.status !== 202) {
        throw new BriaError(
          "uncertain",
          "Bria submission could not be confirmed; do not resubmit",
          response.status,
        );
      }
      const data = await readJson(response, signal);
      if (data.error != null || data.result != null) {
        invalid("Conflicting Bria submission response");
      }
      return readBriaRef(data);
    }, body);
  }
  return {
    configured(): boolean {
      try {
        token();
        return true;
      } catch {
        return false;
      }
    },
    readRef: readBriaRef,
    outputUrl,
    async downloadOutput(
      value: string,
      maxBytes = MAX_OUTPUT_BYTES,
    ): Promise<{ bytes: ArrayBuffer; mime: "video/mp4" }> {
      const url = outputUrl(value);
      if (
        !validTimeout || !Number.isInteger(maxBytes) || maxBytes < 12 ||
        maxBytes > MAX_OUTPUT_BYTES
      ) invalid("Invalid Bria download limit");
      const controller = new AbortController();
      let timer: ReturnType<typeof setTimeout> | undefined;
      const timeout = new Promise<never>((_resolve, reject) => {
        timer = setTimeout(() => {
          controller.abort();
          reject(new BriaError("status", "Bria output download timed out"));
        }, timeoutMs);
      });
      try {
        return await Promise.race([
          (async () => {
            const response = await deps.fetch(url, {
              method: "GET",
              redirect: "error",
              signal: controller.signal,
              // No API credentials or signed status URL accompanies the media.
              headers: { accept: "video/mp4, application/octet-stream" },
            });
            if (controller.signal.aborted) {
              void discard(response);
              throw new Error("aborted");
            }
            try {
              if (response.status !== 200) {
                throw new BriaError(
                  "status",
                  "Bria output is temporarily unavailable",
                  response.status,
                );
              }
              const mime = response.headers.get("content-type")?.split(";")[0]
                .trim();
              if (mime !== "video/mp4" && mime !== "application/octet-stream") {
                invalid("Invalid Bria output content type");
              }
              const length = response.headers.get("content-length");
              if (
                length !== null &&
                (!/^\d+$/.test(length) || Number(length) > maxBytes)
              ) invalid("Bria output exceeds its size limit");
              if (!response.body) invalid("Empty Bria output");
              const reader = response.body.getReader(),
                chunks: Uint8Array[] = [];
              let size = 0;
              const abort = () => {
                void reader.cancel().catch(() => {});
              };
              controller.signal.addEventListener("abort", abort, {
                once: true,
              });
              try {
                while (true) {
                  controller.signal.throwIfAborted();
                  const part = await reader.read();
                  controller.signal.throwIfAborted();
                  if (part.done) break;
                  size += part.value.byteLength;
                  if (size > maxBytes) {
                    invalid("Bria output exceeds its size limit");
                  }
                  chunks.push(part.value);
                }
                const bytes = new Uint8Array(size);
                let offset = 0;
                for (const chunk of chunks) {
                  bytes.set(chunk, offset);
                  offset += chunk.length;
                }
                if (
                  size < 12 ||
                  new TextDecoder().decode(bytes.subarray(4, 8)) !== "ftyp"
                ) invalid("Bria output is not an MP4 video");
                return { bytes: bytes.buffer, mime: "video/mp4" as const };
              } finally {
                controller.signal.removeEventListener("abort", abort);
                void reader.cancel().catch(() => {});
                reader.releaseLock();
              }
            } finally {
              void discard(response);
            }
          })(),
          timeout,
        ]);
      } catch (error) {
        if (error instanceof BriaError) throw error;
        throw new BriaError("status", "Bria output could not be downloaded");
      } finally {
        clearTimeout(timer);
        controller.abort();
      }
    },
    async submitMask(input: BriaMaskInput): Promise<BriaRef> {
      const source = video(input);
      if (
        typeof input.prompt !== "string" || input.prompt.trim().length === 0 ||
        input.prompt.length > 6000 || hasControl(input.prompt, true)
      ) invalid("A bounded reflection mask prompt is required");
      return await submit(BRIA_MASK_ENDPOINT, {
        video: source,
        prompt: input.prompt,
        auto_trim: false,
        output_container_and_codec: "mp4_h264",
      });
    },
    async submitErase(
      input: BriaVideoInput,
      maskUrl: string,
    ): Promise<BriaRef> {
      const source = video(input), mask = outputUrl(maskUrl);
      if (source === mask) invalid("The mask must differ from the input video");
      return await submit(BRIA_ERASE_ENDPOINT, {
        video: source,
        mask,
        preserve_audio: true,
        auto_trim: false,
        output_container_and_codec: "mp4_h264",
      });
    },
    async poll(value: BriaRef, stage: BriaStage): Promise<BriaPoll> {
      const ref = readBriaRef(value);
      if (stage !== "mask" && stage !== "erase") invalid("Invalid Bria stage");
      return await request(ref.status_url, "GET", async (response, signal) => {
        if (response.status === 404) {
          return { status: "failed", error: "Bria request is unavailable" };
        }
        if (response.status !== 200) {
          throw new BriaError(
            "status",
            "Bria status is temporarily unavailable",
            response.status,
          );
        }
        const data = await readJson(response, signal);
        if (requestId(data.request_id) !== ref.request_id) {
          invalid("Bria status request id mismatch");
        }
        if (
          ["ERROR", "UNKNOWN", "FAILED", "CANCELLED"].includes(
            String(data.status),
          )
        ) {
          return {
            status: "failed",
            error: "Bria reflection processing failed",
          };
        }
        if (data.status === "IN_PROGRESS") {
          if (data.result != null || data.error != null) {
            invalid("Conflicting Bria job state");
          }
          return { status: "processing" };
        }
        if (data.status !== "COMPLETED" || data.error != null) {
          invalid("Invalid Bria job state");
        }
        const result = object(data.result);
        // Bria warns when it changes requested output parameters. Such output
        // needs review instead of being treated as a verified edited clip.
        if (result.warning != null && result.warning !== "") {
          return {
            status: "failed",
            error: "Bria adjusted the requested output",
          };
        }
        let url: unknown = result.video_url;
        if (stage === "mask" && result.mask_url !== undefined) {
          if (url !== undefined && url !== result.mask_url) {
            invalid("Conflicting Bria mask outputs");
          }
          url = result.mask_url;
        }
        if (stage === "erase" && result.mask_url != null) {
          invalid("Bria returned a mask for an erase job");
        }
        return { status: "completed", output_url: outputUrl(url) };
      });
    },
  };
}
