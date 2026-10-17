import type {SupabaseClient} from 'npm:@supabase/supabase-js@2.116.0';
import {assert} from '../_shared/http.ts';

type Selection = {asset: any; photo: string};
const columns = 'id,kind,bucket,storage_key,bytes,sha256,content_type';
const effectiveKey = (photo: any): string | null =>
  photo.enhanced_key || photo.original_key || null;

/** Project the current selection; never reorder an already saved video recipe.
 * Explicit native gallery IDs retain their order. Older Studio galleries use
 * their saved photo rows, including the chosen edit, rather than capture time.
 */
export async function selectedGallerySources(db: SupabaseClient, listing: string, gallery: string[] | null, offset: number): Promise<{selected: Selection[]; count: number}> {
  const photos = await db.from('photos').select('id,original_key,enhanced_key,sort')
    .eq('listing_id', listing).order('sort').order('created_at').order('id').limit(1000);
  assert(!photos.error && Array.isArray(photos.data), 503, 'Selected property photos could not be read.');
  if (gallery !== null) {
    assert(Array.isArray(gallery) && gallery.length <= 1000, 503, 'The selected gallery is invalid.');
    const ids = gallery.slice(offset, offset + 100);
    if (!ids.length) return {selected: [], count: gallery.length};
    const loaded = await db.from('capture_assets').select(columns).eq('listing_id', listing).in('id', ids);
    assert(!loaded.error, 503, 'Selected photos could not be read.');
    const assets = new Map((loaded.data ?? []).map(asset => [asset.id, asset]));
    return {count: gallery.length, selected: ids.map(id => {
      const asset = assets.get(id) ?? {id, kind: 'photo', storage_key: null};
      return {asset, photo: photos.data.find(photo => effectiveKey(photo) === asset.storage_key)?.id ?? id};
    })};
  }
  if (photos.data.length) {
    const rows = photos.data.slice(offset, offset + 100);
    const keys = [...new Set(rows.map(effectiveKey).filter((key): key is string => key !== null))];
    const loaded = keys.length ? await db.from('capture_assets').select(columns).eq('listing_id', listing)
      .in('storage_key', keys).order('created_at').order('id') : {data: [], error: null};
    assert(!loaded.error, 503, 'Selected photo versions could not be read.');
    return {count: photos.data.length, selected: rows.map(photo => {
      const key = effectiveKey(photo);
      // A missing edited asset remains unavailable. Falling back to the
      // Original here would quietly change the user's chosen photo version.
      const asset = loaded.data?.find(asset => asset.storage_key === key && asset.id === photo.id)
        ?? loaded.data?.find(asset => asset.storage_key === key)
        ?? {id: null, kind: 'photo', storage_key: key};
      return {asset, photo: photo.id};
    })};
  }
  // Pre-photo-row libraries keep their previous chronological capture fallback.
  const loaded = await db.from('capture_assets').select(columns).eq('listing_id', listing)
    .eq('kind', 'photo').eq('bucket', 'renders').eq('uploaded', true).like('storage_key', '%/gallery-%')
    .order('created_at').order('id').range(offset, offset + 100);
  const totals = await db.from('capture_assets').select('id', {count: 'exact', head: true}).eq('listing_id', listing)
    .eq('kind', 'photo').eq('bucket', 'renders').eq('uploaded', true).like('storage_key', '%/gallery-%');
  assert(!loaded.error && !totals.error && typeof totals.count === 'number', 503, 'Current gallery masters could not be read.');
  const count = Math.min(100, totals.count);
  return {count, selected: (loaded.data ?? []).slice(0, Math.max(0, Math.min(100, count - offset)))
    .map(asset => ({asset, photo: asset.id}))};
}
