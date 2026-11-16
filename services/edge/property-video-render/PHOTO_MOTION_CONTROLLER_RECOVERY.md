# Photo Motion controller source candidate

The active controller source now includes the Photo Motion and aerial task
paths, a separate `PhotoMotionCPU` Durable Object, and concurrent scheduled
reads of the video and photo-quality queues. The recovered source inputs were
checked against a retained production controller bundle before this public
candidate was prepared. This candidate is **not** byte-identical to that
bundle: deployment-specific held-job and Durable Object identifiers have been
removed from source, and image admission is restricted to the Photo Motion
image name. It therefore requires a new controller hash and qualification.

`wrangler.jsonc` binds the existing AI and Photo Motion container image digests
to separate CPU classes. `ENABLED` remains `false`. The Photo Motion image URI
and renderer source hash are pinned, while
`CPU_PHOTO_MOTION_CONTROLLER_SHA256` and
`CPU_PHOTO_MOTION_SLOT_NAME` are intentionally unset. The latter must identify
the existing private Photo Motion Durable Object instance; the controller
refuses video queue work before a queue request when that setting is absent.
The controller hash must be generated from the final qualified bundle and
recorded with the exact producer tuple before activation.

An optional historical terminal-reconciliation exception now requires all
four deployment-supplied `CPU_PHOTO_MOTION_HELD_COMPAT_*` settings: job ID,
image URI, controller SHA-256, and renderer SHA-256. Partial or malformed
settings fail closed. The values belong in the private deployment environment,
not this repository. Their absence leaves the historical exception disabled.

Local verification covers TypeScript typecheck, Wrangler configuration type
generation, validated identifiers, immutable image bindings, and a compiled
scheduled handler with inert authority and Durable Object doubles. These
checks do not establish production behavior. Before enabling the worker,
qualify the new controller bundle and exact producer tuple, reconcile the
existing private slot and any held work, verify backend acceptance, then run
the relevant device and runtime checks. No deployment is part of this source
candidate.
