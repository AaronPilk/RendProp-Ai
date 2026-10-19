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
/** Contract A9.1: ledger money is cents with up to four decimals, like /admin/spend. */
const cents = (value: unknown) => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1e12 ? value : fail();
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
  // Contract A9.2: coverage is reviewed of REVIEWABLE (delivered) outputs; refused, held and pending
  // generations were never delivered. A9.3: per-useful figures divide what sits behind reviewed outputs by
  // the outputs judged useful, not by Useful verdicts; the whole-window figure is only an upper bound.
  const outputs = n(g.outputs), reviewable = n(e.reviewable_outputs), reviewed = n(e.reviewed_outputs), unreviewed = n(e.unreviewed_outputs),
    useful = n(e.useful), needsWork = n(e.needs_work), usefulOutputs = n(e.explicitly_useful_outputs), contested = n(e.contested_outputs),
    recorded = cents(c.recorded_cents), reviewedCents = cents(c.reviewed_recorded_cents), attempts = n(c.attributable_attempts), reviewedAttempts = n(c.reviewed_attempts);
  if (!REPORT_WINDOWS.includes(r.window as ReportWindow) || reviewable > outputs || reviewed > reviewable || unreviewed > reviewable
    || usefulOutputs > reviewed || reviewedCents > recorded || reviewedAttempts > attempts) fail();
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
      ["Explicitly reviewed", rate(reviewed, reviewable, "No delivered results"), `${unreviewed} delivered results without a verdict · ${outputs - reviewable} not delivered · ${n(e.reviewers)} reviewers`],
      ["Useful among explicit verdicts", rate(useful, useful + needsWork), `${useful} useful · ${needsWork} needs work · ${usefulOutputs} results judged useful · ${contested} contested`],
    ] as Fact[],
    reasons,
    groups: `Reason mentions: ${Object.values(GROUPS).map(group => `${group} ${reasons.reduce((sum, row) => sum + (row[1] === group ? row[2] as number : 0), 0)}`).join(" · ")}`,
    breakdowns: [breakdown("By edit", r.by_edit), breakdown("By provider and model", r.by_provider_model), breakdown("By recipe revision", r.by_recipe_revision)],
    cost: [
      ["Attributable attempts", `${attempts}`, `${n(c.succeeded_attempts)} succeeded · ${n(c.failed_or_rejected_attempts)} failed or rejected · ${n(c.uncertain_attempts)} uncertain`],
      ["Recorded estimate", money(recorded), `${money(cents(c.outstanding_hold_cents))} outstanding holds · outputs with unknown attribution: ${n(c.unknown_attribution_outputs)}`],
      ["Recorded estimate per explicitly useful result", usefulOutputs ? money(reviewedCents / usefulOutputs) : "No results judged useful",
        `${money(reviewedCents)} behind reviewed results ÷ ${usefulOutputs} results judged useful · window upper bound ${usefulOutputs ? money(recorded / usefulOutputs) : "n/a"}`],
      ["Attempts per explicitly useful result", usefulOutputs ? `${Math.round(reviewedAttempts / usefulOutputs * 100) / 100}` : "No results judged useful",
        `${reviewedAttempts} attempts behind reviewed results ÷ ${usefulOutputs} results judged useful`],
    ] as Fact[],
    signals: [["Accuracy acknowledged", "accuracy_ack"], ["Chosen by a person", "manual_selection"], ["Chosen automatically", "automatic_selection"], ["Exported", "export"],
      ["Published", "publication"]].map(([name, key]) => [name, `${n(s[key])}`] as Fact),
    regression: `Regression set: ${n(cases.active)} active cases · ${n(cases.withdrawn)} withdrawn`,
    signalsNote: text(s.note), costBasis: text(c.basis), sampleNote: text(r.sample_note),
  };
}
