import { assert } from './http.ts';
import type { AppleTransaction } from './applejws.ts';
export const PROPERTY_WEBSITE_PRODUCT = 'com.rendprop.app.website.premium.property';
export const WEBSITE_THEMES = ['basic','signature-estate','coastal-luxe'] as const;
export type WebsitePurchaseEvent = 'purchase'|'refund'|'revoke'|'refund_reversed';
/** Only called with the existing pinned-chain, signature-verified Apple facts.
 * The new consumable always has an account token; legacy subscription rules
 * do not become a transferable property-upgrade path. */
export function websitePurchaseArgs(tx: AppleTransaction, actor: string, listing: string|null, org: string|null,
 options: { notification?:boolean; event?:WebsitePurchaseEvent; eventSignedAt?:string|null } = {}) {
 assert(tx.productId===PROPERTY_WEBSITE_PRODUCT,400,'That product is not a property website upgrade.');
 assert(tx.type==='Consumable' && tx.expiresDate===null && tx.quantity===1,400,'Choose one property website upgrade.');
 assert(tx.inAppOwnershipType==='PURCHASED',403,'The account that bought this upgrade must restore it.');
 assert(tx.appAccountToken?.toLowerCase()===actor.toLowerCase(),403,'This property upgrade belongs to another account.');
 assert(tx.purchaseDate!==null && tx.signedDate!==null,400,'The verified purchase is missing its dates.');
 const event=options.event??(tx.revocationDate?'refund':'purchase');
 assert(!options.notification || typeof options.eventSignedAt==='string' && Number.isFinite(Date.parse(options.eventSignedAt)),400,'The verified notification is missing its signed chronology.');
 const signedAt=options.notification?options.eventSignedAt!:tx.signedDate;
 return {p_actor:actor,p_listing:listing,p_expected_org:org,p_environment:tx.environment,p_transaction:tx.transactionId,
  p_product:tx.productId,p_purchased:tx.purchaseDate,p_signed:signedAt,p_revoked:tx.revocationDate,
  p_event:event,p_notification:options.notification===true};
}
