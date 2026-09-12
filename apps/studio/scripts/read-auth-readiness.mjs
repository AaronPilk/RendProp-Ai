// GET-only configuration inspection. Never prints keys, client secrets, tokens,
// arbitrary server bodies or identities. This script cannot change Apple/native auth.
import { readFile } from "node:fs/promises";
const project = "ymgqpbnjpztwjsyvceld";
const token = (
  await readFile(
    "/Users/pilksclaes/Rendprop AI/_bridge/.supabase-token",
    "utf8",
  )
).trim();
const response = await fetch(
  `https://api.supabase.com/v1/projects/${project}/config/auth`,
  {
    headers: { Authorization: `Bearer ${token}` },
    redirect: "error",
    signal: AbortSignal.timeout(15000),
  },
);
if (!response.ok)
  throw new Error(`Auth readiness read failed (${response.status}).`);
const config = await response.json();
const clientIds = String(config.external_apple_client_id ?? "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
const redirects = String(config.uri_allow_list ?? "")
  .split(",")
  .filter(Boolean);
console.log(
  JSON.stringify(
    {
      project,
      read_at: new Date().toISOString(),
      apple_enabled: config.external_apple_enabled === true,
      apple_client_ids: clientIds,
      has_native_audience: clientIds.includes("com.rendprop.app"),
      has_web_audience: clientIds.some((s) => s !== "com.rendprop.app"),
      apple_secret_field_returned: Object.hasOwn(
        config,
        "external_apple_secret",
      ),
      apple_secret_nonempty_in_response: Boolean(config.external_apple_secret),
      studio_redirect_allowed: redirects.some(
        (s) =>
          s === "https://studio.rendprop.com/" ||
          s === "https://studio.rendprop.com/**",
      ),
      site_url_is_studio: config.site_url === "https://studio.rendprop.com",
      read_only: true,
    },
    null,
    2,
  ),
);
