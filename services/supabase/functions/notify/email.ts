// email.ts — one interface, one provider.
//
// SECRETS:
//   RESEND_API_KEY     the provider key
//   NOTIFY_FROM_EMAIL  the From address, e.g. "Rendprop <hello@rendprop.com>"
//
// With either missing, `configured()` is false, the drain marks every e-mail
// row `skipped` with a reason and carries on with push. Nothing throws.
//
// WHY RESEND IS THE ONE THAT SHIPPED: it is one key and one POST. No SDK, no
// webhook to receive, no domain-verification dance in the request path. The
// point of an outbox is that the provider is the replaceable part, so the
// shape below is what matters more than the choice:
//
//   sendEmail(message) → EmailResult          the ONLY thing index.ts calls
//   EmailProvider                              { name, configured, missingReason, send }
//
// ADDING A SECOND PROVIDER IS A NEW FUNCTION, NOT A REWRITE: write
// `sendViaPostmark(message, fetchImpl)` with the same signature as
// `sendViaResend`, add it to PROVIDERS below, and `sendEmail()` picks the first
// one whose secrets are present. Nothing in index.ts changes, nothing in the
// database changes, and rows already queued go out through whichever provider
// is configured when the drain next runs.

export interface EmailMessage {
  to: string;
  subject: string;
  text: string;
}

export interface EmailResult {
  ok: boolean;
  /** The provider's message id, recorded in notification_log. */
  id: string | null;
  /** Set when ok is false — goes into notification_outbox.last_error. */
  reason: string | null;
  /** True when THIS address will never accept mail (a hard bounce shape). */
  dead: boolean;
}

export interface EmailProvider {
  name: string;
  configured(): boolean;
  missingReason(): string;
  send(message: EmailMessage, fetchImpl: typeof fetch): Promise<EmailResult>;
}

// ── Resend ───────────────────────────────────────────────────────────────────

// Read at CALL time, not at module load — same reason as apns.ts: a key added
// to the project takes effect on the next drain, not the next cold start.
const env = (name: string): string | undefined => {
  const v = Deno.env.get(name);
  return v && v.trim() ? v : undefined;
};

const RESEND_VARS = ["RESEND_API_KEY", "NOTIFY_FROM_EMAIL"] as const;

async function sendViaResend(
  message: EmailMessage,
  fetchImpl: typeof fetch,
): Promise<EmailResult> {
  let res: Response;
  try {
    res = await fetchImpl("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env("RESEND_API_KEY")}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: env("NOTIFY_FROM_EMAIL"),
        to: [message.to],
        subject: message.subject,
        text: message.text,
      }),
    });
  } catch (e) {
    return {
      ok: false,
      id: null,
      reason: `resend unreachable: ${e instanceof Error ? e.message : String(e)}`,
      dead: false,
    };
  }

  let body: Record<string, unknown> = {};
  try {
    body = (await res.json()) as Record<string, unknown>;
  } catch {
    body = {};
  }

  if (res.ok) {
    const id = typeof body.id === "string" ? body.id : null;
    return { ok: true, id, reason: null, dead: false };
  }

  const detail = typeof body.message === "string" ? body.message : `resend ${res.status}`;
  // 422 is Resend's "this address/payload is not acceptable" — retrying it
  // forever is how a queue silts up. 4xx other than 429 is the same judgement.
  const dead = res.status === 422 || (res.status >= 400 && res.status < 500 && res.status !== 429);
  return { ok: false, id: null, reason: detail.slice(0, 300), dead };
}

export const resendProvider: EmailProvider = {
  name: "resend",
  configured: () => RESEND_VARS.every((n) => env(n) !== undefined),
  missingReason: () =>
    `email is not configured: set ${RESEND_VARS.filter((n) => !env(n)).join(", ")}`,
  send: sendViaResend,
};

/** Registration order is preference order. A second provider is one more entry. */
const PROVIDERS: EmailProvider[] = [resendProvider];

/** The configured provider, or null when none of them has its secrets. */
export function activeProvider(): EmailProvider | null {
  return PROVIDERS.find((p) => p.configured()) ?? null;
}

export function configured(): boolean {
  return activeProvider() !== null;
}

/** The one sentence the drain writes into `last_error` when nothing is configured. */
export function missingReason(): string {
  return PROVIDERS[0].missingReason();
}

/**
 * Send one e-mail through whichever provider is configured. NEVER throws.
 * `fetchImpl` is injectable so the tests can run without a network.
 */
export async function sendEmail(
  message: EmailMessage,
  fetchImpl: typeof fetch = fetch,
): Promise<EmailResult> {
  const provider = activeProvider();
  if (!provider) {
    return { ok: false, id: null, reason: missingReason(), dead: false };
  }
  try {
    return await provider.send(message, fetchImpl);
  } catch (e) {
    return {
      ok: false,
      id: null,
      reason: `${provider.name}: ${e instanceof Error ? e.message : String(e)}`,
      dead: false,
    };
  }
}
