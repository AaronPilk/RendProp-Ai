import { useState } from "react";
import { analyzeCustomPhotoPrompt, CUSTOM_PHOTO_CHOICES } from "../../../../../services/supabase/functions/_shared/custom-photo-prompt.ts";

export { analyzeCustomPhotoPrompt };

/** Preparation is free and never refuses a request for its wording (owner
 * decision, 12 Nov 2026). A request that mentions repainting, remodelling or
 * hiding damage still runs; the note says that part stays as photographed.
 * The starting choices are offered only while the box is empty. */
export default function CustomPhotoPromptHelp({ prompt, onPrompt, space, disabled }: {
  prompt: string; onPrompt: (value: string) => void; space: string; disabled?: boolean;
}) {
  const decision = analyzeCustomPhotoPrompt(prompt, space);
  const [clarification, setClarification] = useState<{ original: string; instruction: string } | null>(null);
  const original = clarification?.instruction === prompt ? clarification.original : null;
  return <div className="creative-notice" aria-label="Prepare your photo edit">
    <p>Describe the change in your own words. The rest of the photo stays as it is. Compare the result with the original before using it.</p>
    {prompt.trim() && <p role="status">{decision.message}</p>}
    {decision.status !== "ready" && <div className="creative-actions" aria-label="Start from a common photo edit">
      {CUSTOM_PHOTO_CHOICES.map(choice => <button type="button" key={choice.id} disabled={disabled}
        onClick={() => { setClarification({ original: original ?? prompt, instruction: choice.prompt }); onPrompt(choice.prompt); }}>{choice.label}</button>)}
    </div>}
    {original !== null && original.trim() && <details><summary>Your original request</summary><p>{original}</p></details>}
  </div>;
}
