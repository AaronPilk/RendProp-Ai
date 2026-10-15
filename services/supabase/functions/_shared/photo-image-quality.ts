// Server-prepared photo resolution bounds. No client field grants authority.
// The owner comparison keeps its original8192-token contract; normal edits
// prospectively select a complete input tier using actual source geometry/text.
export const PHOTO_2K_INPUT_ALLOWANCES = [8192, 16384, 24576] as const;
export function photo2KInputAllowance(input: unknown): number | null {
 const value=input&&typeof input==="object"&&!Array.isArray(input)?input as Record<string,unknown>:{};
 const extra=value.extra&&typeof value.extra==="object"&&!Array.isArray(value.extra)?value.extra as Record<string,unknown>:{};
 if(extra.photo_quality_4k===true)return null;
 if(extra.owner_photo_2k===true&&Number.isInteger(extra.owner_photo_input_bound)&&Number(extra.owner_photo_input_bound)>0&&Number(extra.owner_photo_input_bound)<=8192)return 8192;
 return preparedInputAllowance(extra,"photo_quality_2k");
}
function preparedInputAllowance(extra:Record<string,unknown>,flag:string):number|null {
 const allowance=extra.photo_input_allowance,used=extra.photo_input_token_bound;
 return extra[flag]===true&&PHOTO_2K_INPUT_ALLOWANCES.includes(allowance as 8192|16384|24576)&&Number.isInteger(used)&&Number(used)>0&&Number(used)<=Number(allowance)?Number(allowance):null;
}
export function photo4KInputAllowance(input:unknown):number|null {
 const value=input&&typeof input==="object"&&!Array.isArray(input)?input as Record<string,unknown>:{};
 const extra=value.extra&&typeof value.extra==="object"&&!Array.isArray(value.extra)?value.extra as Record<string,unknown>:{};
 if(extra.owner_photo_2k===true||extra.photo_quality_2k===true)return null;
 return preparedInputAllowance(extra,"photo_quality_4k");
}

/** Set only by the separately scoped server owner-comparison path. */
export function ownerPhotoPro4KInputAllowance(input:unknown):number|null {
 const value=input&&typeof input==="object"&&!Array.isArray(input)?input as Record<string,unknown>:{};
 const extra=value.extra&&typeof value.extra==="object"&&!Array.isArray(value.extra)?value.extra as Record<string,unknown>:{};
 return extra.owner_photo_pro_4k===true?photo4KInputAllowance(input):null;
}

export const NORMAL_PHOTO_PRO4K_PROFILE="gemini-pro-4k-preservation-v1" as const;
/** Distinct from the temporary owner-comparison marker. Constructed only after
 * normal server policy + isolated eligible route selection, never from a DTO. */
export function normalPhotoPro4KInputAllowance(input:unknown):number|null {
 const value=input&&typeof input==="object"&&!Array.isArray(input)?input as Record<string,unknown>:{};
 const extra=value.extra&&typeof value.extra==="object"&&!Array.isArray(value.extra)?value.extra as Record<string,unknown>:{};
 return ["photo.stage","photo.declutter"].includes(String(value.task))&&extra.photo_preservation_profile===NORMAL_PHOTO_PRO4K_PROFILE?photo4KInputAllowance(input):null;
}
export function photoPro4KInputAllowance(input:unknown):number|null {
 return ownerPhotoPro4KInputAllowance(input)??normalPhotoPro4KInputAllowance(input);
}
