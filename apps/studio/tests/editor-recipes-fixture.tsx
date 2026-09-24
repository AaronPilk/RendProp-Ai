import { createRoot } from "react-dom/client";
import { useRef, useState } from "react";
import VideoEditor from "../src/editor/VideoEditor";
import type { EditDraft } from "../src/editor/model";
import type { RecipeRequest } from "../src/editor/RecipePanel";
import "../src/styles.css";
let current: EditDraft | undefined, changes = 0, playhead = 0, sourceChanges = 0;
function Fixture() {
  const [review, setReview] = useState(false), [seek, setSeek] = useState<{id: string; time: number}>();
  const [recipe, setRecipe] = useState<RecipeRequest>();
  const files = useRef<File[]>([]), saved = useRef<EditDraft | undefined>(undefined);
  const [relink, setRelink] = useState<{id: string; files: File[]}>();
  Object.assign(window, { recipeFixture: {
    snapshot: () => ({ draft: structuredClone(current), changes, playhead, sourceChanges }),
    seek: (time: number) => setSeek({id:crypto.randomUUID(),time}),
    request: (value: RecipeRequest) => setRecipe(value),
    review: () => { saved.current = structuredClone(current); setReview(true); setRelink({id:crypto.randomUUID(),files:files.current}); },
  } });
  return <main style={{padding:20,maxWidth:1350,margin:"auto"}}><VideoEditor key={String(review)} initialMode="simple" readOnly={review} initialDraft={review ? saved.current : undefined}
    recipeRequest={recipe} seekRequest={seek} relinkRequest={relink ? {...relink} : undefined}
    onDraftChange={draft => { current = structuredClone(draft); changes++; }}
    onSourcesChange={sources => { files.current = sources.map(source => source.file); sourceChanges++; }}
    onPlayheadChange={time => { playhead = time; }} /></main>;
}
createRoot(document.getElementById("root")!).render(<Fixture />);
