import { assert, HttpError } from "../_shared/http.ts";
import { corsHeaders } from "../_shared/cors.ts";

// This inventory contains explicit account-owned fields, never a SELECT * or
// workspace-wide diagnostic dump. All limits fail explicitly; no row truncation.
type Row = Record<string, unknown>;
type Scope = { column: string; values: string[] };
type Spec = { name: string; fields: string; order: string[]; actorColumn?: string; listingColumn?: string; assetColumn?: string; workspace?: boolean };
export const EXPORT_LIMITS = { page: 100, workspaces: 100, rows: 20000, collectionRows: 10000, queries: 300, bytes: 20 * 1024 * 1024, textBytes: 2 * 1024 * 1024 };
const own = (name: string, fields: string, actorColumn = "user_id", order = ["id"], workspace = true): Spec => ({ name, fields, actorColumn, order, workspace });
const child = (name: string, fields: string, order = ["id"]): Spec => ({ name, fields, listingColumn: "listing_id", order });
const specs: Spec[] = [
  own("member_portfolios", "id,org_id,user_id,listing_ids,revision,updated_at"),
  child("capture_assets", "id,listing_id,kind,duration_s,fps,width,height,codec,is_drone,has_gyro,sha256,bytes,uploaded,created_at"),
  { name: "capture_chapters", fields: "id,asset_id,label,t_ms,sort", order: ["id"], assetColumn: "asset_id" },
  child("photos", "id,listing_id,is_main,is_staged,caption,sort,created_at"),
  child("render_jobs", "id,listing_id,capture_asset_id,tier,enhancements,status,current_step,progress,cost_cents,created_at,started_at,finished_at"),
  child("renders", "id,job_id,listing_id,slug,duration_s,speed_factor,staged,published_at,created_at"),
  child("media_provenance", "id,org_id,listing_id,render_id,kind,label,model_id,edit,style,disclosure,created_at"),
  child("leads", "id,render_id,listing_id,org_id,name,phone,email,extra,source,synced_crm,created_at"),
  child("listing_client_contacts", "listing_id,org_id,enabled,public_card,recipient_email,hide_rendprop_branding,photo_asset_id,revision,updated_at", ["listing_id"]),
  own("studio_documents", "user_id,org_id,key,kind,listing_id,revision,payload,updated_at", "user_id", ["org_id", "key"]),
  own("studio_creative_results", "id,user_id,org_id,listing_id,kind,provenance_id,created_at"),
  own("studio_presenter_profiles", "id,org_id,subject_user_id,source_listing_id,display_name,reference_asset_ids,revision,status,approved_revision,consent_at,updated_at", "subject_user_id"),
  own("studio_presenter_drafts", "id,org_id,listing_id,author_user_id,title,script,source_asset_id,format,resolution,revision,approved_revision,consent_at,generation_result_id,updated_at", "author_user_id"),
  own("studio_presenter_jobs", "id,org_id,listing_id,actor_id,draft_id,draft_revision,quote_cents,held_cents,charged_cents,state,revision,created_at,updated_at", "actor_id"),
  own("studio_production_versions", "id,document_user_id,org_id,document_key,listing_id,document_revision,reason,brief,payload,created_at", "document_user_id"),
  own("studio_production_reviews", "document_user_id,org_id,document_key,listing_id,revision,document_revision,status,submitted_at,updated_at", "document_user_id", ["org_id", "document_key"]),
  own("studio_project_media", "id,actor_id,org_id,sha256,bytes,mime,filename,modified,parts,created_at", "actor_id"),
  own("serving_operation_results", "org_id,actor_id,request_key,result,created_at", "actor_id", ["org_id", "request_key"]),
  own("subscription_trial_purchase_reservations", "id,actor_id,org_id,product_id,walkthrough_cap,photo_cap,listing_cap,max_days,max_video_seconds,upload_budget_bytes,held_at,converted_at", "actor_id"),
  own("subscription_trial_grants", "id,actor_id,org_id,starts_at,ends_at,walkthrough_cap,photo_cap,listing_cap,upload_budget_bytes,max_video_seconds,created_at", "actor_id"),
  own("subscription_trial_actions", "grant_id,kind,identity,actor_id,org_id,held_bytes,created_at", "actor_id", ["grant_id", "kind", "identity"]),
  own("notification_preferences", "user_id,lead_received,render_ready,upload_stuck,free_week_ending,allowance_low,first_tour_nudge,muted_until,created_at,updated_at", "user_id", ["user_id"], false),
  own("notification_devices", "id,user_id,bundle_id,environment,locale,app_version,created_at,last_seen_at,disabled_at", "user_id", ["id"], false),
  own("apple_subscriptions", "original_transaction_id,org_id,user_id,product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,created_at,updated_at", "user_id", ["original_transaction_id"], false),
  own("deletion_requests", "id,user_id,status,requested_at,completed_at", "user_id", ["id"], false),
];
const omissions = [
  { collection: "subscription_trial_video_attestations", reason: "Technical object validation evidence contains private storage identities and is excluded; saved media metadata and account-owned trial admission metadata are included." },
  { collection: "binary_media", reason: "Use the separate media download flow for original files; this JSON contains metadata only." },
  { collection: "on_device_unsynced_data", reason: "Local-only files and changes have not reached this service." },
  { collection: "removed_workspaces_and_other_members", reason: "Only current workspace access and the caller's assigned listings or authored records are exported." },
  { collection: "credentials_and_media_capabilities", reason: "Authentication, device, verification and provider tokens, signed/private media URLs, storage keys, and delivery leases are excluded." },
  { collection: "server_diagnostics_and_provider_payloads", reason: "Operational logs, raw provider requests/errors, notification delivery payloads and cleanup payloads are excluded." },
  { collection: "workspace_cost_and_usage_ledger", reason: "The shared ledger has no reliable account ownership column. Assigned render costs and actor-owned presenter charges are included; they are not a complete billing ledger." },
  { collection: "reviewer_and_presenter_subject_private_data", reason: "Other members' private profiles, presenter snapshots, and review events are excluded." },
  { collection: "consent_acceptance_evidence", reason: "Account-wide legal acceptance evidence is not available in the current export schema; presenter consent timestamps are included." },
  { collection: "spatial_experiment_and_transient_jobs", reason: "Experimental spatial jobs, quotes, upload reservations and transient AI requests are excluded; saved listing details and authored Studio documents are included." },
];

