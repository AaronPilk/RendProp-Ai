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
