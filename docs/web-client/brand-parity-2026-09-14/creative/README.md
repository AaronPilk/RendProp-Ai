# Creative and business cards — 14 September 2026

> **Historical evidence: 14 September 2026.** This report preserves the behavior,
> versions, test counts and open checks observed at that release. For the current
> Create-first navigation, property edit/chat sync, prompt library and deployment
> state, read [the 24 September production record](../../../handoff/CODEX-STUDIO-LIVE-20260924.md). Guided prompt
> enhancement is live; optional LLM enhancement and Presenter generation remain
> disabled. Older screenshots, TestFlight references and local-only boundaries
> below are not a current release checklist.

The same native feature names now open the matching property tool directly. AI Photo Studio presents edit modes before photos, uses the native plain-language mode labels, exposes all four staging styles, and offers photo animation. Aerial opens the aerial controls; voiceover, scripts, shot plans, on-camera cutaways, room chapters and Ask Rendprop retain their existing generation and disclosure contracts. Open Reel Studio carries the selected property.

A feature-card request selects its tool once, only for its intended property. It does not start an AI generation or reset an unsaved script, source selection or staging settings. Batch photo previews remain mounted when switching creative tools, and single-photo actions cannot overlap an active batch. Save or download unsaved AI previews before leaving their property.

Agent card, Leads, Team, Account and other business cards open their matching section. Visited business forms remain mounted across section navigation. Account refresh updates clean forms while preserving unsaved agent details and notification choices; invite text remains unsent until the existing explicit submit action.

Validation:

- `creative-receipt.json`: 9 real-component browser groups, including original/disclosure attachment, recovery after phone edits, scripts/shot plans, narration, generated video review, chapters, coach, explicit batch generation and save without re-generation, and a 390px layout.
- `business-receipt.json`: 7 browser groups covering leads, brand, notifications, guarded deletion, explicit invite opt-in, role controls and a 390px layout.
- `feature-entry-receipt.json`: 5 browser groups covering direct card selection, once-only requests, property scoping, no writes from navigation, and unsaved business-form retention through card navigation and account refresh.
- 26 focused creative/transcript/business unit checks passed. Whole-app TypeScript checking passed at this handoff; the root release check covers subsequent integration changes.

The browser suites use real React components and isolated API/media fixtures. They make no paid provider calls, send no live invitation mail, and alter no customer data. Batch engine tests and final connected-dashboard verification are recorded separately by their owners.
