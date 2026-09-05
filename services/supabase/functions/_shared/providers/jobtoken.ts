// The opaque job token that lets ONE async status route serve every provider.
//
// ai-video submits and returns 202 with { request_id, status_url, response_url },
// and the shipped app hands those three strings back to GET /ai-video/status
// verbatim — it never looks inside them (LiveAPIClient percent-encodes and
// returns them as-is). So for a routed job we mint a URL addressed to OUR OWN
// status route carrying the vendor job in a query parameter, and one code path
// serves fal, Kie and Higgsfield with no client change at all.
//
// WHAT A TOKEN MAY CONTAIN: provider, model, vendor job id, vendor poll URL,
// submit time, task. Nothing else. NO credential, NO signed URL, NO org id —
// the status route re-derives the org from the caller's own JWT rather than
// trusting anything that made a round trip through a client.
//
// A token is NOT a capability: it is base64url of JSON, unsigned and readable.
// Everything it can reach is re-authorised server-side — the request is
// JWT-authenticated like every other route, and each adapter re-validates the
// poll URL against its own host allowlist before it fetches with our key, so a
// forged token cannot point our credentials at somebody else's host.

import type { JobRef } from "./types.ts";

export interface RouterJobToken {
  p: string; // provider
  m: string; // model
  i: string; // vendor job id
  u?: string; // vendor poll url
  t: string; // submitted_at
  k: string; // task
}

export function encodeJobToken(job: RouterJobToken): string {
  const bytes = new TextEncoder().encode(JSON.stringify(job));
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function decodeJobToken(raw: string): RouterJobToken | null {
  try {
    const b64 = raw.replace(/-/g, "+").replace(/_/g, "/");
    const bin = atob(b64.padEnd(Math.ceil(b64.length / 4) * 4, "="));
    const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    const parsed = JSON.parse(new TextDecoder().decode(bytes)) as Partial<RouterJobToken>;
    if (!parsed || typeof parsed.p !== "string" || typeof parsed.m !== "string" || typeof parsed.i !== "string") {
      return null;
    }
    if (parsed.u !== undefined && typeof parsed.u !== "string") return null;
    return { p: parsed.p, m: parsed.m, i: parsed.i, u: parsed.u, t: String(parsed.t ?? ""), k: String(parsed.k ?? "") };
  } catch {
    return null;
  }
}

/** OUR status URL for a routed job, built from the request's own origin. */
export function routerStatusUrl(req: Request, functionName: string, task: string, ref: JobRef): string {
  const u = new URL(req.url);
  const parts = u.pathname.split("/").filter(Boolean);
  const idx = parts.lastIndexOf(functionName);
  const base = idx >= 0 ? `/${parts.slice(0, idx + 1).join("/")}` : `/${functionName}`;
  const token = encodeJobToken({
    p: ref.provider,
    m: ref.model,
    i: ref.id,
    u: ref.poll_url,
    t: ref.submitted_at,
    k: task,
  });
  return `${u.origin}${base}/status?job=${token}`;
}

/**
 * The routed job named by a status request, or null when this is a legacy fal
 * poll (status_url on queue.fal.run, no `job` parameter) and the caller should
 * take the unchanged legacy path.
 */
export function routerJobFrom(params: URLSearchParams): RouterJobToken | null {
  const direct = params.get("job");
  if (direct) return decodeJobToken(direct);
  const statusUrl = params.get("status_url");
  if (!statusUrl) return null;
  try {
    const token = new URL(statusUrl).searchParams.get("job");
    return token ? decodeJobToken(token) : null;
  } catch {
    return null;
  }
}
