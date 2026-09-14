export const INDUSTRIES = {
  real_estate: "Real estate",
  venue: "Venues & bars",
  restaurant: "Restaurants",
  retail: "Retail",
  fitness: "Fitness",
  other: "Other businesses",
} as const;
export type Industry = keyof typeof INDUSTRIES;
export const CHANNELS = [
  "Instagram",
  "Facebook",
  "TikTok",
  "YouTube",
  "LinkedIn",
] as const;
export type PlanItem = {
  id: string;
  title: string;
  caption: string;
  channel: (typeof CHANNELS)[number];
  date: string;
  createdAt: string;
  timeZone?: string;
  scheduledAt?: string;
};
export const MAX_PLANS = 100;
export const MAX_PLAN_BACKUP_BYTES = 2 * 1024 * 1024;
export type PlanBackup = {
  format: "rendprop-content-plans";
  version: 1;
  exportedAt: string;
  plans: PlanItem[];
};
export type PlanImportMode = "merge" | "replace";
export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}
export function scopeKey(subject: string | null, org: string | null): string {
  if (subject && !org)
    throw new Error("Choose a workspace before saving account drafts.");
  return `rendprop-studio:v1:${subject ? `${encodeURIComponent(subject)}:${encodeURIComponent(org!)}` : "local"}`;
}
function wallDate(value: string): number {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(value);
  if (!match) throw new Error("Choose a valid date and time.");
  const [, year, month, day, hour, minute] = match.map(Number);
  const time = Date.UTC(year, month - 1, day, hour, minute);
  // Date.parse normalizes February 30 and 24:00. A reminder must never move silently.
  if (
    year < 1000 ||
    !Number.isFinite(time) ||
    new Date(time).toISOString().slice(0, 16) !== value
  )
    throw new Error("Choose a real calendar date and time.");
  return time;
}
function utcInstant(value: string): number {
  const match =
    /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$/.exec(value);
  if (!match) throw new Error("Invalid UTC reminder time.");
  wallDate(match[1]);
  if (Number(match[2]) > 59) throw new Error("Invalid UTC reminder time.");
  const time = Date.parse(value);
  if (
    !Number.isFinite(time) ||
    new Date(time).toISOString() !==
      `${match[1]}:${match[2]}.${(match[3] ?? "").padEnd(3, "0")}Z`
  )
    throw new Error("Invalid UTC reminder time.");
  return time;
}
function zoneFormatter(timeZone: string): Intl.DateTimeFormat {
  if (
    timeZone.length > 100 ||
    !/^[-A-Za-z_+]+(?:\/[-A-Za-z_+0-9]+)*$/.test(timeZone)
  )
    throw new Error("Choose a supported timezone, such as America/New_York.");
  try {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone,
      calendar: "gregory",
      numberingSystem: "latn",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    });
  } catch {
    throw new Error("Choose a supported timezone, such as America/New_York.");
  }
}
function zoneParts(
  time: number,
  formatter: Intl.DateTimeFormat,
): { wall: string; utc: number; second: number } {
  const parts = Object.fromEntries(
    formatter.formatToParts(new Date(time)).map((p) => [p.type, p.value]),
  );
  return {
    wall: `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`,
    utc: Date.UTC(
      Number(parts.year),
      Number(parts.month) - 1,
      Number(parts.day),
      Number(parts.hour),
      Number(parts.minute),
      Number(parts.second),
    ),
    second: Number(parts.second),
  };
}
export function currentTimeZone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
}
export function planDateChoices(date: string, timeZone: string): string[] {
  const nominal = wallDate(date),
    formatter = zoneFormatter(timeZone),
    offsets = new Set<number>();
  // Nearby offsets cover both sides of DST, including half-hour changes and skipped dates.
  // Keeping every exact round-trip lets the agent explicitly choose a repeated clock time.
  for (let hours = -48; hours <= 48; hours += 6) {
    const sample = nominal + hours * 3_600_000;
    offsets.add(zoneParts(sample, formatter).utc - sample);
  }
  return [...offsets]
    .map((offset) => nominal - offset)
    .filter((time) => zoneParts(time, formatter).wall === date)
    .sort((a, b) => a - b)
    .map((time) => new Date(time).toISOString());
}
export function bindPlanDate(
  date: string,
  timeZone: string,
  choice?: string,
): { date: string; timeZone: string; scheduledAt: string } {
  const choices = planDateChoices(date, timeZone);
  if (!choices.length)
    throw new Error(
      "This local time does not exist because the clocks change. Choose another time.",
    );
  if (choice && !choices.includes(choice))
    throw new Error(
      "The selected time no longer matches this date and timezone.",
    );
  if (choices.length > 1 && !choice)
    throw new Error(
      "This clock time occurs twice. Choose the first or second occurrence.",
    );
  return { date, timeZone, scheduledAt: choice ?? choices[0] };
}
export function validatePlanItem(value: unknown): PlanItem {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("Invalid content plan.");
  const p = value as Record<string, unknown>;
  for (const [field, max] of [
    ["id", 100],
    ["title", 120],
    ["caption", 2200],
    ["createdAt", 32],
  ] as const) {
    if (typeof p[field] !== "string" || (p[field] as string).length > max)
      throw new Error("Invalid content plan.");
  }
  if (
    !(p.title as string).trim() ||
    !CHANNELS.includes(p.channel as PlanItem["channel"])
  )
    throw new Error("Choose a title and channel.");
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/.test(p.id as string))
    throw new Error("Invalid content plan identity.");
  if (typeof p.date !== "string")
    throw new Error("Choose a valid date and time.");
  wallDate(p.date);
  utcInstant(p.createdAt as string);
  const item: PlanItem = {
    id: p.id as string,
    title: p.title as string,
    caption: p.caption as string,
    channel: p.channel as PlanItem["channel"],
    date: p.date,
    createdAt: p.createdAt as string,
  };
  if (p.timeZone !== undefined || p.scheduledAt !== undefined) {
    if (typeof p.timeZone !== "string" || typeof p.scheduledAt !== "string")
      throw new Error("A saved reminder needs both its timezone and UTC time.");
    const time = utcInstant(p.scheduledAt);
    const local = zoneParts(time, zoneFormatter(p.timeZone));
    if (
      local.wall !== p.date ||
      local.second !== 0 ||
      new Date(time).getUTCMilliseconds() !== 0
    )
      throw new Error("Saved reminder time does not match its timezone.");
    item.timeZone = p.timeZone;
    item.scheduledAt = new Date(time).toISOString();
  }
  return item;
}
export function validatePlans(items: unknown): PlanItem[] {
  if (!Array.isArray(items) || items.length > MAX_PLANS)
    throw new Error("Keep up to 100 planned posts in this browser.");
  const result = items.map(validatePlanItem);
  if (new Set(result.map((item) => item.id)).size !== result.length)
    throw new Error("Saved content plans have duplicate identities.");
  return result;
}
function requireBackupSize(bytes: number): void {
  if (!Number.isSafeInteger(bytes) || bytes < 1 || bytes > MAX_PLAN_BACKUP_BYTES)
    throw new Error("Choose a nonempty plans backup no larger than 2 MiB.");
}
export function planBackupFile(
  items: PlanItem[],
  exportedAt = new Date().toISOString(),
): { text: string; filename: string } {
  utcInstant(exportedAt);
  const backup: PlanBackup = {
    format: "rendprop-content-plans",
    version: 1,
    exportedAt: new Date(exportedAt).toISOString(),
    plans: validatePlans(items),
  };
  const text = JSON.stringify(backup, null, 2) + "\n";
  requireBackupSize(new TextEncoder().encode(text).length);
  return {
    text,
    filename: `rendprop-content-plans-${backup.exportedAt.replace(/[:.]/g, "-")}-${backup.plans.length}-plans.json`,
  };
}
export function parsePlanBackup(text: string): PlanBackup {
  requireBackupSize(new TextEncoder().encode(text).length);
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error("This file is not valid JSON. Export a Rendprop plans backup and try again.");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    throw new Error("Choose a Rendprop content-plans backup, not a calendar or video-edit file.");
  const value = parsed as Record<string, unknown>;
  if (value.format !== "rendprop-content-plans" || value.version !== 1)
    throw new Error("Unsupported plans backup format or version. This Studio reads version 1 only.");
  // Refuse unknown fields instead of quietly dropping data from a newer export.
  if (Object.keys(value).some((key) => !["format", "version", "exportedAt", "plans"].includes(key)))
    throw new Error("This plans backup contains unsupported fields.");
  if (typeof value.exportedAt !== "string") throw new Error("Invalid backup export date.");
  utcInstant(value.exportedAt);
  const plans = validatePlans(value.plans);
  const itemFields = ["id", "title", "caption", "channel", "date", "createdAt", "timeZone", "scheduledAt"];
  if ((value.plans as object[]).some((item) => Object.keys(item).some((key) => !itemFields.includes(key))))
    throw new Error("A plan contains unsupported fields. No plans were imported.");
  return { format: "rendprop-content-plans", version: 1, exportedAt: new Date(value.exportedAt).toISOString(), plans };
}
export async function readPlanBackupFile(
  file: Pick<File, "size" | "arrayBuffer">,
): Promise<PlanBackup> {
  // Bound before allocating/decoding; a renamed video must not freeze the planner.
  requireBackupSize(file.size);
  const bytes = await file.arrayBuffer();
  requireBackupSize(bytes.byteLength);
  if (bytes.byteLength !== file.size) throw new Error("The backup file changed while reading. Choose it again.");
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new Error("The backup must be a valid UTF-8 JSON file.");
  }
  return parsePlanBackup(text);
}
export function planImportSnapshot(items: PlanItem[]): string {
  return JSON.stringify(validatePlans(items));
}
export function previewPlanImport(
  current: PlanItem[],
  imported: PlanItem[],
  mode: PlanImportMode,
): { plans: PlanItem[]; importedCount: number; existingCount: number } {
  const existing = validatePlans(current), incoming = validatePlans(imported);
  if (mode !== "merge" && mode !== "replace") throw new Error("Choose Merge or Replace before importing.");
  if (mode === "merge") {
    const identities = new Set(existing.map((item) => item.id));
    const overlaps = incoming.filter((item) => identities.has(item.id)).length;
    if (overlaps)
      throw new Error(`${overlaps} imported ${overlaps === 1 ? "plan has an identity" : "plans have identities"} already in this workspace. Merge cannot overwrite or duplicate plans. Choose Replace only if the backup should replace the entire queue.`);
    if (existing.length + incoming.length > MAX_PLANS)
      throw new Error(`Merging would create ${existing.length + incoming.length} plans; the limit is ${MAX_PLANS}. No plans will be dropped. Choose a smaller backup or Replace.`);
  }
  return {
    plans: mode === "replace" ? incoming : [...existing, ...incoming],
    importedCount: incoming.length,
    existingCount: existing.length,
  };
}
export function confirmPlanImport(
  current: PlanItem[],
  imported: PlanItem[],
  mode: PlanImportMode,
  reviewedSnapshot: string,
  onSave: (items: PlanItem[]) => void,
): void {
  // An import is a single synchronous parent save. A failed storage write must leave both
  // the queue and preview intact; never clear then append or save a partially valid file.
  if (planImportSnapshot(current) !== reviewedSnapshot)
    throw new Error("Your saved plans changed after this preview. Cancel and choose the backup again before importing.");
  const preview = previewPlanImport(current, imported, mode);
  onSave(preview.plans);
}
export function savePlan(
  items: PlanItem[],
  item: PlanItem,
  editingId: string | null = null,
): PlanItem[] {
  const existing = validatePlans(items),
    next = validatePlanItem(item);
  if (editingId !== null) {
    const original = existing.find((p) => p.id === editingId);
    if (
      !original ||
      next.id !== editingId ||
      next.createdAt !== original.createdAt
    )
      throw new Error(
        "This plan changed or was removed. Reopen it before saving.",
      );
    return existing.map((p) => (p.id === editingId ? next : p));
  }
  return validatePlans([...existing, next]);
}
export function removePlan(items: PlanItem[], id: string): PlanItem[] {
  const existing = validatePlans(items);
  if (!existing.some((p) => p.id === id))
    throw new Error("This plan has already been removed.");
  return existing.filter((p) => p.id !== id);
}
export function plannerWeekStart(now: number, timeZone: string): string {
  const day = zoneParts(now, zoneFormatter(timeZone)).wall.slice(0, 10);
  const noon = wallDate(`${day}T12:00`),
    weekDay = new Date(noon).getUTCDay();
  return new Date(noon - ((weekDay + 6) % 7) * 86_400_000)
    .toISOString()
    .slice(0, 10);
}
export function shiftPlannerWeek(start: string, weeks: number): string {
  if (!Number.isInteger(weeks) || Math.abs(weeks) > 520)
    throw new Error("Choose a nearby calendar week.");
  return new Date(wallDate(`${start}T12:00`) + weeks * 7 * 86_400_000)
    .toISOString()
    .slice(0, 10);
}
export function filterPlans(
  items: PlanItem[],
  options: {
    channel: "All" | PlanItem["channel"];
    view: "all" | "upcoming" | "week";
    timeZone: string;
    now: number;
    weekStart: string;
  },
): PlanItem[] {
  const formatter = zoneFormatter(options.timeZone),
    weekEnd = shiftPlannerWeek(options.weekStart, 1);
  const currentWall = zoneParts(options.now, formatter).wall;
  const rows = items
    .filter((p) => options.channel === "All" || p.channel === options.channel)
    .map((item) => ({
      item,
      wall: item.scheduledAt
        ? zoneParts(Date.parse(item.scheduledAt), formatter).wall
        : item.date,
    }));
  return rows
    .filter(({ item: p, wall }) => {
      if (options.view === "all") return true;
      if (options.view === "upcoming")
        return p.scheduledAt
          ? Date.parse(p.scheduledAt) >= options.now
          : p.date >= currentWall;
      const day = wall.slice(0, 10);
      return day >= options.weekStart && day < weekEnd;
    })
    .sort(
      (a, b) =>
        a.wall.localeCompare(b.wall) ||
        (a.item.scheduledAt ?? "").localeCompare(b.item.scheduledAt ?? "") ||
        a.item.id.localeCompare(b.item.id),
    )
    .map((row) => row.item);
}
export function readPlans(storage: StorageLike, key: string): PlanItem[] {
  const text = storage.getItem(`${key}:planner`);
  if (text === null) return [];
  if (text.length > 500_000)
    throw new Error("Saved content plan is too large.");
  const parsed: unknown = JSON.parse(text);
  return validatePlans(parsed);
}
export function writePlans(
  storage: StorageLike,
  key: string,
  items: PlanItem[],
) {
  const text = JSON.stringify(validatePlans(items));
  // The read guard is 500,000 characters. Never write a backup which cannot be reopened.
  if (text.length > 500_000) throw new Error("These plans exceed browser draft storage limits. Existing plans were not changed.");
  storage.setItem(`${key}:planner`, text);
}
const escapeICS = (text: string) =>
  text
    .replace(/\\/g, "\\\\")
    .replace(/\r\n|\r|\n/g, "\\n")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,");
