import { decideGhlTagAction, type GhlCleanupTarget } from "../me/logic.ts";

const digits = (value: string | undefined) => { const n = (value ?? "").replace(/\D/g, ""); return n.length === 11 && n.startsWith("1") ? n.slice(1) : n; };
const exact = (contact: { email?: string; phone?: string }, target: GhlCleanupTarget) =>
  (!!target.email && contact.email?.trim().toLowerCase() === target.email.trim().toLowerCase()) ||
  (!!target.phone && digits(target.phone).length >= 7 && digits(contact.phone) === digits(target.phone));

/** Legacy shared CRM only. Exact identity plus current org tags are required
 * before deletion; a multi-tenant match loses only this tenant's tag. */
export async function cleanupLegacyGhlTarget(target: GhlCleanupTarget, fetchImpl: typeof fetch = fetch) {
  const key = Deno.env.get("GHL_API_KEY")?.trim(), location = Deno.env.get("GHL_LOCATION_ID")?.trim();
  if (!key || !location) throw new Error("Legacy CRM cleanup is not configured.");
  if (!target.email && !target.phone) throw new Error("Legacy CRM identity is missing.");
  const headers = { Authorization: `Bearer ${key}`, Version: "2021-07-28", Accept: "application/json" };
  const deadline = Date.now() + 20_000;
  const request = (url: string, init: RequestInit = {}) => {
    const remaining = deadline - Date.now(); if (remaining <= 0) throw new Error("Legacy CRM cleanup deadline reached.");
    return fetchImpl(url, { ...init, headers: { ...headers, ...init.headers }, signal: AbortSignal.timeout(Math.min(10_000, remaining)), redirect: "error" });
  };
  const read = async (response: Response): Promise<Record<string, unknown>> => {
    if (!response.ok || !response.body) throw new Error("Legacy CRM lookup was not confirmed.");
    const reader = response.body.getReader(); const decoder = new TextDecoder(); let size = 0, text = "";
    try {
      while (true) { const part = await reader.read(); if (part.done) break; size += part.value.length; if (size > 131072) throw new Error("Legacy CRM response exceeds its bound."); text += decoder.decode(part.value, { stream: true }); }
      const body = JSON.parse(text + decoder.decode());
      if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("Legacy CRM receipt is unreadable.");
      return body;
    } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  };
  let removed = 0, untagged = 0, leftover = 0;
  const seen = new Set<string>();
  for (const query of [target.email, target.phone].filter((x): x is string => !!x)) {
    const url = new URL("https://services.leadconnectorhq.com/contacts/"); url.searchParams.set("locationId", location); url.searchParams.set("query", query); url.searchParams.set("limit", "20");
    const result = await read(await request(url.href));
    if (!Array.isArray(result.contacts) || result.contacts.length > 20) throw new Error("Legacy CRM contact inventory is unreadable.");
    const meta = result.meta as { nextPageUrl?: unknown; total?: unknown } | undefined;
    if (meta?.nextPageUrl || (typeof meta?.total === "number" && meta.total > result.contacts.length)) throw new Error("Legacy CRM inventory requires assisted pagination.");
    for (const item of result.contacts) {
      if (!item || typeof item !== "object" || !exact(item, target)) continue;
      const id = (item as { id?: unknown }).id;
      if (typeof id !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(id)) throw new Error("Legacy CRM contact identity is unreadable.");
      if (seen.has(id)) continue; seen.add(id);
      const full = await read(await request(`https://services.leadconnectorhq.com/contacts/${id}`));
      const contact = full.contact as { email?: string; phone?: string; tags?: unknown } | undefined;
      if (!contact || !exact(contact, target)) { leftover++; continue; }
      const decision = decideGhlTagAction(contact.tags, target.org_id);
      if (decision.action === "leftover") { leftover++; continue; }
      const response = decision.action === "untag"
        ? await request(`https://services.leadconnectorhq.com/contacts/${id}/tags`, { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ tags: [decision.tag] }) })
        : await request(`https://services.leadconnectorhq.com/contacts/${id}`, { method: "DELETE" });
      await response.body?.cancel().catch(() => {});
      if (!response.ok && !(response.status === 404 && decision.action === "delete")) throw new Error("Legacy CRM cleanup was not acknowledged.");
      if (decision.action === "untag") untagged++; else removed++;
    }
  }
  return { removed, untagged, leftover };
}
