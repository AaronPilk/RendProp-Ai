// Reel clips must have a funded, explicitly routed provider before a supplier
// hold or POST. FAL's account balance is not available to this service and its
// current account is exhausted; a route row or configured key is not proof of
// funding. Keep FAL out of this path until it has a separate live balance gate.
import { HttpError } from "../_shared/http.ts";
import type { RouteStep } from "../_shared/router.ts";

type Dependencies = {
  kieKey: () => string | undefined;
  kieCredits: (key: string) => Promise<number>;
};

const unavailable = () => new HttpError(
  503,
  "AI camera is temporarily unavailable. Choose Photo motion or try again later. No clip was sent.",
  "upstream",
);
const noCredits = () => new HttpError(
  402,
  "AI camera is waiting for processing capacity. No clip was sent; try again later.",
  "upstream",
);

/** KIE credits cost $0.005 each. Never infer provider funding from a secret or
 * a route row alone. The account read is free and fails closed on any unknown
 * response; the provider's createTask 402 remains the final race-safe guard. */
export async function readKieAccountCredits(key: string): Promise<number> {
  let response: Response;
  try {
    response = await fetch("https://api.kie.ai/api/v1/chat/credit", {
      method: "GET", headers: { Authorization: `Bearer ${key}` },
      redirect: "error", signal: AbortSignal.timeout(6000),
    });
  } catch { throw noCredits(); }
  if (!response.ok) throw noCredits();
  const length = Number(response.headers.get("content-length"));
  if (Number.isFinite(length) && length > 4096) throw noCredits();
  let body: unknown;
  try {
    const raw = await response.text();
    if (raw.length > 4096) throw Error("Oversized credit reply");
    body = JSON.parse(raw);
  } catch { throw noCredits(); }
  const answer = body as { code?: unknown; data?: unknown } | null;
  // KIE has returned HTTP 200 with body.code=401 for rejected API keys.
  const credits = typeof answer?.data === "string" ? Number(answer.data) : answer?.data;
  if (answer?.code !== 200 || typeof credits !== "number" ||
      !Number.isFinite(credits) || credits < 0) throw noCredits();
  return credits;
}

/** Block FAL-only and underfunded KIE server-job recipes before a job is
 * admitted. Existing completed/retained jobs can still be read or composed. */
export async function admitFundedReelRecipe(
  quote: { provider: string; reel_cents: number },
  requiredCents = quote.reel_cents,
  deps: Dependencies = {
    kieKey: () => Deno.env.get("KIE_API_KEY")?.trim(),
    kieCredits: readKieAccountCredits,
  },
): Promise<void> {
  if (quote.provider !== "kie" || !Number.isFinite(requiredCents) || requiredCents <= 0) throw unavailable();
  const key = deps.kieKey()?.trim();
  if (!key) throw noCredits();
  let balance: number;
  try { balance = await deps.kieCredits(key); }
  catch { throw noCredits(); }
  if (!Number.isFinite(balance) || balance < Math.ceil(requiredCents / 0.5)) throw noCredits();
}

export async function admitFundedReelSteps(
  steps: RouteStep[], seconds: number,
  deps: Dependencies = {
    kieKey: () => Deno.env.get("KIE_API_KEY")?.trim(),
    kieCredits: readKieAccountCredits,
  },
): Promise<RouteStep[]> {
  const kie = steps.find(step => step.enabled === true && step.provider === "kie" &&
    step.task === "video.reel_clip" && step.unit === "second" &&
    Number.isFinite(step.unit_cents) && step.unit_cents > 0);
  if (!kie || !Number.isInteger(seconds) || seconds < 2 || seconds > 12) throw unavailable();
  const key = deps.kieKey()?.trim();
  if (!key) throw noCredits();
  const required = Math.ceil(seconds * kie.unit_cents / 0.5);
  let balance: number;
  try { balance = await deps.kieCredits(key); }
  catch { throw noCredits(); }
  if (!Number.isFinite(balance) || balance < required) throw noCredits();
  // One priced route per logical attempt; never fall through to an unproven
  // alternative after a lost acknowledgement or an exhausted account.
  return [kie];
}
