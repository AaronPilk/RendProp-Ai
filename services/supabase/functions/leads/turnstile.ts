// turnstile.ts — Cloudflare Turnstile verification for the public lead form.
//
// Pulled out of index.ts (which calls Deno.serve at module load and so is
// never imported by a test — see events/schema.ts or admin/funnel.ts for the
// same pattern in this codebase) so this gets a direct unit test with a
// stubbed `fetch` instead of only being reachable through an HTTP-level
// integration test. See turnstile.test.ts.
//
// ── Audit: "Turnstile fails open when unconfigured" ─────────────────────────
//
// Before this fix, `TURNSTILE_SECRET_KEY` unset meant verifyTurnstile()
// returned `true` unconditionally — the public lead form had NO bot
// protection at all (the honeypot catches only the laziest bots) until
// someone remembered to set the secret, and nothing said so at runtime.
//
// This now FAILS CLOSED: a missing secret REJECTS the submission. There is no
// separate "environment" concept anywhere in this codebase (grepping
// `_shared/` turns up per-provider required-secret checks — e.g.
// `_shared/r2.ts`'s `endpoint()`, `_shared/providers/gemini.ts`'s
// `geminiKey()` — each of which throws naming the exact missing var, not a
// NODE_ENV-style dev/prod switch), so "the secret is missing" IS the signal
// here too, exactly like every other required credential in this codebase.
//
// The one deliberate escape hatch is `TURNSTILE_OPTIONAL=1`: an explicit,
// opt-IN acknowledgment (not a default) that a local dev box or a
// not-yet-configured production deploy is knowingly running without bot
// protection. Whichever path is taken when the secret is missing — rejected,
// or allowed via the opt-out — a single unmistakable warning naming
// `TURNSTILE_SECRET_KEY` is logged every time, so an operator who left it
// unset (with or without the opt-out) cannot miss it in the function logs.
//
// See services/supabase/DEPLOYMENT.md, functions/README.md, and
// leads/README.md for where these two env vars are documented, and
// docs/LAUNCH-CHECKLIST.md item 12.

/** True when the caller has knowingly opted out of Turnstile verification. */
function turnstileOptedOut(): boolean {
  return Deno.env.get("TURNSTILE_OPTIONAL") === "1";
}

/**
 * Verify a Cloudflare Turnstile token.
 *
 *   secret set,   token valid    -> true
 *   secret set,   token missing/bad, or the verify call itself errors -> false
 *   secret unset, TURNSTILE_OPTIONAL !== "1" -> false (FAIL CLOSED) + warning logged
 *   secret unset, TURNSTILE_OPTIONAL === "1" -> true  (deliberate opt-out)  + warning logged
 */
export async function verifyTurnstile(token: string | undefined, ip: string): Promise<boolean> {
  const secret = Deno.env.get("TURNSTILE_SECRET_KEY");
  if (!secret) {
    const optedOut = turnstileOptedOut();
    // One unmistakable line either way — an operator who left the secret
    // unset must see this in the logs whether the result was "rejected" or
    // "allowed because TURNSTILE_OPTIONAL=1", not just once at first deploy.
    console.error(
      `leads: TURNSTILE_SECRET_KEY is not set — ${
        optedOut ? "ALLOWING public lead submissions with NO bot protection (TURNSTILE_OPTIONAL=1 is set)" : "REJECTING public lead submissions"
      }. Set TURNSTILE_SECRET_KEY (see services/supabase/DEPLOYMENT.md), or set TURNSTILE_OPTIONAL=1 to accept no bot protection knowingly.`,
    );
    return optedOut;
  }
  if (!token) return false;
  try {
    const form = new URLSearchParams();
    form.set("secret", secret);
    form.set("response", token);
    if (ip && ip !== "unknown") form.set("remoteip", ip);
    const res = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const data = await res.json().catch(() => ({ success: false }));
    return data?.success === true;
  } catch (e) {
    console.error("Turnstile verify error:", e);
    return false; // a configured verifier that errors should not let bots through
  }
}
