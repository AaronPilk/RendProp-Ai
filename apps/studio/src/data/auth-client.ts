import { AuthClient } from "@supabase/auth-js";
import type { StudioConfig } from "./config";

/** Studio sends database/storage requests through its scoped transport. Keep the
 * official Auth SDK, without bundling unused database, realtime and storage SDKs.
 * Preserve the existing PKCE/session keys so connected browsers stay signed in. */
export function createStudioAuth(config: StudioConfig, storage?: Storage, fetcher?: typeof fetch) {
  return new AuthClient({
    url: `${config.supabaseUrl}/auth/v1`,
    headers: { apikey: config.publishableKey, Authorization: `Bearer ${config.publishableKey}` },
    flowType: "pkce",
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storage,
    storageKey: `rendprop-studio-auth:${new URL(config.supabaseUrl).host}`,
    hasCustomAuthorizationHeader: false,
    ...(fetcher ? { fetch: fetcher } : {}),
  });
}
