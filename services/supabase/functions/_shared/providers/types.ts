// Provider adapter interface — docs/AI-ROUTER-CONTRACT.md §2, verbatim.
//
// One shape for every vendor the router can pick. The router (../router.ts)
// decides WHICH provider/model runs; an adapter knows HOW to talk to it:
//
//   submit(step, input) -> JobRef      one bounded POST, never a retry loop
//   poll(ref)           -> JobState    one bounded GET, caller drives the clock
//   persist(done, key)  -> { key }     copy the result into OUR R2, always
//
// Rules that hold for every implementation in this directory:
//   • Never log, return, or embed a credential or a signed URL.
//   • Every network call is timeout-bounded (see common.ts BUDGETS).
//   • persist() runs BEFORE a generation is reported as successful — every
//     reseller expires media (Kie 14 d, Higgsfield 7 d, fal 24 h by our own
//     lifecycle header), so the canonical asset is always ours.

import type { RouteStep } from "../router.ts";

export interface GenerateInput {
  task: string;
  prompt?: string;
  image_url?: string; // public https URL (already in R2)
  image_b64?: string; // when the adapter must upload first
  video_url?: string;
  mask_url?: string;
  seconds?: number;
  aspect?: "16:9" | "9:16" | "1:1";
  resolution?: "720p" | "1080p" | "4k";
  text?: string; // tts
  voice_id?: string;
  extra?: Record<string, unknown>;
}

export interface JobRef {
  provider: string;
  model: string;
  id: string;
  poll_url?: string;
  submitted_at: string;
}

export type JobState =
  | { status: "queued" | "running" }
  | {
    status: "done";
    result_url: string;
    mime: string;
    duration_s?: number;
    width?: number;
    height?: number;
    meta?: Record<string, unknown>;
  }
  | {
    status: "failed";
    error_class: "rate_limit" | "upstream" | "timeout" | "validation" | "nsfw" | "other";
    message: string;
  };

export interface ProviderAdapter {
  key: string;
  submit(step: RouteStep, input: GenerateInput): Promise<JobRef>;
  poll(ref: JobRef): Promise<JobState>;
  /** Every reseller expires media (Kie 14d, Higgsfield 7d, fal configurable). The
   *  adapter copies result_url into OUR R2 and returns the R2 key. Canonical asset
   *  is always ours. */
  persist(state: Extract<JobState, { status: "done" }>, r2Key: string): Promise<{ key: string; bytes: number }>;
}

// ── Additive helpers over the contract types (no shape changes) ───────────────

/** The failure vocabulary shared by JobState and router.reportOutcome(). */
export type ErrorClass = Extract<JobState, { status: "failed" }>["error_class"];

/** A terminal done state — what persist() takes and what the callers unwrap. */
export type DoneState = Extract<JobState, { status: "done" }>;
