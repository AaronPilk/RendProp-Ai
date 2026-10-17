import {HttpError} from "../_shared/http.ts";
export const PHOTO_QUALITY_PROTOCOL="retained-operation-v1";
export const PHOTO_QUALITY_PROTOCOL_HEADER="x-rendprop-photo-quality-protocol";
export const hasPhotoRecoveryProtocol=(req:Pick<Request,"headers">):boolean=>req.headers.get(PHOTO_QUALITY_PROTOCOL_HEADER)===PHOTO_QUALITY_PROTOCOL;
/** Only a client that retains the exact operation may buy new checked media.
 * Saved historical results are resolved before this fresh-work gate. */
export function assertPhotoRecoveryProtocol(req:Pick<Request,"headers">):void{
 if(!hasPhotoRecoveryProtocol(req))throw new HttpError(409,"Update Rendprop or refresh Studio before creating this photo edit. Your original is unchanged. No edit was sent or charged.","conflict",{recovery_protocol_required:true,required_photo_quality_protocol:PHOTO_QUALITY_PROTOCOL,no_provider_dispatch:true,failure_phase:"photo_recovery_protocol"});
}
