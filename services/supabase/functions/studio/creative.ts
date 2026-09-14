import { HttpError, json, readJsonLimited } from "../_shared/http.ts";
import {
  headObject,
  R2_BUCKET_RENDERS,
  R2_BUCKET_UPLOADS,
} from "../_shared/r2.ts";
import { presignGet } from "../_shared/providers/common.ts";
import type { StudioContext } from "./context.ts";
import {
  editQualityProjection,
  qualityProjection,
} from "./creative-quality.ts";
import { handleEditOutput } from "./edit-output.ts";
import { attachGeneratedVideoProof } from "./generated-proof.ts";
import {
  decodeJobToken,
  encodeJobToken,
} from "../_shared/providers/jobtoken.ts";

/** Only call with references read from the private, server-written result row.
 * A saved generation may be revisited after its original two-hour token expires. */
export async function renewTrustedJobReferences(
  status: string,
  response: string,
  owner: { orgId: string; userId: string },
) {
  let statusURL: URL, responseURL: URL;
  try {
    statusURL = new URL(status);
    responseURL = new URL(response);
  } catch {
    throw new HttpError(502, "Saved video progress is unreadable.");
  }
  const token = statusURL.searchParams.get("job"),
    other = responseURL.searchParams.get("job");
  if (!token && !other) return { status_url: status, response_url: response };
  if (!token || token !== other) {
    throw new HttpError(403, "Saved video references do not match.");
  }
  const job = await decodeJobToken(token);
  if (
    !job || job.o !== owner.orgId || job.usr !== owner.userId ||
    !job.k.startsWith("video.")
  ) {
    throw new HttpError(
      403,
      "This saved video does not belong to the current account.",
    );
  }
  if (job.exp * 1000 > Date.now() + 60_000) {
    return { status_url: status, response_url: response };
  }
  const renewed = await encodeJobToken({
    p: job.p,
    m: job.m,
    i: job.i,
    u: job.u,
    t: job.t,
    k: job.k,
  }, owner);
  statusURL.searchParams.set("job", renewed);
  responseURL.searchParams.set("job", renewed);
  return { status_url: statusURL.href, response_url: responseURL.href };
}

