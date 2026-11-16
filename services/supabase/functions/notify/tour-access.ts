import { HttpError } from "../_shared/http.ts";
import type { DeviceRow, OutboxRow } from "./deliver.ts";

const UUID = /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
type Reader = {
  rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }>;
  from(name: string): any;
};
type Kind = "unrelated" | "private-video" | "tour" | "invalid";
const uuid = (value: unknown): value is string => typeof value === "string" && UUID.test(value);
function facts(row: OutboxRow): Record<string, unknown> | null {
  const data = row.payload?.data;
  return data && typeof data === "object" && !Array.isArray(data) ? data as Record<string, unknown> : null;
}

/** The same category serves two distinct destinations. Never infer one from
 * an incomplete or mixed payload belonging to the other. */
export function renderNoticeKind(row: OutboxRow): Kind {
  if (row.category !== "render_ready") return "unrelated";
  const data = facts(row);
  if (!data || !uuid(row.user_id) || !uuid(data.listing_id)) return "invalid";
  if (Object.hasOwn(data, "property_video_job_id")) {
    return uuid(data.property_video_job_id) && uuid(data.reel_job_id) &&
        data.property_video_job_id.toLowerCase() === data.reel_job_id.toLowerCase() &&
        !["render_id", "slug", "lead_id", "workspace_id"].some((key) => Object.hasOwn(data, key)) &&
        (row.payload.deep_link === undefined || row.payload.deep_link === null)
      ? "private-video" : "invalid";
  }
  if (!uuid(row.id) || !uuid(row.org_id) || !uuid(data.render_id) ||
      ["reel_job_id", "lead_id", "workspace_id"].some((key) => Object.hasOwn(data, key)) ||
      typeof data.slug !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(data.slug) ||
      row.payload.deep_link !== "/f/" + data.slug) return "invalid";
  return "tour";
}

export async function tourNoticeCurrent(db: Reader, row: OutboxRow): Promise<boolean> {
  const kind = renderNoticeKind(row);
  if (kind === "invalid") return false;
  if (kind !== "tour") return true;
  const data = facts(row)!;
  const { data: current, error } = await db.rpc("tour_notification_current", {
    p_outbox: row.id,
    p_expected: {
      outbox_id: row.id.toLowerCase(), org_id: row.org_id!.toLowerCase(),
      recipient_user_id: row.user_id!.toLowerCase(), render_id: (data.render_id as string).toLowerCase(),
      listing_id: (data.listing_id as string).toLowerCase(), slug: data.slug, deep_link: row.payload.deep_link,
    },
  });
  if (error || typeof current !== "boolean") {
    throw new HttpError(503, "Current tour notification access could not be verified.");
  }
  return current;
}

/** Recheck both target access and enrollment immediately before each APNs
 * attempt; an access refusal is not a dead token and must not create email. */
export async function tourDeviceCurrent(db: Reader, row: OutboxRow, device: DeviceRow): Promise<boolean> {
  if (!await tourNoticeCurrent(db, row)) return false;
  const { data, error } = await db.from("notification_devices").select("device_token")
    .eq("user_id", row.user_id).eq("device_token", device.device_token)
    .eq("environment", device.environment).is("disabled_at", null).maybeSingle();
  if (error) throw new HttpError(503, "Current notification enrollment could not be verified.");
  return data?.device_token === device.device_token;
}
