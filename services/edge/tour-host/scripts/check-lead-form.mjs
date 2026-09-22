#!/usr/bin/env node
// Exercise the actual script emitted by renderTourPage, not a second submit
// implementation. A small DOM surface keeps capture, video and network out of
// this gate; the complete emitted engine is also parsed before the form slice
// runs. Controlled timers cover headers AND response JSON without real delays.
import vm from "node:vm";
import { buildSrc } from "./build-src.mjs";

globalThis.fetch = () => { throw new Error("unexpected real network request"); };
const load = buildSrc("lead-form-check");
const { renderTourPage } = await load("player");
const { buildDemoTour } = await load("demo");
const ID = "12345678-1234-4234-8234-123456789abc";
const LIMIT = 15000;
let checks = 0, cases = 0;
const failures = [];
function expect(value, message) { checks++; if (!value) failures.push(message); }
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
async function flush() { for (let i = 0; i < 40; i++) await Promise.resolve(); }
const good = (status = 201, extra = {}) => ({ ok: true, status, async json() { return { ok: true, id: ID, ...extra }; } });

function harness(label, { fetch: stub = () => Promise.resolve(good()), hp = "", handoff = false, turnstile = true } = {}) {
  const tour = { ...buildDemoTour(), slug: "synthetic-lead-form", cta: {
    mode: handoff ? "deeplink" : "lead_form", label: "Book a showing",
    url: "https://booking.invalid/fixture", lead_fields: ["name", "phone", "email", "message"],
  } };
  const html = renderTourPage(tour, "https://functions.invalid/v1", "fixture-anon", turnstile ? "fixture-site" : "");
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  const engines = scripts.filter((s) => s.includes("/* ---- Lead form:"));
  expect(engines.length === 1, `${label}: exactly one emitted form engine`);
  if (engines.length !== 1) throw new Error("missing or duplicated emitted lead script");
  new vm.Script(engines[0]); // Template/string escaping must produce valid browser JS.
  const start = engines[0].indexOf("/* ---- Lead form:");
  const end = engines[0].indexOf("/* ---- Staged disclosure toggle ---- */", start);
  if (start < 0 || end <= start) throw new Error("actual emitted handler boundary missing");
  const cfgScripts = scripts.filter((s) => s.startsWith("window.__CFG__="));
  if (cfgScripts.length !== 1) throw new Error("actual emitted configuration missing");
  const cfg = JSON.parse(cfgScripts[0].slice("window.__CFG__=".length, -1));
  const formHtml = html.match(/<form id="leadform"[\s\S]*?<\/form>/g);
  expect(formHtml?.length === 1, `${label}: exactly one rendered form`);
  if (formHtml?.length !== 1) throw new Error("missing or duplicated form markup");
  const fields = new Map();
  const values = { name: "Synthetic Buyer", phone: "+1 555 010 0200", email: "buyer@example.invalid", message: "Please arrange a showing.", _hp: hp };
  for (const tag of formHtml[0].matchAll(/<(?:input|textarea)\b[^>]*>/g)) {
    const name = tag[0].match(/\bname="([^"]+)"/)?.[1];
    if (!name) continue;
    const attrs = new Map();
    if (/\brequired(?:[\s>]|$)/.test(tag[0])) attrs.set("required", "");
    fields.set(name, { value: values[name] || "", attrs,
      hasAttribute: (k) => attrs.has(k), setAttribute: (k, v) => attrs.set(k, v), removeAttribute: (k) => attrs.delete(k),
      focus() { state.focused = name; },
    });
  }
  if (turnstile) fields.set("cf-turnstile-response", { value: "fixture-turnstile-token" });
  const originalValues = () => JSON.stringify([...fields].filter(([k]) => k !== "cf-turnstile-response").map(([k, v]) => [k, v.value]));
  const initialValues = originalValues();
  const node = () => ({ style: {}, textContent: "", classList: { toggle() {} } });
  const msg = node(), ok = node(), errors = new Map();
  const btn = { disabled: false, textContent: formHtml[0].match(/<button\b[^>]*type="submit"[^>]*>([^<]+)<\/button>/)?.[1] };
  if (!btn.textContent) throw new Error("actual submit button missing");
  const originalLabel = btn.textContent;
  const state = { submits: [], fetches: [], resets: 0, opened: [], formResets: 0, focused: null, now: 0, timerSeq: 0, timers: new Map(), delays: [] };
  const form = { style: {},
    addEventListener(type, fn) { if (type === "submit") state.submits.push(fn); },
    reset() { state.formResets++; throw new Error("form inputs must not be reset"); },
    querySelector(selector) {
      if (selector === "button[type=submit]") return btn;
      const field = selector.match(/^\[name="([^"]+)"\]$/)?.[1];
      if (field) return fields.get(field) || null;
      const error = selector.match(/^\[data-err="([^"]+)"\]$/)?.[1];
      if (error) { if (!errors.has(error)) errors.set(error, node()); return errors.get(error); }
      throw new Error(`unmodelled form selector ${selector}`);
    },
  };
  const context = vm.createContext({ CFG: cfg, AbortController,
    document: { getElementById(id) { return { leadform: form, leadmsg: msg, leadok: ok }[id] || null; } },
    window: { open(...args) { state.opened.push(args); }, ...(turnstile ? { turnstile: { reset() { state.resets++; fields.get("cf-turnstile-response").value = ""; } } } : {}) },
    FormData: class extends Map { constructor() { super([...fields].map(([k, v]) => [k, v.value])); } },
    fetch(url, init) { state.fetches.push({ url, init }); return stub(url, init, state); },
    setTimeout(fn, ms) { const id = ++state.timerSeq; state.delays.push(ms); state.timers.set(id, { at: state.now + ms, fn }); return id; },
    clearTimeout(id) { state.timers.delete(id); },
  });
  new vm.Script(engines[0].slice(start, end)).runInContext(context);
  expect(state.submits.length === 1, `${label}: actual submit handler registered once`);
  if (state.submits.length !== 1) throw new Error("submit handler did not attach");
  return { state, btn, msg, ok, form, fields, originalLabel,
    submit() { let prevented = false; state.submits[0]({ preventDefault() { prevented = true; } }); expect(prevented, `${label}: native navigation prevented`); },
    async advance(ms) {
      state.now += ms;
      for (const [id, timer] of [...state.timers]) if (timer.at <= state.now) { state.timers.delete(id); timer.fn(); }
      await flush();
    },
    pending() { expect(btn.disabled && btn.textContent === "Sending...", `${label}: pending state visible`); expect(ok.style.display !== "block", `${label}: pending is not success`); },
    failure() {
      expect(!btn.disabled && btn.textContent === originalLabel, `${label}: retry enabled with original branded label`);
      expect(form.style.display !== "none" && ok.style.display !== "block", `${label}: input form retained, no success card`);
      expect(originalValues() === initialValues && state.formResets === 0, `${label}: all submitted inputs retained`);
      expect(msg.textContent.length > 0, `${label}: inline failure visible`);
      expect(state.opened.length === 0, `${label}: no unconfirmed booking handoff`);
      expect(state.timers.size === 0, `${label}: deadline cleared`);
      expect(state.resets === (turnstile ? state.fetches.length : 0), `${label}: Turnstile reset for each completed failure`);
    },
    success() {
      expect(form.style.display === "none" && ok.style.display === "block", `${label}: confirmed success card only`);
      expect(msg.textContent === "", `${label}: stale failure removed`);
      expect(state.resets === 0 && state.formResets === 0, `${label}: existing successful form/Turnstile behavior retained`);
      expect(state.timers.size === 0, `${label}: successful deadline cleared`);
      expect(state.opened.length === (handoff ? 1 : 0), `${label}: only confirmed handoff opened`);
    },
  };
}

