// Per-industry call-to-action logic for the public tour.
// Mirrors SpaceType in apps/ios/.../Models/Listing.swift and the locked spec in
// docs/INDUSTRY-LOGIC.md. The primary CTA deep-links to the owner's action URL
// (reservations / booking / online store / website) when set, otherwise it
// falls back to the lead form. `lead_fields` hints the player which extra fields
// to render on the end-card form.

export type CtaMode = "deeplink" | "lead_form";

export interface SecondaryLink {
  label: string;
  url: string;
}

export interface Cta {
  label: string;
  mode: CtaMode;
  url: string | null;
  secondary: SecondaryLink[];
  lead_fields: string[];
}

interface ListingLike {
  space_type?: string | null;
  address?: string | null;
  details?: Record<string, unknown> | null;
  zillow_url?: string | null;
  lat?: number | null;
  lng?: number | null;
}

function normalizeUrl(raw: unknown): string | null {
  const s = String(raw ?? "").trim();
  if (!s) return null;
  return /^https?:\/\//i.test(s) ? s : `https://${s}`;
}

function telUrl(raw: unknown): string | null {
  const digits = String(raw ?? "").replace(/[^\d+]/g, "");
  return digits ? `tel:${digits}` : null;
}

function directionsLink(l: ListingLike): SecondaryLink | null {
  if (l.lat != null && l.lng != null) {
    return {
      label: "Get directions",
      url: `https://www.google.com/maps/search/?api=1&query=${l.lat},${l.lng}`,
    };
  }
  if (l.address) {
    return {
      label: "Get directions",
      url: `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(l.address)}`,
    };
  }
  return null;
}

function detail(l: ListingLike, key: string): string {
  return String(l.details?.[key] ?? "").trim();
}

export function buildCta(listing: ListingLike): Cta {
  const type = listing.space_type ?? "real_estate";
  const secondary: SecondaryLink[] = [];

  switch (type) {
    case "venue": {
      const url = normalizeUrl(detail(listing, "bookingUrl"));
      return {
        label: "Plan your event",
        mode: url ? "deeplink" : "lead_form",
        url,
        secondary,
        lead_fields: ["event_date", "guest_count", "event_type"],
      };
    }

    case "restaurant": {
      const url = normalizeUrl(detail(listing, "reservationUrl"));
      const menu = normalizeUrl(detail(listing, "menuUrl"));
      if (menu) secondary.push({ label: "View menu", url: menu });
      const tel = telUrl(detail(listing, "phone"));
      if (tel) secondary.push({ label: "Call", url: tel });
      return {
        label: "Book a table",
        mode: url ? "deeplink" : "lead_form",
        url,
        secondary,
        lead_fields: ["party_size", "date", "time", "occasion", "notes"],
      };
    }

    case "retail": {
      const shop = normalizeUrl(detail(listing, "onlineStoreUrl"));
      const dir = directionsLink(listing);
      if (shop && dir) secondary.push(dir); // directions is always available
      // Retail replaces the lead form with an optional email-only promo opt-in.
      if (shop) {
        return { label: "Shop online", mode: "deeplink", url: shop, secondary, lead_fields: ["email"] };
      }
      return {
        label: "Get directions",
        mode: dir ? "deeplink" : "lead_form",
        url: dir?.url ?? null,
        secondary,
        lead_fields: ["email"],
      };
    }

    case "fitness": {
      const url = normalizeUrl(detail(listing, "bookingUrl"));
      const freeTrial = detail(listing, "freeTrialOffer");
      const facility = detail(listing, "facilityType").toLowerCase();
      const classBased = /class|yoga|pilates|crossfit|martial/.test(facility);
      const label = freeTrial ? "Start free trial" : classBased ? "Book a class" : "Book a session";
      const leadFields = ["fitness_goal", "preferred_time", "interested_class"];
      if (freeTrial) {
        // Capture the lead, then hand off to the booking system if present.
        if (url) secondary.push({ label: "Book now", url });
        return { label, mode: "lead_form", url: null, secondary, lead_fields: leadFields };
      }
      return {
        label,
        mode: url ? "deeplink" : "lead_form",
        url,
        secondary,
        lead_fields: leadFields,
      };
    }

    case "other": {
      const url = normalizeUrl(detail(listing, "website"));
      return {
        label: "Get in touch",
        mode: url ? "deeplink" : "lead_form",
        url,
        secondary,
        lead_fields: ["message"],
      };
    }

    case "real_estate":
    default: {
      // Real estate always uses the lead form ("Book a showing"); Zillow is secondary.
      const zillow = normalizeUrl(listing.zillow_url);
      if (zillow) secondary.push({ label: "View on Zillow", url: zillow });
      return {
        label: "Book a showing",
        mode: "lead_form",
        url: null,
        secondary,
        lead_fields: ["preferred_date"],
      };
    }
  }
}
