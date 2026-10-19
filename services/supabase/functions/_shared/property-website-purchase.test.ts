import {assertEquals,assertThrows} from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {decodeTransaction} from './applejws.ts';
import {HttpError} from './http.ts';
import {PROPERTY_WEBSITE_PRODUCT,websitePurchaseArgs} from './property-website-purchase.ts';
const actor='e2000000-0000-4000-8000-000000000001';
const payload={bundleId:'com.rendprop.app',productId:PROPERTY_WEBSITE_PRODUCT,type:'Consumable',quantity:1,inAppOwnershipType:'PURCHASED',appAccountToken:actor,environment:'Sandbox',transactionId:'receipt-1',originalTransactionId:'receipt-1',purchaseDate:1791972000000,signedDate:1791972060000};
Deno.test('consumable facts assign exact account,property,environment and one quantity with no subscription expiry',()=>{
 const tx=decodeTransaction(payload),args=websitePurchaseArgs(tx,actor,'property','org');assertEquals(args.p_transaction,'receipt-1');assertEquals(args.p_environment,'Sandbox');assertEquals(args.p_listing,'property');assertEquals(tx.quantity,1);assertEquals(tx.expiresDate,null);
});
Deno.test('non-consumable,quantity,family-sharing,foreign-account,date and SKU substitutions are refused',()=>{
 for(const delta of [{type:'Non-Consumable'},{quantity:2},{quantity:'1'},{inAppOwnershipType:'FAMILY_SHARED'},{appAccountToken:'e2000000-0000-4000-8000-000000000099'},{appAccountToken:null},{purchaseDate:0},{signedDate:0},{expiresDate:1791972120000},{productId:'com.rendprop.app.pro.monthly'}])assertThrows(()=>websitePurchaseArgs(decodeTransaction({...payload,...delta}),actor,'property','org'),HttpError);
});
Deno.test('Apple notification chronology is retained while device restore cannot invent refund reversal',()=>{
 const args=websitePurchaseArgs(decodeTransaction({...payload,revocationDate:1791972100000}),actor,null,null,{notification:true,event:'refund',eventSignedAt:'2026-10-14T11:10:00Z'});assertEquals(args.p_event,'refund');assertEquals(args.p_notification,true);assertEquals(args.p_signed,'2026-10-14T11:10:00Z');assertEquals(args.p_listing,null);assertEquals(websitePurchaseArgs(decodeTransaction(payload),actor,'property','org').p_notification,false);
});
Deno.test('legacy subscription decoding omits additive quantity, preserving notification fingerprint shape',()=>{
 const tx=decodeTransaction({...payload,type:'Auto-Renewable Subscription',productId:'com.rendprop.app.pro.monthly',expiresDate:1791972120000});assertEquals(Object.hasOwn(tx,'quantity'),false);
});
