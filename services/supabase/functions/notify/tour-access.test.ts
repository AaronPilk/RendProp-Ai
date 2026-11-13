import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { DeviceRow, OutboxRow } from "./deliver.ts";
import { renderNoticeKind, tourDeviceCurrent, tourNoticeCurrent } from "./tour-access.ts";

const id = (n: number) => `e0150000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const row = (): OutboxRow => ({
  id: id(1), org_id: id(2), user_id: id(3), category: "render_ready", channel: "push",
  dedupe_key: "render_ready:fixture", attempts: 1,
  payload: { deep_link: "/f/safe-tour", data: { render_id: id(4), listing_id: id(5), slug: "safe-tour" } },
});
const noRead = { rpc: () => { throw new Error("unexpected database read"); }, from: () => { throw new Error("unexpected device read"); } };

Deno.test("tour routing requires one complete destination and never guesses across completion types", async () => {
  assertEquals(renderNoticeKind(row()), "tour");
  const original = row();
  for (const payload of [
    {}, { data: null }, { data: [] },
    { ...original.payload, data: { listing_id: id(5), slug: "safe-tour" } },
    { ...original.payload, data: { ...(original.payload.data as object), property_video_job_id: id(7) } },
    { ...original.payload, data: { ...(original.payload.data as object), reel_job_id: id(7) } },
    { ...original.payload, data: { ...(original.payload.data as object), lead_id: id(7) } },
    { ...original.payload, deep_link: "/f/another-tour" },
    { ...original.payload, deep_link: "/f/safe-tour?token=private" },
    { ...original.payload, data: { render_id: "bad", listing_id: id(5), slug: "safe-tour" } },
  ]) {
    assertEquals(await tourNoticeCurrent(noRead, { ...original, payload }), false);
  }
  for (const field of ["id", "user_id", "org_id"] as const) {
    assertEquals(await tourNoticeCurrent(noRead, { ...original, [field]: null } as OutboxRow), false);
  }
});

Deno.test("private video keeps its actor-scoped guard but mixed or incomplete facts refuse", async () => {
  const privateRow = { ...row(), payload: { data: { listing_id: id(5), property_video_job_id: id(7), reel_job_id: id(7) } } };
  assertEquals(renderNoticeKind(privateRow), "private-video");
  assertEquals(await tourNoticeCurrent(noRead, privateRow), true);
  for (const data of [
    { listing_id: id(5), property_video_job_id: id(7) },
    { listing_id: id(5), property_video_job_id: id(7), reel_job_id: id(8) },
    { ...privateRow.payload.data, render_id: id(4) },
    { ...privateRow.payload.data, slug: "safe-tour" },
    { listing_id: id(5), property_video_job_id: null, reel_job_id: id(7) },
  ]) assertEquals(await tourNoticeCurrent(noRead, { ...privateRow, payload: { data } }), false);
  assertEquals(await tourNoticeCurrent(noRead, { ...privateRow, payload: { ...privateRow.payload, deep_link: "/f/safe-tour" } }), false);
  assertEquals(await tourNoticeCurrent(noRead, { ...row(), category: "lead_received" }), true);
});

Deno.test("tour authority binds exact claimed outbox routing facts, not just a valid render", async () => {
  let calls = 0;
  const db = { ...noRead, rpc: (name: string, args: Record<string, unknown>) => {
    calls++;
    assertEquals(name, "tour_notification_current");
    assertEquals(args, { p_outbox: id(1), p_expected: {
      outbox_id: id(1), org_id: id(2), recipient_user_id: id(3), render_id: id(4),
      listing_id: id(5), slug: "safe-tour", deep_link: "/f/safe-tour",
    } });
    return Promise.resolve({ data: true, error: null });
  } };
  assertEquals(await tourNoticeCurrent(db, row()), true);
  assertEquals(calls, 1);
  assertEquals(await tourNoticeCurrent({ ...db, rpc: () => Promise.resolve({ data: false, error: null }) }, row()), false);
});

Deno.test("tour infrastructure errors and malformed authority responses remain retryable", async () => {
  for (const response of [{ data: null, error: { message: "missing helper" } }, { data: null, error: null }, { data: "true", error: null }]) {
    const error = await assertRejects(() => tourNoticeCurrent({ ...noRead, rpc: () => Promise.resolve(response) }, row()));
    assertEquals((error as { status?: number }).status, 503);
  }
});

Deno.test("each tour device rechecks access before exact actor token and environment enrollment", async () => {
  const device: DeviceRow = { user_id: id(3), device_token: "synthetic-device", environment: "production" };
  const filters: unknown[] = [];
  let reply: { data: { device_token: string } | null; error: unknown } = { data: { device_token: device.device_token }, error: null };
  const query = { select: (v: unknown) => { filters.push(["select", v]); return query; },
    eq: (k: unknown, v: unknown) => { filters.push([k, v]); return query; },
    is: (k: unknown, v: unknown) => { filters.push([k, v]); return query; },
    maybeSingle: () => Promise.resolve(reply) };
  const db = { rpc: () => Promise.resolve({ data: true, error: null }), from: (table: string) => { assertEquals(table, "notification_devices"); return query; } };
  assertEquals(await tourDeviceCurrent(db, row(), device), true);
  assertEquals(filters, [["select", "device_token"], ["user_id", id(3)], ["device_token", device.device_token], ["environment", "production"], ["disabled_at", null]]);
  assertEquals(await tourDeviceCurrent({ ...noRead, rpc: () => Promise.resolve({ data: false, error: null }) }, row(), device), false);
  reply = { data: null, error: null };
  assertEquals(await tourDeviceCurrent(db, row(), device), false);
  reply = { data: null, error: { message: "outage" } };
  await assertRejects(() => tourDeviceCurrent(db, row(), device));
});