const secretKey = /(?:token|secret|authorization|password|credential|api.?key|access.?key|bearer|jws|jwt|signed.?transaction|signed.?url|presigned|storage.?key|original.?key|enhanced.?key|altered.?key|output.?key|stream.?uid|status.?url|response.?url|cancel.?url|lease|request.?id|billing.?reference|provider.?payload|reference.?snapshot|approval.?binding)/i;
function privateURL(raw: string): boolean {
  try {
    const u = new URL(raw);
    return u.protocol === "data:" || u.protocol === "blob:" || u.hostname.endsWith(".r2.cloudflarestorage.com") || u.hostname.endsWith(".r2.dev") || u.hostname.endsWith(".videodelivery.net") || u.hostname === "videodelivery.net" || u.hostname.endsWith(".cloudflarestream.com") || ["renders.rendprop.com", "cdn.rendprop.com", "media.rendprop.com"].includes(u.hostname) || /(?:x-amz-|token|signature|credential)/i.test(u.search) || /(?:presenter-private|studio-project|private-ai)\//i.test(u.pathname) || (["rendprop.com", "www.rendprop.com"].includes(u.hostname) && /^\/media\/[^/]+\/(?:r2|stream)\//.test(u.pathname));
  } catch { return false; }
}
/** Keep authored content, redact capabilities even when embedded in saved text. */
export function sanitizeExport(value: unknown, depth = 0): unknown {
  assert(depth <= 32, 413, "Saved content is too complex for one export.");
  if (typeof value === "string") {
    assert(new TextEncoder().encode(value).length <= EXPORT_LIMITS.textBytes, 413, "Saved text is too large for one export.");
    return value.replace(/urn:rendprop:r2:[^\s<>"']+/gi, "[storage identity omitted]").replace(/(?:https?:\/\/|blob:|data:)[^\s<>"']+/gi, (link) => privateURL(link) ? "[private media link omitted]" : link);
  }
  if (Array.isArray(value)) { assert(value.length <= 20000, 413, "Saved content is too large for one export."); return value.map((v) => sanitizeExport(v, depth + 1)); }
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value as Row).filter(([key]) => !secretKey.test(key)).map(([key, item]) => [key, sanitizeExport(item, depth + 1)]));
  return value;
}

