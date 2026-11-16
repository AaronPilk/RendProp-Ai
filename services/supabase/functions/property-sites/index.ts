// Verified per-property consumable entitlement. SKU defaults disabled in SQL;
// no receipt ever changes subscriptions or the website of another property.
import { handleOptions } from '../_shared/cors.ts';
import { assert,HttpError,json,pathSegments,readJsonLimited,respondError,throwRpc } from '../_shared/http.ts';
import { adminClient,assertNotDeleting,getUser,preferredOrg } from '../_shared/supabase.ts';
import { verifyAppleJWS,decodeTransaction } from '../_shared/applejws.ts';
import { PROPERTY_WEBSITE_PRODUCT,WEBSITE_THEMES,websitePurchaseArgs } from '../_shared/property-website-purchase.ts';
const UUID=/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const APPLE_BUNDLE_ID=(Deno.env.get('APPLE_BUNDLE_ID')??'com.rendprop.app').trim();
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return handleOptions();
 try {
  const user=await getUser(req),seg=pathSegments(req,'property-sites'),listing=seg[0];
  assert(typeof listing==='string'&&UUID.test(listing)&&seg.length<=2,400,'Choose a valid property.');
  const admin=adminClient();
  const rpc=async(name:string,args:Record<string,unknown>)=>{const {data,error}=await admin.rpc(name,args);if(error)throwRpc(error.message);return data;};
  if(req.method==='GET'&&seg.length===1){return json(await rpc('property_website_state',{p_actor:user.id,p_listing:listing,p_expected_org:preferredOrg(req)??null}),200,{'cache-control':'no-store'});}
  assert(req.method==='POST'&&seg[1]==='upgrade'||req.method==='PATCH'&&seg.length===1,405,'Use GET, PATCH, or POST /upgrade.');
  await assertNotDeleting(user.id);
  const body=await readJsonLimited<Record<string,unknown>>(req,96*1024),org=body.expected_org_id;
  assert(typeof org==='string'&&UUID.test(org),400,'Choose the property workspace before saving.');
  const selected=preferredOrg(req);assert(!selected||selected===org,409,'The selected workspace changed. Reopen the property.');
  if(req.method==='PATCH'){
   assert(typeof body.website_theme==='string'&&(WEBSITE_THEMES as readonly string[]).includes(body.website_theme),400,'Choose a supported property website theme.');
   return json(await rpc('set_property_website_theme',{p_actor:user.id,p_listing:listing,p_expected_org:org,p_theme:body.website_theme}),200,{'cache-control':'no-store'});
  }
  assert(typeof body.signed_transaction==='string'&&body.signed_transaction.length>0&&body.signed_transaction.length<=64*1024,400,'A signed Apple transaction is required.');
  const tx=decodeTransaction(await verifyAppleJWS(body.signed_transaction));
  assert(tx.bundleId===APPLE_BUNDLE_ID,400,'That purchase belongs to another app.');
  assert(tx.productId===PROPERTY_WEBSITE_PRODUCT,400,'That purchase is not a property website upgrade.');
  return json(await rpc('property_website_transaction',websitePurchaseArgs(tx,user.id,listing,org)),200,{'cache-control':'no-store'});
 }catch(error){return respondError(error instanceof Error?error:new HttpError(500,'Property website update unavailable.'));}
});
