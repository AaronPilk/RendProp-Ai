# Deploy — rendprop-tour-host (Cloudflare Worker)

The Worker that serves the public share links: `/f/:slug` (scroll-scrub player) and
`/a/:handle` (portfolio grid). Deploy from this directory.

## 0. Prereqs (once)

```bash
cd services/edge/tour-host
npm install                  # wrangler + typescript + workers-types (devDeps only)
npx wrangler login           # opens browser; authorizes your Cloudflare account
```

Upstream must already be live: the Supabase functions `tours`, `leads`, `beacon`,
`portfolio` deployed with `--no-verify-jwt` (done by `services/supabase/deploy-functions.sh`).

## 1. Set the two vars

**`SUPABASE_FUNCTIONS_URL`** — edit `wrangler.toml` `[vars]`:

```toml
SUPABASE_FUNCTIONS_URL = "https://<project-ref>.supabase.co/functions/v1"
```

**`SUPABASE_ANON_KEY`** — set as a secret (preferred over committing it):

```bash
npx wrangler secret put SUPABASE_ANON_KEY
# paste the anon/publishable key from Supabase → Settings → API
```

(It's a public-by-design key — RLS enforces access — but keeping it out of git is
still the cleaner habit. **Important:** never add `SUPABASE_ANON_KEY` under `[vars]`
in `wrangler.toml` — a plaintext var with the same name shadows the secret on every
deploy, and a placeholder value would 401 every upstream call. It stays commented
out there on purpose.)

Optional: `TOUR_CACHE_TTL` (seconds of edge cache for rendered HTML; default 60, `0` off).

## 2. First deploy → test on workers.dev

The custom routes in `wrangler.toml` need the `rendprop.com` zone active on your
account. To test **before** DNS is ready, deploy without routes:

```bash
npx wrangler deploy          # if the zone isn't on this account yet, temporarily
                             # comment out the `routes = [...]` block first
```

`workers_dev = true` is set, so the Worker is immediately live at:

```
https://rendprop-tour-host.<your-subdomain>.workers.dev
```

Smoke test (use a real published slug from the app's share sheet):

```bash
curl -s https://rendprop-tour-host.<subdomain>.workers.dev/healthz          # → ok
curl -sI https://rendprop-tour-host.<subdomain>.workers.dev/f/<slug>        # → 200, text/html
open  https://rendprop-tour-host.<subdomain>.workers.dev/f/<slug>          # scroll-scrub plays
open  https://rendprop-tour-host.<subdomain>.workers.dev/a/<handle>        # portfolio grid
```

Checklist on the player page: loader hits 100% and fades, scrolling scrubs the
video frame-accurately (mp4 scrub source — no keyframe snapping), chapter dots
jump on tap, the lead form submits (row appears in `leads`), and a `metering`
row for today shows the view.

## 3. Production routes on rendprop.com

Once `rendprop.com` is an active zone on this Cloudflare account (nameservers on
Cloudflare), keep/restore the routes block in `wrangler.toml`:

```toml
routes = [
  { pattern = "rendprop.com/f/*", zone_name = "rendprop.com" },
  { pattern = "rendprop.com/a/*", zone_name = "rendprop.com" },
]
```

and redeploy:

```bash
npx wrangler deploy
```

The Worker owns only `/f/*` and `/a/*`; the marketing site keeps everything else.

## 4. Day-2

```bash
npm run typecheck            # tsc --noEmit (keep green before every deploy)
npm run dev                  # local dev at http://localhost:8787/f/<slug>
npm run tail                 # live logs (wrangler tail)
npx wrangler deployments list
```

For `npm run dev`, secrets aren't pulled from Cloudflare — put the key in a local
`.dev.vars` file (already gitignored):

```
SUPABASE_ANON_KEY=eyJ...
```

Republished tours show up within `TOUR_CACHE_TTL` (default 60 s) — no purge needed.
