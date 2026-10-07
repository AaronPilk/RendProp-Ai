// Invoked only after signature verification and successful entitlement chronology.
import type { AppleTransaction } from "./applejws.ts";
import { HttpError } from "./http.ts";
import { inputHash, type FundingContext } from "./funded-serving.ts";
export async function fundVerifiedAppleTransaction(rpc:FundingContext["rpc"],orgId:string,tx:AppleTransaction):Promise<unknown> {
 if(tx.environment!=="Production")return {funded:false,reason:"sandbox"};
 const facts={p_org:orgId,p_original:tx.originalTransactionId,p_transaction:tx.transactionId,p_product:tx.productId,p_price_milliunits:tx.priceMilliunits??null,p_currency:tx.currency??null,p_storefront:tx.storefront??null,p_offer_type:tx.offerType??null,p_offer_discount_type:tx.offerDiscountType??null,p_purchased_at:tx.purchaseDate,p_expires_at:tx.expiresDate,p_signed_at:tx.signedDate};
 const reservedTrial=tx.priceMilliunits===0 && tx.offerType===1 && tx.offerDiscountType==="FREE_TRIAL";
 const proof={...facts,...(reservedTrial?{p_actor:tx.appAccountToken??null}:{})};
 const result=await rpc(reservedTrial?"fund_reserved_subscription_trial":"fund_verified_apple_transaction",{...proof,p_evidence_sha256:await inputHash(proof)});
 if(result.error)throw new HttpError(503,"Your purchase is recorded, but its serving allowance could not be activated. Restore the purchase to retry.","upstream");
 return result.data;
}
