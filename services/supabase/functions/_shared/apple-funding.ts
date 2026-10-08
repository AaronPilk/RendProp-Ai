// Invoked only after signature verification and successful entitlement chronology.
import type { AppleTransaction } from "./applejws.ts";
import { HttpError } from "./http.ts";
import { inputHash, servingMode, type FundingContext } from "./funded-serving.ts";
export async function fundVerifiedAppleTransaction(rpc:FundingContext["rpc"],orgId:string,tx:AppleTransaction):Promise<unknown> {
 if(tx.environment!=="Production")return {funded:false,reason:"sandbox"};
 // Ceiling mode: the plan's meters and monthly COGS ceiling are the serving
 // authority; no funding row is required or recorded for the purchase.
 if(await servingMode()==="ceiling")return {funded:false,available:true,reason:"ceiling_mode"};
 const facts={p_org:orgId,p_original:tx.originalTransactionId,p_transaction:tx.transactionId,p_product:tx.productId,p_price_milliunits:tx.priceMilliunits??null,p_currency:tx.currency??null,p_storefront:tx.storefront??null,p_offer_type:tx.offerType??null,p_offer_discount_type:tx.offerDiscountType??null,p_purchased_at:tx.purchaseDate,p_expires_at:tx.expiresDate,p_signed_at:tx.signedDate};
 const reservedTrial=tx.priceMilliunits===0 && tx.offerType===1 && tx.offerDiscountType==="FREE_TRIAL";
 const boundRetail=typeof tx.priceMilliunits === "number" && tx.priceMilliunits>0 && tx.appAccountToken!==null;
 const proof={...facts,...(reservedTrial||boundRetail?{p_actor:tx.appAccountToken??null}:{})};
 const result=await rpc(reservedTrial?"fund_reserved_subscription_trial":boundRetail?"fund_verified_retail_apple_transaction":"fund_verified_apple_transaction",{...proof,p_evidence_sha256:await inputHash(proof)});
 if(result.error)throw new HttpError(503,"Your purchase is recorded, but its serving allowance could not be activated. Restore the purchase to retry.","upstream");
 return result.data;
}
