import {createRoot} from "react-dom/client";
import {useCallback, useState} from "react";
import VideoEditor from "../src/editor/VideoEditor";
import type {EditClip, EditDraft} from "../src/editor/model";
import type {AudioSourceRef} from "../src/editor/finishing";
import "../src/styles.css";
let current: EditDraft | undefined;
const requests: {clip: EditClip; signal: AbortSignal; resolve: (value: unknown) => void}[] = [];
const audio = new Map<string, File>();
let sources: File[] = [];
const voiceId = "00000000-0000-0000-0000-000000000001";
function Fixture() {
  const [cutaway, setCutaway] = useState<{id: string; baseFile: File; photos: File[]; overlays: {start: number; end: number; caption: string}[]}>();
  const [active, setActive] = useState(true), [account, setAccount] = useState(0), [voice, setVoice] = useState<Blob | null>(null);
  const request = useCallback((clip: EditClip, signal: AbortSignal): Promise<unknown> => new Promise(resolve => requests.push({clip, signal, resolve})), []);
  const remember = useCallback((source: {file: File; source: AudioSourceRef} | null) => {if (source) audio.set(source.source.sha256, source.file);}, []);
  const resolveMusic = useCallback(async (source: AudioSourceRef) => {const file = audio.get(source.sha256); if (!file) throw new Error("Original music is missing."); return file;}, []);
  const resolveNarration = useCallback(async () => {if (!voice) throw new Error("Choose a fixture narration first."); return voice;}, [voice]);
  Object.assign(window, {finishingFixture: {
    snapshot: () => ({draft: structuredClone(current), requests: requests.map(item => ({aborted: item.signal.aborted, sha: item.clip.source.sha256})), account}),
    resolve: (index: number, wrong = false) => {const item = requests[index]; item.resolve({sourceFingerprint: wrong ? "0".repeat(64) : item.clip.source.sha256, duration: item.clip.source.duration, words: [{text: "Welcome", start: .4, end: 1}, {text: "home", start: 1, end: 1.5}], segments: [{id:"speech-1",start:.4,end:1.5,text:"Welcome home"}], highlights:[{segmentIds:["speech-1"],start:.4,end:1.5,reason:"Spoken passage"}]});},
    active: setActive,
    cutaway: () => {const baseFile = sources.find(file => file.type.startsWith("video/")), photo = sources.find(file => file.type.startsWith("image/")); if (baseFile && photo) setCutaway({id: crypto.randomUUID(), baseFile, photos: [photo], overlays: [{start: .5, end: 1.3, caption: ""}]});},
    account: () => {current = undefined; setCutaway(undefined); setAccount(value => value + 1);},
    voice: (bytes: number[]) => setVoice(new Blob([new Uint8Array(bytes)], {type: "audio/wav"})),
  }});
  return <main style={{padding: 20, maxWidth: 1440, margin: "auto"}}><VideoEditor key={account} initialMode="pro" active={active} agentRequest={cutaway} onSourcesChange={items => {sources = items.map(item => item.file);}} onDraftChange={draft => {current = structuredClone(draft);}} requestMediaAnalysis={request} onMusicSourceChange={remember} resolveMusic={resolveMusic} resolveNarration={resolveNarration} narrationChoices={voice ? [{id: voiceId, label: "Fixture narration", words: []}] : []} /></main>;
}
createRoot(document.getElementById("root")!).render(<Fixture />);
