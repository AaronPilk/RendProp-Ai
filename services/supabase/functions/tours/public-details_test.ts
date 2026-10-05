import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

const encode = (source: string) =>
  `data:application/typescript;base64,${
    btoa(String.fromCharCode(...new TextEncoder().encode(source)))
  }`;

function productionFunction(source: string, name: string): string {
  const start = source.indexOf(`function ${name}(`);
  const end = source.indexOf("\n}\n", start);
  assert(start >= 0 && end > start, `Missing actual function ${name}`);
  return source.slice(start, end + 3);
}

// The complete actual public handler runs unchanged. Only database/Auth/media
// boundaries are doubles, with synthetic rows; no network, keys or customer data.
async function fixture(bypassFilter = false) {
  const source = await Deno.readTextFile(
    new URL("./index.ts", import.meta.url),
  );
  const ownerSource = await Deno.readTextFile(
    new URL("../listings/index.ts", import.meta.url),
  );
  const start = source.indexOf("Deno.serve(async (req) => {");
  assert(start > 0 && source.trimEnd().endsWith("});"));
  let handler = source.slice(start).trimEnd().replace(
    "Deno.serve(async (req) => {",
    "export const handler = async (req: Request) => {",
  ).slice(0, -3) + "};";
  if (bypassFilter) {
    const call = "details: publicListingDetails(listing.details)";
    assertEquals(handler.split(call).length, 2);
    handler = handler.replace(call, "details: listing.details ?? {}");
  }
  const ownerStart = ownerSource.indexOf("    // ---- GET /listings ----");
  const ownerEnd = ownerSource.indexOf(
    "    // ---- PATCH /listings/:id ----",
    ownerStart,
  );
  assert(ownerStart > 0 && ownerEnd > ownerStart);
  const body = `
    import {HttpError,json,pathSegments,respondError} from ${
    JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)
  };
    import {handleOptions} from ${
    JSON.stringify(new URL("../_shared/cors.ts", import.meta.url).href)
  };
    import {buildCta} from ${
    JSON.stringify(new URL("./cta.ts", import.meta.url).href)
  };
    import {buildPersonalListingCard} from ${
    JSON.stringify(new URL("../_shared/agentcard.ts", import.meta.url).href)
  };
    type MediaSourceRefs={renders:string[]};
    type SpatialChapter={label:string,t_ms:number,sort:number};
    const TOUR_BASE="https://tour-fixture.invalid";
    const brandedUrl=(slug:string)=>TOUR_BASE+"/f/"+slug;
    const unbrandedUrl=(slug:string)=>TOUR_BASE+"/u/"+slug;
    const STAGED_DISCLOSURE="Synthetic staging disclosure";
    const DEMO_SLUGS=new Set();
    const demoTour=()=>{throw Error("Demo boundary must not run");};
    export const state:any={listing:null,client:null,published:true,revoked:false,reads:[]};
    const render={id:"render-fixture",job_id:"job-fixture",listing_id:"listing-fixture",slug:"private-measurement-fixture",duration_s:8,speed_factor:1,video_key:"renders/fixture/video.mp4",stream_uid:null,poster_key:"renders/fixture/poster.jpg",staged:false,published_at:"2030-01-01T00:00:00Z"};
    const rows:any={renders:render,orgs:{handle:"fixture-agent",brand_kit:{name:"Synthetic Public Agent"}},profiles:{name:"Synthetic Public Agent"},render_jobs:{capture_asset_id:null}};
    const adminClient=()=>({rpc:async(name:string,args:any)=>{
      if(name!=="public_listing_agent_identity" || args.p_listing!=="listing-fixture" || Object.keys(args).length!==1)throw Error("Unexpected identity RPC");
      return {error:null,data:{personal_card:null,profile_name:"Synthetic Public Agent",legacy_owned_single_member:false,org_business:{},org_handle:"fixture-agent",legacy_brand:{},legacy_portrait:null}};
    },from:(table:string)=>{
      const query:any={select:(fields:string)=>{state.reads.push({table,fields});return query;},eq:()=>query,not:()=>query,
        maybeSingle:async()=>({data:table==="listings"?state.listing:table==="listing_client_contacts"?state.client:table==="renders"&&!state.published?null:rows[table]??null,error:null})};
      return query;
    }});
    const assertMediaVisible=async()=>{if(state.revoked)throw new HttpError(403,"Media unavailable");};
    const galleryFor=async()=>[];
    const publicMainPhoto=async()=>null;
    const alteredMediaFor=async()=>[];
    const bindSpatialChapters=(chapters:any)=>chapters;
    const resolveContactPhoto=async(_admin:any,row:any)=>row;
    const publicR2Url=(key:string|null)=>key?"https://media-fixture.invalid/"+key:null;
    const streamHlsUrl=()=>null;
    export ${productionFunction(source, "publicListingDetails")}
    ${productionFunction(source, "floorplanUrl")}
    ${productionFunction(source, "formatUSD")}
    async ${productionFunction(source, "listingAgentIdentity")}
    ${handler}
    export const ownerRead=async(req:Request)=>{
      const id=undefined,explicitOrg="org-fixture";
      const q:any={select:()=>q,is:()=>q,eq:()=>q,order:async()=>({data:[state.listing],error:null})};
      const db={from:()=>q};
      ${ownerSource.slice(ownerStart, ownerEnd)}
      throw Error("Owner GET boundary not reached");
    };
  `;
  return await import(encode(body));
}

