// Pure typed tests: local imports only, no endpoint/provider/auth/deletion calls.
import { KNOWLEDGE, knowledgeBlock } from "./knowledge.ts";

function assert(value: boolean, reason: string): asserts value {
  if (!value) throw new Error(reason);
}

function fact(topic: string): string {
  const entries = KNOWLEDGE.filter((entry) => entry.topic === topic);
  assert(
    entries.length === 1,
    `exactly one knowledge entry required: ${topic}`,
  );
  return entries[0].fact;
}

function requireAccountPolicy(text: string): void {
  assert(
    text.includes("No account is required"),
    "must explicitly reject an account requirement",
  );
  assert(text.includes("publish"), "publication must be included");
  assert(
    text.includes("Sign in with Apple is optional"),
    "Apple identity must remain optional",
  );
  assert(
    text.includes("internet connection"),
    "anonymous publication does not mean offline publication",
  );
  assert(
    !/fully signed out|needed only to publish|no server account/i.test(text),
    "stale session/identity claim",
  );
}

Deno.test("knowledge: publication does not require an identified account", () => {
  requireAccountPolicy(fact("Signing in — what needs an account"));
});

Deno.test("knowledge: actual prompt block carries the corrected policy", () => {
  const account = fact("Signing in — what needs an account");
  const block = knowledgeBlock();
  assert(
    block.includes(account),
    "formatted prompt must contain the actual account entry",
  );
  requireAccountPolicy(block);
});

Deno.test("knowledge: anonymous sessions are not described as local-only deletion", () => {
  const deletion = fact("Deleting an account");
  assert(
    deletion.includes("anonymous session"),
    "guests may have a server account",
  );
  assert(
    deletion.includes("not a local-only wipe"),
    "distinguish server account deletion from local clear",
  );
  assert(
    !/since there is no server account|a local wipe only/i.test(deletion),
    "false anonymous account premise",
  );
  assert(
    deletion.includes("does NOT cancel an App Store subscription"),
    "preserve billing distinction",
  );
  assert(
    deletion.includes("Shared-team data"),
    "do not promise deletion of colleagues' workspace",
  );
  assert(
    deletion.includes("cleanup may remain pending"),
    "do not promise instantaneous total cleanup",
  );
});

Deno.test("knowledge: known defective account statement is rejected", () => {
  let rejected = false;
  try {
    requireAccountPolicy(
      "Sign in with Apple is needed only to PUBLISH a tour to the web.",
    );
  } catch {
    rejected = true;
  }
  assert(rejected, "negative control did not reject stale policy");
});

Deno.test("knowledge: introductory trial requires Apple's subscription confirmation", () => {
  const trial = fact("Free trial");
  for (const required of ["7-day", "choosing a subscription", "confirming it in Apple's purchase sheet", "does not start that trial", "selected plan's allowances", "renews at the displayed subscription price", "original end date"]) {
    assert(trial.includes(required), `trial policy omitted: ${required}`);
  }
  const block = knowledgeBlock();
  assert(block.includes(trial), "actual guidance must contain the trial policy");
  assert(block.includes("never on signup"), "allowances summary must not grant an automatic trial");
});

Deno.test("knowledge: Measurements, 3D floor plans and 3D walkthroughs are all Coming soon (build 57)", () => {
  const measurement = fact("Measurements and floor plans — current availability");
  for (const required of ["Measurements, 3D floor plans and 3D walkthroughs are Coming soon", "does not open yet", "no plan includes it", "nothing else in the app waits on it", "PDF or image", "not be a certified survey", "TestFlight Lab", "local capture tests", "agency and Studio capture planning"]) {
    assert(measurement.includes(required), `current availability omitted: ${required}`);
  }
  assert(!measurement.includes("LiDAR phones can also scan"), "ordinary workflow must not promise automatic generation");
  assert(!/Open a listing's Measurements card/.test(measurement), "the Measurements card is Coming soon and must not be described as opening");
  assert(!/Draw a floor outline by entering/.test(measurement), "manual outlines are not available in build 57");
  assert(knowledgeBlock().includes(measurement), "actual online prompt must carry current availability");
  assert(!knowledgeBlock().includes("manual Measurements"), "no fact may describe manual Measurements as usable today");
  assert(fact("What the app needs to run").includes("Measurements, 3D floor plans and 3D walkthroughs are Coming soon"), "requirements fact must carry the Coming-soon state");
  assert(!fact("A render or upload failed").includes("back automatically"), "recovery must not promise every attempt is refunded");
});
