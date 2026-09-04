# SECRETS ROTATION — services/pipeline (audit F-G-12)

**Status of the finding.** The audit reported that `services/pipeline/.env`, holding LIVE
PRODUCTION credentials, had been copied into the audit snapshot and therefore into every
reviewer's working tree. Verified on branch `p12-G` (2026-09-04):

| check | result |
|---|---|
| `services/pipeline/.env` present in the working tree | **no** — absent (also absent in `wt-A/BD/C/E/H` and `rendprop/`) |
| `services/worker/.env` present in the working tree | no |
| `.env` ignored by git | yes — `.gitignore` lines `.env`, `.env.*`, `!.env.example` (unanchored, so they match at every depth) |
| any `.env` blob in git history (`git log --all` × `ls-tree -r`) | **none** |
| provider-key prefixes (`sk-ant-`, `AQ.A…`, service-role JWT) in git history | **none** |
| `.env` excluded from the container image | yes — `services/.dockerignore` |
| tracked files matching `env` | only `services/pipeline/.env.example`, `services/worker/.env.example` (key NAMES, empty values) |

One JWT *is* committed, at `apps/ios/Rendprop/Config.swift:31`, in every commit. Its decoded
claims are `role=anon`, `iss=supabase`, `ref=ymgqpbnjpztwjsyvceld`. An **anon** key is
designed to be shipped inside a client and is not a privileged credential — it is not a
leak. It is listed below only because rotating the project's JWT secret invalidates it too.
That file is owned by the iOS area, not by this one.

**So: nothing to purge from git history.** The exposure the audit described was the *file
copy* into a shared snapshot, not a commit. That copy already happened, so the credentials
that were in that file must still be treated as compromised and rotated.

---

## 1. Rotate these five credentials

No values appear in this file, in any commit message, or in any log line. Each row says
what to rotate, where it is issued, and every place the new value has to be installed.

| # | Credential (env var name) | Issuer / rotation console | Where it is READ in this repo | Where the new value must be INSTALLED |
|---|---|---|---|---|
| 1 | `SUPABASE_SERVICE_ROLE_KEY` | Supabase dashboard → project `ymgqpbnjpztwjsyvceld` → Settings → API → *Rotate JWT secret / service_role key* | `services/worker/settings.py`, `services/worker/db.py` (PostgREST `apikey` + `Authorization`), `services/pipeline/cost_ledger.py`, `services/pipeline/cli.py`, `services/supabase/functions/_shared/supabase.ts` | Edge Function secrets (`services/supabase/set-secrets.sh`), the render-worker process env (Modal secret / Cloud Run env / `docker --env-file`), any operator's local `services/worker/.env` and `services/pipeline/.env` |
| 2 | `GEMINI_API_KEY` | Google AI Studio → API keys (delete the old key, don't just add one) | `services/pipeline/config.py`, `services/pipeline/providers/gemini.py`, `services/supabase/functions/ai-photo/index.ts` | Edge Function secrets, render-worker env, local `.env` |
| 3 | `FAL_KEY` | fal.ai dashboard → Keys (revoke, then create) | `services/pipeline/config.py`, `services/pipeline/providers/fal_client.py`, `services/supabase/functions/ai-video/index.ts` | Edge Function secrets, render-worker env, local `.env` |
| 4 | `ANTHROPIC_API_KEY` | Anthropic Console → API keys (revoke, then create) | `services/pipeline/config.py`, `services/pipeline/providers/anthropic_qc.py` | Edge Function secrets, render-worker env, local `.env` |
| 5 | `KIE_API_KEY` | KIE dashboard → API keys | `services/pipeline/config.py` (route exists; `router._restage_primary` raises for `kie`, so it is not called today) | Edge Function secrets, render-worker env, local `.env` |

**Order matters.** Rotate #1 last, or in a maintenance window: replacing the service-role
key immediately invalidates every deployed edge function and any in-flight worker until the
new value is installed everywhere. Providers #2–#5 can be rotated independently; a running
worker picks up the new value on its next restart.

### Also present in the same `.env` (rotate if the file left the machine)

| env var | issuer | notes |
|---|---|---|
| `CLOUDFLARE_STREAM_TOKEN` | Cloudflare dashboard → My Profile → API Tokens | read by `services/worker/stream.py`; Stream is optional — the tour falls back to the R2 mp4 |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | Cloudflare dashboard → R2 → Manage API tokens | read by `services/worker/r2.py`, `services/supabase/functions/_shared/r2.ts`; grants read/write on `rendprop-uploads` + `rendprop-renders` |
| `SUPABASE_ANON_KEY` (the committed one, iOS `Config.swift`) | invalidated automatically when the JWT secret is rotated in step #1 | public by design; after rotating the JWT secret the iOS build must ship the new anon key or every app request 401s |

### After rotating

1. Redeploy the edge functions so they pick up the new secrets.
2. Restart / redeploy the render worker.
3. Check each provider dashboard for usage on the OLD key after the cutover — any traffic
   means a copy is still live somewhere.
4. Review Supabase logs for service-role calls from unexpected IPs during the exposure
   window.

---

## 2. Git history: nothing to purge here — but this is the command if that ever changes

The scan above found no `.env` blob and no provider-key prefix in any reachable commit on
this branch, so **history rewriting is neither needed nor performed by this change**.
Deleting a file from the working tree would *not* purge it from history, so if a future scan
does find one, the owner (not this worktree) must run one of the following on a fresh clone,
with every collaborator warned first:

```bash
# git-filter-repo (recommended; pip install git-filter-repo)
git clone --mirror git@github.com:<org>/<repo>.git rendprop-purge.git
cd rendprop-purge.git
git filter-repo --invert-paths \
  --path services/pipeline/.env \
  --path services/worker/.env \
  --path-glob '**/.env'
git push --force --all
git push --force --tags
```

```bash
# BFG alternative
java -jar bfg.jar --delete-files '.env' rendprop-purge.git
cd rendprop-purge.git && git reflog expire --expire=now --all && git gc --prune=now --aggressive
git push --force --all && git push --force --tags
```

Afterwards: every collaborator re-clones (a rebase over rewritten history re-introduces the
blob), and the forge's cached views (GitHub PR diffs, forks) are asked to be purged — the
blob stays reachable through them until support removes it. **Rewriting history does not
un-leak a secret; rotation does. Rotate first, rewrite second.**

---

## 3. Keeping it out from now on

- `.gitignore` already ignores `.env` / `.env.*` at every depth and whitelists `.env.example`.
- Never `tar`/`zip` this tree without `--exclude='.env' --exclude='*.env'` when sharing a snapshot.
- Prefer a keychain / `1Password-CLI` + `direnv` shim over an on-disk `.env` for local dev.
- Add a `gitleaks` (or `git-secrets`) pre-commit hook — cheap, catches the next one.
- The worker and the pipeline both read their guards from the process env first; in
  production nothing should read a `.env` file at all.
