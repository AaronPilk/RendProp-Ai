import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { HONESTY, photoFeedbackReport } from "../src/features/admin/photo-feedback-report";

// The server's own answer: SQL photo_feedback_report over the labelled synthetic rows of
// services/supabase/tests/photo_feedback_report_demo.py. No provider or hosted call.
const synthetic = () => JSON.parse(readFileSync(new URL("./fixtures/photo-feedback-report-synthetic.json", import.meta.url), "utf8"));

test("every headline figure shows its own numerator and denominator", () => {
  const view = photoFeedbackReport(synthetic());
  assert.equal(view.range, "2026-09-17 to 2026-10-17 (UTC), 30d window");
  assert.deepEqual(view.explicit, [
    ["Generated results", "20", "17 accepted · 1 refused · 1 held · 1 pending"],
    ["Explicitly reviewed", "88.2% (15 of 17) · small sample", "2 delivered results without a verdict · 3 not delivered · 2 reviewers"],
    ["Useful among explicit verdicts", "47.1% (8 of 17) · small sample", "8 useful · 9 needs work · 7 results judged useful · 1 contested"],
  ]);
  assert.deepEqual(view.cost, [
    ["Attributable attempts", "40", "37 succeeded · 1 failed or rejected · 2 uncertain"],
    ["Recorded estimate", "$3.48", "$0.50 outstanding holds · outputs with unknown attribution: 2"],
    ["Recorded estimate per explicitly useful result", "$0.43", "$2.98 behind reviewed results ÷ 7 results judged useful · window upper bound $0.50"],
    ["Attempts per explicitly useful result", "4.57", "32 attempts behind reviewed results ÷ 7 results judged useful"],
  ]);
  assert.deepEqual(view.signals, [["Accuracy acknowledged", "1"], ["Chosen by a person", "1"], ["Chosen automatically", "2"], ["Exported", "2"], ["Published", "1"]]);
  assert.equal(view.regression, "Regression set: 2 active cases · 0 withdrawn");
});

test("contract A9: fractional ledger cents are read, coverage counts delivered results, per-useful divides by results judged useful", () => {
  const raw = synthetic();
  assert.ok(raw.cost.recorded_cents % 1 !== 0 && raw.cost.outstanding_hold_cents % 1 !== 0, "the fixture carries real fractional ledger cents");
  const view = photoFeedbackReport(raw);
  // generated − unreviewed (18 of 20) would count refused, held and pending generations as reviewed.
  assert.notEqual(view.explicit[1][1], "90% (18 of 20)");
  assert.equal(view.explicit[1][1], `88.2% (${raw.explicit.reviewed_outputs} of ${raw.explicit.reviewable_outputs}) · small sample`);
  // Useful verdicts (8) would inflate the divisor; the server's reviewed-basis figure is 42.54 cents.
  assert.equal(raw.explicit.useful, 8); assert.equal(raw.explicit.explicitly_useful_outputs, 7);
  assert.equal(view.cost[2][1], `$${(raw.cost.recorded_cents_per_useful / 100).toFixed(2)}`);
  assert.match(view.cost[2][2], new RegExp(`upper bound \\$${(raw.cost.window_recorded_cents_per_useful / 100).toFixed(2)}`));
  assert.equal(view.cost[3][1], `${Math.round(raw.cost.attempts_per_useful * 100) / 100}`);
});

test("defects keep property fidelity apart from personal style, and breakdowns carry n per cell", () => {
  const view = photoFeedbackReport(synthetic());
  assert.deepEqual(view.reasons, [["requested edit incomplete", "Property fidelity", 2, 2], ["personal style preference", "Personal style", 2, 2],
    ["changed permanent features", "Property fidelity", 1, 1], ["moved or changed appliance", "Property fidelity", 1, 1],
    ["blocked doorway or opening", "Property fidelity", 1, 1], ["inconsistent furniture between views", "Property fidelity", 1, 1],
    ["visible visual artifacts", "Property fidelity", 1, 1], ["other", "Other", 1, 1]]);
  assert.equal(view.groups, "Reason mentions: Property fidelity 7 · Personal style 2 · Other 1");
  assert.deepEqual(view.breakdowns.map(([title, rows]) => [title, rows]), [
    ["By edit", [["declutter", 6, 5, "60% (3 of 5) · small sample"], ["stage", 5, 5, "28.6% (2 of 7) · small sample"], ["custom", 3, 2, "50% (1 of 2) · small sample"],
      ["twilight", 3, 2, "100% (2 of 2) · small sample"], ["sky", 2, 1, "0% (0 of 1) · small sample"], ["lawn", 1, 0, "No verdicts yet"]]],
    ["By provider and model", [["gemini/gemini-3.1-flash-image", 14, 10, "50% (5 of 10) · small sample"], ["gemini/gemini-3-pro-image", 4, 4, "60% (3 of 5) · small sample"],
      ["fal/flux-kontext-pro", 1, 1, "0% (0 of 2) · small sample"], ["no_retained_output", 1, 0, "No verdicts yet"]]],
    ["By recipe revision", [["photo-recipe/2026-10-17.1", 16, 11, "53.8% (7 of 13) · small sample"], ["photo-recipe/2026-10-16.9", 2, 2, "0% (0 of 2) · small sample"],
      ["Unknown (not recorded)", 2, 2, "50% (1 of 2) · small sample"]]],
  ]);
});

