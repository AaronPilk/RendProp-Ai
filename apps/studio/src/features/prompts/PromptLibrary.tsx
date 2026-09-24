import { useEffect, useMemo, useRef, useState } from "react";
import { canonicalDocument, DocumentSync, type CloudDocument, type SyncState } from "../../data/documents";
import type { StudioServices } from "../../data/services";
import type { Workspace } from "../../data/contracts";
import { downloadText } from "../creative/media";
import { compilePrompt, DEFAULT_PROMPT_INPUTS, decodePromptLibrary, EMPTY_PROMPT_LIBRARY, MAX_SAVED_PROMPTS, PROMPT_RECIPES, promptExport, TARGET_LABELS, type PromptInputs, type PromptLibraryData, type SavedPrompt } from "./model";
import "./prompts.css";

type Props = { services: StudioServices; workspace: Workspace; onPendingChange?: (pending: boolean, busy?: boolean) => void };
const blank = (): SavedPrompt => { const now = new Date().toISOString(); return { id: crypto.randomUUID(), title: "", prompt: "", target: "editing-brief", sourceUrl: "", notes: "", verdict: "untested", revision: 1, createdAt: now, updatedAt: now, recipeId: null, recipeVersion: null }; };
const PHOTO_RECIPES = new Set(["room-push", "detail-shot", "exterior-opening", "twilight-concept", "staged-room-concept"]);
const message = (e: unknown) => e instanceof Error ? e.message : "The prompt library could not finish this action.";
export default function PromptLibrary({ services, workspace, onPendingChange }: Props) {
  const [library, setLibrary] = useState<PromptLibraryData>(EMPTY_PROMPT_LIBRARY), [state, setState] = useState<SyncState>("loading"), [ready, setReady] = useState(false);
  const [form, setForm] = useState<SavedPrompt>(blank), [dirty, setDirty] = useState(false), [busy, setBusy] = useState(false), [query, setQuery] = useState("");
  const [builderStale, setBuilderStale] = useState(false);
  const [recipeId, setRecipeId] = useState<string | null>(null), [inputs, setInputs] = useState<PromptInputs>({ ...DEFAULT_PROMPT_INPUTS });
  const [error, setError] = useState(""), [notice, setNotice] = useState(""), [comparison, setComparison] = useState<{ doc: CloudDocument | null; library: PromptLibraryData } | null>(null);
  const session = useRef<DocumentSync | null>(null), local = useRef(library), alive = useRef(false), version = useRef(services.getSnapshot().identityVersion), running = useRef(false);
  const org = workspace.org.id, user = workspace.user.id;
  local.current = library;
  const current = () => { const s = services.getSnapshot(); return alive.current && s.status === "signed-in" && s.identity?.userId === user && s.identityVersion === version.current; };
  const pending = dirty || busy || !!session.current?.hasUnsavedWork;
  const locked = busy || !ready;
  function makeSession() {
    const next = new DocumentSync(services, org, "prompts", value => { if (current() && session.current === next) setState(value); });
    return next;
  }
  useEffect(() => {
    let active = true; alive.current = true;
    const next = makeSession(); session.current = next;
    const unsubscribe = services.subscribe(() => {
      if (current()) return;
      session.current?.dispose(); setReady(false); setLibrary(EMPTY_PROMPT_LIBRARY); setForm(blank()); setInputs({ ...DEFAULT_PROMPT_INPUTS }); setDirty(false); setComparison(null); setRecipeId(null); setBuilderStale(false);
      setError("Your account changed. Reopen the prompt library.");
    });
    void next.open().then(doc => {
      if (!active || !current()) return;
      if (doc && (doc.kind !== "prompts" || doc.listing_id !== null)) throw new Error("Saved prompts belong to a different scope.");
      const data = doc ? decodePromptLibrary(doc.payload) : EMPTY_PROMPT_LIBRARY;
      local.current = data; setLibrary(data); setReady(true);
    }).catch(e => { if (active && current()) { setState("offline"); setError(message(e)); } });
    const check = () => { if (document.visibilityState === "visible") void session.current?.checkRemote(); };
    window.addEventListener("focus", check); document.addEventListener("visibilitychange", check);
    return () => { active = false; alive.current = false; next.dispose(); session.current?.dispose(); session.current = null; unsubscribe(); window.removeEventListener("focus", check); document.removeEventListener("visibilitychange", check); };
    // A workspace/identity remount owns one document writer.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [services, org, user]);
  useEffect(() => { onPendingChange?.(pending, busy || state === "saving"); }, [onPendingChange, pending, busy, state]);
  useEffect(() => () => onPendingChange?.(false, false), [onPendingChange]);
  useEffect(() => { if (!pending) return; const warn = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ""; }; window.addEventListener("beforeunload", warn); return () => window.removeEventListener("beforeunload", warn); }, [pending]);
  const recipe = PROMPT_RECIPES.find(r => r.id === recipeId);
  const photoRecipe = !!recipe && PHOTO_RECIPES.has(recipe.id);
  const compiled = useMemo(() => { if (!recipeId) return null; try { return compilePrompt(recipeId, inputs); } catch { return null; } }, [recipeId, inputs]);
  const sourceLink = useMemo(() => { try { const u = new URL(form.sourceUrl); return u.protocol === "https:" && !u.username && !u.password ? u.href : ""; } catch { return ""; } }, [form.sourceUrl]);
  const search = query.toLocaleLowerCase().trim();
  const recipes = PROMPT_RECIPES.filter(r => `${r.title} ${r.category} ${r.summary} ${TARGET_LABELS[r.target]}`.toLocaleLowerCase().includes(search));
  const entries = library.entries.filter(e => `${e.title} ${e.prompt} ${e.notes} ${e.verdict}`.toLocaleLowerCase().includes(search));
  function update(patch: Partial<SavedPrompt>) { setForm(f => ({ ...f, ...patch })); setDirty(true); setNotice(""); }
  function changeInputs(patch: Partial<PromptInputs>) { setBuilderStale(true); setInputs(i => ({ ...i, ...patch })); setDirty(true); setNotice(""); }
  function canReplace() { return !locked && (!dirty || window.confirm("Discard this unsaved prompt draft? Saved library entries are kept.")); }
  function choose(id: string | null) {
    if (!canReplace()) return;
    const selected = PROMPT_RECIPES.find(r => r.id === id);
    setBuilderStale(!!selected); setRecipeId(selected?.id ?? null); setInputs({ ...DEFAULT_PROMPT_INPUTS, subject: selected?.category === "Agent" || selected?.id === "multicam-performance" ? "the source performer" : "the visible property", sourceSeconds: selected && PHOTO_RECIPES.has(selected.id) ? 5 : 15 }); setForm({ ...blank(), title: selected?.title ?? "", target: selected?.target ?? "editing-brief", recipeId: selected?.id ?? null, recipeVersion: selected?.version ?? null });
    setDirty(false); setNotice(""); setError("");
  }
  function open(entry: SavedPrompt) { if (!canReplace()) return; setForm({ ...entry }); setRecipeId(null); setBuilderStale(false); setDirty(false); setNotice(""); setError(""); }
  function queue(data: PromptLibraryData) {
    const validated = decodePromptLibrary(data);
    local.current = validated; setLibrary(validated); session.current!.queue({ ...validated }); void session.current!.flush();
  }
  function save() {
    if (locked || builderStale || !current()) return;
    try {
      const previous = local.current.entries.find(e => e.id === form.id), saved = { ...form, title: form.title.trim(), prompt: form.prompt.trim(), sourceUrl: form.sourceUrl.trim(), revision: previous ? previous.revision + 1 : 1, createdAt: previous?.createdAt ?? form.createdAt, updatedAt: new Date().toISOString() };
      queue({ schema: 1, entries: previous ? local.current.entries.map(e => e.id === saved.id ? saved : e) : [saved, ...local.current.entries] });
      setForm(saved); setDirty(false); setError(""); setNotice("Prompt added to your library. Check sync status for account confirmation.");
    } catch (e) { setError(message(e)); }
  }
  function remove(entry: SavedPrompt) {
    if (locked || !current() || !window.confirm(`Delete “${entry.title}” from your saved prompt library?${form.id === entry.id && dirty ? " This also discards its open unsaved edits." : ""}`)) return;
    try {
      queue({ schema: 1, entries: local.current.entries.filter(e => e.id !== entry.id) });
      if (form.id === entry.id) { setForm(blank()); setDirty(false); setRecipeId(null); setBuilderStale(false); }
    } catch (e) { setError(message(e)); }
  }
  async function cloud(mode: "compare" | "load" | "replace" | "retry") {
    if (running.current || state === "saving" || !current()) return;
    if (mode === "load" && (dirty || session.current?.hasUnsavedWork) && !window.confirm("Use the saved account library and discard your open local changes? Download a local copy first if needed.")) return;
    running.current = true; setBusy(true); setError("");
    let next: DocumentSync | undefined;
    try {
      if (mode === "retry" && ready) { await session.current!.retry(); return; }
      next = makeSession(); const doc = await next.open();
      if (!current()) return;
      if (doc && (doc.kind !== "prompts" || doc.listing_id !== null)) throw new Error("Saved prompts belong to a different scope.");
      const data = doc ? decodePromptLibrary(doc.payload) : EMPTY_PROMPT_LIBRARY;
      if (mode === "compare") { setComparison({ doc, library: data }); return; }
      if (mode === "replace" && (!comparison || (comparison.doc?.revision ?? 0) !== (doc?.revision ?? 0) || canonicalDocument(comparison.library) !== canonicalDocument(data))) { setComparison({ doc, library: data }); setError("The account library changed again. Compare this newer version before replacing it."); return; }
      const prior = session.current; session.current = next; next = undefined; prior?.dispose(); setState(session.current.state); setReady(true); setComparison(null);
      if (mode === "replace") { session.current.queue({ ...local.current }); void session.current.flush(); setNotice("Your reviewed library copy is queued to the account."); }
      else { local.current = data; setLibrary(data); setForm(blank()); setDirty(false); setRecipeId(null); setBuilderStale(false); setNotice("Saved account library loaded."); }
    } catch (e) { if (current()) setError(message(e)); }
    finally { next?.dispose(); running.current = false; if (current()) setBusy(false); }
  }
  function build() { try { const value = compilePrompt(recipeId!, inputs); update({ prompt: value.prompt, recipeId: value.recipeId, recipeVersion: value.recipeVersion }); setBuilderStale(false); setError(""); } catch (e) { setError(message(e)); } }
  async function copy() { try { await navigator.clipboard.writeText(form.prompt); if (current()) setNotice("Prompt copied. Settings and review notes stay outside the prompt."); } catch { if (current()) setError("Copy is unavailable here. Download the prompt instead."); } }
  function exportPrompt() { downloadText("rendprop-prompt.txt", compiled ? promptExport({ ...compiled, prompt: form.prompt }) : `${form.prompt}\n\nNOTES — OUTSIDE THE PROMPT\n${TARGET_LABELS[form.target]}\nSource: ${form.sourceUrl || "Your own prompt"}\nYour test verdict: ${form.verdict}\n${form.notes}\n`); }
  function backup() { downloadText("rendprop-prompt-library-local.json", JSON.stringify({ library: local.current, openDraft: form, recipeId, inputs, builderStale }, null, 2), "application/json"); }
  return <section className="prompt-library" aria-label="Prompt library">
    <div className="creative-card"><span className="creative-eyebrow">PROMPT LIBRARY</span><h2>Build a clear brief. Keep what you learn.</h2><p>Prepare prompts and original-footage editing briefs. This tool does not call AI providers or start generation.</p>
      <p role="status">{state === "loading" ? "Opening your saved prompts…" : state === "saving" ? "Saving your library to the account…" : state === "saved" ? "Library synced to your account" : state === "conflict" ? "Another device saved a newer library. Your local copy is still open." : "Sync paused. Your local copy is still open."}{dirty && " Your open prompt has unsaved edits."}</p>
      <div className="creative-actions"><button disabled={busy || state === "saving"} onClick={() => void cloud(state === "offline" || !ready ? "retry" : "compare")}>{state === "offline" || !ready ? "Retry library sync" : "Compare saved library"}</button><button onClick={backup} disabled={!ready}>Download local copy</button></div>
      {error && <p className="creative-alert" role="alert">{error}</p>}{notice && <p className="creative-notice" role="status">{notice}</p>}
    </div>
    {comparison && <div className="creative-card" role="region" aria-label="Prompt library version review"><h3>Compare account revision {comparison.doc?.revision ?? 0}</h3><p>This browser: {library.entries.length} prompts. Saved account: {comparison.library.entries.length} prompts.</p><ul>{comparison.library.entries.map(e => <li key={e.id}><strong>{e.title}</strong><details><summary>Read saved prompt</summary><pre>{e.prompt}</pre></details></li>)}</ul><div className="creative-actions"><button disabled={busy || state === "saving"} onClick={() => void cloud("load")}>Use saved account library</button><button disabled={busy || state === "saving"} onClick={() => void cloud("replace")}>Replace with my reviewed library</button><button disabled={busy} onClick={() => setComparison(null)}>Close comparison</button></div></div>}
    <label>Search recipes and saved prompts<input type="search" value={query} onChange={e => setQuery(e.target.value)} placeholder="Room reveal, agent, camera angles…" /></label>
    <div className="prompt-layout"><aside className="creative-card"><h3>Start with a recipe</h3><p>Original Rendprop recipes. Output quality has not been validated.</p><div className="prompt-recipes">{recipes.map(r => <button key={r.id} disabled={locked} aria-pressed={recipeId === r.id} onClick={() => choose(r.id)}><strong>{r.title}</strong><small>{r.category} · {TARGET_LABELS[r.target]}{r.experimental ? " · Experimental" : ""}</small><span>{r.summary}</span></button>)}</div>{!recipes.length && <p>No matching recipes.</p>}<button disabled={locked} onClick={() => choose(null)}>Write or paste my own prompt</button>
      <details><summary>Recipe research sources</summary><p>Research references; these Rendprop recipes are original and unvalidated.</p><ul>{["Square-Zero-Labs/video-prompting-skill", "YouMind-OpenLab/awesome-seedance-2-prompts", "cliprise/awesome-ai-real-estate-video-prompts", "dexhunter/seedance2-skill", "geekjourneyx/awesome-ai-video-prompts"].map(repo => <li key={repo}><a href={`https://github.com/${repo}`} target="_blank" rel="noopener noreferrer">{repo}</a></li>)}</ul></details>
      <h3>My saved prompts · {library.entries.length}/{MAX_SAVED_PROMPTS}</h3>{entries.map(entry => <div className="prompt-saved" key={entry.id}><button disabled={locked} onClick={() => open(entry)}>{entry.title}<small>My verdict: {entry.verdict} · revision {entry.revision}</small></button><button disabled={locked} aria-label={`Delete ${entry.title}`} onClick={() => remove(entry)}>Delete</button></div>)}{!entries.length && <p>No saved prompts match yet.</p>}
    </aside><div className="creative-card"><h3>{form.recipeId ? "Adapt the brief" : "Your prompt"}</h3><fieldset disabled={locked}>
      <label>Prompt title<input maxLength={120} value={form.title} onChange={e => update({ title: e.target.value })} /></label>
      <label>Prepared for<select aria-label="Prompt target" disabled={!!recipe} value={form.target} onChange={e => update({ target: e.target.value as SavedPrompt["target"] })}>{Object.entries(TARGET_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
      {recipe && <div className="prompt-builder"><p>{recipe.referenceNeed}</p><label>Visible scene details<textarea aria-label="Visible scene details" rows={3} maxLength={600} value={inputs.scene} onChange={e => changeInputs({ scene: e.target.value })} placeholder="Describe only what is visible in your source media." /></label><label>Subject<input maxLength={120} value={inputs.subject} onChange={e => changeInputs({ subject: e.target.value })} /></label><div className="prompt-row"><label>{photoRecipe ? "Clip duration in seconds" : "Source duration in seconds"}<input type="number" min={4} max={30} step={photoRecipe ? 1 : 0.01} value={Number.isFinite(inputs.sourceSeconds) ? inputs.sourceSeconds : ""} onChange={e => changeInputs({ sourceSeconds: e.target.valueAsNumber })} /></label>{!photoRecipe && <label>Video reference label<input maxLength={33} value={inputs.videoReference} onChange={e => changeInputs({ videoReference: e.target.value })} /></label>}<label>Image reference label<input maxLength={33} value={inputs.imageReference} onChange={e => changeInputs({ imageReference: e.target.value })} /></label></div><small>Build the prompt again after changing scene settings. Reference labels must match uploads in your chosen tool; this library does not upload files.</small><button onClick={build}>Build prompt from this recipe</button>{builderStale && <p role="status">Build the prompt to apply your scene changes before saving, copying or downloading it.</p>}</div>}
      <label>Prompt text<textarea aria-label="Prompt text" rows={14} maxLength={16000} value={form.prompt} onChange={e => update({ prompt: e.target.value })} placeholder="Build a recipe above, or paste and edit your own prompt." /></label>
      <label>Source link (optional)<input type="url" maxLength={2000} value={form.sourceUrl} onChange={e => update({ sourceUrl: e.target.value })} placeholder="https://…" /></label>
      {sourceLink && <a href={sourceLink} target="_blank" rel="noopener noreferrer">Open source reference</a>}
      <label>My test verdict<select aria-label="My test verdict" value={form.verdict} onChange={e => update({ verdict: e.target.value as SavedPrompt["verdict"] })}><option value="untested">Untested</option><option value="needs-work">Needs work</option><option value="usable">Usable in my test</option></select></label><label>My test notes<textarea aria-label="My test notes" maxLength={2000} rows={3} value={form.notes} onChange={e => update({ notes: e.target.value })} placeholder="What worked, what failed, and which variable changed." /></label>
    </fieldset><div className="creative-actions"><button className="creative-primary" disabled={locked || !form.title.trim() || !form.prompt.trim() || builderStale || (!dirty && library.entries.some(e => e.id === form.id))} onClick={save}>Save to my prompt library</button><button disabled={!form.prompt.trim() || builderStale} onClick={() => void copy()}>Copy prompt</button><button disabled={!form.prompt.trim() || builderStale} onClick={exportPrompt}>Download prompt</button></div>
      {compiled && <details className="prompt-guidance" open><summary>Settings and review checklist</summary><h4>Outside the prompt</h4><ul>{compiled.settings.map(s => <li key={s}>{s}</li>)}</ul><h4>Review before publishing</h4><ul>{[...compiled.warnings, ...compiled.checklist].map(s => <li key={s}>{s}</li>)}</ul><p>Recipe {compiled.recipeId} · version {compiled.recipeVersion}</p></details>}
    </div></div>
  </section>;
}
