import { createRoot } from "react-dom/client";
import type { Session, AuthChangeEvent } from "@supabase/supabase-js";
import App from "../../src/App";
import { createStudioServices, type StudioAuth } from "../../src/data";
import "../../src/styles.css";

// Separately bundled test entry, never imported by src/main.tsx. No real Auth,
// provider redirect, customer fixture, remote request or secret is used here.
const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const ORG = "33333333-3333-4333-8333-333333333333";
const OTHER = "44444444-4444-4444-8444-444444444444";
let user = A;
let mode = "ok";
let callbacks: (event: AuthChangeEvent, session: Session | null) => void = () => {};
let release: (() => void) | undefined;
const calls: { path: string; org?: string | null }[] = [];
const session = (): Session => ({
  access_token: "isolated-fixture-not-a-token",
  refresh_token: "isolated-fixture-not-a-refresh-token",
  token_type: "bearer", expires_in: 3600,
  user: { id: user, email: "fixture@example.invalid", is_anonymous: false,
    aud: "authenticated", app_metadata: {}, user_metadata: {}, created_at: "2026-09-12T00:00:00Z" },
});
const auth: StudioAuth = {
  getSession: async () => ({ data: { session: session() }, error: null }),
  refreshSession: async () => ({ data: { session: session() }, error: null }),
  onAuthStateChange(callback) { callbacks = callback; return { data: { subscription: { unsubscribe() {} } } }; },
  async signInWithOAuth() { throw new Error("No provider operation is permitted in this fixture"); },
  async signOut() { callbacks("SIGNED_OUT", null); return { error: null }; },
};
const fetcher: typeof fetch = async (input, options) => {
  const url = new URL(String(input));
  const org = new Headers(options?.headers).get("X-Org-Id") ?? ORG;
  const actor = user;
  calls.push({ path: url.pathname, org });
  if (calls.length > 100) throw new Error("Unexpected request loop");
  if (url.pathname === "/rest/v1/memberships") {
    if (mode === "hold") await new Promise<void>((resolve) => {
      const done = () => { options?.signal?.removeEventListener("abort", done); resolve(); };
      release = done;
      options?.signal?.addEventListener("abort", done, { once: true });
    });
    if (mode === "403" || mode === "503") return Response.json({}, { status: Number(mode) });
    return Response.json([ORG, OTHER].map((id) => ({ user_id: actor, org_id: id, role: "owner",
      orgs: { id, name: id === ORG ? "Fixture business" : "Second business", space_type: "real_estate", deleted_at: null } })), { headers: { "Content-Range": "0-1/2" } });
  }
  if (url.pathname === "/functions/v1/me") return Response.json({
    user: { id: actor, name: actor === A ? "Fixture A" : "Fixture B", email: "fixture@example.invalid", avatar_url: null },
    org: { id: org, name: org === ORG ? "Fixture business" : "Second business", handle: null, space_type: "real_estate" },
    plan: "free", plan_raw: "trial", trial_ends_at: null, plan_expires_at: null,
    usage: { listings: 0, leads: 0, leads_new: 0, renders: 0 },
  });
  if (url.pathname === "/rest/v1/listings") {
    if (url.searchParams.get("org_id") !== `eq.${org}`) throw new Error("Missing selected workspace filter");
    return Response.json([], { headers: { "Content-Range": "*/0" } });
  }
  throw new Error(`Unexpected fixture request: ${url.pathname}`);
};
const servicesFactory = () => createStudioServices({
  supabaseUrl: "https://studio-isolated-fixture.supabase.co",
  publishableKey: "sb_publishable_ISOLATED_FIXTURE_NOT_REAL",
  redirectTo: `${window.location.origin}/`,
}, { auth, fetch: fetcher, readTimeoutMs: 5000 });
Object.assign(window, { studioFixture: {
  setMode(next: string) { mode = next; },
  release() { mode = "ok"; release?.(); release = undefined; },
  switchUser(next: "A" | "B") { user = next === "A" ? A : B; callbacks("SIGNED_IN", session()); },
  calls() { return calls.slice(); },
} });
createRoot(document.getElementById("root")!).render(<App servicesFactory={servicesFactory} />);
