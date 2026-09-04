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
  /** Real estate: the street address. Every other space type: the BUSINESS
   *  NAME (the app stores the name in this column for non-RE listings). */
  address: string | null;
  tagline: string | null;
  /** Freeform bag. Non-RE listings carry the camelCase keys from the iOS
   *  `SpaceType.detailFields` (cuisineType, membershipPrice, weeklySpecial…);
   *  the demo/RE microsite reads snake_case editorial keys (story, gallery…). */
  details: Record<string, unknown>;
  /** 0 means "unknown" for real estate (the app never invents beds/baths) and
   *  is meaningless for other space types — render only when > 0. */
  beds: number | null;
  baths: number | null;
  sqft: number | null;
  /** 0/null = no price (non-RE listings, or an RE listing without one). */
  price_cents: number | null;
  price: string | null;
  lat: number | null;
  lng: number | null;
  /** Defensive mirrors of the top-level fields (the tours function may nest them). */
  sold_at?: string | null;
  status?: string | null;
}

/**
 * One AI-altered / AI-generated asset, sourced from `media_provenance`
 * (W2-B: `tours/index.ts` returns `altered_media[]`).
 *
 * EVERY field is optional and the whole array may be absent: older deployed
 * versions of the tours function do not send it at all, and the page must
 * render correctly without it. `original_url` is null when the unaltered
 * source was never published to the public bucket.
 */
export interface AlteredMedium {
  /** "Living room", "Aerial intro". */
  label?: string | null;
  /** photo_edit | virtual_stage | declutter | aerial | reel | other. */
  kind?: string | null;
  /** The sentence shown publicly (written server-side at generation time). */
  disclosure?: string | null;
  /** The model family in plain words ("AI image edit" / "AI video"). The tours
   *  function sends this; the renderer falls back to deriving it from `kind`. */
  model?: string | null;
  created_at?: string | null;
  /** Public URL of the UNALTERED source (CA AB 723 "access to the original"). */
  original_url?: string | null;
  /** Public URL of the published altered asset. */
  altered_url?: string | null;
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
  /** `${TOUR_BASE}/u/<slug>` — the MLS-safe link (W2-B). The Worker derives the
   *  same URL from the slug, so this is informational only and is never
   *  rendered; it is dropped from the sanitized unbranded tour. */
  unbranded_url?: string | null;
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
  /** Per-asset AI disclosure rows (W2-B). Optional — absent on older payloads. */
  altered_media?: AlteredMedium[] | null;
  /** Public URL of the listing's floor plan image (W2-B). Optional. */
  floorplan_url?: string | null;
  /** ISO timestamp when the listing was marked sold (real estate) / archived
   *  (other types). Non-null → the page shows a SOLD / Archived badge and, for
   *  real estate, swaps "Book a showing" for "Ask about similar homes". */
  sold_at?: string | null;
  /** listings.status — 'draft'|'capturing'|'processing'|'ready'|'expired'|'archived'. */
  status?: string | null;
  /** Convenience booleans the tours function derives from the two above. */
  sold?: boolean;
  archived?: boolean;
  published_at?: string | null;
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
