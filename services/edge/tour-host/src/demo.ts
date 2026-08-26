// demo.ts — a self-contained sample tour so rendprop.com/f/estate-demo renders
// the FULL listing microsite with zero database dependency. It is built as a
// normal `Tour` object and rendered through the exact same renderTourPage() a
// real published listing uses — so the demo IS the product, not a mockup.
//
// Video: the flythrough hero points at the proven scroll-scrub master. Poster
// and gallery images are served from this Worker's own /assets (public/assets),
// so the demo can never break on a cross-site miss.

import type { Tour } from "./types";

export const DEMO_SLUG = "estate-demo";

export function isDemoSlug(slug: string): boolean {
  return slug === DEMO_SLUG || slug === "demo";
}

export function buildDemoTour(): Tour {
  return {
    slug: DEMO_SLUG,
    share_url: "https://rendprop.com/f/estate-demo",
    space_type: "real_estate",
    listing: {
      address: "1180 Crestline Ridge",
      tagline: "A glass-and-oak modern estate that opens to the canyon.",
      beds: 5,
      baths: 6,
      sqft: 6200,
      price_cents: 425000000, // $4,250,000
      price: "$4,250,000",
      lat: null,
      lng: null,
      details: {
        year_built: "2023",
        acres: "0.7",
        garage: "4-car",
        frontage: "180'",
        // Self-hosted (2026-08-26 fix): pilk.ai's server returns 206 responses
        // WITHOUT a Content-Range header, which fetch() tolerates but Chrome's
        // media stack rejects — every <video> pointed there sat at readyState 0
        // forever. All demo media now ships from this Worker's own /assets.
        reel_url: "/assets/demo-reel.mp4",
        reel_poster: "/assets/hero-twilight-modern-home.webp",
        story:
          "Set on a private ridge above the canyon, 1180 Crestline was designed around a single idea: erase the wall between the house and the view. Floor-to-ceiling glass slides fully away, so the great room, the pool deck, and the horizon become one continuous space.\n\n" +
          "Materials were chosen for how they age — wide-plank European oak that warms with time, honed stone cut from a single block, bronze and glass detailing that catches the evening light. Nothing here is loud. Everything is considered.\n\n" +
          "Offered turnkey, it is a rare modern estate that lives as beautifully at golden hour as it photographs at dusk.",
        gallery: [
          { url: "/assets/hero-twilight-modern-home.webp", label: "Dusk exterior" },
          { url: "/assets/glass-house-exterior.webp", label: "Glass wing" },
          { url: "/assets/luxury-kitchen-interior.webp", label: "Chef's kitchen" },
          { url: "/assets/living-room-walkthrough.webp", label: "Great room" },
          { url: "/assets/modern-home-exterior-tour.webp", label: "Arrival court" },
          { url: "/assets/hospitality-spa-detail.webp", label: "Spa & wellness" },
        ],
        features: {
          Interior: [
            "Floor-to-ceiling glass with disappearing pocket doors",
            "Wide-plank European white oak flooring throughout",
            "Chef's kitchen with dual islands and pro appliances",
            "Honed Calacatta stone and book-matched slabs",
            "Primary suite with private terrace and dual dressing rooms",
            "Glass-enclosed wine wall for 600+ bottles",
          ],
          "Exterior & grounds": [
            "70-foot vanishing-edge pool and sunken spa",
            "Outdoor kitchen, fire lounge, and covered loggia",
            "Mature landscaped grounds with specimen olive trees",
            "Rooftop terrace with 180° canyon and skyline views",
            "Gated motor court with four-car garage",
          ],
          "Smart home & systems": [
            "Whole-home automation and lighting control",
            "Motorized shades on every opening",
            "Climate zoning with hospital-grade air filtration",
            "Solar array with whole-home battery backup",
            "24/7 monitored security and EV charging",
          ],
        },
        floorplan: {
          levels: [
            { name: "Lower level", sqft: "1,700 SF", blurb: "Theater, wellness spa, glass wine room, and gym — the private retreat beneath the residence." },
            { name: "Main level", sqft: "2,900 SF", blurb: "Great room, chef's kitchen, dining, and study with seamless flow to the pool deck." },
            { name: "Upper level", sqft: "1,600 SF", blurb: "Primary wing with terrace and dual baths, plus three en-suite bedrooms." },
          ],
        },
        neighborhood: {
          blurb: "Minutes to the best dining, trails, and the water — a world away from everything else.",
          commute: [
            { time: "6 min", label: "To the marina & waterfront" },
            { time: "12 min", label: "To downtown dining & galleries" },
            { time: "25 min", label: "To private aviation terminal" },
          ],
        },
      },
    },
    // Same-origin scrub master (the proven 55s all-intra demo walkthrough the
    // iOS app bundles) — served by Workers assets with correct Range support.
    video_url: "/assets/demo-tour.mp4",
    scrub_url: "/assets/demo-tour.mp4",
    hls_url: null,
    poster: "/assets/hero-twilight-modern-home.webp",
    duration_s: 55,
    speed_factor: 1,
    chapters: [
      { label: "Arrival", t_ms: 0, sort: 0 },
      { label: "Great room", t_ms: 9000, sort: 1 },
      { label: "Chef's kitchen", t_ms: 18000, sort: 2 },
      { label: "Primary suite", t_ms: 27000, sort: 3 },
      { label: "Pool deck", t_ms: 36000, sort: 4 },
      { label: "Rooftop", t_ms: 45000, sort: 5 },
    ],
    agent_card: {
      name: "Alexandra Reyes",
      handle: "meridian",
      brokerage: "Meridian Estates",
      phone: "(305) 555-0142",
      email: "aaron@pilk.ai",
      website: "https://pilk.ai/",
      avatar_url: "/assets/agent-headshot.webp",
      instagram: "pilk.ai",
      accent: "#7c3aed",
    },
    cta: {
      label: "Book a showing",
      mode: "lead_form",
      url: null,
      secondary: [],
      lead_fields: ["preferred_date"],
    },
    staged: false,
    staged_disclosure: null,
    disclosure_chip: null,
  };
}
