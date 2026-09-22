import { useState } from "react";
import { createRoot } from "react-dom/client";
import CloudPlanner from "../src/features/sync/CloudPlanner";
import { StudioError } from "../src/data/config";
import { scopeKey, type PlanItem } from "../src/workspace";
import type { StudioServices, Workspace } from "../src/data";
import type { CloudDocument } from "../src/data/documents";
import "../src/styles.css";
const user = "11111111-1111-4111-8111-111111111111", org = "22222222-2222-4222-8222-222222222222", other = "33333333-3333-4333-8333-333333333333";
const workspace: Workspace = { user: { id: user, email: "agent@example.invalid", name: "Agent", avatarUrl: null }, org: { id: org, name: "Fixture office", handle: "office", spaceType: "real_estate" }, memberships: [{ orgId: org, orgName: "Fixture office", role: "owner", spaceType: "real_estate" }], plan: "team", planRaw: "team", planDegraded: false, planExpiresAt: null, trialEndsAt: null, usage: { listings: 1, leads: 1, leadsNew: 1, renders: 1 } };
const plan = (title: string): PlanItem => ({ id: "existing-plan", title, caption: "A property worth seeing", date: "2026-09-15T10:00", createdAt: "2026-09-14T12:00:00Z", channel: "Instagram" });
const doc = (revision: number, items: PlanItem[]): CloudDocument => ({ key: "planner", kind: "planner", listing_id: null, revision, payload: { items }, updated_at: "2026-09-14T12:00:00Z" });
const legacy = new URL(location.href).searchParams.has("legacy"), lost = new URL(location.href).searchParams.has("lost");
localStorage.clear(); const localKey = `${scopeKey(user, org)}:plans`;
let remote: CloudDocument | null = legacy ? null : doc(1, [plan("Account plan")]);
let mode: "hold" | "pass" | "conflict" | "lost" = lost ? "lost" : "hold";
if (legacy) localStorage.setItem(localKey, JSON.stringify([plan("Existing browser plan")]));
const calls: { method: string; orgId: string; body: unknown }[] = [];
let release: (() => void) | null = null;
const services = { api: async (path: string, options: { method?: string; orgId: string; body?: any; signal?: AbortSignal }) => {
  if (!path.startsWith("/functions/v1/studio/documents")) throw new Error("Unexpected fixture route");
  const method = options.method ?? "GET"; calls.push({ method, orgId: options.orgId, body: structuredClone(options.body) });
  if (calls.length > 60) throw new Error("Request loop");
  if (options.orgId === other) { if (method === "POST") throw new Error("Cross-workspace mutation"); return { document: null }; }
  if (options.orgId !== org) throw new Error("Wrong account scope");
  if (method === "POST") {
    if (mode === "hold") await new Promise<void>((resolve, reject) => { release = resolve; options.signal?.addEventListener("abort", () => reject(new DOMException("Interrupted", "AbortError")), { once: true }); });
    if (options.signal?.aborted) throw new DOMException("Interrupted", "AbortError");
    if (mode === "conflict" || options.body.expected_revision !== (remote?.revision ?? 0)) throw new StudioError("conflict", "A newer version is saved", 409);
    remote = doc((remote?.revision ?? 0) + 1, options.body.payload.items);
    if (mode === "lost") throw new Error("Lost save response");
  }
  return { document: structuredClone(remote) };
} } as unknown as StudioServices;
function Fixture() {
  const [visible, setVisible] = useState(true), [activeOrg, setOrg] = useState(org), [notice, setNotice] = useState("");
  Object.assign(window, { plannerFixture: {
    calls: () => structuredClone(calls), remote: () => structuredClone(remote),
    mode: (next: typeof mode) => { mode = next; }, release: () => { mode = "pass"; release?.(); },
    leave: () => setVisible(false), return: () => setVisible(true),
    switchWorkspace: () => setOrg(other), returnWorkspace: () => setOrg(org),
    clearBrowser: () => localStorage.clear(), storage: () => Object.fromEntries(Object.keys(localStorage).map(key => [key, localStorage.getItem(key)])),
    changedCloud: () => { remote = doc((remote?.revision ?? 0) + 1, [plan("Saved by phone while reviewing")]); },
  } });
  return <main style={{ padding: 20 }}><p role="status" aria-label="Planner notice">{notice}</p>{visible ? <CloudPlanner key={activeOrg} services={services} workspace={{ ...workspace, org: { ...workspace.org, id: activeOrg } }} onNotice={setNotice} /> : <p>Planner closed</p>}</main>;
}
createRoot(document.getElementById("root")!).render(<Fixture />);