test("the honesty wording is always present, and server notes are shown verbatim", () => {
  const raw = synthetic(), view = photoFeedbackReport(raw);
  assert.match(view.honesty.join(" "), /Observational, not proof/);
  assert.match(view.honesty.join(" "), /internal ledger estimates, not reconciled supplier invoices/);
  assert.match(view.honesty.join(" "), /no feedback is not a rejection/);
  assert.deepEqual(view.honesty, [...HONESTY, raw.basis]);
  assert.equal(view.costBasis, raw.cost.basis); assert.equal(view.signalsNote, raw.signals.note); assert.equal(view.sampleNote, raw.sample_note);
});

test("rates come from the printed counts, never from the server's precomputed fields", () => {
  const raw = synthetic();
  Object.assign(raw.explicit, { useful_rate: 0.99, coverage: 0.01 }); raw.by_edit[0].useful_rate = 1;
  Object.assign(raw.cost, { recorded_cents_per_useful: 1, attempts_per_useful: 99, window_recorded_cents_per_useful: 1 });
  const view = photoFeedbackReport(raw);
  assert.equal(view.explicit[1][1], "88.2% (15 of 17) · small sample"); assert.equal(view.explicit[2][1], "47.1% (8 of 17) · small sample");
  assert.equal(view.breakdowns[0][1][0][3], "60% (3 of 5) · small sample"); assert.equal(view.cost[2][1], "$0.43"); assert.equal(view.cost[3][1], "4.57");
  raw.explicit.useful = 40; raw.explicit.needs_work = 10;
  assert.equal(photoFeedbackReport(raw).explicit[2][1], "80% (40 of 50)", "50 verdicts is no longer a small sample");
});

test("empty denominators say so instead of showing 0%", () => {
  const raw = synthetic();
  Object.assign(raw.generated, { outputs: 0, accepted: 0, refused: 0, held: 0, pending: 0 });
  Object.assign(raw.explicit, { reviewable_outputs: 0, reviewed_outputs: 0, useful: 0, needs_work: 0, unreviewed_outputs: 0, explicitly_useful_outputs: 0,
    contested_outputs: 0, reviewers: 0, useful_rate: null, coverage: null });
  Object.assign(raw.cost, { attributable_attempts: 0, reviewed_attempts: 0, recorded_cents: 0, reviewed_recorded_cents: 0, attempts_per_useful: null, recorded_cents_per_useful: null });
  raw.reasons = []; raw.by_edit = [{ key: "stage", generated: 3, reviewed: 0, useful: 0, needs_work: 0, useful_rate: null }];
  const view = photoFeedbackReport(raw);
  assert.equal(view.explicit[1][1], "No delivered results"); assert.equal(view.explicit[2][1], "No verdicts yet");
  assert.equal(view.cost[2][1], "No results judged useful"); assert.equal(view.cost[3][1], "No results judged useful");
  assert.equal(view.breakdowns[0][1][0][3], "No verdicts yet"); assert.deepEqual(view.reasons, []);
});

test("an unreadable answer fails closed instead of showing a partial report", () => {
  const broken: ((raw: any) => void)[] = [
    raw => { raw.generated.outputs = -1; }, raw => { raw.explicit.reviewable_outputs = 21; }, raw => { raw.explicit.reviewed_outputs = 18; },
    raw => { raw.explicit.unreviewed_outputs = 18; }, raw => { raw.explicit.explicitly_useful_outputs = 16; }, raw => { delete raw.explicit.reviewable_outputs; },
    raw => { raw.cost.recorded_cents = -0.5; }, raw => { raw.cost.recorded_cents = "348"; }, raw => { raw.cost.reviewed_recorded_cents = 400; },
    raw => { raw.cost.reviewed_attempts = 41; }, raw => { raw.cost.outstanding_hold_cents = Number.NaN; }, raw => { raw.window = "1y"; },
    raw => { raw.reasons[0].group = "taste-ish"; }, raw => { raw.reasons[0].group = "constructor"; }, raw => { delete raw.cost; },
    raw => { raw.by_edit[0].useful = 1.5; }, raw => { raw.from = "not a date"; }, raw => { raw.basis = 7; }, raw => { raw.by_recipe_revision = {}; },
  ];
  for (const change of broken) { const raw = synthetic(); change(raw); assert.throws(() => photoFeedbackReport(raw), /could not be read/, String(change)); }
  assert.throws(() => photoFeedbackReport(null), /could not be read/); assert.throws(() => photoFeedbackReport([]), /could not be read/);
});
