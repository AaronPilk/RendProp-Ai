import { disclosureFallback, type ProvenanceResult } from "../_shared/provenance.ts";

type RPC = (name: string, args: Record<string, unknown>) => PromiseLike<{data: unknown; error: unknown}>;
type Source = { listing: string; asset: string; photoProvenance: string | null; sha256: string; qcHash: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The provider has already accepted. Audit failure never retries generation or
 * falls back to the legacy disclosure dedupe. SQL owns the atomic paid binding. */
export async function recordDirectPropertyVideoSource(args: {
  actor: string; org: string; key: string; request: string; source: Source;
  label: string | null; style: string | null; promptSummary: string | null;
}, rpc: RPC): Promise<{ provenance: ProvenanceResult; sourceBound: boolean }> {
  try {
    const {data, error} = await rpc("record_direct_property_video_source", {
      p_actor: args.actor, p_org: args.org, p_key: args.key, p_listing: args.source.listing,
      p_asset: args.source.asset, p_photo_provenance: args.source.photoProvenance,
      p_request: args.request, p_sha256: args.source.sha256, p_qc_hash: args.source.qcHash,
      p_label: args.label, p_style: args.style, p_prompt_summary: args.promptSummary,
    });
    const row = data as Record<string, unknown> | null;
    if (!error && row && !Array.isArray(row) && row.bound === true && row.request_id === args.request &&
      typeof row.provenance_id === "string" && UUID.test(row.provenance_id) &&
      typeof row.disclosure === "string" && row.disclosure.trim().length > 0 && row.disclosure.length <= 2000) {
      return { provenance: {id: row.provenance_id, recorded: true, disclosure: row.disclosure}, sourceBound: true };
    }
  } catch { /* An accepted receipt remains usable for status/reconciliation. */ }
  return { provenance: {id: null, recorded: false, disclosure: disclosureFallback("reel"), reason: "source_audit_unavailable"}, sourceBound: false };
}
