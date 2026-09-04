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
        reel_poster: "/assets/demo-poster.webp",
        story:
          "Set on a private ridge above the canyon, 1180 Crestline was designed around a single idea: erase the wall between the house and the view. Floor-to-ceiling glass slides fully away, so the great room, the pool deck, and the horizon become one continuous space.\n\n" +
          "Materials were chosen for how they age — wide-plank European oak that warms with time, honed stone cut from a single block, bronze and glass detailing that catches the evening light. Nothing here is loud. Everything is considered.\n\n" +
          "Offered turnkey, it is a rare modern estate that lives as beautifully at golden hour as it photographs at dusk.",
        // Gallery stills extracted FROM the tour footage itself, so the whole
        // demo is one coherent property (2026-08-26 media fix).
        gallery: [
          { url: "/assets/demo-g1.webp", label: "Twilight arrival" },
          { url: "/assets/demo-g2.webp", label: "Chef's kitchen" },
          { url: "/assets/demo-g3.webp", label: "Great room" },
          { url: "/assets/demo-g4.webp", label: "Primary bath" },
          { url: "/assets/demo-g5.webp", label: "Sunken lounge" },
          { url: "/assets/demo-g6.webp", label: "The estate" },
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
    // Same-origin scrub master — the REAL 137s twilight-mansion walkthrough
    // (mansion-v4), self-hosted so video elements get well-formed responses.
    video_url: "/assets/demo-tour.mp4",
    scrub_url: "/assets/demo-tour.mp4",
    hls_url: null,
    poster: "/assets/demo-poster.webp",
    duration_s: 137,
    speed_factor: 1,
    // Chapter times matched to the actual footage.
    chapters: [
      { label: "Arrival", t_ms: 0, sort: 0 },
      { label: "Chef's kitchen", t_ms: 14000, sort: 1 },
      { label: "Primary suite", t_ms: 55000, sort: 2 },
      { label: "Spa bath", t_ms: 66000, sort: 3 },
      { label: "Great room", t_ms: 82000, sort: 4 },
      { label: "The grounds", t_ms: 105000, sort: 5 },
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
    // The demo shows the compliance wedge, not just the player: two real
    // before/after pairs already ship in public/assets, so /f/estate-demo and
    // /u/estate-demo both render the AI disclosure block with working
    // "View original" links (CA AB 723) and side-by-side Before/After images
    // (NorthstarMLS). The disclosure text mirrors STAGED_DISCLOSURE in
    // services/supabase/functions/tours/index.ts.
    staged: true,
    staged_disclosure:
      "Some imagery in this tour has been virtually staged or digitally decluttered. " +
      "Furniture and decor may be digitally added, removed, or restyled; the architecture, " +
      "layout, dimensions, and views are unchanged.",
    disclosure_chip: "✦ Virtually staged",
    // Labels, model families and sentences are copied VERBATIM from the demo
    // branch of services/supabase/functions/tours/index.ts, whose sentences in
    // turn come from public.provenance_disclosure() in migration 0012 — the one
    // source of truth for disclosure copy. Keep the two demos in step: this one
    // is what rendprop.com/f/estate-demo and /u/estate-demo actually serve
    // (the Worker short-circuits the demo slug and never calls Supabase).
    altered_media: [
      {
        label: "Great room — virtually staged",
        kind: "virtual_stage",
        disclosure:
          "This photo was virtually staged with AI: furniture and decor were digitally added or restyled. " +
          "The architecture, dimensions, and views are unchanged.",
        model: "AI image edit",
        original_url: "/assets/example-staging-before.webp",
        altered_url: "/assets/example-staging-after.webp",
      },
      {
        label: "Twilight arrival — sky and lighting",
        kind: "photo_edit",
        disclosure:
          "This photo was digitally altered with AI: the sky and lighting were changed to simulate dusk. " +
          "The property itself is unchanged.",
        model: "AI image edit",
        original_url: "/assets/example-twilight-before.webp",
        altered_url: "/assets/example-twilight-after.webp",
      },
      {
        // The legally most-scrutinised item: HousingWire's AI-listing-video
        // disclosure test asks "does the video show movement/perspective never
        // actually captured?" and names this exact sentence. Wisconsin Act 69
        // brings generated video into scope on 1 Jan 2027. The demo must model
        // the disclosure we require of every customer.
        label: "Aerial intro — AI generated",
        kind: "aerial",
        disclosure:
          "Drone-style movement is simulated. No drone footage was captured. " +
          "This opening clip was generated by AI from a still exterior photograph of the property.",
        model: "AI video",
        original_url: null,
        altered_url: null,
      },
    ],
  };
}
