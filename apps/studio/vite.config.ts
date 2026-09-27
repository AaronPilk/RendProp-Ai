import { defineConfig, loadEnv } from "vite";
import { readStudioConfig } from "./src/data/config.ts";

export default defineConfig(({ mode }) => {
  const browserEnv = loadEnv(mode, process.cwd(), "VITE_");
  const allowed = new Set([
    "VITE_SUPABASE_URL",
    "VITE_SUPABASE_PUBLISHABLE_KEY",
    "VITE_SUPABASE_ANON_KEY",
  ]);
  for (const key of Object.keys(browserEnv))
    if (!allowed.has(key))
      throw new Error(
        "Unexpected VITE_ variable. Studio permits only its three public Supabase configuration fields.",
      );
  // Reject a server credential BEFORE bundling. A runtime-only check would still
  // ship the rejected value inside JavaScript downloaded by every visitor.
  if (Object.keys(browserEnv).length)
    readStudioConfig(browserEnv, "https://studio.rendprop.com");
  return {
    build: { sourcemap: false, manifest:true },
    server: { host: "127.0.0.1" },
    preview: { host: "127.0.0.1" },
  };
});
