// Invoked only after signature verification and successful entitlement chronology.
import type { AppleTransaction } from "./applejws.ts";
import { HttpError } from "./http.ts";
import { inputHash, servingMode, type FundingContext } from "./funded-serving.ts";
export async function fundVerifiedAppleTransaction(rpc:FundingContext["rpc"],orgId:string,tx:AppleTransaction):Promise<unknown> {
 if(tx.environment!=="Production")return {funded:false,reason:"sandbox"};
 const reservedTrial=tx.type==="Auto-Renewable Subscription"&&tx.priceMilliunits===0&&tx.offerType===1&&tx.offerDiscountType==="FREE_TRIAL";
 // Legacy ceiling service needs no retail receipt. An activated monthly-credit
 // period does: its grant and shared margin envelope require an exact signed
 // funding row, before the credit RPC runs. The service-only gate also retains
 // refund settlement after that SKU is retired. It never activates a catalog.
 let creditFundingRequired=false;
 let newCreditPeriod=false;
 if(await servingMode()==="ceiling"&&!reservedTrial){
  if(tx.type!=="Auto-Renewable Subscription")return {funded:false,available:true,reason:"ceiling_mode"};
  const gate=await rpc("credit_paid_funding_route",{
   p_org:orgId,p_product:tx.productId,p_original:tx.originalTransactionId,
   p_transaction:tx.transactionId,p_price_milliunits:tx.priceMilliunits??null,
   p_purchased_at:tx.purchaseDate,
  });
  if(gate.error||(gate.data!=="none"&&gate.data!=="existing_receipt"&&gate.data!=="activated_paid_period"))throw new HttpError(503,
   "Your purchase is recorded, but its serving allowance could not be checked. Restore the purchase to retry.","upstream");
  creditFundingRequired=gate.data!=="none";
  newCreditPeriod=gate.data==="activated_paid_period";
  if(!creditFundingRequired)return {funded:false,available:true,reason:"ceiling_mode"};
 }
 const facts={p_org:orgId,p_original:tx.originalTransactionId,p_transaction:tx.transactionId,p_product:tx.productId,p_price_milliunits:tx.priceMilliunits??null,p_currency:tx.currency??null,p_storefront:tx.storefront??null,p_offer_type:tx.offerType??null,p_offer_discount_type:tx.offerDiscountType??null,p_purchased_at:tx.purchaseDate,p_expires_at:tx.expiresDate,p_signed_at:tx.signedDate};
 const boundRetail=typeof tx.priceMilliunits === "number" && tx.priceMilliunits>0 && tx.appAccountToken!==null;
 const proof={...facts,...(reservedTrial||boundRetail?{p_actor:tx.appAccountToken??null}:{})};
 const result=await rpc(reservedTrial?"fund_reserved_subscription_trial":boundRetail?"fund_verified_retail_apple_transaction":"fund_verified_apple_transaction",{...proof,p_evidence_sha256:await inputHash(proof)});
 if(result.error||(reservedTrial&&!tx.revocationDate&&tx.expiresDate!==null&&Date.parse(tx.expiresDate)>Date.now()&&
   (typeof result.data!=="object"||result.data===null||(result.data as Record<string,unknown>).funded!==true))||(newCreditPeriod&&
   (typeof result.data!=="object"||result.data===null||
    (result.data as Record<string,unknown>).funded!==true)))
  throw new HttpError(503,"Your purchase is recorded, but its serving allowance could not be activated. Restore the purchase to retry.","upstream");
 return result.data;
}
