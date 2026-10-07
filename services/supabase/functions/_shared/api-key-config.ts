import { HttpError } from "./http.ts";

/** Runtime-injected keys are independently revocable. A malformed injected
 * dictionary must never silently select the compromised legacy credential. */
export function runtimeApiKey(
  dictionary: string | undefined,
  name: string,
  kind: "secret" | "publishable",
  legacy: string | undefined,
): string | undefined {
  if (dictionary === undefined) return legacy;
  let keys: unknown;
  try { keys = JSON.parse(dictionary); } catch { throw unavailable(); }
  if (!keys || typeof keys !== "object" || Array.isArray(keys)) throw unavailable();
  const value = Object.hasOwn(keys, name) ? (keys as Record<string, unknown>)[name] : undefined;
  if (typeof value !== "string" || !new RegExp(`^sb_${kind}_[A-Za-z0-9_-]{16,}$`).test(value)) throw unavailable();
  return value;
}

function unavailable(): HttpError {
  return new HttpError(503, "Backend credentials are unavailable. Please retry shortly.", "upstream");
}

/** Modern credentials authenticate service callers only on the apikey header.
 * The temporary legacy bridge is explicit and removed at the coordinated
 * client/Vault/worker cutover. Development without injected modern keys keeps
 * the legacy fixture contract. User JWT role claims confer no service access. */
export function serviceKeyMatches(
  req: Request,
  selected: string | undefined,
  legacy: string | undefined,
  legacyBridge: string | undefined,
): boolean {
  if (!selected) return false;
  if (selected.startsWith("sb_secret_")) {
    if (req.headers.get("apikey") === selected) return true;
    if (legacyBridge !== "enabled") return false;
  }
  const parts = (req.headers.get("authorization") ?? "").trim().split(/\s+/);
  return parts.length === 2 && parts[0].toLowerCase() === "bearer"
    && !!legacy && parts[1] === legacy;
}
