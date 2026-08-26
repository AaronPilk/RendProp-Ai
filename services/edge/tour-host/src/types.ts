// Shared types for the tour-host Worker.
//
// The `Tour` shape mirrors exactly what `GET /tours/:slug` returns from the
// Supabase Edge Function at services/supabase/functions/tours/index.ts — that
// function is the contract this Worker renders. `Portfolio` mirrors
// `GET /portfolio/:handle` (services/supabase/functions/portfolio/index.ts),
// read defensively since brand_kit-derived fields are freeform.

export interface Env {
  /** Base URL of the Supabase Edge Functions, e.g. https://<ref>.supabase.co/functions/v1 */
  SUPABASE_FUNCTIONS_URL: string;
  /** Supabase anon key — public by design (RLS enforces access). Used as the
   *  apikey/Authorization header on the server->Supabase read and on the public
   *  browser lead/beacon calls. Provided as a Worker SECRET (`wrangler secret
   *  put SUPABASE_ANON_KEY`; `.dev.vars` for local dev), so it may be absent —
   *  all call sites default to "". The public functions are --no-verify-jwt,
   *  so requests still pass without it. */
  SUPABASE_ANON_KEY?: string;
  /** Optional: edge cache TTL (seconds) for published tour/portfolio HTML. */
  TOUR_CACHE_TTL?: string;
  /** Optional Cloudflare Turnstile SITE key (public). When set, the tour lead
   *  form renders the Turnstile widget; the leads function verifies the token
   *  with its matching TURNSTILE_SECRET_KEY. Both must be set to activate. */
  TURNSTILE_SITE_KEY?: string;
}

export interface Chapter {
  label: string;
  t_ms: number;
  sort: number;
}

export interface SecondaryLink {
  label: string;
  url: string;
}

export type CtaMode = "deeplink" | "lead_form";

export interface Cta {
  label: string;
  mode: CtaMode;
  url: string | null;
  secondary: SecondaryLink[];
  lead_fields: string[];
}

export interface TourListing {
  address: string | null;
  tagline: string | null;
  details: Record<string, unknown>;
  beds: number | null;
  baths: number | null;
  sqft: number | null;
  price_cents: number | null;
  price: string | null;
  lat: number | null;
  lng: number | null;
}

/** brand_kit (freeform jsonb) spread + name/handle. We read keys defensively. */
export interface AgentCard {
  name?: string | null;
  handle?: string | null;
  [key: string]: unknown;
}

export interface Tour {
  slug: string;
  share_url?: string;
  space_type: string;
  listing: TourListing;
  /** scrub_url ?? hls_url — legacy convenience field. Prefer the two below. */
  video_url: string | null;
  /** All-intra R2 mp4 served over HTTP byte-range. PRIMARY scrub source —
   *  frame-accurate seeks make the scroll-scrub buttery. */
  scrub_url?: string | null;
  /** Cloudflare Stream HLS manifest. FALLBACK ONLY: HLS snaps seeks to
   *  keyframes, which degrades the scroll-scrub to keyframe-stepping. */
  hls_url?: string | null;
  poster: string | null;
  duration_s: number | null;
  speed_factor: number | null;
  chapters: Chapter[];
  agent_card: AgentCard;
  cta: Cta;
  staged: boolean;
  staged_disclosure: string | null;
  disclosure_chip: string | null;
}

/** One card in the portfolio grid. The deployed portfolio function sends
 *  { slug, share_url, space_type, address, tagline, price, poster }; the extra
 *  optional keys stay for defensive rendering of older/richer payloads. */
export interface PortfolioTour {
  slug: string;
  share_url?: string | null;
  space_type?: string | null;
  address?: string | null;
  tagline?: string | null;
  title?: string | null;
  price?: string | null;
  price_cents?: number | null;
  poster?: string | null;
  beds?: number | null;
  baths?: number | null;
  sqft?: number | null;
  duration_s?: number | null;
  staged?: boolean;
}

/** GET /portfolio/:handle → { org, agent_card, tours }. */
export interface Portfolio {
  org?: { name?: string | null; handle?: string | null; space_type?: string | null };
  agent_card: AgentCard;
  tours?: PortfolioTour[];
  /** Legacy/defensive alternates still accepted by the renderer. */
  listings?: PortfolioTour[];
  space_type?: string | null;
}
