export class StudioError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly status?: number,
  ) {
    super(message);
    this.name = "StudioError";
  }
}

export type StudioConfig = Readonly<{
  supabaseUrl: string;
  publishableKey: string;
  redirectTo: string;
}>;

function safeOrigin(value: string, label: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new StudioError("configuration", `${label} must be a valid URL.`);
  }
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (
    (url.protocol !== "https:" && !(local && url.protocol === "http:")) ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    url.pathname !== "/"
  ) {
    throw new StudioError(
      "configuration",
      `${label} must be an HTTPS origin (HTTP is allowed only for localhost).`,
    );
  }
  return url.origin;
}

export function validateStudioConfig(config: StudioConfig): StudioConfig {
  const supabaseUrl = safeOrigin(config.supabaseUrl, "Supabase URL");
  const redirectTo = `${safeOrigin(config.redirectTo, "Studio redirect URL")}/`;
  const key = config.publishableKey.trim();
  let isPublic = /^sb_publishable_[A-Za-z0-9_-]{16,}$/.test(key);
  if (
    !isPublic &&
    /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(key)
  ) {
    try {
      const encoded = key.split(".")[1]!.replace(/-/g, "+").replace(/_/g, "/");
      const payload = JSON.parse(
        atob(encoded.padEnd(Math.ceil(encoded.length / 4) * 4, "=")),
      ) as Record<string, unknown>;
      // This is a configuration check, never authentication or JWT verification.
      isPublic = payload.role === "anon";
    } catch {
      isPublic = false;
    }
  }
  if (!isPublic)
    throw new StudioError(
      "configuration",
      "Use a Supabase publishable key or legacy anon key. Secret and service-role keys are forbidden in the browser.",
    );
  return Object.freeze({ supabaseUrl, publishableKey: key, redirectTo });
}

/** Accept only public project configuration. Never read a server credential file. */
export function readStudioConfig(
  env: Record<string, unknown>,
  origin: string,
): StudioConfig {
  for (const name of Object.keys(env)) {
    if (
      /^VITE_.*(?:SERVICE_ROLE|SECRET|PRIVATE_KEY|ACCESS_TOKEN)/i.test(name) &&
      env[name]
    ) {
      throw new StudioError(
        "configuration",
        "A private credential is present in browser environment variables. Remove it before building Studio.",
      );
    }
  }
  // Vite embeds the entire import.meta.env object used by App. Even an unused
  // fallback value must not bypass validation and enter the public bundle.
  if (
    env.VITE_SUPABASE_PUBLISHABLE_KEY !== undefined &&
    env.VITE_SUPABASE_ANON_KEY !== undefined
  ) {
    throw new StudioError(
      "configuration",
      "Set only VITE_SUPABASE_PUBLISHABLE_KEY or VITE_SUPABASE_ANON_KEY, never both. Remove the unused browser key field before building Studio.",
    );
  }
  const supabaseUrl = env.VITE_SUPABASE_URL;
  const publishableKey =
    env.VITE_SUPABASE_PUBLISHABLE_KEY ?? env.VITE_SUPABASE_ANON_KEY;
  if (
    typeof supabaseUrl !== "string" ||
    typeof publishableKey !== "string" ||
    !supabaseUrl ||
    !publishableKey
  ) {
    throw new StudioError(
      "configuration",
      "Add VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY to connect your Rendprop account.",
    );
  }
  return validateStudioConfig({
    supabaseUrl,
    publishableKey,
    redirectTo: origin,
  });
}