const privateWire = JSON.stringify({
  version: 1,
  unit: "meters",
  rooms: [{
    name: "PrivateOnlyMeasurementSentinel",
    widthMeters: 3,
    lengthMeters: 4,
  }],
  updatedAt: 1_000,
});
const privateOutlineWire = JSON.stringify({
  version: 2,
  unit: "meters",
  rooms: [],
  outlines: [{
    name: "OutlineOnlyMeasurementSentinel",
    floor: 0,
    category: "finished",
    vertices: [
      { x: 0, y: 0 },
      { x: 5, y: 0 },
      { x: 5, y: 2 },
      { x: 2, y: 2 },
      { x: 2, y: 5 },
      { x: 0, y: 5 },
    ],
  }],
  updatedAt: 1_000,
});
const details = {
  floor_measurements_v1: privateWire,
  floor_measurements_v2: { private: "FutureOnlyMeasurementSentinel" },
  floor_measurements_internal: ["InternalOnlyMeasurementSentinel"],
  FLOOR_MEASUREMENTS_V99: "CaseOnlyMeasurementSentinel",
  floorMeasurementsV1: "CamelOnlyMeasurementSentinel",
  floorMeasurementsInternal: "CamelFutureMeasurementSentinel",
  FloorMeasurementsV99: "CamelCaseMeasurementSentinel",
  floorplan_url: "https://media-fixture.invalid/public-floor-plan.png",
  floorplan_asset_id: "public-plan-asset",
  floorplan: { levels: [{ name: "Public first floor", sqft: 900 }] },
  year_built: "2001",
  features: ["Public garden"],
  allow_indexing: "true",
  show_partners: "false",
  bookingUrl: "https://booking-fixture.invalid",
  unrelated_future_fact: "Keep public unknown fact",
};

function listing() {
  return {
    id: "listing-fixture",
    org_id: "org-fixture",
    agent_id: "agent-fixture",
    space_type: "real_estate",
    address: "Synthetic property",
    tagline: "Public property facts",
    details: structuredClone(details),
    beds: 2,
    baths: 1,
    sqft: 900,
    price_cents: 100_000,
    lat: null,
    lng: null,
    main_photo_key: null,
    gallery_asset_ids: [],
    deleted_at: null,
    sold_at: null,
    status: "ready",
  };
}

function assertPrivateAbsent(value: unknown) {
  const text = JSON.stringify(value);
  for (
    const token of [
      "floor_measurements_",
      "PrivateOnlyMeasurementSentinel",
      "FutureOnlyMeasurementSentinel",
      "InternalOnlyMeasurementSentinel",
      "CaseOnlyMeasurementSentinel",
      "OutlineOnlyMeasurementSentinel",
    ]
  ) {
    assert(
      !text.toLowerCase().includes(token.toLowerCase()),
      `${token} must stay private`,
    );
  }
}

const request = () =>
  new Request("https://edge-fixture.invalid/tours/private-measurement-fixture");