async function run(label, fn) {
  cases++;
  try { await fn(label); } catch (err) { failures.push(`${label}: unexpected test/handler failure: ${err.stack || err}`); }
}

for (const [label, response, hp] of [
  ["created", good(), ""], ["deduplicated", good(200, { deduplicated: true }), ""],
  ["honeypot deliberately accepted without ID", { ok: true, status: 200, async json() { return { ok: true }; } }, "bot"],
  ["whitespace honeypot preserves API truthiness", { ok: true, status: 200, async json() { return { ok: true }; } }, " "],
]) await run(label, async (name) => {
  const h = harness(name, { fetch: () => Promise.resolve(response), hp });
  h.submit(); h.pending(); await flush(); h.success();
  expect(h.state.fetches.length === 1, `${name}: one request`);
  const { url, init } = h.state.fetches[0];
  expect(url === "https://functions.invalid/v1/leads" && init.method === "POST", `${name}: actual leads route and method`);
  expect(init.credentials === "omit" && init.mode === "cors", `${name}: existing credential posture`);
  const body = JSON.parse(init.body);
  expect(body.slug === "synthetic-lead-form" && body.turnstile_token === "fixture-turnstile-token", `${name}: slug and Turnstile token forwarded`);
  expect(body.extra.message === "Please arrange a showing." && body._hp === hp, `${name}: message and raw honeypot preserved`);
  expect(init.signal instanceof AbortSignal && !init.signal.aborted, `${name}: live abort signal attached`);
  expect(h.state.delays.length === 1 && h.state.delays[0] === LIMIT, `${name}: one 15s header+body deadline`);
  h.submit(); await flush(); expect(h.state.fetches.length === 1, `${name}: success cannot be submitted again`);
});