export function calendarFile(item: PlanItem): string {
  validatePlanItem(item);
  // UTC means the reminder is the same instant when imported on a phone in another zone.
  const stamp = (d: Date) =>
    d
      .toISOString()
      .replace(/[-:]/g, "")
      .replace(/\.\d{3}Z$/, "Z");
  // Old drafts remain readable. Bind them at export in the current zone, but never silently
  // pick one side of a repeated DST hour. New plans retain their original UTC instant.
  const start = new Date(
    item.scheduledAt ?? bindPlanDate(item.date, currentTimeZone()).scheduledAt,
  );
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Rendprop//Studio Content Plan//EN",
    "BEGIN:VEVENT",
    `UID:${escapeICS(item.id)}@studio.rendprop.com`,
    `DTSTAMP:${stamp(new Date(item.createdAt))}`,
    `DTSTART:${stamp(start)}`,
    `DTEND:${stamp(new Date(start.getTime() + 15 * 60000))}`,
    `SUMMARY:${escapeICS(`${item.channel}: ${item.title}`)}`,
    `DESCRIPTION:${escapeICS(`${item.caption}\n\nManual publishing reminder. Rendprop has not scheduled this post on ${item.channel}.`)}`,
    "END:VEVENT",
    "END:VCALENDAR",
  ];
  // Fold on UTF-8 byte boundaries: long captions must remain a valid calendar file.
  return (
    lines
      .map((line) => {
        let result = "",
          current = "",
          bytes = 0;
        for (const char of line) {
          const length = new TextEncoder().encode(char).length;
          if (bytes + length > 73) {
            result += current + "\r\n";
            current = " ";
            bytes = 1;
          }
          current += char;
          bytes += length;
        }
        return result + current;
      })
      .join("\r\n") + "\r\n"
  );
}
export function downloadBlob(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob);
  let a: HTMLAnchorElement | undefined;
  try {
    a = document.createElement("a");
    a.href = url;
    a.download = name;
    document.body.append(a);
    a.click();
  } finally {
    a?.remove();
    // Give the browser time to start its download; even a failed click releases the URL.
    setTimeout(() => URL.revokeObjectURL(url), 30_000);
  }
}
