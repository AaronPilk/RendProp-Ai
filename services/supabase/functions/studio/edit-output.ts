import { HttpError, json, readJsonLimited } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";
import { projectAssetQuality } from "./creative-quality.ts";
import { hasMusicCopy, propertyMusicRow } from "./property-music.ts";

type Row = Record<string, any>;
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
function id(value: unknown): string {
  if (typeof value !== "string" || !UUID.test(value)) {
    throw new HttpError(400, "Choose saved media from this property.");
  }
  return value.toLowerCase();
}
export function editOutputInput(raw: Row) {
  if (
    !Array.isArray(raw.source_asset_ids) || raw.source_asset_ids.length < 1 ||
    raw.source_asset_ids.length > 24
  ) {
    throw new HttpError(
      400,
      "Save between 1 and 24 source files before saving this edit.",
    );
  }
  const assetId = id(raw.asset_id),
    sourceIds = [...new Set<string>(raw.source_asset_ids.map(id))].sort();
  if (sourceIds.includes(assetId)) {
    throw new HttpError(400, "An edited output cannot be its own source.");
  }
  if (raw.music_sha256 !== undefined && (typeof raw.music_sha256 !== "string" || !/^[a-f0-9]{64}$/.test(raw.music_sha256))) throw new HttpError(400, "Choose a saved music source.");
  return {
    listingId: id(raw.listing_id),
    assetId,
    sourceIds,
    narrationId: raw.narration_result_id == null
      ? null
      : id(raw.narration_result_id),
    ...(raw.music_sha256 ? { musicSha256: raw.music_sha256 as string } : {}),
  };
}
export function editDisclosure(visualAI: boolean, narration: boolean, music = false) {
  return "This video was edited in Rendprop Studio." +
    (visualAI
      ? " Its selected sources include AI-altered or generated visuals."
      : "") +
    (narration ? " AI-generated narration was selected for this edit." : "") +
    (music ? " User-supplied music was selected; its usage permission is the uploader's declaration." : "") +
    " Review the finished video against the original property media; its final content has not been independently verified.";
}
function assetScope(asset: Row | undefined, orgId: string, listingId: string) {
  return asset && asset.listing_id === listingId && asset.uploaded === true &&
    ["photo", "video"].includes(asset.kind) &&
    ["uploads", "renders"].includes(asset.bucket) &&
    typeof asset.storage_key === "string" &&
    asset.storage_key.startsWith(`${asset.bucket}/${orgId}/${listingId}/`) &&
    !asset.storage_key.includes("..") && asset.storage_key.length <= 1024;
}
/** Source selection is a declaration. Only the source records, scope, and existing QC are verified here. */
export function resolveEditSources(
  inputIds: string[],
  assets: Row[],
  photos: Row[],
  orgId: string,
  listingId: string,
): Row[] {
  return [...new Map(inputIds.map((sourceId) => {
    const photo = photos.find((row) =>
      row.id === sourceId && row.listing_id === listingId
    );
    const key = photo?.enhanced_key || photo?.original_key;
    const asset = assets.find((row) => row.id === sourceId) ??
      (key ? assets.find((row) => row.storage_key === key) : undefined);
    if (!assetScope(asset, orgId, listingId)) {
      throw new HttpError(
        409,
        "A source file is not saved in this property. Finish syncing its media first.",
      );
    }
    return [asset!.id, asset!] as const;
  })).values()];
}
function dataRows(
  response: { data: unknown; error: unknown },
  message: string,
): Row[] {
  if (response.error || !Array.isArray(response.data)) {
    throw new HttpError(503, message);
  }
  return response.data;
}
export async function handleEditOutput(
  req: Request,
  context: StudioContext,
): Promise<Response> {
  if (req.method !== "POST") {
    throw new HttpError(405, "Saving an edited video requires POST.");
  }
  const raw = await readJsonLimited(req, 64 * 1024);
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new HttpError(400, "Choose the edited video to save.");
  }
  const input = editOutputInput(raw as Row);
  await context.authorizeListing(input.listingId);
  const role = await context.db.rpc("org_role", { target: context.orgId });
  if (role.error) {
    throw new HttpError(503, "Workspace permissions could not be checked.");
  }
  if (!["owner", "admin", "agent"].includes(role.data)) {
    throw new HttpError(403, "Your role cannot save edited media.");
  }
  if (input.musicSha256) {
    const music = await propertyMusicRow(context, input.listingId, input.musicSha256);
    if (music.actor_id !== context.userId) {
      if (!await hasMusicCopy(context, context.userId, input.listingId, input.musicSha256)) throw new HttpError(403, "This music has no authorized handoff to your edit.");
    }
  }
  const [assetRead, photoRead] = await Promise.all([
    context.admin.from("capture_assets").select(
      "id,listing_id,kind,bucket,uploaded,storage_key,duration_s,presenter_job_id",
    )
      .eq("listing_id", input.listingId).in("id", [
        input.assetId,
        ...input.sourceIds,
      ]),
    context.admin.from("photos").select(
      "id,listing_id,original_key,enhanced_key,is_staged",
    )
      .eq("listing_id", input.listingId).in("id", input.sourceIds),
  ]);
  const assets = dataRows(
      assetRead,
      "Saved source files could not be checked.",
    ),
    photos = dataRows(photoRead, "Saved photos could not be checked.");
  const output = assets.find((row) => row.id === input.assetId);
  if (
    !assetScope(output, context.orgId, input.listingId) ||
    output!.kind !== "video" || output!.bucket !== "renders" ||
    !output!.storage_key.endsWith(".mp4")
  ) {
    throw new HttpError(
      409,
      "Finish uploading the edited MP4 before saving its source record.",
    );
  }
  const photoKeys = [
    ...new Set(
      photos.map((row) => row.enhanced_key || row.original_key).filter((key) =>
        typeof key === "string"
      ),
    ),
  ];
  if (photoKeys.length) {
    assets.push(...dataRows(
      await context.admin.from("capture_assets")
        .select("id,listing_id,kind,bucket,uploaded,storage_key").eq(
          "listing_id",
          input.listingId,
        ).in("storage_key", photoKeys),
      "Photo source files could not be checked.",
    ));
  }
  const sources = resolveEditSources(
    input.sourceIds,
    assets,
    photos,
    context.orgId,
    input.listingId,
  );
  if (sources.some((row) => row.id === input.assetId)) {
    throw new HttpError(400, "An edited output cannot be its own source.");
  }
  await projectAssetQuality(context, input.listingId, sources);
  if (sources.some((row) => row.qc_required && row.qc_publishable !== true)) {
    throw new HttpError(
      409,
      "Review property accuracy for the generated source clips before saving this edit.",
    );
  }
  for (const source of sources) {
    const quality = await context.admin.rpc("assert_studio_edit_quality", {
      p_asset: source.id,
      p_seen: [input.assetId],
    });
    if (quality.error) {
      if (String(quality.error.message).startsWith("RP409:")) {
        throw new HttpError(
          409,
          "A source edit needs its disclosure or property accuracy review completed before it can be reused.",
        );
      }
      throw new HttpError(503, "The saved source edit could not be checked.");
    }
  }
  const sourceIds = sources.map((row) => row.id).sort(),
    keys = sources.map((row) => row.storage_key);
  const [proofRead, resultRead, narrationRead] = await Promise.all([
    context.admin.from("media_provenance").select(
      "id,org_id,listing_id,kind,model_id,altered_key,disclosure,qc",
    )
      .eq("org_id", context.orgId).eq("listing_id", input.listingId).in(
        "altered_key",
        keys,
      ).limit(501),
    context.admin.from("studio_creative_results").select(
      "id,user_id,org_id,listing_id,kind,storage_key,provenance_id,metadata",
    )
      .eq("org_id", context.orgId).eq("listing_id", input.listingId).eq(
        "kind",
        "video",
      ).in("metadata->>asset_id", [input.assetId, ...sourceIds]),
    input.narrationId
      ? context.admin.from("studio_creative_results").select(
        "id,listing_id,kind,storage_key,metadata",
      )
        .eq("id", input.narrationId).eq("user_id", context.userId).eq(
          "org_id",
          context.orgId,
        ).eq("listing_id", input.listingId).maybeSingle()
      : Promise.resolve({ data: null, error: null }),
  ]);
  const proofs = dataRows(
      proofRead,
      "Source disclosures could not be checked.",
    ),
    results = dataRows(resultRead, "Saved edit history could not be checked.");
  if (proofs.length > 500) {
    throw new HttpError(
      409,
      "This property's source history requires review before saving another edit.",
    );
  }
  if (
    proofs.some((row) =>
      ["reel", "aerial"].includes(row.kind) &&
      (row.qc?.verdict !== "pass" || row.qc?.publishable !== true ||
        !row.qc?.request_id)
    )
  ) {
    throw new HttpError(
      409,
      "A generated source has no passing property accuracy review.",
    );
  }
  if (narrationRead.error) {
    throw new HttpError(503, "The selected narration could not be checked.");
  }
  const narration = narrationRead.data;
  if (
    input.narrationId &&
    (!narration || narration.kind !== "voice" ||
      narration.metadata?.state !== "completed" ||
      typeof narration.storage_key !== "string" ||
      !narration.storage_key.startsWith(`ai-voice/${context.orgId}/`))
  ) {
    throw new HttpError(
      409,
      "Choose a completed narration saved with this property.",
    );
  }
  const existing = results.find((row) =>
    row.metadata?.asset_id === input.assetId
  );
  if (existing && existing.metadata?.video_kind !== "edit") {
    throw new HttpError(
      409,
      "This file is already a generated result. Export a new edited MP4 first.",
    );
  }
  const visualAI =
    proofs.some((proof) =>
      proof.model_id !== "rendprop-studio-editor-v1" ||
      results.some((row) =>
        row.provenance_id === proof.id && row.metadata?.has_visual_ai === true
      )
    ) ||
    photos.some((photo) => !!photo.enhanced_key || photo.is_staged === true) ||
    results.some((row) =>
      sourceIds.includes(row.metadata?.asset_id) &&
      row.metadata?.video_kind !== "edit"
    );
  const hasNarration = !!narration ||
    results.some((row) =>
      sourceIds.includes(row.metadata?.asset_id) &&
      row.metadata?.has_narration === true
    );
  const disclosure = editDisclosure(visualAI, hasNarration, !!input.musicSha256);
  const history = dataRows(
    await context.admin.from("media_provenance").select("id")
      .eq("org_id", context.orgId).eq("listing_id", input.listingId).limit(501),
    "The property's disclosure history could not be checked.",
  );
  if (
    history.length >= 500 &&
    !history.some((row) => row.id === (existing?.provenance_id || existing?.id))
  ) {
    throw new HttpError(
      409,
      "This property has reached its saved disclosure limit. Contact support before saving another edited output.",
    );
  }
  const signature = JSON.stringify({
    sourceIds,
    narrationId: input.narrationId,
    ...(input.musicSha256 ? { musicSha256: input.musicSha256 } : {}),
  });
  let result: Row | undefined = existing;
  if (!result) {
    const created = await context.admin.from("studio_creative_results").insert({
      user_id: context.userId,
      org_id: context.orgId,
      listing_id: input.listingId,
      kind: "video",
      request_key: `studio-edit:${input.assetId}`,
      storage_key: output!.storage_key,
      bucket: "renders",
      metadata: {
        video_kind: "edit",
        state: "finalizing",
        asset_id: input.assetId,
        source_asset_ids: sourceIds,
        source_provenance_ids: proofs.map((row) => row.id),
        narration_result_id: input.narrationId,
        source_declaration: signature,
        source_evidence: "client_selected_records_verified_in_workspace",
        final_content_verified: false,
        label: "Studio edited video",
        duration_s: output!.duration_s ?? null,
        has_visual_ai: visualAI,
        has_narration: hasNarration,
        ...(input.musicSha256 ? { music_source_sha256: input.musicSha256, has_uploaded_music: true, music_permission: "uploader_declared" } : {}),
        disclosure,
      },
    }).select("*").single();
    if (created.error?.code === "23505") {
      const replay = await context.admin.from("studio_creative_results").select(
        "*",
      ).eq("org_id", context.orgId).eq("listing_id", input.listingId)
        .eq("kind", "video").eq("metadata->>video_kind", "edit").eq(
          "metadata->>asset_id",
          input.assetId,
        ).maybeSingle();
      if (replay.error || !replay.data) {
        throw new HttpError(
          503,
          "This edit is still being saved. Retry the saved upload.",
        );
      }
      result = replay.data;
    } else {
      if (created.error || !created.data) {
        throw new HttpError(
          503,
          "The edited video's source record could not be saved.",
        );
      }
      result = created.data;
    }
  }
  if (
    result!.storage_key !== output!.storage_key ||
    result!.metadata?.source_declaration !== signature ||
    visualAI && result!.metadata?.has_visual_ai !== true ||
    hasNarration && result!.metadata?.has_narration !== true
  ) {
    throw new HttpError(
      409,
      "This output already has a different source record. Export a new MP4 after changing its sources.",
    );
  }
  const proofId = result!.provenance_id || result!.id;
  const proof = {
    id: proofId,
    org_id: context.orgId,
    listing_id: input.listingId,
    kind: "other",
    label: "Studio edited video",
    model_id: "rendprop-studio-editor-v1",
    edit: "browser-assembly",
    original_key: null,
    altered_key: output!.storage_key,
    disclosure: result!.metadata.disclosure,
    prompt_summary:
      "Client-selected source records are scoped to this property; final pixels and audio are not independently verified.",
  };
  const writeProof = await context.admin.from("media_provenance").insert(proof);
  if (writeProof.error && writeProof.error.code !== "23505") {
    throw new HttpError(
      503,
      "The video uploaded, but its disclosure still needs to finish saving. Retry this saved output.",
    );
  }
  if (writeProof.error) {
    const savedProof = await context.admin.from("media_provenance").select(
      "id,org_id,listing_id,altered_key,original_key,disclosure,kind",
    )
      .eq("id", proofId).eq("org_id", context.orgId).eq(
        "listing_id",
        input.listingId,
      ).maybeSingle();
    if (savedProof.error) {
      throw new HttpError(503, "The saved disclosure could not be confirmed.");
    }
    if (
      !savedProof.data || savedProof.data.altered_key !== proof.altered_key ||
      savedProof.data.original_key !== null ||
      savedProof.data.kind !== "other" ||
      savedProof.data.disclosure !== proof.disclosure
    ) {
      throw new HttpError(
        409,
        "The saved video disclosure changed. Reopen this property's media before continuing.",
      );
    }
  }
  const saved = await context.admin.from("studio_creative_results").update({
    provenance_id: proofId,
    metadata: { ...result!.metadata, state: "completed" },
  })
    .eq("id", result!.id).eq("org_id", context.orgId).eq(
      "listing_id",
      input.listingId,
    ).select("id").single();
  if (saved.error || !saved.data) {
    throw new HttpError(
      503,
      "The disclosure was saved. Retry to confirm this output before publishing.",
    );
  }
  return json({
    ok: true,
    asset_id: input.assetId,
    provenance_id: proofId,
    disclosure: proof.disclosure,
  });
}
