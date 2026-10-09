import { useState } from "react";
import { analyzeCustomPhotoPrompt, CUSTOM_PHOTO_CHOICES } from "../../../../../services/supabase/functions/_shared/custom-photo-prompt.ts";

export { analyzeCustomPhotoPrompt };

/** Preparation is free. Generation stays behind the existing consent, budget
 * and provider gates; the server independently prepares the same request. */
export default function CustomPhotoPromptHelp({ prompt, onPrompt, space, disabled }: {
  prompt: string; onPrompt: (value: string) => void; space: string; disabled?: boolean;
}) {
  const decision = analyzeCustomPhotoPrompt(prompt, space);
  const [clarification, setClarification] = useState<{ original: string; instruction: string } | null>(null);
  const original = clarification?.instruction === prompt ? clarification.original : null;
  return <div className="creative-notice" aria-label="Prepare your photo edit">
    <p>We automatically prepare your request to keep existing paint, garage and trim finishes, materials and layout. Compare the result with the original before using it.</p>
    {prompt.trim() && <>
      <p role={decision.status === "blocked" ? "alert" : "status"}>{decision.status === "ready"
        ? "Your request is ready for a preview. Only the changes you described will be requested."
        : decision.status === "blocked"
        ? "Listing photos need to show the real finishes and condition. Repainting, remodeling and hiding damage aren't available here. Choose a photo edit below instead."
        : "What would you like to change? Choose one below, or describe a specific edit. Clarifying your request doesn't use photo edits."}</p>
      {decision.status !== "ready" && <div className="creative-actions" aria-label="Clarify the photo edit">
        {CUSTOM_PHOTO_CHOICES.map(choice => <button type="button" key={choice.id} disabled={disabled}
          onClick={() => { setClarification({ original: original ?? prompt, instruction: choice.prompt }); onPrompt(choice.prompt); }}>{choice.label}</button>)}
      </div>}
    </>}
    {original !== null && <details><summary>Your original request</summary><p>{original}</p></details>}
  </div>;
}