// The transport is injectable for tests; authority lives in these actual query
// filters AND independent receipt checks, not in a mock returning owned rows.
export async function accountDataExport(admin: any, actor: string, limits = EXPORT_LIMITS): Promise<Response> {
  const data: Record<string, Row[]> = {}, omitted = [...omissions];
  let rows = 0, encodedBytes = 0, queries = 0;
  const budget = (items: Row[]) => {
    rows += items.length; encodedBytes += new TextEncoder().encode(JSON.stringify(items)).length;
    assert(rows <= limits.rows && encodedBytes <= limits.bytes, 413, "Your data exceeds the download limit. Contact support for an assisted export.");
  };
  async function read(spec: Spec, scopes: Scope[], optional = false): Promise<Row[] | null> {
    if (scopes.some((s) => s.values.length === 0)) return [];
    // Bound IN filters as well as response pages; thousands of UUIDs cannot be
    // placed in one PostgREST URL. Partitions are disjoint on their scope key.
    const wide = scopes.findIndex((s) => s.values.length > 100);
    if (wide >= 0) {
      const combined: Row[] = []; let combinedBytes = 0;
      for (let i = 0; i < scopes[wide].values.length; i += 100) {
        const partition = scopes.map((s, index) => index === wide ? { ...s, values: s.values.slice(i, i + 100) } : s);
        const items = await read(spec, partition, optional);
        if (items === null) return null;
        combinedBytes += new TextEncoder().encode(JSON.stringify(items)).length;
        assert(combinedBytes <= limits.bytes, 413, "A collection exceeds the download limit. Contact support for an assisted export.");
        combined.push(...items);
        assert(combined.length <= limits.collectionRows, 413, "A collection exceeds the download limit.");
      }
      return combined;
    }
    const result: Row[] = [], seen = new Set<string>(); let expected: number | undefined, bytes = 0;
    // A saved document can hold two MiB. Small heavy-content pages avoid
    // assembling hundreds of MiB before the total attachment bound can fire.
    const page = /(?:payload|details|brief)/.test(spec.fields) ? Math.min(limits.page, 5) : limits.page;
    for (let offset = 0; offset <= limits.collectionRows; offset += page) {
      let q = admin.from(spec.name).select(spec.fields, { count: "exact" });
      for (const scope of scopes) q = scope.values.length === 1 ? q.eq(scope.column, scope.values[0]) : q.in(scope.column, scope.values);
      for (const key of spec.order) q = q.order(key, { ascending: true });
      assert(++queries <= limits.queries, 413, "Your data needs an assisted export. Contact support.");
      const response = await q.range(offset, offset + page - 1);
      if (response.error) {
        // Optional means missing schema only, never a DB outage quietly dressed
        // up as a successful inventory. PostgREST missing relation/column codes.
        if (optional && ["42P01", "42703", "PGRST205", "PGRST204"].includes(response.error.code)) {
          omitted.push({ collection: spec.name, reason: "This collection is unavailable in the deployed schema." }); return null;
        }
        throw new HttpError(503, "Account export is temporarily unavailable. Please retry.");
      }
      assert(Array.isArray(response.data) && Number.isSafeInteger(response.count) && response.count >= 0, 503, "Export inventory could not be verified.");
      assert(response.count <= limits.collectionRows, 413, "A collection exceeds the download limit. Contact support for an assisted export.");
      if (expected === undefined) expected = response.count;
      assert(response.count === expected, 409, "Your data changed during the export. Please retry.");
      for (const row of response.data as Row[]) {
        assert(row && !Array.isArray(row), 503, "Export inventory could not be verified.");
        for (const scope of scopes) assert(scope.values.includes(String(row[scope.column])), 403, "Export contains an unavailable record.");
        const key = JSON.stringify(spec.order.map((field) => row[field]));
        assert(spec.order.every((field) => row[field] !== undefined && row[field] !== null) && !seen.has(key), 409, "Your data changed during the export. Please retry.");
        seen.add(key);
        // Re-project even a malformed transport receipt: newly added columns or
        // provider fields cannot leak into the attachment.
        const projected = Object.fromEntries(spec.fields.split(",").map((field) => [field, row[field] ?? null]));
        bytes += new TextEncoder().encode(JSON.stringify(projected)).length;
        assert(bytes <= limits.bytes, 413, "A collection exceeds the download limit. Contact support for an assisted export.");
        result.push(projected);
      }
      assert(result.length <= limits.collectionRows, 413, "A collection exceeds the download limit.");
      if (response.data.length < page) { assert(result.length === expected, 409, "Your data changed during the export. Please retry."); return result; }
    }
    throw new HttpError(413, "A collection exceeds the download limit.");
  }
  async function authority() {
    const named = await admin.rpc("studio_review_named_account", { p_user: actor });
    assert(!named.error && named.data === true, named.error ? 503 : 403, "Your account is unavailable for export.");
    const profiles = (await read({ name: "profiles", fields: "id,email,phone,name,avatar_url,created_at,real_estate_role,public_card", order: ["id"] }, [{ column: "id", values: [actor] }]))!;
    assert(profiles.length === 1, 403, "Your account is unavailable for export.");
    const members = (await read(own("memberships", "id,user_id,org_id,role", "user_id", ["id"], false), [{ column: "user_id", values: [actor] }]))!;
    assert(members.length <= limits.workspaces, 413, "Too many workspaces for one export.");
    const orgIDs = [...new Set(members.map((m) => String(m.org_id)))];
    const orgs = orgIDs.length ? (await read({ name: "orgs", fields: "id,name,handle,space_type,plan,plan_source,plan_expires_at,trial_ends_at,created_at,deleted_at", order: ["id"] }, [{ column: "id", values: orgIDs }]))! : [];
    const active = orgs.filter((o) => o.deleted_at === null), activeIDs = active.map((o) => String(o.id));
    const listings = (await read({ name: "listings", fields: "id,org_id,agent_id,space_type,address,tagline,details,beds,baths,sqft,price_cents,zillow_url,lat,lng,status,sold_at,source,mls_ref,created_at,deleted_at", order: ["id"] }, [{ column: "agent_id", values: [actor] }, { column: "org_id", values: activeIDs }]))!;
    return { profiles, members: members.filter((m) => activeIDs.includes(String(m.org_id))), orgs: active, listings: listings.filter((l) => l.deleted_at === null), orgIDs: activeIDs };
  }
  const first = await authority();
  for (const workspace of first.orgs) {
    assert(++queries <= limits.queries, 413, "Your data needs an assisted export. Contact support.");
    const plan = await admin.rpc("effective_plan", { p_org: workspace.id });
    assert(!plan.error && typeof plan.data === "string", 503, "Your workspace plan could not be verified. Please retry.");
    workspace.plan_raw = workspace.plan; delete workspace.plan;
    workspace.effective_plan = plan.data;
  }
  data.profiles = first.profiles; data.memberships = first.members; data.workspaces = first.orgs; data.listings = first.listings;
  for (const items of Object.values(data)) budget(items);
  const ownIDs = first.listings.map((l) => String(l.id)), referenced = new Map<string, string>();
  for (const spec of specs) {
    const scopes: Scope[] = [];
    if (spec.actorColumn) scopes.push({ column: spec.actorColumn, values: [actor] });
    if (spec.workspace) scopes.push({ column: "org_id", values: first.orgIDs });
    if (spec.listingColumn) scopes.push({ column: spec.listingColumn, values: ownIDs });
    if (spec.assetColumn) scopes.push({ column: spec.assetColumn, values: (data.capture_assets ?? []).map((a) => String(a.id)) });
    const items = await read(spec, scopes, true);
    if (items === null) continue;
    for (const item of items) {
      // Lifetime trial admissions are accounting metadata. Deleted listing or
      // asset references are intentionally omitted from the export projection;
      // they are not current private media authority or required live drafts.
      if (spec.name === "subscription_trial_actions") { delete item.listing_id; delete item.asset_id; }
      if (item.org_id != null && spec.workspace) assert(first.orgIDs.includes(String(item.org_id)), 403, "A workspace is unavailable.");
      if (item.org_id != null && spec.listingColumn) assert(first.listings.some((l) => l.id === item.listing_id && l.org_id === item.org_id), 403, "A listing is unavailable.");
      if (spec.workspace) for (const field of ["listing_id", "source_listing_id"]) if (item[field]) referenced.set(String(item[field]), String(item.org_id));
      if (spec.name === "member_portfolios") {
        assert(Array.isArray(item.listing_ids) && item.listing_ids.every((id) => ownIDs.includes(String(id))), 409, "Your portfolio assignment changed. Please review it before exporting.");
      }
    }
    data[spec.name] = items; budget(items);
  }
  // Recheck every author's referenced listing, including drafts authored for a
  // collaborator's assigned listing. This checks availability without exporting
  // that collaborator's card, listing facts or recordings.
  const referenceIDs = [...referenced.keys()];
  async function checkReferences() { for (let i = 0; i < referenceIDs.length; i += 100) {
    const ids = referenceIDs.slice(i, i + 100);
    const current = (await read({ name: "listings", fields: "id,org_id,deleted_at", order: ["id"] }, [{ column: "id", values: ids }]))!;
    assert(current.length === ids.length && current.every((l) => l.deleted_at === null && l.org_id === referenced.get(String(l.id)) && first.orgIDs.includes(String(l.org_id))), 409, "A referenced listing changed during export. Please retry.");
  } }
  const clean = sanitizeExport(data) as Record<string, Row[]>;
  const manifest = { version: "rendprop-account-export-v1", actor_id: actor, generated_at: new Date().toISOString(), scope: "current-account-owned-cloud-records", complete_within_scope: true, truncated: false, consistency: "Assembled live inventory; access is rechecked before download. This is not a database transaction snapshot.", collections: Object.fromEntries(Object.entries(clean).map(([name, items]) => [name, { count: items.length }])), omissions: omitted, limits };
  const body = JSON.stringify({ manifest, data: clean }, null, 2);
  assert(new TextEncoder().encode(body).length <= limits.bytes, 413, "Your data exceeds the download limit. Contact support for an assisted export.");
  const final = await authority();
  const signature = (a: typeof first) => JSON.stringify({ profile: a.profiles.map((p) => p.id), members: a.members.map((m) => [m.id, m.org_id, m.role]).sort(), orgs: [...a.orgIDs].sort(), listings: a.listings.map((l) => [l.id, l.org_id, l.agent_id]).sort() });
  assert(signature(first) === signature(final), 409, "Account or workspace access changed during export. Please retry.");
  await checkReferences();
  const named = await admin.rpc("studio_review_named_account", { p_user: actor });
  assert(!named.error && named.data === true, named.error ? 503 : 403, "Your account is unavailable for export.");
  return new Response(body, { headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8", "Content-Disposition": 'attachment; filename="rendprop-account-data.json"', "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" } });
}
