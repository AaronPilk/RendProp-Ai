import { assert, HttpError, json, pathSegments, readJsonLimited } from "../_shared/http.ts";
import { projectMediaComplete, projectMediaManifest, type ProjectMediaRow } from "./project-media.ts";
import type { StudioContext } from "./context.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HASH = /^[a-f0-9]{64}$/;
const AUDIO = ["audio/mpeg", "audio/mp4", "audio/wav", "audio/x-wav", "audio/wave", "audio/ogg", "audio/webm"];
const headers = { "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" };

export function propertyMusicInput(raw: unknown) {
  assert(raw && typeof raw === "object" && !Array.isArray(raw), 400, "Choose saved property music.");
  const input = raw as Record<string, unknown>;
  assert(typeof input.listing_id === "string" && UUID.test(input.listing_id) && typeof input.sha256 === "string" && HASH.test(input.sha256), 400, "Choose saved property music.");
  return { listing: input.listing_id, sha256: input.sha256 };
}
function rpcError(error: { message?: string } | null) {
  if (!error) return;
  const match = /^RP(400|403|404|409|422): ([^\r\n]{1,240})$/.exec(error.message ?? "");
  throw new HttpError(match ? Number(match[1]) : 503, match ? match[2] : "The music source could not be confirmed.");
}
/** A completed copy is a durable handoff of that immutable revision. Later
 * edits/withdrawal of the author's live review do not rewrite the recipient's
 * copy. Deleting the source/version/binding does revoke this narrow grant. */
export async function hasMusicCopy(context: StudioContext, actor: string, listing: string, sha256: string): Promise<boolean> {
  const copied = await context.admin.from("studio_property_music_copies").select("source_version_id").eq("actor_id", actor).eq("org_id", context.orgId).eq("listing_id", listing).eq("sha256", sha256).maybeSingle();
  assert(!copied.error, 503, "The music handoff could not be checked.");
  if (!copied.data) return false;
  const version = await context.admin.from("studio_production_versions").select("payload").eq("id", copied.data.source_version_id).eq("org_id", context.orgId).eq("listing_id", listing).maybeSingle();
  assert(!version.error, 503, "The music source version could not be checked.");
  return version.data?.payload?.draft?.music?.source?.sha256 === sha256 && version.data.payload.draft.music.licensed === true;
}
/** Binding is deliberately narrower than knowing a content hash. The file must
 * have been explicitly attached to this property by its original uploader. */
export async function propertyMusicRow(context: StudioContext, listing: string, sha256: string): Promise<ProjectMediaRow> {
  const binding = await context.admin.from("studio_property_music").select("media_id").eq("org_id", context.orgId).eq("listing_id", listing).eq("sha256", sha256).maybeSingle();
  assert(!binding.error, 503, "Saved music could not be loaded.");
  assert(binding.data, 422, "Save and attach this music before sharing the property edit.");
  const result = await context.admin.from("studio_project_media").select("*").eq("id", binding.data.media_id).eq("org_id", context.orgId).eq("sha256", sha256).maybeSingle();
  const row = result.data as ProjectMediaRow | null;
  assert(!result.error, 503, "Saved music could not be loaded.");
  assert(row && row.bytes <= 16 * 1024 * 1024 && AUDIO.includes(row.mime) && projectMediaComplete(row), 422, "This music upload is incomplete or unavailable.");
  const deleting = await context.admin.from("deletion_requests").select("user_id").eq("user_id", row.actor_id).neq("status", "completed").limit(1);
  assert(!deleting.error, 503, "The music source could not be checked.");
  assert(!deleting.data?.length, 404, "This music source is no longer available.");
  return row;
}

export async function handlePropertyMusic(req: Request, context: StudioContext, manifest = projectMediaManifest): Promise<Response> {
  const seg = pathSegments(req, "studio"), reviewing = seg[0] === "production-review";
  assert(reviewing ? req.method === "POST" : req.method === "GET" || req.method === "POST", 405, "Choose saved music or attach your original audio.");
  const input = req.method === "GET" ? Object.fromEntries(new URL(req.url).searchParams) : await readJsonLimited(req, 4096);
  const scope = propertyMusicInput(input);
  await context.authorizeListing(scope.listing);
  if (!reviewing && req.method === "POST") {
    assert(input.licensed === true, 400, "Confirm permission to use and share this music with property collaborators.");
    const attached = await context.admin.rpc("studio_property_music_attach", { p_actor: context.userId, p_org: context.orgId, p_listing: scope.listing, p_sha256: scope.sha256 }).abortSignal(req.signal);
    rpcError(attached.error);
    assert(attached.data, 503, "Music attachment could not be confirmed.");
    // An existing binding is not permission to mint a capability for its private
    // uploader. The subsequent GET still requires ownership or a copied draft.
    return json({ attached: true, sha256: scope.sha256 }, 200, headers);
  }
  let owner = context.userId;
  if (reviewing) {
    assert(input.key === `edit:${scope.listing}` && typeof input.document_user_id === "string" && UUID.test(input.document_user_id), 400, "Choose the saved reel and author.");
    assert(Number.isSafeInteger(input.expected_document_revision) && Number(input.expected_document_revision) > 0, 400, "Refresh the saved reel revision.");
    owner = input.document_user_id;
  }
  const authorizeSelection = async (row: ProjectMediaRow) => {
    if (reviewing) {
      const review = await context.admin.rpc("studio_production_review", { p_actor: context.userId, p_org_id: context.orgId, p_document_user_id: owner, p_key: input.key, p_action: "get" }).abortSignal(req.signal);
      rpcError(review.error);
      assert(review.data?.document && review.data.review?.status !== "draft" && review.data.review?.submitted_at, 404, "This reel is no longer submitted for review.");
      assert(review.data.document.revision === input.expected_document_revision && review.data.source_revision === input.expected_document_revision, 409, "This reel changed. Reload before previewing music.");
      assert(review.data.document.payload?.draft?.music?.source?.sha256 === scope.sha256 && review.data.document.payload?.draft?.music?.source?.size === row.bytes && review.data.document.payload?.draft?.music?.licensed === true, 404, "This music is not selected in the submitted reel.");
      // Submitted payload text cannot authorize someone else's private binding.
      if (row.actor_id !== owner) {
        assert(await hasMusicCopy(context, owner, scope.listing, scope.sha256), 404, "The submitted music has no authorized source handoff.");
      }
    } else if (row.actor_id !== context.userId) {
      const [copied, document] = await Promise.all([
        hasMusicCopy(context, context.userId, scope.listing, scope.sha256),
        context.admin.from("studio_documents").select("payload").eq("user_id", context.userId).eq("org_id", context.orgId).eq("key", `edit:${scope.listing}`).maybeSingle(),
      ]);
      assert(!document.error && copied && document.data?.payload?.draft?.music?.source?.sha256 === scope.sha256 && document.data.payload.draft.music.licensed === true, 404, "This music was not handed off with your current edit.");
    }
  };
  const row = await propertyMusicRow(context, scope.listing, scope.sha256);
  await authorizeSelection(row);
  req.signal.throwIfAborted();
  const media = await manifest(row);
  // No capabilities survive a withdrawal, revision change, binding deletion or
  // account deletion that occurs during signing.
  await context.authorizeListing(scope.listing);
  const final = await propertyMusicRow(context, scope.listing, scope.sha256);
  assert(final.id === row.id && final.actor_id === row.actor_id, 409, "The music source changed. Reload the edit.");
  await authorizeSelection(final);
  return json({ media }, 200, headers);
}
