import { assert, HttpError, throwRpc } from "../_shared/http.ts";
import { R2_BUCKET_RENDERS } from "../_shared/r2.ts";
import { presignGet } from "../_shared/providers/common.ts";
import { mediaVisibility } from "../_shared/media-source-access.ts";

export const CONTACT_FIELDS = [
  "name",
  "title",
  "brokerage",
  "phone",
  "email",
  "website",
  "instagram",
  "linkedin",
  "avatar_url",
] as const;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const object = (v: unknown): v is Record<string, unknown> =>
  !!v && typeof v === "object" && !Array.isArray(v);
export function contactInput(body: unknown) {
  assert(object(body), 400, "Enter the client contact details.");
  const accepted = [
    "expected_revision",
    "enabled",
    "public_card",
    "recipient_email",
    "hide_rendprop_branding",
    "photo_asset_id",
  ];
  assert(
    Object.keys(body).every((k) => accepted.includes(k)),
    400,
    "Unknown client contact field.",
  );
  assert(
    Number.isSafeInteger(body.expected_revision) &&
      Number(body.expected_revision) >= 0,
    400,
    "Refresh the client contact before saving.",
  );
  assert(
    typeof body.enabled === "boolean" &&
      typeof body.hide_rendprop_branding === "boolean",
    400,
    "Choose the client page settings.",
  );
  assert(
    object(body.public_card) &&
      Object.keys(body.public_card).every((k) =>
        (CONTACT_FIELDS as readonly string[]).includes(k)
      ),
    400,
    "Unknown public contact field.",
  );
  const card: Record<string, string> = {};
  for (const [key, raw] of Object.entries(body.public_card)) {
    assert(
      typeof raw === "string" && raw.length <= 300 &&
        !/[\u0000-\u001f\u007f]/.test(raw),
      400,
      `Enter a valid ${key.replaceAll("_", " ")}.`,
    );
    const value = raw.trim();
    if (!value) continue;
    assert(
      key !== "avatar_url",
      400,
      "Choose an uploaded client photo instead of entering a photo address.",
    );
    if (["name", "title", "brokerage"].includes(key)) {
      assert(
        !value.includes("@"),
        400,
        "Use a name rather than an email address.",
      );
    }
    if (key === "email") {
      assert(EMAIL.test(value), 400, "Enter a valid public email address.");
    }
    if (key === "phone") {
      assert(
        /^[+()\d\s.-]{7,40}$/.test(value),
        400,
        "Enter a valid phone number.",
      );
    }
    if (["website", "instagram", "linkedin", "avatar_url"].includes(key)) {
      let valid = false;
      try {
        const u = new URL(value);
        valid = u.protocol === "https:" && !u.username && !u.password;
      } catch { /* invalid URL */ }
      assert(
        valid,
        400,
        `Use a complete https:// address for ${key.replaceAll("_", " ")}.`,
      );
    }
    card[key] = value;
  }
  assert(
    typeof body.recipient_email === "string" &&
      body.recipient_email.length <= 200,
    400,
    "Enter the email address that should receive leads.",
  );
  const recipient = body.recipient_email.trim().toLowerCase();
  assert(
    !recipient || EMAIL.test(recipient),
    400,
    "Enter a valid lead email address.",
  );
  assert(
    !body.enabled || (!!card.name && !!recipient),
    400,
    "A client name and lead email are required before enabling this page.",
  );
  assert(
    body.photo_asset_id === undefined || body.photo_asset_id === null ||
      (typeof body.photo_asset_id === "string" &&
        UUID.test(body.photo_asset_id)),
    400,
    "Choose a valid uploaded client photo.",
  );
  // An uploaded photo is resolved by the server; never accept its URL from the caller.
  if (body.photo_asset_id) delete card.avatar_url;
  return {
    expected_revision: Number(body.expected_revision),
    enabled: body.enabled,
    public_card: card,
    recipient_email: recipient,
    hide_rendprop_branding: body.hide_rendprop_branding,
    photo_asset_id: body.photo_asset_id ?? null,
  };
}

function rpcError(error: { message?: string }): never {
  if (error.message && /RP\d{3}:/.test(error.message)) throwRpc(error.message);
  throw new HttpError(
    503,
    "The client contact could not be verified. Please retry.",
  );
}
// deno-lint-ignore no-explicit-any
export async function resolveContactPhoto(
  admin: any,
  contact: Record<string, any> | null,
  refs?: { assets: string[]; keys: string[] },
  publicURL: (key: string) => string | null | Promise<string | null> = (key) => presignGet(R2_BUCKET_RENDERS, key, 600),
) {
  if (!contact) return null;
  const out = { ...contact, public_card: { ...(contact.public_card ?? {}) } };
  if (!contact.photo_asset_id) return out;
  delete out.public_card.avatar_url;
  const { data: asset, error } = await admin.from("capture_assets").select(
    "id,listing_id,kind,bucket,storage_key,uploaded",
  )
    .eq("id", contact.photo_asset_id).eq("listing_id", contact.listing_id)
    .maybeSingle();
  if (error) {
    throw new HttpError(503, "The client photo could not be verified.");
  }
  if (
    !asset || asset.kind !== "photo" || asset.bucket !== "renders" ||
    asset.uploaded !== true ||
    !String(asset.storage_key).startsWith(
      `renders/${contact.org_id}/${contact.listing_id}/contact-`,
    )
  ) return out;
  const visible = await mediaVisibility(admin, contact.listing_id, {
    assets: [asset.id],
    keys: [asset.storage_key],
  });
  if (
    visible.assets[asset.id] !== true ||
    visible.keys[asset.storage_key] !== true
  ) return out;
  const url = await publicURL(asset.storage_key);
  const current = await mediaVisibility(admin, contact.listing_id, {
    assets: [asset.id], keys: [asset.storage_key],
  });
  if (current.assets[asset.id] !== true || current.keys[asset.storage_key] !== true) return out;
  if (url) {
    out.public_card.avatar_url = url;
    refs?.assets.push(asset.id);
    refs?.keys.push(asset.storage_key);
  }
  return out;
}
// deno-lint-ignore no-explicit-any
export async function clientContact(
  admin: any,
  user: string,
  org: string,
  listing: string,
) {
  const { data, error } = await admin.rpc("listing_client_contact_get", {
    p_user: user,
    p_org: org,
    p_listing: listing,
  });
  if (error) rpcError(error);
  return resolveContactPhoto(admin, data);
}
// deno-lint-ignore no-explicit-any
export async function saveClientContact(
  admin: any,
  user: string,
  org: string,
  listing: string,
  raw: unknown,
) {
  const body = contactInput(raw);
  const { data, error } = await admin.rpc("listing_client_contact_put", {
    p_user: user,
    p_org: org,
    p_listing: listing,
    p_expected_revision: body.expected_revision,
    p_enabled: body.enabled,
    p_public_card: body.public_card,
    p_recipient_email: body.recipient_email,
    p_hide_branding: body.hide_rendprop_branding,
    p_photo_asset: body.photo_asset_id,
  });
  if (error) rpcError(error);
  return resolveContactPhoto(admin, data);
}
