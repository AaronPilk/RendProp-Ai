import type { StudioContext } from "./context.ts";
import { HttpError } from "../_shared/http.ts";
type Row = Record<string, any>;
export type CreativeQuality = {
  qc_required: boolean;
  qc_publishable: boolean;
  qc_message: string | null;
};
export async function editQualityProjection(
  context: StudioContext,
  assetId: string,
): Promise<CreativeQuality> {
  const result = await context.admin.rpc("assert_studio_edit_quality", {
    p_asset: assetId,
  });
  if (result.error && !String(result.error.message).startsWith("RP409:")) {
    throw new HttpError(
      503,
      "The edited video's saved source checks are unavailable.",
    );
  }
  return {
    qc_required: true,
    qc_publishable: !result.error,
    qc_message: result.error
      ? "Finish this edit's source disclosure and resolve any source accuracy review before publishing."
      : "Source records are ready. Review the finished edit against the original property media before publishing.",
  };
}
export function qualityProjection(
  result: Row | null,
  proof: Row | null,
  asset: Row,
  source?: Row | null,
): CreativeQuality {
  const metadata = result?.metadata;
  if (
    !result || result.kind !== "video" ||
    !["reel", "aerial"].includes(metadata?.video_kind)
  ) return { qc_required: false, qc_publishable: true, qc_message: null };
  const qc = proof?.qc;
  const pass = metadata.state === "completed" &&
    result.storage_key === asset.storage_key && asset.uploaded === true &&
    asset.listing_id === result.listing_id && proof?.org_id === result.org_id &&
    proof?.listing_id === result.listing_id &&
    proof?.altered_key === asset.storage_key &&
    source?.listing_id === result.listing_id && source?.uploaded === true &&
    source?.kind === "photo" && source?.bucket === "renders" &&
    proof?.original_key === source.storage_key && qc?.verdict === "pass" &&
    qc?.publishable === true && typeof qc.request_id === "string" &&
    qc.request_id.length > 0 && qc.request_id === metadata.request_id;
  return {
    qc_required: true,
    qc_publishable: pass,
    qc_message: pass
      ? "Property accuracy review passed."
      : qc?.verdict === "fail"
      ? "This clip did not pass property accuracy review. Generate a new version before publishing."
      : "Review property accuracy in Creative Studio before publishing this generated clip.",
  };
}
export async function projectAssetQuality(
  context: StudioContext,
  listingId: string,
  assets: Row[],
): Promise<void> {
  const ids = assets.map((asset) => asset.id);
  if (!ids.length) return;
  const reads = await Promise.all(
    ["asset_id", "import_asset_id"].map((field) =>
      context.admin.from("studio_creative_results").select(
        "id,kind,org_id,listing_id,storage_key,provenance_id,metadata",
      ).eq("org_id", context.orgId).eq("listing_id", listingId).eq(
        "kind",
        "video",
      ).in(`metadata->>${field}`, ids)
    ),
  );
  if (reads.some((result) => result.error || !Array.isArray(result.data))) {
    throw new HttpError(
      503,
      "Generated video review status could not be checked.",
    );
  }
  const results = [
    ...new Map(
      reads.flatMap((result) => result.data!).map((row) => [row.id, row]),
    ).values(),
  ];
  const proofIds = [
    ...new Set(results.map((row) => row.provenance_id).filter(Boolean)),
  ];
  const sourceIds = [
    ...new Set(
      results.map((row) => row.metadata?.source_asset_id).filter(Boolean),
    ),
  ];
  const [proofs, sources] = await Promise.all([
    proofIds.length
      ? context.admin.from("media_provenance").select(
        "id,org_id,listing_id,original_key,altered_key,qc",
      ).eq("org_id", context.orgId).eq("listing_id", listingId).in(
        "id",
        proofIds,
      )
      : Promise.resolve({ data: [], error: null }),
    sourceIds.length
      ? context.admin.from("capture_assets").select(
        "id,listing_id,kind,bucket,storage_key,uploaded",
      ).eq("listing_id", listingId).in("id", sourceIds)
      : Promise.resolve({ data: [], error: null }),
  ]);
  if (proofs.error || sources.error) {
    throw new HttpError(
      503,
      "Generated video review status could not be checked.",
    );
  }
  for (const asset of assets) {
    const result = results.find((row) =>
      row.metadata?.asset_id === asset.id ||
      row.metadata?.import_asset_id === asset.id
    );
    if (result?.metadata?.video_kind === "edit") {
      Object.assign(asset, await editQualityProjection(context, asset.id));
      continue;
    }
    Object.assign(
      asset,
      qualityProjection(
        result ?? null,
        proofs.data?.find((row) => row.id === result?.provenance_id) ?? null,
        asset,
        sources.data?.find((row) =>
          row.id === result?.metadata?.source_asset_id
        ) ?? null,
      ),
    );
  }
}