const ID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
export function creativeId(value: unknown): string {
  if (typeof value !== "string" || !ID.test(value)) {
    throw new HttpError(400, "Choose a saved listing or creative result.");
  }
  return value.toLowerCase();
}
export function completedVideoKey(
  receipt: Record<string, any>,
  scope: { orgId: string; listingId: string; assetId: string },
  renewed = false,
): string {
  const key = String(receipt.storage_key ?? "");
  if (
    receipt.uploaded !== true ||
    (renewed ? receipt.asset_id : receipt.id) !== scope.assetId ||
    (!renewed || receipt.listing_id !== undefined) &&
      receipt.listing_id !== scope.listingId ||
    !key.startsWith(`renders/${scope.orgId}/${scope.listingId}/`) ||
    !key.endsWith(".mp4") ||
    key.length > 1024 || key.includes("..") || /[\\?#\u0000-\u001f]/.test(key)
  ) {
    throw new HttpError(
      502,
      "The generated clip storage receipt could not be verified.",
    );
  }
  return key;
}
export function voiceStorageKey(value: unknown, orgId: string): string {
  if (typeof value !== "string") {
    throw new HttpError(
      502,
      "Narration did not include a playable audio file.",
    );
  }
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new HttpError(502, "Narration returned an invalid audio file.");
  }
  if (
    url.protocol !== "https:" ||
    !/^[a-f0-9]{32}\.r2\.cloudflarestorage\.com$/.test(url.hostname) ||
    url.username || url.password || url.port || url.hash
  ) throw new HttpError(502, "Narration returned an invalid audio file.");
  const prefix = `/${R2_BUCKET_UPLOADS}/ai-voice/${orgId}/`;
  if (
    !url.pathname.startsWith(prefix) ||
    !new RegExp(`^${ID.source.slice(1, -1)}\\.mp3$`, "i").test(
      url.pathname.slice(prefix.length),
    )
  ) {
    throw new HttpError(
      502,
      "Narration returned an audio file outside this workspace.",
    );
  }
  return url.pathname.slice(R2_BUCKET_UPLOADS.length + 2);
}
export function downloadURL(
  value: unknown,
  ownPublicBase?: string | null,
): string {
  if (typeof value !== "string" || value.length > 8192) {
    throw new HttpError(502, "The generated clip has no downloadable file.");
  }
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new HttpError(502, "The generated clip returned an invalid file.");
  }
  const own = ownPublicBase ? new URL(ownPublicBase) : null;
  const approved = (own && url.origin === own.origin &&
    url.pathname.startsWith(own.pathname)) ||
    url.hostname === "fal.media" || url.hostname.endsWith(".fal.media") ||
    url.hostname === "v3.fal.media" ||
    url.hostname === "storage.googleapis.com" ||
    url.hostname === "tempfile.aiquickdraw.com";
  if (
    url.protocol !== "https:" || !approved || url.username || url.password ||
    url.port || url.hash
  ) {
    throw new HttpError(
      502,
      "The clip provider returned a file that Studio cannot import safely.",
    );
  }
  return url.href;
}
export async function boundedBytes(
  response: Response,
  limit: number,
): Promise<Uint8Array<ArrayBuffer>> {
  const declared = Number(response.headers.get("content-length") || 0);
  if (declared > limit) {
    await response.body?.cancel();
    throw new HttpError(
      413,
      "This generated clip is too large to import in Studio.",
    );
  }
  const reader = response.body?.getReader();
  if (!reader) throw new HttpError(502, "The generated file is empty.");
  const chunks: Uint8Array[] = [];
  let count = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      count += value.length;
      if (count > limit) {
        await reader.cancel();
        throw new HttpError(
          413,
          "This generated clip is too large to import in Studio.",
        );
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (!count) throw new HttpError(502, "The generated file is empty.");
  const bytes = new Uint8Array(new ArrayBuffer(count));
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}
function clean(value: unknown, max = 1000): string {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}
function object(value: unknown): Record<string, any> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, any>
    : {};
}
async function invoke(
  req: Request,
  context: StudioContext,
  path: string,
  body?: unknown,
  requestKey?: string,
): Promise<Record<string, any>> {
  const base = Deno.env.get("SUPABASE_URL")?.replace(/\/+$/, "");
  if (!base) {
    throw new HttpError(503, "Creative tools are temporarily unavailable.");
  }
  const headers = new Headers({
    authorization: req.headers.get("authorization") ?? "",
    "X-Org-Id": context.orgId,
  });
  const apikey = req.headers.get("apikey");
  if (apikey) headers.set("apikey", apikey);
  if (body !== undefined) headers.set("content-type", "application/json");
  if (requestKey) headers.set("Idempotency-Key", requestKey);
  const response = await fetch(`${base}/functions/v1/${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    redirect: "error",
    signal: AbortSignal.timeout(300_000),
  });
  const bytes = await boundedBytes(response, 2 * 1024 * 1024);
  let data: Record<string, any>;
  try {
    data = object(JSON.parse(new TextDecoder().decode(bytes)));
  } catch {
    throw new HttpError(
      502,
      "The creative service returned an unreadable response.",
    );
  }
  if (!response.ok) {
    const message = clean(data.error, 600).replace(/https?:\/\/\S+/g, "[link]");
    throw new HttpError(
      response.status,
      message || "The creative service could not finish this request.",
      undefined,
    );
  }
  return data;
}
async function resultRow(context: StudioContext, id: unknown) {
  const { data, error } = await context.admin.from("studio_creative_results")
    .select("*").eq("id", creativeId(id)).eq("user_id", context.userId).eq(
      "org_id",
      context.orgId,
    ).maybeSingle();
  if (error) throw new HttpError(503, "Creative results could not be loaded.");
  if (!data) {
    throw new HttpError(
      404,
      "This creative result is not available in your workspace.",
    );
  }
  await context.authorizeListing(data.listing_id);
  return data;
}
async function publicResult(context: StudioContext, row: any) {
  const metadata = object(row.metadata);
  const result: Record<string, unknown> = {
    id: row.id,
    kind: row.kind,
    listing_id: row.listing_id,
    created_at: row.created_at,
    state: metadata.state ?? "pending",
    label: metadata.label ?? "",
    provenance_id: row.provenance_id,
    disclosure: metadata.disclosure ?? null,
    video_kind: metadata.video_kind ?? null,
    asset_id: metadata.asset_id ?? null,
    source_asset_id: metadata.source_asset_id ?? null,
    duration_s: metadata.duration_s ?? null,
    voice_name: metadata.voice_name ?? null,
    words: Array.isArray(metadata.words) ? metadata.words : [],
    message: metadata.message ?? null,
  };
  // No upstream job URLs or upload capabilities ever leave this trusted store.
  if (row.storage_key && ["uploads", "renders"].includes(row.bucket)) {
    result.url = await presignGet(
      row.bucket === "uploads" ? R2_BUCKET_UPLOADS : R2_BUCKET_RENDERS,
      row.storage_key,
      600,
    );
    result.expires_at = new Date(Date.now() + 600_000).toISOString();
  }
  let sourceProof: Record<string, unknown> | null = null;
  if (metadata.source_asset_id) {
    const { data: source } = await context.admin.from("capture_assets").select(
      "id,listing_id,storage_key,bucket,kind,uploaded",
    ).eq("id", metadata.source_asset_id).eq("listing_id", row.listing_id).eq(
      "uploaded",
      true,
    ).maybeSingle();
    sourceProof = source;
    if (
      source && source.kind === "photo" && source.bucket === "renders" &&
      String(source.storage_key).startsWith(
        `renders/${context.orgId}/${row.listing_id}/`,
      )
    ) {
      result.source_url = await presignGet(
        R2_BUCKET_RENDERS,
        source.storage_key,
        600,
      );
    }
  }
  if (row.kind === "video") {
    if (metadata.video_kind === "edit" && metadata.asset_id) {
      Object.assign(
        result,
        await editQualityProjection(context, metadata.asset_id),
      );
      return result;
    }
    const proof = row.provenance_id
      ? (await context.admin.from("media_provenance").select(
        "org_id,listing_id,original_key,altered_key,qc",
      ).eq("id", row.provenance_id).eq("org_id", context.orgId).eq(
        "listing_id",
        row.listing_id,
      ).maybeSingle()).data
      : null;
    Object.assign(
      result,
      qualityProjection(row, proof, {
        listing_id: row.listing_id,
        storage_key: row.storage_key,
        uploaded: metadata.state === "completed",
      }, sourceProof),
    );
  }
  if (metadata.request_id) result.request_id = metadata.request_id;
  return result;
}
async function writeRow(
  context: StudioContext,
  id: string,
  patch: Record<string, unknown>,
) {
  const { data, error } = await context.admin.from("studio_creative_results")
    .update(patch).eq("id", id).eq("user_id", context.userId).eq(
      "org_id",
      context.orgId,
    ).select().single();
  if (error || !data) {
    throw new HttpError(
      503,
      "Your generated result could not be saved. Refresh creative results before generating again.",
    );
  }
  return data;
}
async function provenance(
  context: StudioContext,
  raw: unknown,
  listingId: string,
): Promise<string | null> {
  const p = object(raw);
  if (!p.recorded || !p.id || !ID.test(p.id)) return null;
  const { data, error } = await context.admin.from("media_provenance").select(
    "id",
  ).eq("id", p.id).eq("org_id", context.orgId).eq("listing_id", listingId)
    .maybeSingle();
  if (error || !data) return null;
  return data.id;
}
export async function handleCreative(
  req: Request,
  context: StudioContext,
): Promise<Response | null> {
  const route = new URL(req.url).pathname.split("/").pop();
  if (route === "edit-output") return await handleEditOutput(req, context);
  if (
    !["voice", "video", "video-status", "creative-results", "sign-media"]
      .includes(route ?? "")
  ) return null;
  if (route === "creative-results" && req.method === "GET") {
    const listingId = creativeId(
      new URL(req.url).searchParams.get("listing_id"),
    );
    await context.authorizeListing(listingId);
    const offset = Number(new URL(req.url).searchParams.get("offset") ?? 0);
    if (
      !Number.isInteger(offset) || offset < 0 || offset > 10000 || offset % 100
    ) throw new HttpError(400, "Invalid creative results page.");
    const { data, error } = await context.admin.from("studio_creative_results")
      .select("*").eq("user_id", context.userId).eq("org_id", context.orgId).eq(
        "listing_id",
        listingId,
      ).order("created_at", { ascending: false }).order("id", {
        ascending: false,
      }).range(offset, offset + 100);
    if (error) {
      throw new HttpError(503, "Creative results could not be loaded.");
    }
    return json({
      results: await Promise.all(
        (data ?? []).slice(0, 100).map((row: unknown) =>
          publicResult(context, row)
        ),
      ),
      next_offset: (data ?? []).length > 100 ? offset + 100 : null,
    });
  }
  if (req.method !== "POST") {
    throw new HttpError(405, "This creative action requires POST.");
  }
  const body = object(await readJsonLimited(req, 32 * 1024 * 1024));
  if (route === "sign-media") {
    return json({
      result: await publicResult(
        context,
        await resultRow(context, body.result_id),
      ),
    });
  }
  if (route === "video-status") {
    const row = await resultRow(context, body.result_id);
    let metadata = object(row.metadata);
    if (row.kind !== "video") {
      throw new HttpError(400, "Choose a generated video.");
    }
    if (row.storage_key || metadata.state === "failed") {
      return json({ result: await publicResult(context, row) });
    }
    if (!metadata.status_url || !metadata.response_url) {
      throw new HttpError(
        409,
        "The video submission is still being confirmed. Refresh results before generating again.",
      );
    }
    if (
      metadata.state === "importing" &&
      Number(metadata.import_started) > Date.now() - 300_000
    ) return json({ result: await publicResult(context, row) });
    // One importer at a time across web tabs and phones. A five-minute lease can
    // recover a stopped isolate, while the immutable ticket resumes actual bytes.
    const started = Date.now();
    let claim = context.admin.from("studio_creative_results").update({
      metadata: { ...metadata, state: "importing", import_started: started },
    }).eq("id", row.id).eq("user_id", context.userId).eq(
      "org_id",
      context.orgId,
    ).is("storage_key", null).eq("metadata->>state", metadata.state);
    if (metadata.state === "importing") {
      claim = claim.eq(
        "metadata->>import_started",
        String(metadata.import_started),
      );
    }
    const { data: locked, error: lockError } = await claim.select()
      .maybeSingle();
    if (lockError) {
      throw new HttpError(
        503,
        "Video progress could not be checked. Try again shortly.",
      );
    }
    if (!locked) {
      return json({
        result: await publicResult(context, await resultRow(context, row.id)),
      });
    }
    metadata = object(locked.metadata);
    try {
      const refs = await renewTrustedJobReferences(
        metadata.status_url,
        metadata.response_url,
        context,
      );
      metadata = { ...metadata, ...refs };
      const query = new URLSearchParams(refs);
      const state = await invoke(req, context, `ai-video/status?${query}`);
      if (state.status === "failed") {
        return json({
          result: await publicResult(
            context,
            await writeRow(context, row.id, {
              metadata: {
                ...metadata,
                state: "failed",
                message: clean(state.error, 600),
              },
            }),
          ),
        });
      }
      if (state.status !== "completed") {
        return json({
          result: await publicResult(
            context,
            await writeRow(context, row.id, {
              metadata: { ...metadata, state: "processing" },
            }),
          ),
        });
      }
      const source = downloadURL(
        state.video_url,
        Deno.env.get("R2_PUBLIC_BASE_URL"),
      );
      const response = await fetch(source, {
        credentials: "omit",
        redirect: "error",
        signal: AbortSignal.timeout(90_000),
      });
      if (!response.ok) {
        throw new HttpError(
          502,
          "The generated clip is not ready to download. Try checking again.",
        );
      }
      const mime = response.headers.get("content-type")?.split(";")[0].trim()
        .toLowerCase();
      if (mime !== "video/mp4") {
        await response.body?.cancel();
        throw new HttpError(502, "The generated clip is not an MP4 video.");
      }
      const bytes = await boundedBytes(response, 48 * 1024 * 1024);
      // Native quota/reservation rules apply. Retry by the immutable asset ID:
      // native ticket idempotency intentionally excludes completed uploads.
      const ticket = metadata.import_asset_id
        ? await invoke(
          req,
          context,
          `uploads/${creativeId(metadata.import_asset_id)}/renew`,
          {},
        )
        : await invoke(req, context, "uploads", {
          listing_id: row.listing_id,
          filename: `studio-${row.id}.mp4`,
          kind: "video",
          role: "render",
          bytes: bytes.length,
          content_type: "video/mp4",
        }, `studio-result:${row.id}`);
      const assetId = creativeId(ticket.asset_id);
      metadata = { ...metadata, import_asset_id: assetId };
      await writeRow(context, row.id, { metadata });
      if (ticket.mode !== "single") {
        throw new HttpError(
          502,
          "The generated clip needs a different upload format.",
        );
      }
      let completed = ticket;
      if (ticket.uploaded !== true) {
        let destination: URL;
        try {
          destination = new URL(String(ticket.put_url));
        } catch {
          throw new HttpError(
            502,
            "The generated clip upload link is unavailable.",
          );
        }
        const gateway = Deno.env.get("UPLOAD_GATEWAY_ORIGIN")?.trim() ||
          "https://uploads.rendprop.com";
        if (
          destination.origin !== gateway || destination.protocol !== "https:" ||
          destination.username || destination.password || destination.hash ||
          !/^\/v2\/[a-f0-9-]{36}$/.test(destination.pathname)
        ) {
          throw new HttpError(
            502,
            "The generated clip upload link is invalid.",
          );
        }
        const put = await fetch(destination, {
          method: "PUT",
          headers: { "content-type": "video/mp4" },
          body: bytes,
          redirect: "error",
          signal: AbortSignal.timeout(120_000),
        });
        if (!put.ok) {
          await put.body?.cancel();
          throw new HttpError(
            502,
            "The generated clip could not be stored. Check progress to resume the existing upload.",
          );
        }
        await put.body?.cancel();
        completed = await invoke(
          req,
          context,
          `uploads/${assetId}/complete`,
          {},
          `complete:${assetId}`,
        );
      }
      const key = completedVideoKey(completed, {
        orgId: context.orgId,
        listingId: row.listing_id,
        assetId,
      }, completed === ticket);
      await attachGeneratedVideoProof(context, row, metadata, assetId, key);
      await context.authorizeListing(row.listing_id);
      return json({
        result: await publicResult(
          context,
          await writeRow(context, row.id, {
            storage_key: key,
            bucket: "renders",
            metadata: { ...metadata, state: "completed", asset_id: assetId },
          }),
        ),
      });
    } catch (error) {
      await context.admin.from("studio_creative_results").update({
        metadata: { ...metadata, state: "processing" },
      }).eq("id", row.id).eq("user_id", context.userId).eq(
        "org_id",
        context.orgId,
      ).is("storage_key", null).eq(
        "metadata->>import_started",
        String(started),
      );
      throw error;
    }
  }
  const listingId = creativeId(body.listing_id);
  await context.authorizeListing(listingId);
  const requestKey = req.headers.get("Idempotency-Key") ?? "";
  if (!/^[A-Za-z0-9:_-]{8,160}$/.test(requestKey)) {
    throw new HttpError(
      400,
      "A unique request key is required for generation.",
    );
  }
  const digest = Array.from(
    new Uint8Array(
      await crypto.subtle.digest(
        "SHA-256",
        new TextEncoder().encode(JSON.stringify(body)),
      ),
    ),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
  const kind = route === "voice" ? "voice" : "video";
  const metadata: Record<string, unknown> = {
    state: "submitting",
    label: clean(body.label, 80),
    digest,
  };
  const { data: reserved, error: reserveError } = await context.admin.from(
    "studio_creative_results",
  ).insert({
    user_id: context.userId,
    org_id: context.orgId,
    listing_id: listingId,
    kind,
    request_key: requestKey,
    metadata,
  }).select().single();
  if (reserveError) {
    if (reserveError.code !== "23505") {
      throw new HttpError(
        503,
        "The request could not be reserved. No generation was started.",
      );
    }
    const { data: previous, error } = await context.admin.from(
      "studio_creative_results",
    ).select("*").eq("user_id", context.userId).eq("org_id", context.orgId).eq(
      "request_key",
      requestKey,
    ).maybeSingle();
    if (
      error || !previous || previous.kind !== kind ||
      previous.listing_id !== listingId ||
      object(previous.metadata).digest !== digest
    ) {
      throw new HttpError(
        409,
        "This request key has already been used for another action.",
      );
    }
    return json({ result: await publicResult(context, previous) });
  }
  try {
    if (kind === "voice") {
      const output = await invoke(req, context, "ai-voice/tts", {
        listing_id: listingId,
        text: body.text,
        voice_id: body.voice_id,
        label: clean(body.label, 80),
      }, requestKey);
      const storageKey = voiceStorageKey(output.audio_url, context.orgId);
      const head = await headObject(R2_BUCKET_UPLOADS, storageKey);
      if (!head.exists || !head.bytes || head.bytes > 20 * 1024 * 1024) {
        throw new HttpError(
          502,
          "The narration audio could not be confirmed in storage.",
        );
      }
      const p = await provenance(context, output.provenance, listingId);
      const saved = await writeRow(context, reserved.id, {
        storage_key: storageKey,
        bucket: "uploads",
        provenance_id: p,
        metadata: {
          ...metadata,
          state: "completed",
          disclosure: clean(output.disclosure, 1000),
          duration_s: Number(output.duration_s) || null,
          voice_name: clean(output.voice_name, 100),
          words: Array.isArray(output.words) ? output.words.slice(0, 1500) : [],
        },
      });
      return json({ result: await publicResult(context, saved) }, 201);
    }
    const types: Record<string, string> = {
      reel: "reel-clip",
      aerial: "aerial",
      drone: "drone",
      declutter: "declutter",
    };
    const videoKind = clean(body.kind, 30), path = types[videoKind];
    if (!path) throw new HttpError(400, "Choose a supported video tool.");
    const fields = [
      "asset_id",
      "image_b64",
      "mime",
      "prompt",
      "seconds",
      "motion",
      "room",
      "time_of_day",
      "aspect",
      "region",
      "style",
      "tier",
      "target_fps",
      "space_type",
      "label",
    ];
    const forwarded: Record<string, unknown> = { listing_id: listingId };
    for (const field of fields) {
      if (body[field] !== undefined) forwarded[field] = body[field];
    }
    if (body.asset_id) {
      const { data: source, error } = await context.admin.from("capture_assets")
        .select("id,listing_id,uploaded,storage_key,bucket").eq(
          "id",
          creativeId(body.asset_id),
        ).eq("listing_id", listingId).eq("uploaded", true).maybeSingle();
      if (error || !source) {
        throw new HttpError(
          400,
          "Choose a completed source from this listing.",
        );
      }
    }
    const output = await invoke(
      req,
      context,
      `ai-video/${path}`,
      forwarded,
      requestKey,
    );
    if (
      !clean(output.request_id, 500) || !clean(output.status_url, 12000) ||
      !clean(output.response_url, 12000)
    ) {
      throw new HttpError(
        502,
        "The generation was submitted but its status could not be confirmed.",
      );
    }
    const p = await provenance(context, output.provenance, listingId);
    const saved = await writeRow(context, reserved.id, {
      provenance_id: p,
      metadata: {
        ...metadata,
        state: "processing",
        video_kind: videoKind,
        source_asset_id: body.asset_id ?? null,
        request_id: clean(output.request_id, 500),
        status_url: clean(output.status_url, 12000),
        response_url: clean(output.response_url, 12000),
        disclosure: clean(output.disclosure, 1000),
      },
    });
    return json({ result: await publicResult(context, saved) }, 202);
  } catch (error) {
    // Keep an ambiguous reservation: a user retry cannot dispatch a paid operation twice.
    await context.admin.from("studio_creative_results").update({
      metadata: {
        ...metadata,
        state: "needs_review",
        message:
          "This generation could not be confirmed. Check results before starting another.",
      },
    }).eq("id", reserved.id);
    throw error;
  }
}
