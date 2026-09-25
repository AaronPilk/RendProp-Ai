import {useEffect, useRef, useState} from "react";
import type {EditClip, EditDraft} from "./model";
import {formatTime} from "./model";
import {analyzeMusic, type LocalMusic} from "./music";
import {decodeSpeechPassages, parseSubtitleFile, proposeBeatCuts, useSpeechPassage, validateSpeechWords, type BeatProposal, type SpeechWord, type SpeechPassage} from "./finishing";

type Props = {
  draft: EditDraft;
  selected?: EditClip;
  music: LocalMusic | null;
  musicIssue: string;
  busy: boolean;
  active: boolean;
  onChange: (patch: Partial<Pick<EditDraft, "music" | "speech" | "clips">>, label: string) => boolean;
  onImportMusic: (file: File) => Promise<void>;
  requestMediaAnalysis?: (clip: EditClip, signal: AbortSignal) => Promise<unknown>;
  onBusyChange: (busy: boolean) => void;
};
type TranscriptReview = {draftId: string; revision: number; sourceSha256: string; sourceDuration: number; words: SpeechWord[]; clipId: string; passages: SpeechPassage[]};
const errorText = (error: unknown) => error instanceof Error ? error.message : "This sound task could not finish.";
export default function SoundPanel({draft, selected, music, musicIssue, busy, active, onChange, onImportMusic, requestMediaAnalysis, onBusyChange}: Props) {
  const [licensed, setLicensed] = useState(false), [issue, setIssue] = useState(""), [working, setWorking] = useState(false);
  const [bpm, setBpm] = useState(120), [firstBeat, setFirstBeat] = useState(0), [beats, setBeats] = useState<BeatProposal | null>(null);
  const [review, setReview] = useState<TranscriptReview | null>(null), [checked, setChecked] = useState(false);
  const abort = useRef<AbortController | null>(null), current = useRef(draft); current.current = draft;
  const stopWork = () => {abort.current?.abort(); abort.current = null; setWorking(false);};
  useEffect(() => {setBeats(null); setReview(null); setChecked(false); stopWork();}, [draft.id, draft.revision]);
  useEffect(() => {setReview(null); setChecked(false); stopWork();}, [selected?.id]);
  useEffect(() => {if (!active) stopWork(); return () => abort.current?.abort();}, [active]);
  useEffect(() => {onBusyChange(working); return () => onBusyChange(false);}, [working, onBusyChange]);
  const isCurrent = (snapshot: EditDraft, signal?: AbortSignal) => !signal?.aborted && current.current.id === snapshot.id && current.current.revision === snapshot.revision;
  async function analyze() {
    if (!music || working || busy) return;
    const snapshot = draft, controller = new AbortController(); abort.current = controller; setWorking(true); setIssue("");
    try {
      const result = await analyzeMusic(music.file, controller.signal);
      if (!isCurrent(snapshot, controller.signal)) return;
      const period = 60 / result.bpm;
      const phase = (snapshot.music?.offset ?? 0) + ((result.firstBeat - (snapshot.music?.start ?? 0)) % period + period) % period;
      setBpm(result.bpm); setFirstBeat(phase);
      setIssue(`Estimated ${result.bpm} BPM. Listen and adjust the first beat, then review the cuts. Beat detection can be wrong.`);
    } catch (error) {if (isCurrent(snapshot, controller.signal)) setIssue(errorText(error));}
    finally {if (abort.current === controller) {abort.current = null; setWorking(false);}}
  }
  async function transcribe() {
    if (!selected || selected.source.kind !== "video" || !requestMediaAnalysis || working || busy) return;
    const snapshot = draft, clip = selected, controller = new AbortController(); abort.current = controller; setWorking(true); setIssue("");
    try {
      const raw = await requestMediaAnalysis(clip, controller.signal);
      if (!isCurrent(snapshot, controller.signal)) return;
      if (!raw || typeof raw !== "object") throw new Error("Speech analysis returned an invalid response.");
      const row = raw as Record<string, unknown>;
      if (row.sourceFingerprint !== clip.source.sha256 || typeof row.duration !== "number" || Math.abs(row.duration - clip.source.duration) > .15) throw new Error("The transcript does not match this original clip.");
      const words = validateSpeechWords(row.words, clip.source.duration);
      if (!words.length) throw new Error("No spoken words were found in this clip.");
      setReview({draftId: snapshot.id, revision: snapshot.revision, sourceSha256: clip.source.sha256, sourceDuration: clip.source.duration, words, clipId: clip.id, passages: decodeSpeechPassages(row, words, clip.source.duration)}); setChecked(false);
    } catch (error) {if (isCurrent(snapshot, controller.signal)) setIssue(errorText(error));}
    finally {if (abort.current === controller) {abort.current = null; setWorking(false);}}
  }
  async function importSubtitles(file: File) {
    if (!selected || selected.source.kind !== "video") return;
    const snapshot = draft, clip = selected;
    try {
      if (file.size > 128 * 1024) throw new Error("Subtitle files must be under 128 KiB.");
      const words = parseSubtitleFile(await file.text(), clip.source.duration);
      if (!isCurrent(snapshot)) return;
      setReview({draftId: snapshot.id, revision: snapshot.revision, sourceSha256: clip.source.sha256, sourceDuration: clip.source.duration, words, clipId: clip.id, passages: []}); setChecked(false); setIssue("");
    } catch (error) {if (isCurrent(snapshot)) setIssue(errorText(error));}
  }
  function applySpeech(passage?: SpeechPassage) {
    if (!review || !checked || review.draftId !== draft.id || review.revision !== draft.revision) return;
    const speech = [...(draft.speech ?? []).filter(track => track.sourceSha256 !== review.sourceSha256), {sourceSha256: review.sourceSha256, sourceDuration: review.sourceDuration, reviewed: true as const, words: review.words}];
    let clips: EditClip[] | undefined;
    if (passage) {try {clips = useSpeechPassage(draft, review.clipId, passage);} catch (error) {setIssue(errorText(error)); return;}}
    if (onChange({speech, ...(clips ? {clips} : {})}, passage ? "reviewed speaking passage" : "reviewed speech captions")) {setReview(null); setChecked(false); setIssue("Captions applied. They follow the original speech through trimming and reordering.");}
  }
  const locked = busy || working || !active;
  return <details className="rp-editor-sound" open={undefined}>
    <summary>Sound & captions</summary>
    <fieldset disabled={locked}>
      <legend>Background music</legend>
      <p>Add your own licensed track. Your original footage stays intact.</p>
      <label><input type="checkbox" checked={licensed} onChange={event => setLicensed(event.target.checked)} />I have permission to use this music</label>
      <label>{draft.music ? "Replace or restore music" : "Add music"}<input aria-label="Add licensed music" type="file" accept="audio/mpeg,audio/mp4,audio/wav,audio/x-wav,audio/ogg,audio/webm,.mp3,.m4a,.wav,.ogg" disabled={!licensed || locked} onChange={event => {const file = event.target.files?.[0]; event.target.value = ""; if (file) void onImportMusic(file);}} /></label>
      {draft.music && <>
        <p>{draft.music.source.name}{music ? " · Ready" : " · Original file needed"}</p>
        <label>Music volume<input aria-label="Music volume" type="range" min="0" max="1" step=".05" value={draft.music.volume} onChange={event => onChange({music: {...draft.music!, volume: Number(event.target.value)}}, "music volume")} /></label>
        <label>Lower music under<select aria-label="Music ducking" value={draft.music.ducking} onChange={event => onChange({music: {...draft.music!, ducking: event.target.value as "speech" | "original" | "none"}}, "music mixing")}><option value="original">All original video and narration</option><option value="speech">Reviewed speech and narration</option><option value="none">Keep a steady level</option></select></label>
        <details><summary>Music timing and fades</summary><div className="rp-editor-sound-grid">
          <label>Music starts at<input aria-label="Music starts at" type="number" min="0" max="180" step=".1" value={draft.music.offset} onChange={event => event.target.value !== "" && onChange({music: {...draft.music!, offset: Number(event.target.value)}}, "music timeline start")} /></label>
          <label>Track in point<input aria-label="Music in point" type="number" min="0" max={draft.music.end - .1} step=".1" value={draft.music.start} onChange={event => event.target.value !== "" && onChange({music: {...draft.music!, start: Number(event.target.value)}}, "music trim")} /></label>
          <label>Track out point<input aria-label="Music out point" type="number" min={draft.music.start + .1} max={draft.music.source.duration} step=".1" value={draft.music.end} onChange={event => event.target.value !== "" && onChange({music: {...draft.music!, end: Number(event.target.value)}}, "music trim")} /></label>
          <label>Fade in<input aria-label="Music fade in" type="number" min="0" max={Math.min(10, draft.music.end - draft.music.start)} step=".1" value={draft.music.fadeIn} onChange={event => event.target.value !== "" && onChange({music: {...draft.music!, fadeIn: Number(event.target.value)}}, "music fade in")} /></label>
          <label>Fade out<input aria-label="Music fade out" type="number" min="0" max={Math.min(10, draft.music.end - draft.music.start)} step=".1" value={draft.music.fadeOut} onChange={event => event.target.value !== "" && onChange({music: {...draft.music!, fadeOut: Number(event.target.value)}}, "music fade out")} /></label>
        </div></details>
        <button type="button" onClick={() => onChange({music: undefined}, "remove music")}>Remove music</button>
        <details><summary>Match cuts to the beat</summary>
          <p>Review a tempo grid before applying it. Video ends can be shortened, so check any speech afterward.</p>
          <button type="button" disabled={!music} onClick={() => void analyze()}>Find the beat</button>
          <label>Tempo (BPM)<input aria-label="Tempo (BPM)" type="number" min="40" max="240" step=".1" value={bpm} onChange={event => {setBpm(Number(event.target.value)); setBeats(null);}} /></label>
          <label>First beat in edit (seconds)<input aria-label="First beat in edit (seconds)" type="number" min="0" max="180" step=".01" value={firstBeat} onChange={event => {setFirstBeat(Number(event.target.value)); setBeats(null);}} /></label>
          <button type="button" onClick={() => {try {setBeats(proposeBeatCuts(draft, bpm, firstBeat)); setIssue("");} catch (error) {setIssue(errorText(error));}}}>Review beat cuts</button>
          {beats && <div role="region" aria-label="Beat cut proposal"><ul>{beats.changes.map(change => <li key={change.clipId}>Clip {draft.clips.findIndex(clip => clip.id === change.clipId) + 1}: {formatTime(change.before)} → {formatTime(change.after)}</li>)}</ul><button type="button" onClick={() => {if (beats.draftId === draft.id && beats.revision === draft.revision && onChange({clips: beats.clips}, "beat aligned cuts")) setBeats(null);}}>Apply reviewed beat cuts</button><button type="button" onClick={() => setBeats(null)}>Keep current cuts</button></div>}
        </details>
      </>}
      {musicIssue && <p role="status">{musicIssue}</p>}
    </fieldset>
    <fieldset disabled={locked}>
      <legend>Speech captions</legend>
      {selected?.source.kind === "video" ? <>
        <p>Selected clip: {selected.source.name}. Review the original speech before applying captions.</p>
        {requestMediaAnalysis && <button type="button" onClick={() => void transcribe()}>Transcribe selected clip</button>}
        <label>Import timed subtitles<input aria-label="Import timed subtitles" type="file" accept=".srt,.vtt,text/vtt" onChange={event => {const file = event.target.files?.[0]; event.target.value = ""; if (file) void importSubtitles(file);}} /></label>
        {draft.speech?.some(track => track.sourceSha256 === selected.source.sha256) && <button type="button" onClick={() => onChange({speech: draft.speech!.filter(track => track.sourceSha256 !== selected.source.sha256)}, "remove speech captions")}>Remove this clip’s speech captions</button>}
      </> : <p>Select a video clip to add timed speech captions.</p>}
      {review && <div role="region" aria-label="Review speech captions"><p>Listen to the original clip. Correct any names, addresses or words below. Times are measured in the original file.</p><div className="rp-editor-transcript">{review.words.map((word, index) => <label key={index}>{formatTime(word.start)}–{formatTime(word.end)}<input aria-label={`Transcript text ${index + 1}`} maxLength={80} value={word.text} onChange={event => {const text = event.target.value; setReview({...review, words: review.words.map((item, i) => i === index ? {...item, text} : item)}); setChecked(false);}} /></label>)}</div><label><input type="checkbox" checked={checked} onChange={event => setChecked(event.target.checked)} />I checked these words and timings against the original clip</label><button type="button" disabled={!checked} onClick={() => applySpeech()}>Apply reviewed captions</button>{review.passages.length > 0 && <div aria-label="Suggested speaking passages"><p>These suggestions use the spoken words; review picture quality yourself. Choosing one replaces this clip’s selected trim and adds its reviewed captions.</p>{review.passages.map((passage, index) => <div key={index}><p>{formatTime(passage.start)}–{formatTime(passage.end)} · “{passage.text}”</p><button type="button" disabled={!checked} onClick={() => applySpeech(passage)}>Use speaking passage {index + 1}</button></div>)}</div>}<button type="button" onClick={() => {setReview(null); setChecked(false);}}>Discard transcript</button></div>}
    </fieldset>
    {working && <p role="status">Preparing sound… <button type="button" onClick={() => {stopWork(); setIssue("Sound task canceled. Your edit is unchanged.");}}>Cancel sound task</button></p>}
    {issue && <p role="status">{issue}</p>}
  </details>;
}
