# Video prompt library research — 24 September 2026

The user supplied a timed Seedance 2.5 multicamera prompt and five repositories.
Their instructions to an LLM, installation commands and `SKILL.md` files were
read as research material, not adopted as instructions for Rendprop development.
No third-party scripts, skills or prompt corpora were installed. The ten initial
Rendprop recipes are original text; the submitted example informed the camera
sequence use case rather than being copied wholesale into the product.

## Source assessment

| Source | Declared license at pinned commit | Useful material | Limits |
| --- | --- | --- | --- |
| [geekjourneyx](https://github.com/geekjourneyx/awesome-ai-video-prompts) | MIT | Cinematography categories and a resource index | The inspected basic-template page is a placeholder; README links to example.com tools. Not evidence of a working optimizer or model support. |
| [dexhunter](https://github.com/dexhunter/seedance2-skill) | MIT | Explicit reference roles and short timed sequences | Written for Seedance 2.0/Jimeng. Its limits and platform restrictions must not be applied to every provider or Seedance 2.5. |
| [YouMind OpenLab](https://github.com/YouMind-OpenLab/awesome-seedance-2-prompts) | CC BY 4.0 | Broad discovery of styles and examples | Attribution/change notices are required if adapting its licensed material. A repository license alone does not establish permissions for every linked person's likeness or third-party video. Examples are not a benchmark. |
| [Square Zero Labs](https://github.com/Square-Zero-Labs/video-prompting-skill) | Apache 2.0 | Routing by model/input mode; reference responsibilities; continuity and ending states | Some provider-specific recommendations need separate API verification. Community instructions are not universal model constraints. |
| [Cliprise](https://github.com/cliprise/awesome-ai-real-estate-video-prompts) | No explicit license found | Real-estate use cases and property accuracy considerations | Includes promotional material. Do not import its prompt text as a redistributable library without permission. |
| [GitHub video-prompt topic](https://github.com/topics/video-prompt) | Per-repository | Discovery | Ranking and stars do not establish rights, supported capabilities or measured quality. |

Exact reviewed commit hashes and license observations are in
[the source manifest](video-prompt-sources-20260924.json). A later source update
requires another review; these repositories are not runtime dependencies.

## Verified model distinctions

ByteDance describes Seedance 2.5 as a multimodal video model with up to 30 seconds
per generation and targeted editing. Those capabilities support exploring the
user's idea; they do not guarantee exact performance preservation, frame timing,
accurate unseen property geometry or a usable result on this account.
[Official model page](https://seed.bytedance.com/en/seedance2_5).

Current BytePlus task documentation distinguishes **reference generation** from
**editing a reference video**. For the documented 2.5 edit path, the task uses a
reference video, `omni_reference_task_type: "edit"`, `ratio: "adaptive"`, and
`duration: -1`. It approximately matches the input duration; specifying a numeric
length is not the documented edit setting. Model/endpoint and mode capabilities
must be checked together. Prompt prose does not change an endpoint's parameters.
[Create-task API](https://docs.byteplus.com/en/docs/ModelArk/1520757),
[video editing](https://docs.byteplus.com/en/docs/ModelArk/2607688).

Reference labels must map to the files actually uploaded in the relevant order.
A literal `@Video1` in a copied prompt does not upload or attach anything. A
character reference should have a separate role from performance, camera and
property references. Time blocks express requested beats, not deterministic edit
instructions. [Official prompt guide](https://docs.byteplus.com/en/docs/ModelArk/2607689).

The API's `generate_audio` parameter controls generated sound. The reviewed
current task documentation does not provide an `original_audio` parameter. When
exact narration matters, preserve the real recording in Rendprop's editor and
compare any generated picture/lip timing against it. Do not invent an upstream
voice-preservation flag. Genjutsu likewise has no voice identity parameter in its
verified [model schema](https://docs.higgsfield.ai/docs/models/genjutsu/motion-transfer.md).

This change does **not** add a Seedance 2.5 execution adapter, entitlement, price,
quality claim or account activation. Model controls remain preparation notes.
The user's instruction is to keep Presenter generation disabled.

## Product decisions

The library has ten original recipes spanning real-footage editing, agent
performance, restrained property animation and explicitly experimental concepts.
Each keeps a scene description, source/reference roles, a contiguous shot plan,
camera direction, audio intent, consistency requirements and a deliberate ending.
Settings and review notes are displayed/exported separately from prompt text.

The multicamera recipe is labeled experimental: a new angle inferred from a
single take may invent part of the room. Real listing footage remains the source
of truth. A property-preservation instruction is a request to the model, not a
claim that geometry has been verified.

Users can paste their own prompts, retain a source link, save versions, and record
whether a result is untested, needs work or was usable in their own test. That
feedback is explicitly personal feedback, not Rendprop certification. Personal
collections sync through existing user/workspace-scoped documents, with revision
conflicts and uncertain-save recovery. No prompt is executed merely by saving it.

For a future quality trial, keep the source and model/version constant, change
one prompt variable, and retain all outcomes including failures. Evaluate property
accuracy, identity, gesture continuity, speech timing, first/last frames, visible
artifacts and actual spend. Promote a recipe only after a reproducible comparison;
do not use repository popularity or a single attractive sample as the criterion.
