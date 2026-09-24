import { useEffect, useMemo, useRef, useState } from "react";
import { EDIT_LIMITS, formatTime, timelineDuration, type EditDraft } from "./model";
import { RECIPE_CATALOG, buildRecipeDraft, type RecipeId, type RecipeOptions, type RecipeResult } from "./recipes";

export type RecipeRequest = { id: string; recipe: RecipeId; options?: RecipeOptions };
export function RecipePanel({ draft, busy, request, onApply }: {
  draft: EditDraft; busy: boolean; request?: RecipeRequest; onApply: (result: RecipeResult) => void;
}) {
  const [open, setOpen] = useState(false);
  const [recipe, setRecipe] = useState<RecipeId>("listing-highlight");
  const [options, setOptions] = useState<RecipeOptions>({});
  const consumed = useRef(new Set<string>());
  useEffect(() => {
    if (!request || busy || consumed.current.has(request.id)) return;
    consumed.current.add(request.id);
    setRecipe(request.recipe); setOptions(request.options ?? {}); setOpen(true);
  }, [request, busy]);
  const selectedRecipe = RECIPE_CATALOG.find(item => item.id === recipe)!;
  const recordings = draft.clips.filter(clip => clip.source.kind === "video");
  const primary = recordings.find(clip => clip.id === options.primaryClipId);
  const preview = useMemo(() => {
    try { return { result: buildRecipeDraft(draft, recipe, options), error: "" }; }
    catch (error) { return { result: null, error: error instanceof Error ? error.message : "Review your selected footage." }; }
  }, [draft, recipe, options]);
  const range = options.primaryRange ?? (primary ? { start: primary.start, end: primary.end } : undefined);
  return <section className="rp-editor-recipes" aria-label="Guided draft recipes">
    <div className="rp-editor-recipe-heading">
      <div><h3>Start with a guided draft</h3><p>Use your actual media, then adjust every cut and caption.</p></div>
      <button type="button" aria-expanded={open} onClick={() => setOpen(value => !value)}>{open ? "Close guided drafts" : "Choose a guided draft"}</button>
    </div>
    {open && <fieldset disabled={busy}>
      <legend className="rp-editor-sr-only">Guided draft settings</legend>
      <div className="rp-editor-recipe-fields">
        <label>Draft recipe<select aria-label="Draft recipe" value={recipe} onChange={event => { setRecipe(event.target.value as RecipeId); setOptions(current => ({targetSeconds: current.targetSeconds})); }}>
          {RECIPE_CATALOG.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}
        </select></label>
        <label>Target duration<select aria-label="Target duration" value={options.targetSeconds ?? ""} onChange={event => setOptions(current => ({ ...current, targetSeconds: event.target.value ? Number(event.target.value) as 30 | 45 | 60 : undefined }))}>
          <option value="">No target</option>{[30,45,60].map(seconds => <option key={seconds} value={seconds}>{seconds} seconds</option>)}
        </select></label>
        <label>Photo / highlight length<select aria-label="Photo / highlight length" value={options.shotSeconds ?? ""} onChange={event => setOptions(current => ({ ...current, shotSeconds: event.target.value ? Number(event.target.value) : undefined }))}>
          <option value="">Recipe pacing</option>
          {[2, 3, 4, 5, 6, 8].map(seconds => <option key={seconds} value={seconds}>{seconds} seconds</option>)}
        </select></label>
      </div>
      <p>{selectedRecipe.description}</p>
      {selectedRecipe.needsRecording && <>
        <label>Presentation recording<select aria-label="Presentation recording" value={primary?.id ?? ""} onChange={event => setOptions(current => ({ ...current, primaryClipId: event.target.value, primaryRange: undefined }))}>
          <option value="">Choose your recording</option>
          {recordings.map(clip => <option key={clip.id} value={clip.id}>{clip.source.name} · selected {formatTime(clip.end - clip.start)}</option>)}
        </select></label>
        {primary && range && <div className="rp-editor-recipe-fields">
          <label>Recording starts (source seconds)<input type="number" min={0} max={primary.source.duration} step={.1} value={range.start} onChange={event => { if (event.target.value !== "") setOptions(current => ({ ...current, primaryRange: { ...range, start: Number(event.target.value) } })); }} /></label>
          <label>Recording ends (source seconds)<input type="number" min={.5} max={primary.source.duration} step={.1} value={range.end} onChange={event => { if (event.target.value !== "") setOptions(current => ({ ...current, primaryRange: { ...range, end: Number(event.target.value) } })); }} /></label>
          <button type="button" onClick={() => setOptions(current => ({ ...current, primaryRange: { start: 0, end: Math.min(primary.source.duration, EDIT_LIMITS.timelineSeconds) } }))}>{primary.source.duration > EDIT_LIMITS.timelineSeconds ? "Use first 3 minutes" : "Use full recording"}</button>
          <p>Source {formatTime(primary.source.duration)}. Review the exact speech range before applying.</p>
        </div>}
      </>}
      {preview.error && <p className="rp-editor-recipe-review" role="status">{preview.error}</p>}
      {preview.result && <div className="rp-editor-recipe-review" aria-live="polite">
        <strong>{formatTime(timelineDuration(preview.result.draft.clips))} · {preview.result.draft.clips.length} sequence item{preview.result.draft.clips.length === 1 ? "" : "s"} · {preview.result.draft.overlays?.length ?? 0} photo cutaways</strong>
        <ul>{preview.result.reviewNotes.map(note => <li key={note}>{note}</li>)}</ul>
        {!!preview.result.omittedSourceIds.length && <p>Not used: {[...draft.clips, ...(draft.overlays ?? [])].filter(item => preview.result!.omittedSourceIds.includes(item.id)).map(item => item.source.name).join(", ")}</p>}
      </div>}
      <button className="rp-editor-primary" type="button" disabled={!preview.result || busy} onClick={() => { if (preview.result) onApply(preview.result); }}>Apply guided draft</button>
      <small>This replaces the current sequence as one undoable edit. It does not generate media, transcribe speech or verify property facts.</small>
    </fieldset>}
  </section>;
}