for (const [label, body] of [
  ["empty object", {}], ["false ok", { ok: false, id: ID }], ["string ok", { ok: "true", id: ID }],
  ["missing ok", { id: ID }], ["null", null], ["array", []], ["number", 1],
  ["normal missing ID", { ok: true }], ["empty ID", { ok: true, id: "" }],
  ["whitespace ID", { ok: true, id: " " }], ["numeric ID", { ok: true, id: 1 }],
  ["not a lead ID", { ok: true, id: "not-a-lead-id" }],
]) await run(label, async (name) => {
  const h = harness(name, { fetch: () => Promise.resolve({ ok: true, status: 200, async json() { return body; } }), handoff: true });
  h.submit(); await flush(); h.failure();
});

await run("honeypot still requires true success", async (name) => {
  const h = harness(name, { hp: "bot", fetch: () => Promise.resolve({ ok: true, status: 200, async json() { return { ok: false }; } }) });
  h.submit(); await flush(); h.failure();
});

for (const [label, response] of [
  ["HTML 200", { ok: true, status: 200, async json() { throw new SyntaxError("Unexpected token <"); } }],
  ["empty 204", { ok: true, status: 204, async json() { throw new SyntaxError("Unexpected end"); } }],
  ["403 JSON error", { ok: false, status: 403, async json() { return { error: "Bot check failed — please retry the form." }; } }],
  ["429 JSON error", { ok: false, status: 429, async json() { return { error: "internal detail" }; } }],
  ["500 HTML error", { ok: false, status: 500, async json() { throw new SyntaxError("Unexpected token <"); } }],
]) await run(label, async (name) => {
  const h = harness(name, { fetch: () => Promise.resolve(response) });
  h.submit(); await flush(); h.failure();
  if (response.status === 403) expect(h.msg.textContent === "Bot check failed — please retry the form.", `${name}: API validation message preserved`);
  if (response.status === 429) expect(h.msg.textContent.includes("wait a minute") && !h.msg.textContent.includes("internal detail"), `${name}: rate-limit retry copy preserved`);
});

for (const sync of [false, true]) await run(sync ? "synchronous fetch failure" : "network rejection", async (name) => {
  const h = harness(name, { fetch() { if (sync) throw new TypeError("network failed"); return Promise.reject(new TypeError("network failed")); } });
  h.submit(); await flush(); h.failure();
});

