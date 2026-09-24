import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { presenterQualityProjection, qualityProjection } from "./creative-quality.ts";
import type { StudioContext } from "./context.ts";
import { HttpError } from "../_shared/http.ts";
const asset = {
    id: "asset",
    listing_id: "listing",
    storage_key: "generated.mp4",
    uploaded: true,
  },
  source = {
    id: "source",
    listing_id: "listing",
    storage_key: "original.jpg",
    uploaded: true,
    kind: "photo",
    bucket: "renders",
  };
const result = {
  kind: "video",
  org_id: "org",
  listing_id: "listing",
  storage_key: "generated.mp4",
  metadata: { video_kind: "reel", state: "completed", request_id: "request" },
};
const proof = {
  org_id: "org",
  listing_id: "listing",
  original_key: "original.jpg",
  altered_key: "generated.mp4",
  qc: { verdict: "pass", publishable: true, request_id: "request" },
};
Deno.test("ordinary recorded videos do not require synthetic quality checks", () =>
  assertEquals(qualityProjection(null, null, asset), {
    qc_required: false,
    qc_publishable: true,
    qc_message: null,
  }));
Deno.test("presenter output requires the live database approval predicate", async () => {
  for (const active of [true, false]) {
    const context = { admin: { rpc(name: string, args: unknown) {
      assertEquals(name,"studio_presenter_asset_access");assertEquals(args,{p_asset:"asset"});
      return Promise.resolve({data:active,error:null});
    } } } as unknown as StudioContext;
    const value=await presenterQualityProjection(context,"asset");assertEquals(value.qc_required,true);assertEquals(value.qc_publishable,active);
  }
});
Deno.test("presenter approval outages and malformed replies fail closed", async () => {
  for (const reply of [{data:null,error:null},{data:"true",error:null},{data:true,error:{message:"offline"}}]) {
    const context={admin:{rpc:()=>Promise.resolve(reply)}} as unknown as StudioContext;
    await assertRejects(()=>presenterQualityProjection(context,"asset"),HttpError,"approval could not be checked");
  }
});
Deno.test("matching source output generation and server verdict is publishable", () =>
  assertEquals(
    qualityProjection(result, proof, asset, source).qc_publishable,
    true,
  ));
Deno.test("quality holds absent mismatched or failed verdicts", () => {
  for (
    const candidate of [
      null,
      { ...proof, qc: null },
      { ...proof, qc: { ...proof.qc, request_id: "different" } },
      { ...proof, qc: { ...proof.qc, verdict: "fail" } },
      { ...proof, original_key: "other.jpg" },
      { ...proof, altered_key: "other.mp4" },
      { ...proof, org_id: "other" },
    ]
  ) {
    const projection = qualityProjection(result, candidate, asset, source);
    assertEquals(projection.qc_required, true);
    assertEquals(projection.qc_publishable, false);
  }
});
Deno.test("quality holds incomplete imports and unconfirmed sources", () => {
  assertEquals(
    qualityProjection(
      { ...result, metadata: { ...result.metadata, state: "importing" } },
      proof,
      asset,
      source,
    ).qc_publishable,
    false,
  );
  assertEquals(
    qualityProjection(result, proof, asset, { ...source, uploaded: false })
      .qc_publishable,
    false,
  );
  assertEquals(
    qualityProjection(result, proof, asset, null).qc_publishable,
    false,
  );
});
