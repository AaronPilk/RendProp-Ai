import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { HONESTY, photoFeedbackReport } from "../src/features/admin/photo-feedback-report";

// Clearly labeled synthetic fixture in the contract §5 shape; no provider or hosted call.
const synthetic = () => JSON.parse(readFileSync(new URL("./fixtures/photo-feedback-report-synthetic.json", import.meta.url), "utf8"));

test("every headline figure shows its own numerator and denominator", () => {
  const view = photoFeedbackReport(synthetic());
  assert.equal(view.range, "2026-09-17 to 2026-10-17 (UTC), 30d window");
  assert.deepEqual(view.explicit, [
    ["Generated results", "42", "36 accepted · 3 refused · 1 held · 2 pending"],
    ["Explicitly reviewed", "26.2% (11 of 42)", "31 unreviewed · 12 distinct outputs with a verdict · 2 reviewers"],
    ["Useful among explicit verdicts", "61.5% (8 of 13) · small sample", "8 useful · 5 needs work"],
  ]);
  assert.deepEqual(view.cost, [
    ["Attributable attempts", "51", "44 succeeded · 5 failed or rejected · 2 uncertain"],
    ["Recorded estimate", "$12.64", "$0.80 outstanding holds · outputs with unknown attribution: 1"],
    ["Recorded estimate per explicitly useful result", "$1.58", "$12.64 ÷ 8 useful"],
    ["Attempts per explicitly useful result", "6.38", "51 attempts ÷ 8 useful"],
  ]);
  assert.deepEqual(view.signals, [["Accuracy acknowledged", "4"], ["Chosen by a person", "9"], ["Chosen automatically", "0"], ["Exported", "6"], ["Published", "2"]]);
  assert.equal(view.regression, "Regression set: 2 active cases · 1 withdrawn");
});

test("defects keep property fidelity apart from personal style, and breakdowns carry n per cell", () => {
  const view = photoFeedbackReport(synthetic());
  assert.deepEqual(view.reasons, [["changed permanent features", "Property fidelity", 3, 3], ["personal style preference", "Personal style", 2, 2],
    ["moved or changed appliance", "Property fidelity", 1, 1], ["other", "Other", 1, 1]]);
  assert.equal(view.groups, "Reason mentions: Property fidelity 4 · Personal style 2 · Other 1");
  assert.deepEqual(view.breakdowns.map(([title, rows]) => [title, rows]), [
    ["By edit", [["stage", 30, 9, "55.6% (5 of 9) · small sample"], ["declutter", 12, 4, "75% (3 of 4) · small sample"]]],
    ["By provider and model", [["gemini/gemini-2.5-flash-image", 40, 12, "66.7% (8 of 12) · small sample"], ["Unknown (not recorded)", 2, 1, "0% (0 of 1) · small sample"]]],
    ["By recipe revision", [["photo-recipe/2026-10-17.1", 40, 12, "66.7% (8 of 12) · small sample"], ["Unknown (not recorded)", 2, 1, "0% (0 of 1) · small sample"]]],
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
  raw.explicit.useful_rate = 0.99; raw.by_edit[0].useful_rate = 1; raw.cost.recorded_cents_per_useful = 1;
  const view = photoFeedbackReport(raw);
  assert.equal(view.explicit[2][1], "61.5% (8 of 13) · small sample"); assert.equal(view.breakdowns[0][1][0][3], "55.6% (5 of 9) · small sample"); assert.equal(view.cost[2][1], "$1.58");
  raw.explicit.useful = 40; raw.explicit.needs_work = 10;
  assert.equal(photoFeedbackReport(raw).explicit[2][1], "80% (40 of 50)", "50 verdicts is no longer a small sample");
});

test("empty denominators say so instead of showing 0%", () => {
  const raw = synthetic();
  Object.assign(raw.generated, { outputs: 0, accepted: 0, refused: 0, held: 0, pending: 0 });
  Object.assign(raw.explicit, { reviewed_outputs: 0, useful: 0, needs_work: 0, unreviewed_outputs: 0, reviewers: 0, useful_rate: null, coverage: null });
  Object.assign(raw.cost, { attempts_per_useful: null, recorded_cents_per_useful: null });
  raw.reasons = []; raw.by_edit = []; raw.by_edit.push({ key: "stage", generated: 3, reviewed: 0, useful: 0, needs_work: 0, useful_rate: null });
  const view = photoFeedbackReport(raw);
  assert.equal(view.explicit[1][1], "No generated results"); assert.equal(view.explicit[2][1], "No verdicts yet");
  assert.equal(view.cost[2][1], "No useful verdicts"); assert.equal(view.cost[3][1], "No useful verdicts");
  assert.equal(view.breakdowns[0][1][0][3], "No verdicts yet"); assert.deepEqual(view.reasons, []);
});

test("an unreadable answer fails closed instead of showing a partial report", () => {
  const broken: ((raw: any) => void)[] = [
    raw => { raw.generated.outputs = -1; }, raw => { raw.explicit.unreviewed_outputs = 43; }, raw => { raw.window = "1y"; },
    raw => { raw.reasons[0].group = "taste-ish"; }, raw => { raw.reasons[0].group = "constructor"; }, raw => { delete raw.cost; },
    raw => { raw.by_edit[0].useful = 1.5; }, raw => { raw.from = "not a date"; }, raw => { raw.basis = 7; }, raw => { raw.by_recipe_revision = {}; },
  ];
  for (const change of broken) { const raw = synthetic(); change(raw); assert.throws(() => photoFeedbackReport(raw), /could not be read/, String(change)); }
  assert.throws(() => photoFeedbackReport(null), /could not be read/); assert.throws(() => photoFeedbackReport([]), /could not be read/);
});
