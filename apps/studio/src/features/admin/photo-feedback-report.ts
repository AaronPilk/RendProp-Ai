/** GET /admin/photo-feedback (feedback contract §5). The decoder fails closed:
 * an unreadable answer shows nothing rather than a partial report. Every rate
 * and per-useful figure is recomputed here from the counts printed beside it,
 * so each one carries its own numerator and denominator. */
export const REPORT_WINDOWS = ["7d", "30d", "90d"] as const;
export type ReportWindow = typeof REPORT_WINDOWS[number];
/** §5 sample_note: fewer than 30 reviewed rows in a cell is too small to read as a rate. */
export const SMALL_SAMPLE = 30;
export const HONESTY = [
  "Observational, not proof: a difference between edits, models or recipe revisions does not show that one is better, and no feedback is not a rejection.",
  "Costs are internal ledger estimates, not reconciled supplier invoices.",
];
/** [label, value, detail] */
export type Fact = [string, string, string?];
export type Row = (string | number)[];
export type ReportView = ReturnType<typeof photoFeedbackReport>;
type Rec = Record<string, unknown>;

const fail = (): never => { throw Error("The report could not be read, so nothing is shown."); };
const obj = (value: unknown) => value && typeof value === "object" && !Array.isArray(value) ? value as Rec : fail();
const n = (value: unknown) => Number.isSafeInteger(value) && (value as number) >= 0 ? value as number : fail();
const text = (value: unknown) => typeof value === "string" && value.length <= 2000 ? value : fail();
const day = (value: unknown) => new Date(Date.parse(text(value)) || fail()).toISOString().slice(0, 10);
const list = (value: unknown) => Array.isArray(value) && value.length <= 500 ? value.map(obj) : fail();
/** "67% (2 of 3)", flagged when the denominator is a small sample. */
const rate = (part: number, whole: number, empty = "No verdicts yet") =>
  whole ? `${Math.round(part / whole * 1000) / 10}% (${part} of ${whole})${whole < SMALL_SAMPLE ? " · small sample" : ""}` : empty;
const money = (cents: number) => `$${(cents / 100).toFixed(2)}`;
const GROUPS: Rec = { fidelity: "Property fidelity", taste: "Personal style", other: "Other" };

export function photoFeedbackReport(raw: unknown) {
  const r = obj(raw), g = obj(r.generated), e = obj(r.explicit), s = obj(r.signals), c = obj(r.cost), cases = obj(r.regression_cases);
  const outputs = n(g.outputs), unreviewed = n(e.unreviewed_outputs), useful = n(e.useful), needsWork = n(e.needs_work), cents = n(c.recorded_cents), attempts = n(c.attributable_attempts);
  if (!REPORT_WINDOWS.includes(r.window as ReportWindow) || unreviewed > outputs) fail();
  // Reason rows count mentions: one verdict can name several reasons.
  const reasons: Row[] = list(r.reasons).map(row => [text(row.reason).replaceAll("_", " "), text(Object.hasOwn(GROUPS, text(row.group)) ? GROUPS[row.group as string] : fail()), n(row.feedback_rows), n(row.outputs)]);
  const breakdown = (title: string, rows: unknown) => [title, list(rows).map((row): Row => {
    const key = text(row.key), useful = n(row.useful);
    return [key === "unknown" ? "Unknown (not recorded)" : key, n(row.generated), n(row.reviewed), rate(useful, useful + n(row.needs_work))];
  })] as const;
  return {
    range: `${day(r.from)} to ${day(r.to)} (UTC), ${r.window} window`,
    honesty: [...HONESTY, text(r.basis)],
    explicit: [
      ["Generated results", `${outputs}`, `${n(g.accepted)} accepted · ${n(g.refused)} refused · ${n(g.held)} held · ${n(g.pending)} pending`],
      ["Explicitly reviewed", rate(outputs - unreviewed, outputs, "No generated results"), `${unreviewed} unreviewed · ${n(e.reviewed_outputs)} distinct outputs with a verdict · ${n(e.reviewers)} reviewers`],
      ["Useful among explicit verdicts", rate(useful, useful + needsWork), `${useful} useful · ${needsWork} needs work`],
    ] as Fact[],
    reasons,
    groups: `Reason mentions: ${Object.values(GROUPS).map(group => `${group} ${reasons.reduce((sum, row) => sum + (row[1] === group ? row[2] as number : 0), 0)}`).join(" · ")}`,
    breakdowns: [breakdown("By edit", r.by_edit), breakdown("By provider and model", r.by_provider_model), breakdown("By recipe revision", r.by_recipe_revision)],
    cost: [
      ["Attributable attempts", `${attempts}`, `${n(c.succeeded_attempts)} succeeded · ${n(c.failed_or_rejected_attempts)} failed or rejected · ${n(c.uncertain_attempts)} uncertain`],
      ["Recorded estimate", money(cents), `${money(n(c.outstanding_hold_cents))} outstanding holds · outputs with unknown attribution: ${n(c.unknown_attribution_outputs)}`],
      ["Recorded estimate per explicitly useful result", useful ? money(cents / useful) : "No useful verdicts", `${money(cents)} ÷ ${useful} useful`],
      ["Attempts per explicitly useful result", useful ? `${Math.round(attempts / useful * 100) / 100}` : "No useful verdicts", `${attempts} attempts ÷ ${useful} useful`],
    ] as Fact[],
    signals: [["Accuracy acknowledged", "accuracy_ack"], ["Chosen by a person", "manual_selection"], ["Chosen automatically", "automatic_selection"], ["Exported", "export"],
      ["Published", "publication"]].map(([name, key]) => [name, `${n(s[key])}`] as Fact),
    regression: `Regression set: ${n(cases.active)} active cases · ${n(cases.withdrawn)} withdrawn`,
    signalsNote: text(s.note), costBasis: text(c.basis), sampleNote: text(r.sample_note),
  };
}
