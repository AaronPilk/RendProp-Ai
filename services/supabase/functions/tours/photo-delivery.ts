import { HttpError, assert } from "../_shared/http.ts";
import { propertyGalleryKey } from "../_shared/property-cover.ts";
import { assertMediaVisible } from "../_shared/media-source-access.ts";
import { assertHostingAvailable } from "../_shared/hosting-retention.ts";
import { admitMediaRead } from "../_shared/media-delivery-admission.ts";

const RENDER = "id,listing_id,slug,published_at";
const LISTING = "id,org_id,deleted_at,main_photo_key,gallery_asset_ids";
const PHOTO = "id,listing_id,kind,bucket,storage_key,uploaded,upload_aborted,bytes,content_type,created_at";
const UUID = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const IMAGE_MIME = new Set(["image/jpeg", "image/png", "image/webp", "image/avif"]);
export type PhotoDelivery = {schema:1;slug:string;objects:Record<string,"renders">;stream_uid:null};

/** Thumbnail-only optimization. null delegates to the existing complete
 * delivery authority; it never classifies an unknown gallery copy as Original.
 * No cache of publication, selection, hosting or source approval is consulted.
 * The caller still verifies its private gateway and performs the initial,
 * post-HEAD and final-byte invocations independently. */
// deno-lint-ignore no-explicit-any
export async function photoDelivery(admin:any, slug:string, key:unknown, bytes=0):Promise<PhotoDelivery|null> {
  assert(/^[A-Za-z0-9_-]{1,64}$/.test(slug) && typeof key==="string",400,"Choose an exact published photo.");
  assert(Number.isSafeInteger(bytes) && bytes>=0 && bytes<=2*1024*1024,400,"Use bounded photo previews.");
  const readRender = async()=>{
    const {data,error}=await admin.from("renders").select(RENDER).eq("slug",slug).not("published_at","is",null).maybeSingle();
    if(error)throw new HttpError(503,"Published photo could not be verified.");
    if(!data || !UUID.test(data.id??"") || !UUID.test(data.listing_id??"") || data.slug!==slug || !data.published_at)
      throw new HttpError(404,"This photo is no longer published.");
    return data;
  };
  const readListing = async(id:string)=>{
    const {data,error}=await admin.from("listings").select(LISTING).eq("id",id).maybeSingle();
    if(error)throw new HttpError(503,"Published photo selection could not be verified.");
    if(!data || data.id!==id || !UUID.test(data.org_id??"") || data.deleted_at)throw new HttpError(404,"This photo is no longer published.");
    return data;
  };
  const render=await readRender(), listing=await readListing(render.listing_id);
  const scope={orgId:listing.org_id,listingId:listing.id};
  if(!propertyGalleryKey(key,scope))return null;
  const selection=listing.gallery_asset_ids??null;
  if(selection!==null && (!Array.isArray(selection)||selection.length>100||selection.some((id:unknown)=>typeof id!=="string"||!UUID.test(id))))return null;
  const readPhoto=async()=>{
    const {data,error}=await admin.from("capture_assets").select(PHOTO).eq("listing_id",listing.id).eq("storage_key",key).maybeSingle();
    if(error)throw new HttpError(503,"Published photo source could not be verified.");
    return data;
  };
  // The complete authority assembles linked disclosure/original references.
  // Keep its exact behavior for those rows rather than inventing a new alias,
  // QC or disclosure policy in this performance-only helper.
  const hasDisclosure=async()=>{
    const {data,error}=await admin.from("media_provenance").select("id").eq("listing_id",listing.id).eq("altered_key",key).limit(1);
    return Boolean(error)||!Array.isArray(data)||data.length!==0;
  };
  const [photo,disclosed]=await Promise.all([readPhoto(),hasDisclosure(),assertHostingAvailable(admin,listing.org_id)]);
  if(disclosed)return null;
  if(!photo || !UUID.test(photo.id??"") || photo.listing_id!==listing.id || photo.storage_key!==key ||
    photo.kind!=="photo" || photo.bucket!=="renders" || photo.uploaded!==true)throw new HttpError(404,"This photo is no longer published.");
  const mime=typeof photo.content_type==="string"?photo.content_type.split(";")[0].trim().toLowerCase():"";
  if(photo.upload_aborted===true || !Number.isSafeInteger(photo.bytes) || photo.bytes<1 || photo.bytes>20_000_000 || !IMAGE_MIME.has(mime))return null;
  if(selection!==null){
    if(!selection.includes(photo.id))throw new HttpError(404,"This photo is no longer selected.");
  } else if(listing.main_photo_key!==key){
    // Legacy null means the first100 eligible uploads, plus an explicit cover.
    // Query only IDs; no other gallery photo, contact, card or URL is assembled.
    const {data,error}=await admin.from("capture_assets").select("id").eq("listing_id",listing.id).eq("kind","photo")
      .eq("bucket","renders").eq("uploaded",true).like("storage_key","%/gallery-%")
      .order("created_at",{ascending:true}).order("id",{ascending:true}).limit(100);
    if(error)throw new HttpError(503,"Published photo order could not be verified.");
    if(!Array.isArray(data)||!data.some((row:{id:string})=>row.id===photo.id))throw new HttpError(404,"This photo is not in the published gallery.");
  }
  const refs={renders:[render.id],assets:[photo.id],keys:[key]};
  await assertMediaVisible(admin,listing.id,refs);
  await admitMediaRead(admin,listing.org_id,bytes);
  const [currentRender,currentListing,currentPhoto,currentDisclosure]=await Promise.all([readRender(),readListing(listing.id),readPhoto(),hasDisclosure()]);
  if(currentDisclosure)return null;
  if(JSON.stringify(currentRender)!==JSON.stringify(render) || JSON.stringify(currentListing)!==JSON.stringify(listing) ||
    JSON.stringify(currentPhoto)!==JSON.stringify(photo))throw new HttpError(404,"The published photo changed. Please refresh.");
  await Promise.all([assertMediaVisible(admin,listing.id,refs),assertHostingAvailable(admin,listing.org_id)]);
  return {schema:1,slug,objects:{[key]:"renders"},stream_uid:null};
}
