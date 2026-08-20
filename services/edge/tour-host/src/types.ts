// Shared types for the tour-host Worker.
//
// The `Tour` shape mirrors exactly what `GET /tours/:slug` returns from the
// Supabase Edge Function at services/supabase/functions/tours/index.ts — that
// function is the contract this Worker renders. `Portfolio` is defensive because
// `GET /portfolio/:handle` is not implemented yet (see README TODOs).

export interface Env {
  /** Base URL of the Supabase Edge Functions, e.g. https://<ref>.supabase.co/functions/v1 */
  SUPABASE_FUNCTIONS_URL: string;
  /** Supabase anon key — public by design (RLS enforces access). Used as the
   *  apikey/Authorization header on the server->Supabase read and on the public
   *  browser lead/beacon calls. */
  SUPABASE_ANON_KEY: string;
  /** Optional: edge cache TTL (seconds) for published tour/portfolio HTML. */
  TOUR_CACHE_TTL?: string;
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
  video_url: string | null;
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

/** One card in the portfolio grid. Keys are best-effort — the endpoint isn't
 *  built yet, so `renderPortfolioPage` normalizes whatever it receives. */
export interface PortfolioTour {
  slug: string;
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

export interface Portfolio {
  agent_card: AgentCard;
  /** The contract says `[tour summaries]`; we accept `tours`, `listings`, or an
   *  array under a few likely keys and normalize in the renderer. */
  tours?: PortfolioTour[];
  listings?: PortfolioTour[];
  space_type?: string | null;
}
