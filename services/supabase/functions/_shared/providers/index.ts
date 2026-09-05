// The adapter registry. resolveRoute() returns a provider NAME; this is the
// only place that turns one into code.
//
// A provider with no adapter is a `validation` failure, not a crash: the chain
// loop reports the outcome and moves to the next step, so a routing row that
// names a provider this deploy does not know degrades to the next vendor
// instead of 500-ing the request.

import type { ProviderAdapter } from "./types.ts";
import { ProviderError } from "./common.ts";
import { falAdapter } from "./fal.ts";
import { kieAdapter } from "./kie.ts";
import { higgsfieldAdapter } from "./higgsfield.ts";
import { openaiAdapter } from "./openai.ts";
import { anthropicAdapter } from "./anthropic.ts";
import { geminiAdapter } from "./gemini.ts";
import { elevenlabsAdapter } from "./elevenlabs.ts";

const REGISTRY: Record<string, ProviderAdapter> = {
  [falAdapter.key]: falAdapter,
  [kieAdapter.key]: kieAdapter,
  [higgsfieldAdapter.key]: higgsfieldAdapter,
  [openaiAdapter.key]: openaiAdapter,
  [anthropicAdapter.key]: anthropicAdapter,
  [geminiAdapter.key]: geminiAdapter,
  [elevenlabsAdapter.key]: elevenlabsAdapter,
};

/** The adapter for a routing row's `provider`. Throws for an unknown one. */
export function adapterFor(provider: string): ProviderAdapter {
  const a = REGISTRY[provider.trim().toLowerCase()];
  if (!a) {
    throw new ProviderError(provider, "validation", `No adapter is registered for provider "${provider}"`);
  }
  return a;
}

/** Provider names this deploy can actually run (admin/diagnostics). */
export function knownProviders(): string[] {
  return Object.keys(REGISTRY).sort();
}

export { anthropicAdapter, elevenlabsAdapter, falAdapter, geminiAdapter, higgsfieldAdapter, kieAdapter, openaiAdapter };
export * from "./types.ts";
export {
  BUDGETS,
  ProviderError,
  awaitJob,
  errorClassOf,
  persistedUrl,
  routedR2Key,
} from "./common.ts";
