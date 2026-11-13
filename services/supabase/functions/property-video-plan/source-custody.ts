// Prepared JPEGs retain their authoritative master and publication custody.
// This read-only fence runs at every existing planner checkSaved boundary.
import { assert, HttpError } from '../_shared/http.ts';
import { assertMediaVisible, type MediaAccessClient, type MediaSourceRefs } from '../_shared/media-source-access.ts';
import { headObject, R2_BUCKET_RENDERS, R2_BUCKET_UPLOADS } from '../_shared/r2.ts';
type Row = Record<string, any>;
type Client = MediaAccessClient & { from(name: string): any };
export type PlannerScope = { actor: string; org: string; library: string; listing: string };
export type SavedPlannerSource = { asset: string; key: string; bytes: number; etag: string; contentType: string };
export type PlannerCustodyIO = {
  head(source: Row): Promise<{ exists: boolean; bytes: number | null; etag: string | null; contentType: string | null }>;
  visible(db: MediaAccessClient, listing: string, refs: MediaSourceRefs): Promise<void>;
};
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const HASH = /^[a-f0-9]{64}$/;
const object = (x: unknown): x is Row => !!x && typeof x === 'object' && !Array.isArray(x);
const failure = 'The selected prepared photo master changed or is unavailable.';
const defaultIO: PlannerCustodyIO = {
  head: source => headObject(source.bucket === 'uploads' ? R2_BUCKET_UPLOADS : R2_BUCKET_RENDERS, source.storage_key, AbortSignal.timeout(10_000)),
  visible: assertMediaVisible,
};
function boundPreparation(p: unknown, id: string, source: SavedPlannerSource, scope: PlannerScope) {
  assert(object(p) && p.id === id && p.actor_id === scope.actor && p.org_id === scope.org && p.library_org_id === scope.library && p.listing_id === scope.listing && p.state === 'ready', 409, failure);
  assert(p.asset_id === source.asset && p.storage_key === source.key && p.bytes === source.bytes && p.etag === source.etag && source.contentType === 'image/jpeg' && typeof p.sha256 === 'string' && HASH.test(p.sha256), 409, failure);
  assert(typeof p.original_asset_id === 'string' && UUID.test(p.original_asset_id) && p.original_asset_id !== source.asset && p.version_id === 'asset:' + p.original_asset_id && (p.photo_provenance_id === null || (typeof p.photo_provenance_id === 'string' && UUID.test(p.photo_provenance_id))), 409, failure);
  assert(typeof p.lease_token === 'string' && UUID.test(p.lease_token) && source.key === `uploads/${scope.org}/${scope.listing}/prepared-video/${id}/${p.lease_token}.jpg`, 409, failure);
  const original = p.original_source;
  assert(object(original) && original.actor_id === scope.actor && original.org_id === scope.org && original.listing_id === scope.listing && original.asset_id === p.original_asset_id && ['uploads', 'renders'].includes(original.bucket), 409, failure);
  assert(typeof original.storage_key === 'string' && original.storage_key.startsWith(`${original.bucket}/${scope.org}/${scope.listing}/`) && !original.storage_key.includes('..') && Number.isSafeInteger(original.bytes) && original.bytes > 0 && original.bytes <= 52_428_800 && ['image/jpeg', 'image/png', 'image/webp'].includes(original.content_type) && typeof original.sha256 === 'string' && HASH.test(original.sha256) && typeof original.etag === 'string' && original.etag.length > 0 && original.etag.length <= 256, 409, failure);
  return { id, actor_id: p.actor_id, org_id: p.org_id, library_org_id: p.library_org_id, listing_id: p.listing_id, state: p.state, asset_id: p.asset_id, storage_key: p.storage_key, bytes: p.bytes, sha256: p.sha256, etag: p.etag, lease_token: p.lease_token, original_asset_id: p.original_asset_id, version_id: p.version_id, photo_provenance_id: p.photo_provenance_id, original_source: original };
}
async function freshScope(db: Client, id: string, actor: string) {
  const { data, error } = await db.rpc('property_video_preparation_scope', { p_id: id, p_actor: actor });
  if (error) throw new HttpError(409, failure);
  return data;
}
export async function assertPlannerSourceCustody(db: Client, scope: PlannerScope, sources: readonly SavedPlannerSource[], io: PlannerCustodyIO = defaultIO): Promise<void> {
  assert(Object.values(scope).every(x => typeof x === 'string' && UUID.test(x)) && Array.isArray(sources) && sources.length > 0 && sources.length <= 100, 503, 'Photo planning source scope could not be verified.');
  const assets = new Set<string>(), prepared: Array<{ source: SavedPlannerSource; bound: ReturnType<typeof boundPreparation> }> = [];
  for (const source of sources) {
    assert(UUID.test(source.asset), 503, failure); assets.add(source.asset);
    // Do not filter actor/state before lookup: foreign, duplicate or unfinished
    // alias rows must fail, never become an apparently ordinary raw upload.
    const { data, error } = await db.from('property_video_preparations').select('id').eq('asset_id', source.asset).limit(2);
    assert(!error && Array.isArray(data) && data.length <= 1, 503, failure);
    if (data.length === 0) {
      assert(!source.key.includes('/prepared-video/'), 409, failure);
      continue;
    }
    assert(object(data[0]) && typeof data[0].id === 'string' && UUID.test(data[0].id), 503, failure);
    const p = boundPreparation(await freshScope(db, data[0].id, scope.actor), data[0].id, source, scope);
    assets.add(p.original_asset_id);
    const h = await io.head(p.original_source);
    assert(h.exists && h.bytes === p.original_source.bytes && h.etag === p.original_source.etag && h.contentType?.split(';')[0].trim().toLowerCase() === p.original_source.content_type, 409, failure);
    if (p.photo_provenance_id !== null) {
      const { data: m, error: provenanceError } = await db.from('media_provenance').select('id,org_id,listing_id,photo_publication').eq('id', p.photo_provenance_id).eq('org_id', scope.org).eq('listing_id', scope.listing).maybeSingle();
      assert(!provenanceError && object(m) && m.id === p.photo_provenance_id && m.org_id === scope.org && m.listing_id === scope.listing, 409, failure);
      if (m.photo_publication !== null) {
        const publication = m.photo_publication;
        assert(object(publication) && publication.schema === 1 && publication.phase === 'prepared' && publication.target?.org_id === scope.org && publication.target?.library_org_id === scope.library && publication.target?.listing_id === scope.listing && publication.target?.output_asset_id === p.original_asset_id && typeof publication.target?.source_copy_asset_id === 'string' && UUID.test(publication.target.source_copy_asset_id), 409, failure);
        assets.add(publication.target.output_asset_id); assets.add(publication.target.source_copy_asset_id);
      }
    }
    prepared.push({ source, bound: p });
  }
  // The existing central guard HEADs all four retained publication objects,
  // then re-reads current SQL visibility; ordinary sources keep their old path.
  await io.visible(db, scope.listing, { assets: [...assets] });
  for (const { source, bound } of prepared) {
    const current = boundPreparation(await freshScope(db, bound.id, scope.actor), bound.id, source, scope);
    assert(JSON.stringify(current) === JSON.stringify(bound), 409, failure);
  }
}
