# Shared agent photo contract audit

There is no existing native-to-Studio headshot upload contract to reuse without backend and native changes.

- `apps/ios/Rendprop/Screens/SettingsView.swift`, `AgentCard.saveHeadshot`: resizes the image to at most 512 pixels and writes a JPEG into the iPhone Documents directory. `AgentCard.headshotURL(for:)` is scoped by business type, not a cloud storage key.
- The native Agent card editor explicitly explains that this photo appears in the app and in-app previews, while hosted tour pages show initials. `AgentCard.fieldNames` and `acceptCloud` transfer contact and social text fields; they do not upload or download a portrait.
- `services/supabase/functions/me/index.ts`, `handleBrandPatch`: accepts `headshot_url` and `avatar_url` as string fields, with a 300-character field limit. It does not accept image bytes or provide a photo upload reservation.
- `services/supabase/functions/uploads/index.ts`, `CreateBody` and `uploadSpec`: supports `capture`, `render`, `original` and `gallery`, all attached to a property. These are not account portrait assets.

Uploading an agent portrait as a property's gallery asset would attach its lifetime and cleanup to that property, and the iPhone would still never read it. No such workaround or misleading file picker was added. The Studio Agent card introduction was corrected to promise shared contact details only.

A complete photo picker needs a shared account or workspace portrait reservation/completion contract, safe photo validation and cleanup, and a native read/write adapter. This audit performed no live account changes, uploads, paid calls or outgoing messages.