for (const stage of ["headers", "JSON"]) await run(`${stage} deadline`, async (name) => {
  const wait = deferred();
  const h = harness(name, { fetch: () => stage === "headers" ? wait.promise : Promise.resolve({ ok: true, status: 201, json: () => wait.promise }) });
  h.submit(); await flush(); h.pending();
  expect(h.state.delays.length === 1 && h.state.delays[0] === LIMIT, `${name}: exactly one full-operation deadline`);
  await h.advance(LIMIT - 1); h.pending();
  await h.advance(1); h.failure();
  expect(h.state.fetches[0]?.init.signal?.aborted === true, `${name}: original fetch aborted`);
  expect(h.msg.textContent.includes("confirm") && !h.msg.textContent.includes("not sent"), `${name}: unknown acceptance, not a false rejection claim`);
  expect(h.state.fetches.length === 1, `${name}: no automatic retry`);
  wait.resolve(stage === "headers" ? good() : { ok: true, id: ID });
  await flush(); h.failure(); // A late response cannot hide the retained form.
});

await run("double submit while pending", async (name) => {
  const wait = deferred();
  const h = harness(name, { fetch: () => wait.promise });
  h.submit(); h.submit(); await flush();
  expect(h.state.fetches.length === 1, `${name}: exactly one POST, including synthetic Enter submits`);
  expect(h.state.delays.length === 1, `${name}: exactly one timer`);
  h.pending(); wait.resolve(good()); await flush(); h.success();
});

await run("manual retry after timeout, late old completion", async (name) => {
  const first = deferred(), second = deferred();
  const h = harness(name, { fetch: (_url, _init, state) => state.fetches.length === 1 ? first.promise : second.promise });
  h.submit(); await flush(); await h.advance(LIMIT); h.failure();
  h.fields.get("cf-turnstile-response").value = "new-fixture-token";
  h.submit(); await flush(); h.pending();
  expect(h.state.fetches.length === 2, `${name}: second POST only after explicit retry`);
  expect(JSON.parse(h.state.fetches[1].init.body).turnstile_token === "new-fixture-token", `${name}: retry uses new Turnstile token`);
  first.resolve(good()); await flush(); h.pending();
  expect(h.state.timers.size === 1, `${name}: old completion cannot cancel current deadline`);
  second.resolve(good(200, { deduplicated: true })); await flush();
  expect(h.form.style.display === "none" && h.ok.style.display === "block", `${name}: only current verified response confirms`);
  expect(h.state.timers.size === 0 && h.state.resets === 1, `${name}: one failed attempt reset, success timer cleared`);
});

await run("booking handoff after confirmation", async (name) => {
  const h = harness(name, { handoff: true }); h.submit(); await flush(); h.success();
  expect(JSON.stringify(h.state.opened[0]) === JSON.stringify(["https://booking.invalid/fixture", "_blank", "noopener"]), `${name}: original safe handoff preserved`);
});

await run("failure without Turnstile widget", async (name) => {
  const h = harness(name, { turnstile: false, fetch: () => Promise.reject(new Error("offline")) });
  h.submit(); await flush(); h.failure();
});

await run("invalid client input never requests", async (name) => {
  const h = harness(name); h.fields.get("name").value = "";
  h.submit(); await flush();
  expect(h.state.fetches.length === 0 && h.state.delays.length === 0, `${name}: zero requests and timers`);
  expect(!h.btn.disabled && h.state.focused === "name", `${name}: invalid field remains editable and focused`);
  expect(h.fields.get("name").attrs.get("aria-invalid") === "true", `${name}: accessible validation preserved`);
});

expect(cases === 31, `all 31 emitted-handler cases ran, got ${cases}`);
if (failures.length) {
  console.error(`FAIL lead form: ${failures.length} failures / ${checks} assertions / ${cases} cases / 0 skipped`);
  for (const failure of failures) console.error(`  ${failure}`);
  process.exitCode = 1;
} else console.log(`PASS lead form: ${checks} assertions / ${cases} cases / 0 skipped / 0 real network requests`);