Deno.test("actual public tour response omits all reserved measurement metadata and preserves public facts", async () => {
  const f = await fixture();
  f.state.listing = listing();
  const response = await f.handler(request());
  assertEquals(response.status, 200);
  const payload = await response.json();
  assertPrivateAbsent(payload);
  const expected = Object.fromEntries(
    Object.entries(details).filter(([key]) =>
      !["floor_measurements_v1", "floor_measurements_v2", "floor_measurements_internal", "FLOOR_MEASUREMENTS_V99", "floorMeasurementsV1", "floorMeasurementsInternal", "FloorMeasurementsV99"].includes(key)
    ),
  );
  assertEquals(payload.listing.details, expected);
  assertEquals(payload.floorplan_url, details.floorplan_url);
  assertEquals(payload.agent_card.name, "Synthetic Public Agent");
  assertEquals(
    payload.share_url,
    "https://tour-fixture.invalid/f/private-measurement-fixture",
  );
  assertEquals(
    payload.unbranded_url,
    "https://tour-fixture.invalid/u/private-measurement-fixture",
  );
  assertEquals(payload.listing.address, "Synthetic property");
});

Deno.test("public filtering does not mutate the owner listing read or its measurement wire", async () => {
  const f = await fixture();
  f.state.listing = listing();
  await f.handler(request());
  const ownedResponse = await f.ownerRead(
    new Request("https://edge-fixture.invalid/listings"),
  );
  assertEquals(ownedResponse.status, 200);
  const owned = await ownedResponse.json();
  assertEquals(owned[0].details, details);
  assertEquals(owned[0].details.floor_measurements_v1, privateWire);
  assertEquals(
    JSON.parse(owned[0].details.floor_measurements_v1).rooms[0].name,
    "PrivateOnlyMeasurementSentinel",
  );
});

Deno.test("actual tour response omits version-two outlines under the existing wire key while the owner read preserves them", async () => {
  const f = await fixture();
  f.state.listing = listing();
  f.state.listing.details.floor_measurements_v1 = privateOutlineWire;
  const response = await f.handler(request());
  assertEquals(response.status, 200);
  const payload = await response.json();
  assertPrivateAbsent(payload);
  assertEquals(payload.floorplan_url, details.floorplan_url);
  const ownedResponse = await f.ownerRead(
    new Request("https://edge-fixture.invalid/listings"),
  );
  assertEquals(ownedResponse.status, 200);
  const owned = await ownedResponse.json();
  assertEquals(owned[0].details.floor_measurements_v1, privateOutlineWire);
  assertEquals(
    JSON.parse(owned[0].details.floor_measurements_v1).outlines[0].name,
    "OutlineOnlyMeasurementSentinel",
  );
});

Deno.test("actual public response changes only the reserved private details namespace", async () => {
  const current = await fixture(), prior = await fixture(true);
  current.state.listing = listing();
  prior.state.listing = listing();
  const clean = await (await current.handler(request())).json();
  const unsafe = await (await prior.handler(request())).json();
  unsafe.listing.details = current.publicListingDetails(unsafe.listing.details);
  assertEquals(clean, unsafe);
  assertEquals(current.publicListingDetails(null), {});
  assertEquals(current.publicListingDetails([]), {});
});

Deno.test("publication and media-revocation gates still reject public tour access", async () => {
  const f = await fixture();
  f.state.listing = listing();
  f.state.published = false;
  assertEquals((await f.handler(request())).status, 404);
  f.state.published = true;
  f.state.revoked = true;
  assertEquals((await f.handler(request())).status, 403);
});

Deno.test("copied actual-route bypass control exposes the sentinel and is rejected", async () => {
  const unsafe = await fixture(true);
  unsafe.state.listing = listing();
  const payload = await (await unsafe.handler(request())).json();
  assertEquals(payload.listing.details.floor_measurements_v1, privateWire);
  let rejected = false;
  try {
    assertPrivateAbsent(payload);
  } catch {
    rejected = true;
  }
  assert(
    rejected,
    "Acceptance must detect bypassing the actual response filter",
  );
});

Deno.test("copied actual-route bypass control exposes a version-two outline and is rejected", async () => {
  const unsafe = await fixture(true);
  unsafe.state.listing = listing();
  unsafe.state.listing.details.floor_measurements_v1 = privateOutlineWire;
  const payload = await (await unsafe.handler(request())).json();
  assertEquals(
    payload.listing.details.floor_measurements_v1,
    privateOutlineWire,
  );
  let rejected = false;
  try {
    assertPrivateAbsent(payload);
  } catch {
    rejected = true;
  }
  assert(
    rejected,
    "Acceptance must detect leaking an outline-only version-two plan",
  );
});
